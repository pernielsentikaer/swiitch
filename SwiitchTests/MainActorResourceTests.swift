import Foundation
@testable import Swiitch
import XCTest

@MainActor
final class MainActorResourceTests: XCTestCase {
    @MainActor private final class Probe {
        var releases = 0
        var releasedOnMain = false
        weak var object: NSObject?
    }

    func testMainActorReleaseIsSynchronousAndRunsOnce() {
        let probe = Probe()
        var resource: MainActorResource<NSObject>? = MainActorResource(NSObject()) { _ in
            probe.releases += 1
            probe.releasedOnMain = Thread.isMainThread
        }
        XCTAssertNotNil(resource?.value)
        resource = nil
        XCTAssertEqual(probe.releases, 1)
        XCTAssertTrue(probe.releasedOnMain)
    }

    func testLastReferenceReleasedOffMainCleansUpOnMain() async {
        let probe = Probe()
        await Task.detached {
            let resource = await MainActor.run {
                let object = NSObject()
                probe.object = object
                return MainActorResource(object) { value in
                    XCTAssertTrue(probe.object === value, "Native context must survive until main-actor teardown")
                    probe.releases += 1
                    probe.releasedOnMain = Thread.isMainThread
                }
            }
            XCTAssertFalse(Thread.isMainThread)
            withExtendedLifetime(resource) {}
        }.value
        await waitUntil("off-main release to dispatch cleanup") { probe.releases == 1 }
        XCTAssertTrue(probe.releasedOnMain)
        XCTAssertNil(probe.object, "Cleanup must not permanently retain the native resource")
    }

    func testDroppingTimerOwnerInvalidatesTimer() {
        let timer = Timer(timeInterval: 60, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: .common)
        var resource: MainActorResource<Timer>? = MainActorResource(timer) { $0.invalidate() }
        XCTAssertTrue(resource?.value.isValid == true)
        resource = nil
        XCTAssertFalse(timer.isValid, "A run-loop-retained timer must not outlive its owner")
    }
}
