import Foundation

public enum ScanError: Error, Sendable, Equatable {
    case volumeUnreadable(path: String, code: Int32)
    case mountTableUnavailable(code: Int32)
    case pathUnreadable(path: String, code: Int32)
}

extension ScanError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .volumeUnreadable(path, code):
            "Could not read volume statistics for \(path) (errno \(code))"
        case let .mountTableUnavailable(code):
            "Could not read the mount table (errno \(code))"
        case let .pathUnreadable(path, code):
            "Could not read \(path) (errno \(code))"
        }
    }
}
