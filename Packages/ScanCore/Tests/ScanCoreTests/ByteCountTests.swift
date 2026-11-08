import Testing
@testable import ScanCore

@Suite("ByteCount")
struct ByteCountTests {
    @Test("Builds from blocks and block size the way stat reports them")
    func blocksAndBlockSize() {
        #expect(ByteCount(blocks: 8, blockSize: 512).rawValue == 4096)
        #expect(ByteCount(blocks: 0, blockSize: 4096) == .zero)
    }

    @Test("Adds and subtracts")
    func arithmetic() {
        var total = ByteCount.zero
        total += ByteCount(1_000)
        total += ByteCount(2_000)
        #expect(total.rawValue == 3_000)
        #expect((total - ByteCount(500)).rawValue == 2_500)
    }

    @Test("Orders by raw value")
    func ordering() {
        #expect(ByteCount(1) < ByteCount(2))
        #expect([ByteCount(30), ByteCount(10), ByteCount(20)].max() == ByteCount(30))
    }
}
