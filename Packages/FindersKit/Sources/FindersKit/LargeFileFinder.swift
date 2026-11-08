import Foundation
import ScanCore

public struct FoundFile: Sendable, Hashable, Identifiable {
    public let path: String
    public let size: ByteCount
    public let modified: Date

    public var id: String { path }

    public init(path: String, size: ByteCount, modified: Date) {
        self.path = path
        self.size = size
        self.modified = modified
    }

    public var name: String { (path as NSString).lastPathComponent }
}

public struct FindCriteria: Sendable {
    public var minimumSize: ByteCount
    /// Only files untouched for at least this long. `nil` accepts any age.
    public var untouchedFor: TimeInterval?
    public var limit: Int

    public init(
        minimumSize: ByteCount = ByteCount(100_000_000),
        untouchedFor: TimeInterval? = nil,
        limit: Int = 200
    ) {
        self.minimumSize = minimumSize
        self.untouchedFor = untouchedFor
        self.limit = limit
    }
}

/// Finds the biggest and oldest files under a root.
///
/// Nothing here is a cleanup rule, and none of it is ever selected for the
/// user. A large file is not junk; it is usually something they made. The
/// finder's job is to show where the space went and let them decide.
public struct LargeFileFinder: Sendable {
    private let scanner: DirectoryScanner
    private let now: @Sendable () -> Date

    public init(
        scanner: DirectoryScanner = DirectoryScanner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scanner = scanner
        self.now = now
    }

    /// The walk is nearly all of the time this takes, so its progress is
    /// passed straight through: the screen reports the directory tree being
    /// read, not an invented estimate of the selection that follows it.
    public func find(
        under root: String,
        criteria: FindCriteria,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> [FoundFile] {
        let result = try await scanner.scan(rootPath: root, onProgress: onProgress)
        return select(from: result.root, criteria: criteria)
    }

    func select(from root: ScanNode, criteria: FindCriteria) -> [FoundFile] {
        let cutoff = criteria.untouchedFor.map { now().addingTimeInterval(-$0) }
        var files: [FoundFile] = []

        for node in root.flattenedFiles() where node.totalSize >= criteria.minimumSize {
            let modified = modificationDate(of: node.path)
            if let cutoff, modified >= cutoff { continue }
            files.append(FoundFile(path: node.path, size: node.totalSize, modified: modified))
        }

        return files.sorted { $0.size > $1.size }.prefix(criteria.limit).map { $0 }
    }

    private func modificationDate(of path: String) -> Date {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }
}
