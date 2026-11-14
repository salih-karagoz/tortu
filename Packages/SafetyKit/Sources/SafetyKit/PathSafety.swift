import Foundation

public enum PathSafetyError: Error, Sendable, Equatable {
    case notAbsolute(String)
    case containsTraversal(String)
    case tooShallow(String)
    case isHomeDirectory(String)
    case isVolumeRoot(String)
    case protectedLocation(String)
    case doesNotExist(String)
}

/// The last check before anything is removed.
///
/// The rule that produced a path has already been validated, and the matcher
/// only returns paths that exist. This runs anyway, because it is the one
/// place a mistake anywhere upstream stops being recoverable.
public enum PathSafety {
    /// Locations nothing in Tortu may remove, whatever a rule says.
    public static let protectedPrefixes = [
        "/System", "/bin", "/sbin", "/usr", "/etc", "/var", "/private/var",
        "/Applications", "/Library/Apple", "/cores", "/Volumes",
    ]

    /// Carved out of the protected prefixes above. `/var/folders` holds the
    /// per-user temporary and cache directories macOS hands out through
    /// `DARWIN_USER_CACHE_DIR`; they are ordinary caches and grow large, so
    /// protecting the whole of `/var` would put a real cleanup target out of
    /// reach along with the system state that does need protecting.
    public static let allowedWithinProtected = [
        "/var/folders", "/private/var/folders",
    ]

    /// Fewest path components a removable path may have, counting the way
    /// `split(separator: "/")` does: `/Users/someone` has two and is refused,
    /// `/Users/someone/.dartServer` has three and is refused, and
    /// `/Users/someone/.npm/_cacache` has four and is allowed.
    ///
    /// The count used to be written down one higher than the code counts,
    /// which is how a bundled rule came to point at a path this always
    /// refused — it appeared in the plan with a size and was skipped without
    /// a word every time it ran.
    public static let minimumComponents = 4

    /// Prefixes the privileged helper may remove inside, and nothing else.
    ///
    /// Root operations use an allow list rather than the deny list that
    /// governs the unprivileged side. A deny list is a promise that every
    /// dangerous location has been thought of; running as root, that promise
    /// is not one worth making. Adding a prefix here is a deliberate change to
    /// a signed binary, which is the point.
    public static let rootAllowedPrefixes = [
        "/Library/Developer/CoreSimulator/Caches",
    ]

    /// The check the helper runs. Everything outside `rootAllowedPrefixes` is
    /// refused however the request arrived.
    public static func validateForRemovalWithRootAllowances(_ path: String) throws {
        guard path.hasPrefix("/") else { throw PathSafetyError.notAbsolute(path) }
        guard !path.contains("..") else { throw PathSafetyError.containsTraversal(path) }

        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard rootAllowedPrefixes.contains(where: { trimmed.hasPrefix($0 + "/") }) else {
            throw PathSafetyError.protectedLocation(path)
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= minimumComponents else {
            throw PathSafetyError.tooShallow(path)
        }

        var info = stat()
        guard lstat(trimmed, &info) == 0 else { throw PathSafetyError.doesNotExist(path) }
        if try isVolumeRoot(trimmed, info: info) {
            throw PathSafetyError.isVolumeRoot(path)
        }
    }

    public static func validateForRemoval(
        _ path: String,
        home: String = NSHomeDirectory()
    ) throws {
        guard path.hasPrefix("/") else { throw PathSafetyError.notAbsolute(path) }
        guard !path.contains("..") else { throw PathSafetyError.containsTraversal(path) }

        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= minimumComponents else {
            throw PathSafetyError.tooShallow(path)
        }

        let normalisedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard trimmed != normalisedHome else { throw PathSafetyError.isHomeDirectory(path) }

        let isExplicitlyAllowed = allowedWithinProtected.contains {
            trimmed.hasPrefix($0 + "/")
        }
        if !isExplicitlyAllowed {
            for prefix in protectedPrefixes
            where trimmed == prefix || trimmed.hasPrefix(prefix + "/") {
                // The simulator's shared cache lives under a protected prefix
                // and is reached through the privileged helper, which carries
                // its own allow list; nothing here may widen that.
                throw PathSafetyError.protectedLocation(path)
            }
        }

        var info = stat()
        guard lstat(trimmed, &info) == 0 else { throw PathSafetyError.doesNotExist(path) }

        // A volume root has the same device as itself but no parent on that
        // device; removing one would mean deleting a whole mounted filesystem.
        if try isVolumeRoot(trimmed, info: info) {
            throw PathSafetyError.isVolumeRoot(path)
        }
    }

    private static func isVolumeRoot(_ path: String, info: stat) throws -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return true }
        var parentInfo = stat()
        guard lstat(parent, &parentInfo) == 0 else { return false }
        return parentInfo.st_dev != info.st_dev
    }
}
