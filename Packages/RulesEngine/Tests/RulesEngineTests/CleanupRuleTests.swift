import Foundation
import Testing
@testable import RulesEngine

@Suite("Cleanup rules")
struct CleanupRuleTests {
    /// The rule exactly as it appears in the architecture plan.
    static let flutterRuleJSON = """
    {
      "id": "flutter.build-cache",
      "name": { "en": "Flutter build cache", "tr": "Flutter build önbelleği" },
      "category": "developer",
      "paths": ["~/**/.dart_tool/flutter_build/*"],
      "strategy": { "keepNewest": 2 },
      "blockedByProcesses": [],
      "requiresRoot": false,
      "regrows": true,
      "cost": { "en": "The next build compiles from scratch",
                "tr": "Sonraki build sıfırdan derlenir" }
    }
    """

    @Test("Decodes the Flutter rule from the plan")
    func decodesFlutterRule() throws {
        let data = Data(Self.flutterRuleJSON.utf8)
        let rule = try JSONDecoder().decode(CleanupRule.self, from: data)

        #expect(rule.id == "flutter.build-cache")
        #expect(rule.category == .developer)
        #expect(rule.strategy == .keepNewest(2))
        #expect(!rule.requiresRoot)
        #expect(rule.regrows)
        #expect(rule.name.resolved(for: Locale(identifier: "tr")) == "Flutter build önbelleği")
        #expect(rule.name.resolved(for: Locale(identifier: "en")) == "Flutter build cache")
        // An unsupported language falls back to English rather than to nothing.
        #expect(rule.name.resolved(for: Locale(identifier: "de")) == "Flutter build cache")
    }

    @Test("Round-trips through encoding")
    func roundTrip() throws {
        let original = try JSONDecoder().decode(
            CleanupRule.self, from: Data(Self.flutterRuleJSON.utf8)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CleanupRule.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Accepts a bare string as an English-only label")
    func bareStringLabel() throws {
        let json = """
        { "id": "a.b", "name": "Xcode DerivedData", "category": "developer",
          "paths": ["~/Library/Developer/Xcode/DerivedData/*"],
          "strategy": "deleteAll", "cost": "The next build is slower" }
        """
        let rule = try JSONDecoder().decode(CleanupRule.self, from: Data(json.utf8))
        #expect(rule.name.resolved() == "Xcode DerivedData")
        #expect(rule.strategy == .deleteAll)
        #expect(rule.blockedByProcesses.isEmpty)
    }

    @Test("Rejects a path that can escape its directory", arguments: [
        "~/Library/../../../etc",
        "relative/path",
        "/",
    ])
    func rejectsUnsafePaths(_ path: String) {
        let json = """
        { "id": "x", "name": "x", "category": "other",
          "paths": ["\(path)"], "strategy": "deleteAll", "cost": "none" }
        """
        #expect(throws: RuleError.self) {
            try JSONDecoder().decode(CleanupRule.self, from: Data(json.utf8))
        }
    }

    @Test("Rejects a negative keepNewest count")
    func rejectsNegativeKeepNewest() {
        let json = """
        { "id": "x", "name": "x", "category": "other", "paths": ["~/a"],
          "strategy": { "keepNewest": -1 }, "cost": "none" }
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CleanupRule.self, from: Data(json.utf8))
        }
    }
}
