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

    @Test("The build that ships unlocks everything")
    func openBuildUnlocksEverything() {
        let provider = OpenEntitlements()
        #expect(provider.unlockedEntitlements == Set(Entitlement.allCases))
        #expect(provider.hasAnyPaidEntitlement)
    }

    @Test("A fixed provider reports exactly what it was given")
    func fixedProvider() {
        let provider = FixedEntitlements(unlocked: [.backgroundMonitoring])
        #expect(provider.isUnlocked(.backgroundMonitoring))
        #expect(!provider.isUnlocked(.liveActivity))
        #expect(provider.unlockedEntitlements.count == 1)
    }

    @Test("Cleaning capabilities are never gated")
    func cleaningIsNotSold() {
        // Guards the product rule: nothing that scans, deletes or runs as
        // root is ever gated. This reads names, which is as far as a test in
        // this package can see — a capability that deleted files under a name
        // that did not say so would pass, and review has to catch that part.
        let gatedNames = Entitlement.allCases.map(\.rawValue)
        for forbidden in ["scan", "clean", "delete", "helper", "privileged"] {
            #expect(!gatedNames.contains { $0.lowercased().contains(forbidden) })
        }
    }
}
