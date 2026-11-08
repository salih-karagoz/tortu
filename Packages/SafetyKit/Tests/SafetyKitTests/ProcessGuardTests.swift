import Testing
@testable import SafetyKit

@Suite("Process guard")
struct ProcessGuardTests {
    @Test("Names the running applications that block a rule")
    func namesBlockers() {
        let guardian = ProcessGuard(
            applications: StubApplications(["com.jetbrains.intellij", "com.apple.dt.Xcode"])
        )
        let blockers = guardian.blockingApplications(
            among: ["com.jetbrains.intellij", "com.google.android.studio"]
        )
        #expect(blockers == ["com.jetbrains.intellij"])
        #expect(guardian.isBlocked(by: ["com.jetbrains.intellij"]))
    }

    @Test("A rule with no guarded applications is never blocked")
    func noGuards() {
        let guardian = ProcessGuard(applications: StubApplications(["com.apple.dt.Xcode"]))
        #expect(guardian.blockingApplications(among: []).isEmpty)
        #expect(!guardian.isBlocked(by: []))
    }

    @Test("Nothing is blocked when nothing is running")
    func nothingRunning() {
        let guardian = ProcessGuard(applications: StubApplications([]))
        #expect(!guardian.isBlocked(by: ["com.jetbrains.intellij"]))
    }
}
