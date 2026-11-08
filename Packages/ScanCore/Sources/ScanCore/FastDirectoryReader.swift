import Foundation

/// Reads a directory with `getattrlistbulk`, which returns many entries and
/// their attributes from a single syscall.
///
/// The portable reader needs one `fstatat` per entry; over a tree with
/// hundreds of thousands of files that difference is the whole point. The cost
/// is a hand-written parser, so `FastDirectoryReader` is checked against
/// `PortableDirectoryReader` in the tests rather than trusted on sight.
public struct FastDirectoryReader: DirectoryReading {
    /// Bits are declared here rather than taken from the Darwin import,
    /// because `ATTR_CMN_RETURNED_ATTRS` is `0x80000000` and arrives as a
    /// negative `Int32`.
    private enum Attr {
        static let commonReturned: UInt32 = 0x8000_0000
        static let commonName: UInt32     = 0x0000_0001
        static let commonDevID: UInt32    = 0x0000_0002
        static let commonObjType: UInt32  = 0x0000_0008
        static let commonModTime: UInt32  = 0x0000_0400
        static let commonFileID: UInt32   = 0x0200_0000

        static let fileAllocSize: UInt32  = 0x0000_0004
        static let fileDataLength: UInt32 = 0x0000_0200
    }

    private let bufferSize: Int

    /// 32 KB holds a few hundred entries, which covers almost every real
    /// directory in one syscall. A larger buffer only costs more memory to
    /// allocate per directory and buys nothing.
    public init(bufferSize: Int = 32 * 1024) {
        self.bufferSize = bufferSize
    }

    public func entries(at path: String) throws -> [DirectoryEntry] {
        let descriptor = open(path, O_RDONLY, 0)
        guard descriptor >= 0 else {
            throw ScanError.pathUnreadable(path: path, code: errno)
        }
        defer { close(descriptor) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Attr.commonReturned
            | Attr.commonName
            | Attr.commonDevID
            | Attr.commonObjType
            | Attr.commonModTime
            | Attr.commonFileID
        request.fileattr = Attr.fileAllocSize | Attr.fileDataLength

        // Allocated rather than declared as an array, because an array of
        // 32 KB would be zeroed on every directory. Over a tree with tens of
        // thousands of directories that memset costs more than the syscalls
        // this reader exists to avoid.
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferSize, alignment: MemoryLayout<UInt64>.alignment
        )
        defer { buffer.deallocate() }

        var results: [DirectoryEntry] = []
        while true {
            let returned = withUnsafeMutablePointer(to: &request) { list in
                getattrlistbulk(descriptor, list, buffer, bufferSize, 0)
            }
            if returned == 0 { break }
            guard returned > 0 else {
                throw ScanError.pathUnreadable(path: path, code: errno)
            }
            let raw = UnsafeRawBufferPointer(start: buffer, count: bufferSize)
            parse(raw, entryCount: Int(returned), into: &results)
        }
        return results
    }

    private func parse(
        _ raw: UnsafeRawBufferPointer,
        entryCount: Int,
        into results: inout [DirectoryEntry]
    ) {
        var offset = 0
        for _ in 0 ..< entryCount {
            let entryStart = offset
            let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            defer { offset = entryStart + length }

            var cursor = offset + MemoryLayout<UInt32>.size
            let present = raw.loadUnaligned(fromByteOffset: cursor, as: attribute_set_t.self)
            cursor += MemoryLayout<attribute_set_t>.size

            // Attributes arrive in bit order within each group, and only the
            // ones named in `present` are there at all. A directory carries no
            // file attributes, so advancing past them unconditionally would
            // misread every entry that followed.
            var name = ""
            if present.commonattr & Attr.commonName != 0 {
                let reference = raw.loadUnaligned(
                    fromByteOffset: cursor, as: attrreference_t.self
                )
                let nameOffset = cursor + Int(reference.attr_dataoffset)
                if let base = raw.baseAddress, nameOffset < raw.count {
                    name = String(cString: base.advanced(by: nameOffset)
                        .assumingMemoryBound(to: CChar.self))
                }
                cursor += MemoryLayout<attrreference_t>.size
            }

            var deviceID = dev_t()
            if present.commonattr & Attr.commonDevID != 0 {
                deviceID = raw.loadUnaligned(fromByteOffset: cursor, as: dev_t.self)
                cursor += MemoryLayout<dev_t>.size
            }

            var kind = EntryKind.other
            if present.commonattr & Attr.commonObjType != 0 {
                let objectType = raw.loadUnaligned(fromByteOffset: cursor, as: fsobj_type_t.self)
                kind = EntryKind(objectType: objectType)
                cursor += MemoryLayout<fsobj_type_t>.size
            }

            var modified = Date(timeIntervalSince1970: 0)
            if present.commonattr & Attr.commonModTime != 0 {
                let time = raw.loadUnaligned(fromByteOffset: cursor, as: timespec.self)
                modified = Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
                cursor += MemoryLayout<timespec>.size
            }

            var fileID: UInt64 = 0
            if present.commonattr & Attr.commonFileID != 0 {
                fileID = raw.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
                cursor += MemoryLayout<UInt64>.size
            }

            var allocated = ByteCount.zero
            if present.fileattr & Attr.fileAllocSize != 0 {
                let value = raw.loadUnaligned(fromByteOffset: cursor, as: off_t.self)
                allocated = ByteCount(Int64(value))
                cursor += MemoryLayout<off_t>.size
            }

            var logical = ByteCount.zero
            if present.fileattr & Attr.fileDataLength != 0 {
                let value = raw.loadUnaligned(fromByteOffset: cursor, as: off_t.self)
                logical = ByteCount(Int64(value))
                cursor += MemoryLayout<off_t>.size
            }

            guard !name.isEmpty, name != ".", name != ".." else { continue }

            results.append(
                DirectoryEntry(
                    name: name,
                    kind: kind,
                    deviceID: deviceID,
                    fileID: fileID,
                    logicalSize: logical,
                    allocatedSize: allocated,
                    modified: modified
                )
            )
        }
    }
}
