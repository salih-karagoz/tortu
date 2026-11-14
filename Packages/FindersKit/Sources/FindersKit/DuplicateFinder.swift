import CryptoKit
import Foundation
import ScanCore

/// Files with identical contents.
public struct DuplicateGroup: Sendable, Identifiable, Hashable {
    public let digest: String
    public let files: [FoundFile]

    public var id: String { digest }

    /// What removing all but one copy would return.
    ///
    /// This is an upper bound, not a promise. On APFS a file can be a clone of
    /// another: identical contents, distinct inodes, and the same blocks on
    /// disk. No walk can see that, so a group of clones reads as a saving that
    /// deleting them will not produce. Tortu reports the measured result after
    /// the fact rather than standing behind this number.
    public var reclaimableUpperBound: ByteCount {
        guard let first = files.first, files.count > 1 else { return .zero }
        return ByteCount(first.size.rawValue * Int64(files.count - 1))
    }

    public init(digest: String, files: [FoundFile]) {
        self.digest = digest
        self.files = files.sorted { $0.path < $1.path }
    }
}

/// Finds files whose contents match.
///
/// The work is staged so that almost nothing gets read: files are grouped by
/// size, then hard links are collapsed, then only the first 64 KB is hashed,
/// and only groups that still collide are read in full. On a disk of ordinary
/// files this reaches the answer having read a tiny fraction of it.
public struct DuplicateFinder: Sendable {
    public struct Options: Sendable {
        /// Below this, duplicates are not worth a user's attention and the
        /// hashing cost is all of the expense.
        public var minimumSize: ByteCount
        public var prefixBytes: Int

        public init(
            minimumSize: ByteCount = ByteCount(1_000_000),
            prefixBytes: Int = 64 * 1024
        ) {
            self.minimumSize = minimumSize
            self.prefixBytes = prefixBytes
        }

        public static let `default` = Options()
    }

    private let scanner: DirectoryScanner
    private let options: Options

    public init(scanner: DirectoryScanner = DirectoryScanner(), options: Options = .default) {
        self.scanner = scanner
        self.options = options
    }

    /// Progress covers the walk only. The hashing that follows reads a tiny
    /// fraction of what was walked and cannot be counted out in advance, so
    /// nothing here pretends to measure it.
    public func find(
        under root: String,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> [DuplicateGroup] {
        let result = try await scanner.scan(rootPath: root, onProgress: onProgress)
        return findDuplicates(in: result.root)
    }

    func findDuplicates(in root: ScanNode) -> [DuplicateGroup] {
        let candidates = root.flattenedFiles()
            .filter { $0.totalSize >= options.minimumSize }

        // Files of different sizes cannot have the same contents, and this
        // costs nothing to check.
        let bySize = Dictionary(grouping: candidates, by: \.totalSize)

        var groups: [DuplicateGroup] = []
        for (size, nodes) in bySize where nodes.count > 1 {
            let distinct = collapsingHardLinks(nodes)
            guard distinct.count > 1 else { continue }
            groups.append(contentsOf: hashGroups(distinct, size: size))
        }
        return groups.sorted { $0.reclaimableUpperBound > $1.reclaimableUpperBound }
    }

    /// Drops every name after the first that points at the same storage.
    ///
    /// Two hard links are one file with two names. Offering them as duplicates
    /// would promise space that deleting one of them cannot return, which is
    /// the single most common way a duplicate finder misleads people.
    private func collapsingHardLinks(_ nodes: [ScanNode]) -> [ScanNode] {
        var seen: Set<StorageIdentity> = []
        var distinct: [ScanNode] = []
        for node in nodes {
            var info = stat()
            guard lstat(node.path, &info) == 0 else { continue }
            let identity = StorageIdentity(deviceID: info.st_dev, fileID: UInt64(info.st_ino))
            if seen.insert(identity).inserted {
                distinct.append(node)
            }
        }
        return distinct
    }

    /// When each copy was last written.
    ///
    /// `ScanNode` does not carry a date, and the screen offers to keep the
    /// newest copy, so without this every copy claimed the same instant and
    /// "newest" picked an arbitrary one — frequently selecting the genuinely
    /// newest file for deletion. Only files that already matched on size and
    /// on a full content hash reach this, so the extra `lstat` is paid on a
    /// handful of paths rather than on everything scanned.
    private func modificationDate(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    private func hashGroups(_ nodes: [ScanNode], size: ByteCount) -> [DuplicateGroup] {
        var byPrefix: [String: [ScanNode]] = [:]
        for node in nodes {
            guard let digest = hash(node.path, limit: options.prefixBytes) else { continue }
            byPrefix[digest, default: []].append(node)
        }

        var groups: [DuplicateGroup] = []
        for (_, sharing) in byPrefix where sharing.count > 1 {
            // A matching prefix is not a match. Only these get read in full.
            var byContent: [String: [ScanNode]] = [:]
            for node in sharing {
                guard let digest = hash(node.path, limit: nil) else { continue }
                byContent[digest, default: []].append(node)
            }
            for (digest, identical) in byContent where identical.count > 1 {
                groups.append(
                    DuplicateGroup(
                        digest: digest,
                        files: identical.map {
                            FoundFile(
                                path: $0.path,
                                size: size,
                                modified: modificationDate($0.path) ?? .distantPast
                            )
                        }
                    )
                )
            }
        }
        return groups
    }

    private func hash(_ path: String, limit: Int?) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        if let limit {
            guard let data = try? handle.read(upToCount: limit) else { return nil }
            hasher.update(data: data)
        } else {
            // Read in chunks so a very large file does not have to fit in memory.
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
