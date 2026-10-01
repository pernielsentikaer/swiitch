@testable import Swiitch
import XCTest

@MainActor
final class MemoryPressureMonitorTests: XCTestCase {
    func testWarningsAlwaysReportAndNormalReportsOnceAfterPressure() {
        var reported: [Bool] = []
        let monitor = MemoryPressureMonitor { reported.append($0) }
        monitor.handle(.normal)
        XCTAssertEqual(reported, [], "Normal without prior pressure is not news")
        monitor.handle(.warning)
        monitor.handle(.critical)
        XCTAssertEqual(reported, [true, true], "Every warning drops the cache again; the picker may have refilled it")
        XCTAssertTrue(monitor.constrained)
        XCTAssertEqual(monitor.pressureEventCount, 2)
        monitor.handle(.normal)
        monitor.handle(.normal)
        XCTAssertEqual(reported, [true, true, false], "Normal reports once")
        XCTAssertFalse(monitor.constrained)
    }

    func testStartAndStopAreIdempotent() {
        let monitor = MemoryPressureMonitor { _ in }
        monitor.start()
        monitor.start()
        monitor.stop()
        monitor.stop()
        XCTAssertFalse(monitor.constrained)
    }
}
