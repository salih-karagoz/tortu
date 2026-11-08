import Foundation

/// Removes a path. Behind a protocol so that a test can run a whole cleanup
/// without putting real files at risk.
public protocol FileRemoving: Sendable {
    func remove(at path: String) throws
    func trash(at path: String) throws
}

/// The real thing.
///
/// A fresh `FileManager` is created per call rather than stored, because
/// `FileManager` is not `Sendable` and sharing one across the concurrent parts
/// of a cleanup is exactly the kind of thing strict concurrency exists to stop.
public struct SystemFileRemover: FileRemoving {
    public init() {}

    public func remove(at path: String) throws {
        try FileManager().removeItem(at: URL(filePath: path))
    }

    public func trash(at path: String) throws {
        try FileManager().trashItem(at: URL(filePath: path), resultingItemURL: nil)
    }
}

/// Records what would have been removed and touches nothing.
public final class RecordingFileRemover: FileRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private var _removed: [String] = []
    private var _trashed: [String] = []
    private let failingPaths: Set<String>

    public init(failingPaths: Set<String> = []) {
        self.failingPaths = failingPaths
    }

    public var removed: [String] {
        lock.lock(); defer { lock.unlock() }
        return _removed
    }

    public var trashed: [String] {
        lock.lock(); defer { lock.unlock() }
        return _trashed
    }

    public func remove(at path: String) throws {
        if failingPaths.contains(path) {
            throw CocoaError(.fileNoSuchFile)
        }
        lock.lock(); defer { lock.unlock() }
        _removed.append(path)
    }

    public func trash(at path: String) throws {
        if failingPaths.contains(path) {
            throw CocoaError(.fileNoSuchFile)
        }
        lock.lock(); defer { lock.unlock() }
        _trashed.append(path)
    }
}
