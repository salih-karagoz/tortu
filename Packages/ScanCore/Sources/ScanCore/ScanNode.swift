import Foundation

/// One node of a completed scan.
public struct ScanNode: Sendable, Identifiable, Hashable {
    public let path: String
    public let name: String
    public let kind: EntryKind

    /// Space this entry itself occupies, from allocated blocks.
    public let ownSize: ByteCount

    /// `ownSize` plus everything beneath it.
    public let totalSize: ByteCount

    public let children: [ScanNode]

    /// True when the walk stopped here because the entry sits on a different
    /// filesystem. Its size is reported as zero rather than guessed at.
    public let isBoundary: Bool

    /// Files at or below this node, directories excluded.
    public let fileCount: Int

    /// True when this entry is another name for storage already counted
    /// elsewhere in the scan, so its size is reported as zero here. The path
    /// is still listed, because hiding it would make the tree look wrong to
    /// anyone comparing it with Finder.
    public let sharesStorage: Bool

    public var id: String { path }

    public var isDirectory: Bool { kind == .directory }

    public init(
        path: String,
        name: String,
        kind: EntryKind,
        ownSize: ByteCount,
        totalSize: ByteCount,
        children: [ScanNode] = [],
        isBoundary: Bool = false,
        fileCount: Int = 0,
        sharesStorage: Bool = false
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.ownSize = ownSize
        self.totalSize = totalSize
        self.children = children
        self.isBoundary = isBoundary
        self.fileCount = fileCount
        self.sharesStorage = sharesStorage
    }

    /// Children ordered largest first, which is the order a disk tool is read
    /// in. The scanner sorts once when it builds the node, so this is already
    /// in order and an outline can expand without re-sorting.
    public var childrenBySize: [ScanNode] { children }

    /// `nil` for a leaf, so an outline does not offer a disclosure arrow on
    /// something that cannot open.
    public var outlineChildren: [ScanNode]? {
        children.isEmpty ? nil : children
    }

    /// Every file at or below this node, directories and mount boundaries
    /// excluded. A node marked `sharesStorage` is left out as well: it is
    /// another name for storage already listed, and a finder that offered both
    /// would promise space that removing one of them cannot return.
    public func flattenedFiles() -> [ScanNode] {
        var collected: [ScanNode] = []
        var stack: [ScanNode] = [self]
        while let node = stack.popLast() {
            if node.isBoundary { continue }
            if node.kind == .file, !node.sharesStorage {
                collected.append(node)
            }
            stack.append(contentsOf: node.children)
        }
        return collected
    }
}

public struct ScanProgress: Sendable {
    public let directoriesVisited: Int
    public let entriesSeen: Int
    public let bytesAccounted: ByteCount
    public let currentPath: String
}

public struct ScanResult: Sendable {
    public let root: ScanNode
    public let directoriesVisited: Int
    public let entriesSeen: Int

    /// Entries whose storage had already been counted under another path,
    /// which is how hard links avoid being added twice.
    public let hardLinksSkipped: Int

    /// Paths where the walk stopped at a filesystem boundary.
    public let boundariesStopped: [String]

    /// Paths that could not be read, usually for want of permission. They are
    /// listed rather than silently dropped, because a scan that quietly
    /// skipped half a tree would under-report and look like good news.
    public let unreadablePaths: [String]

    public let duration: Duration
}
