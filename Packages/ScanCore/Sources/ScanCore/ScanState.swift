import Foundation

/// A directory entry plus whether its bytes had already been counted.
struct AccountedEntry: Sendable {
    let entry: DirectoryEntry
    let sharesStorage: Bool
}

/// Mutable bookkeeping shared by every branch of a walk.
///
/// Entries are submitted a directory at a time rather than one by one, so a
/// tree with a million files costs one hop per directory instead of one per
/// file.
actor ScanState {
    private var seenStorage: Set<StorageIdentity> = []
    private(set) var directoriesVisited = 0
    private(set) var entriesSeen = 0
    private(set) var hardLinksSkipped = 0
    private(set) var bytesAccounted = ByteCount.zero
    private(set) var boundariesStopped: [String] = []
    private(set) var unreadablePaths: [String] = []

    /// Returns the entries whose storage has not been counted yet.
    ///
    /// Two hard links to one file share a device and inode, so the second one
    /// contributes nothing. APFS clones are a different matter: they share
    /// blocks on disk but have distinct inodes, so no walk can tell they
    /// overlap. That is one of the reasons a cleanup reports what the volume
    /// actually returned rather than what the scan predicted.
    func account(_ entries: [DirectoryEntry]) -> [AccountedEntry] {
        var accounted: [AccountedEntry] = []
        accounted.reserveCapacity(entries.count)
        for entry in entries {
            entriesSeen += 1
            guard entry.kind == .file, entry.allocatedSize > .zero else {
                accounted.append(AccountedEntry(entry: entry, sharesStorage: false))
                continue
            }
            if seenStorage.insert(entry.storageIdentity).inserted {
                bytesAccounted += entry.allocatedSize
                accounted.append(AccountedEntry(entry: entry, sharesStorage: false))
            } else {
                hardLinksSkipped += 1
                accounted.append(AccountedEntry(entry: entry, sharesStorage: true))
            }
        }
        return accounted
    }

    func noteDirectoryVisited() {
        directoriesVisited += 1
    }

    func noteBoundary(_ path: String) {
        boundariesStopped.append(path)
    }

    func noteUnreadable(_ path: String) {
        unreadablePaths.append(path)
    }

    var snapshot: (Int, Int, ByteCount) {
        (directoriesVisited, entriesSeen, bytesAccounted)
    }

    var summary: (Int, Int, Int, [String], [String]) {
        (directoriesVisited, entriesSeen, hardLinksSkipped, boundariesStopped, unreadablePaths)
    }
}
