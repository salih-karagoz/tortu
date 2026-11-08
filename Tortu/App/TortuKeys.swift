import Foundation

enum TortuKeys {
    /// Public half of the licence signing key. The private half is not in this
    /// repository and must never be.
    ///
    /// This is a development key, generated so the paid surfaces can be
    /// exercised before release. It is replaced at M6 by a production key
    /// whose private half lives in the Keychain.
    static let licensePublicKeyBase64 = "BX/qbvOj0BbBvP4yw2Uzr2aM8msSFQerLciI7Cmq/AM="

    static var licensePublicKey: Data {
        Data(base64Encoded: licensePublicKeyBase64) ?? Data()
    }

    /// Where a bought licence is dropped.
    static var licenseURL: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appending(path: "Tortu/license.tortulicense")
    }
}
