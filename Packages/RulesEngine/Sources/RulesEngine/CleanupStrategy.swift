import Foundation

/// What a rule does with the paths it matches.
public enum CleanupStrategy: Sendable, Hashable {
    /// Remove every match.
    case deleteAll

    /// Keep the most recently modified `count` entries and remove the rest.
    ///
    /// This exists for Flutter. A single project accumulated 95 directories
    /// under `.dart_tool/flutter_build`, roughly 100 MB each, because Flutter
    /// creates one per build configuration and never removes the old ones.
    /// Deleting all of them forces a full rebuild; keeping the newest few
    /// reclaims almost everything and leaves the working configuration warm.
    case keepNewest(Int)

    /// Remove matches not modified within the last `days` days.
    case olderThan(days: Int)
}

extension CleanupStrategy: Codable {
    private enum CodingKeys: String, CodingKey {
        case keepNewest
        case olderThan
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let name = try? single.decode(String.self) {
            switch name {
            case "deleteAll":
                self = .deleteAll
                return
            default:
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Unknown cleanup strategy '\(name)'"
                )
            }
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let count = try container.decodeIfPresent(Int.self, forKey: .keepNewest) {
            guard count >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .keepNewest, in: container,
                    debugDescription: "keepNewest must not be negative"
                )
            }
            self = .keepNewest(count)
            return
        }
        if let days = try container.decodeIfPresent(Int.self, forKey: .olderThan) {
            guard days > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .olderThan, in: container,
                    debugDescription: "olderThan must be at least one day"
                )
            }
            self = .olderThan(days: days)
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .keepNewest, in: container,
            debugDescription: "No recognised cleanup strategy"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .deleteAll:
            var single = encoder.singleValueContainer()
            try single.encode("deleteAll")
        case let .keepNewest(count):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(count, forKey: .keepNewest)
        case let .olderThan(days):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(days, forKey: .olderThan)
        }
    }
}
