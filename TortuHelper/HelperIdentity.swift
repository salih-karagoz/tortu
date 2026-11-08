import Foundation

enum HelperIdentity {
    /// The team the Developer ID certificate belongs to.
    ///
    /// Not the same team as the Apple Development certificate on this machine,
    /// which sits under a different identifier. The requirement below pins the
    /// signing team, so taking the value from the development certificate
    /// would make a correctly signed release unable to reach its own helper.
    static let teamIdentifier = "TW3M4N5Q8D"
    static let appBundleIdentifier = "com.muhammedsalihkaragoz.tortu"

    /// Only a build of Tortu signed by this team may talk to the helper.
    ///
    /// Passed to `NSXPCConnection.setCodeSigningRequirement`, which is the
    /// supported way to do this since macOS 13. The older approach reached for
    /// the connection's audit token through private API; this one is checked
    /// by the system before any message is delivered.
    static let clientRequirement = """
        identifier "\(appBundleIdentifier)" \
        and anchor apple generic \
        and certificate leaf[subject.OU] = "\(teamIdentifier)"
        """
}
