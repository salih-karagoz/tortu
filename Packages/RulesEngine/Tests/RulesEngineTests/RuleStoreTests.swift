import Foundation
import Testing
@testable import RulesEngine

@Suite("Rule store")
struct RuleStoreTests {
    @Test("The bundled rules load and validate")
    func bundledRulesLoad() throws {
        let store = try RuleStore.bundled()
        #expect(store.rules.count >= 10)
        #expect(store.rule(id: "flutter.build-cache") != nil)
        #expect(store.rule(id: "xcode.derived-data") != nil)
        for rule in store.rules {
            try rule.validate()
        }
    }

    @Test("Every bundled rule is translated into both languages")
    func bundledRulesAreTranslated() throws {
        for rule in try RuleStore.bundled().rules {
            #expect(
                rule.name.availableLanguages.isSuperset(of: ["en", "tr"]),
                "\(rule.id) is missing a name translation"
            )
            #expect(
                rule.cost.availableLanguages.isSuperset(of: ["en", "tr"]),
                "\(rule.id) is missing a cost translation"
            )
        }
    }

    @Test("Every bundled rule states a real cost")
    func bundledRulesStateACost() throws {
        for rule in try RuleStore.bundled().rules {
            let english = rule.cost.resolved(for: Locale(identifier: "en")).lowercased()
            #expect(!english.isEmpty)
            // "Safe to delete" tells the user nothing they can weigh.
            #expect(!english.contains("safe to delete"), "\(rule.id) states no real cost")
        }
    }

    @Test("Identifiers are unique")
    func identifiersAreUnique() throws {
        let ids = try RuleStore.bundled().rules.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("A user-supplied rule may not ask for root")
    func userRulesCannotRequestRoot() {
        let json = """
        { "version": 1, "rules": [
          { "id": "sneaky", "name": "x", "category": "other",
            "paths": ["/Library/Something"], "strategy": "deleteAll",
            "requiresRoot": true, "cost": "none" }
        ]}
        """
        #expect(throws: RuleError.rootNotPermitted(ruleID: "sneaky")) {
            try RuleStore.userSupplied(data: Data(json.utf8))
        }
    }

    @Test("Rules group by category")
    func groupsByCategory() throws {
        let store = try RuleStore.bundled()
        #expect(!store.rules(in: .developer).isEmpty)
        #expect(store.categories.contains(.developer))
    }
}
