import Foundation

public struct ScanOptions: Sendable {
    /// Directory reads in flight at once.
    public var maxConcurrentDirectories: Int
    /// How often progress is reported, in directories.
    public var progressInterval: Int
    /// Stop descending below this depth. Zero means no limit.
    public var maxDepth: Int

    public init(
        maxConcurrentDirectories: Int = 8,
        progressInterval: Int = 64,
        maxDepth: Int = 0
    ) {
        self.maxConcurrentDirectories = maxConcurrentDirectories
        self.progressInterval = progressInterval
        self.maxDepth = maxDepth
    }

    public static let `default` = ScanOptions()
}

/// Walks a directory tree and measures it.
///
/// Three rules decide what the result means, and all three came from getting
/// them wrong by hand first:
///
/// 1. The walk stops at filesystem boundaries, decided by `st_dev` rather than
///    by the mount table.
/// 2. Sizes come from allocated blocks, not from what a file claims to be.
/// 3. Storage already counted under another path is not counted again.
public struct DirectoryScanner: Sendable {
    private let reader: any DirectoryReading
    private let options: ScanOptions

    public init(
        reader: any DirectoryReading = FastDirectoryReader(),
        options: ScanOptions = .default
    ) {
        self.reader = reader
        self.options = options
    }

    public func scan(
        root: URL,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        try await scan(rootPath: root.path(percentEncoded: false), onProgress: onProgress)
    }

    public func scan(
        rootPath: String,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        let started = ContinuousClock.now
        let boundary = try ScanBoundary(rootPath: rootPath)
        let state = ScanState()
        let limiter = ConcurrencyLimiter(limit: options.maxConcurrentDirectories)

        var rootInfo = stat()
        guard lstat(rootPath, &rootInfo) == 0 else {
            throw ScanError.pathUnreadable(path: rootPath, code: errno)
        }

        let node = await walk(
            path: rootPath,
            name: URL(filePath: rootPath).lastPathComponent,
            ownSize: ByteCount(blocks: Int64(rootInfo.st_blocks), blockSize: 512),
            depth: 0,
            boundary: boundary,
            state: state,
            limiter: limiter,
            onProgress: onProgress
        )

        let elapsed = ContinuousClock.now - started
        let (directories, entries, hardLinks, boundaries, unreadable) = await state.summary
        return ScanResult(
            root: node,
            directoriesVisited: directories,
            entriesSeen: entries,
            hardLinksSkipped: hardLinks,
            boundariesStopped: boundaries,
            unreadablePaths: unreadable,
            duration: elapsed
        )
    }

    private func walk(
        path: String,
        name: String,
        ownSize: ByteCount,
        depth: Int,
        boundary: ScanBoundary,
        state: ScanState,
        limiter: ConcurrencyLimiter,
        onProgress: (@Sendable (ScanProgress) -> Void)?
    ) async -> ScanNode {
        if Task.isCancelled {
            return ScanNode(
                path: path, name: name, kind: .directory,
                ownSize: ownSize, totalSize: ownSize
            )
        }

        if options.maxDepth > 0, depth >= options.maxDepth {
            return ScanNode(
                path: path, name: name, kind: .directory,
                ownSize: ownSize, totalSize: ownSize
            )
        }

        await limiter.acquire()
        let rawEntries: [DirectoryEntry]
        do {
            rawEntries = try reader.entries(at: path)
        } catch {
            await limiter.release()
            await state.noteUnreadable(path)
            return ScanNode(
                path: path, name: name, kind: .directory,
                ownSize: ownSize, totalSize: ownSize
            )
        }
        await limiter.release()

        await state.noteDirectoryVisited()
        let entries = await state.account(rawEntries)

        if let onProgress {
            let (directories, seen, bytes) = await state.snapshot
            if directories % max(1, options.progressInterval) == 0 {
                onProgress(
                    ScanProgress(
                        directoriesVisited: directories,
                        entriesSeen: seen,
                        bytesAccounted: bytes,
                        currentPath: path
                    )
                )
            }
        }

        var leaves: [ScanNode] = []
        var subdirectories: [(entry: DirectoryEntry, ownSize: ByteCount)] = []
        var fileCount = 0
        var total = ownSize

        for accounted in entries {
            let entry = accounted.entry
            let childPath = path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name

            switch entry.kind {
            case .directory:
                // The device reported by the parent's listing cannot be
                // trusted here. `getattrlistbulk` reads the directory's own
                // records and so reports the covered directory's filesystem,
                // not the one mounted over it; `/dev` comes back as the root
                // volume. One `lstat` per directory resolves the mount, and
                // the same call supplies the directory's own allocated size,
                // which bulk attributes do not return for directories.
                var info = stat()
                guard lstat(childPath, &info) == 0 else {
                    await state.noteUnreadable(childPath)
                    continue
                }
                if info.st_dev != boundary.rootDeviceID {
                    await state.noteBoundary(childPath)
                    leaves.append(
                        ScanNode(
                            path: childPath, name: entry.name, kind: .directory,
                            ownSize: .zero, totalSize: .zero, isBoundary: true
                        )
                    )
                    continue
                }
                subdirectories.append(
                    (entry: entry, ownSize: ByteCount(blocks: Int64(info.st_blocks), blockSize: 512))
                )

            case .file, .symlink, .other:
                fileCount += 1
                let counted = accounted.sharesStorage ? ByteCount.zero : entry.allocatedSize
                total += counted
                leaves.append(
                    ScanNode(
                        path: childPath, name: entry.name, kind: entry.kind,
                        ownSize: counted, totalSize: counted,
                        fileCount: 1, sharesStorage: accounted.sharesStorage
                    )
                )
            }
        }

        var childNodes = leaves
        if !subdirectories.isEmpty {
            let scanned = await withTaskGroup(of: ScanNode.self) { group in
                for subdirectory in subdirectories {
                    let entry = subdirectory.entry
                    let ownSize = subdirectory.ownSize
                    let childPath = path.hasSuffix("/")
                        ? path + entry.name : path + "/" + entry.name
                    group.addTask {
                        await walk(
                            path: childPath,
                            name: entry.name,
                            ownSize: ownSize,
                            depth: depth + 1,
                            boundary: boundary,
                            state: state,
                            limiter: limiter,
                            onProgress: onProgress
                        )
                    }
                }
                var collected: [ScanNode] = []
                for await node in group { collected.append(node) }
                return collected
            }
            for node in scanned {
                total += node.totalSize
                fileCount += node.fileCount
            }
            childNodes.append(contentsOf: scanned)
        }

        return ScanNode(
            path: path, name: name, kind: .directory,
            ownSize: ownSize, totalSize: total,
            children: childNodes.sorted { $0.totalSize > $1.totalSize },
            fileCount: fileCount
        )
    }
}
