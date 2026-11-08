import Foundation
import Testing
@testable import HelperProtocol

@Suite("Helper contract")
struct HelperProtocolTests {
    @Test("The mach service name matches the helper bundle identifier")
    func machServiceName() {
        #expect(tortuHelperMachServiceName == "com.muhammedsalihkaragoz.tortu.helper")
        #expect(tortuHelperMachServiceName.hasPrefix("com.muhammedsalihkaragoz.tortu"))
    }

    @Test("A report survives encoding")
    func reportRoundTrip() throws {
        let report = HelperReport(
            outcome: .completed, removedPathCount: 12, reclaimedBytes: 3_221_225_472
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(HelperReport.self, from: data)
        #expect(decoded.outcome == .completed)
        #expect(decoded.removedPathCount == 12)
        #expect(decoded.reclaimedBytes == 3_221_225_472)
    }
}
