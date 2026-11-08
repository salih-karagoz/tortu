import Testing
@testable import Entitlements

@Suite("Entitlements")
struct EntitlementsTests {
    @Test("The free build unlocks nothing")
    func freeBuildUnlocksNothing() {
        let provider = FreeEntitlements()
        #expect(provider.unlockedEntitlements.isEmpty)
        #expect(!provider.hasAnyPaidEntitlement)
    }

    @Test("A fixed provider reports exactly what it was given")
    func fixedProvider() {
        let provider = FixedEntitlements(unlocked: [.history, .growthCharts])
        #expect(provider.isUnlocked(.history))
        #expect(!provider.isUnlocked(.duplicateFinder))
        #expect(provider.unlockedEntitlements.count == 2)
    }

    @Test("Cleaning capabilities are never gated")
    func cleaningIsNotSold() {
        // Guards the product rule: if a case ever appears here that gates
        // scanning or deleting, the open-source trust story breaks.
        let gatedNames = Entitlement.allCases.map(\.rawValue)
        for forbidden in ["scan", "clean", "delete", "helper", "privileged"] {
            #expect(!gatedNames.contains { $0.lowercased().contains(forbidden) })
        }
    }
}
