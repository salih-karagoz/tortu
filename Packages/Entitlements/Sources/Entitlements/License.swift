import Foundation

/// What a licence grants, as it is signed.
///
/// The payload is signed as bytes and verified as bytes. It is never decoded,
/// re-encoded and compared, because two encoders disagree about key order and
/// date formatting, and a verifier built that way rejects valid licences while
/// quietly accepting some invalid ones.
public struct License: Codable, Sendable, Hashable {
    public let licenseID: String
    /// Who it was issued to, for the user's own reference. Shown in settings.
    public let issuedTo: String
    public let issued: Date
    /// `nil` for a perpetual licence.
    public let expires: Date?
    /// `nil` when updates never stop. A licence past this date keeps working
    /// on the version it was bought for.
    public let updatesUntil: Date?
    public let entitlements: [Entitlement]
    public let formatVersion: Int

    public init(
        licenseID: String,
        issuedTo: String,
        issued: Date,
        expires: Date? = nil,
        updatesUntil: Date? = nil,
        entitlements: [Entitlement],
        formatVersion: Int = 1
    ) {
        self.licenseID = licenseID
        self.issuedTo = issuedTo
        self.issued = issued
        self.expires = expires
        self.updatesUntil = updatesUntil
        self.entitlements = entitlements
        self.formatVersion = formatVersion
    }

    public static let currentFormatVersion = 1
}

/// A licence payload with the signature that vouches for it.
public struct SignedLicense: Codable, Sendable {
    /// The exact bytes that were signed.
    public let payload: Data
    public let signature: Data

    public init(payload: Data, signature: Data) {
        self.payload = payload
        self.signature = signature
    }
}

public enum LicenseError: Error, Sendable, Equatable {
    case malformed
    case invalidSignature
    case expired(on: Date)
    case unsupportedFormat(version: Int)
}
