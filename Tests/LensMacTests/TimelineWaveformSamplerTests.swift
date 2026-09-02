import XCTest
@testable import LensMac

final class TimelineWaveformSamplerTests: XCTestCase {
    func testMissingFileReturnsNoPeaks() async {
        let url = URL(fileURLWithPath: "/tmp/lens-missing-waveform-\(UUID().uuidString).m4a")
        let peaks = await TimelineWaveformSampler.peaks(from: url, bucketCount: 32)
        XCTAssertTrue(peaks.isEmpty)
    }
}
