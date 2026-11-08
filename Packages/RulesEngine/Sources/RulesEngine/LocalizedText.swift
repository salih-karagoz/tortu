import Foundation

/// A string carried by a rule, in every language the rule ships with.
///
/// Rule names and cost descriptions are data rather than interface strings, so
/// they cannot live in the app's String Catalog. They travel with the rule
/// instead, which also lets a contributed rule arrive already translated.
public struct LocalizedText: Sendable, Hashable, Codable {
    public static let fallbackLanguage = "en"

    private let values: [String: String]

    public init(_ values: [String: String]) {
        self.values = values
    }

    public init(en: String, tr: String? = nil) {
        var values = ["en": en]
        if let tr { values["tr"] = tr }
        self.values = values
    }

    /// The best match for `locale`, falling back to English and then to any
    /// available translation, so a rule never renders as an empty label.
    public func resolved(for locale: Locale = .current) -> String {
        let language = locale.language.languageCode?.identifier
        if let language, let match = values[language] {
            return match
        }
        if let fallback = values[Self.fallbackLanguage] {
            return fallback
        }
        return values.values.sorted().first ?? ""
    }

    public var availableLanguages: Set<String> { Set(values.keys) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // A bare string is accepted and treated as English, so simple rules
        // stay readable in the file.
        if let plain = try? container.decode(String.self) {
            self.values = ["en": plain]
        } else {
            self.values = try container.decode([String: String].self)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}
