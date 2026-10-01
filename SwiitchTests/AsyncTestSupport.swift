import XCTest

/// Waits for `condition` instead of sleeping for a guessed interval.
///
/// A fixed `Task.sleep` before an assertion is a bet on scheduler latency. It pays off
/// on a laptop and loses on a shared CI runner, which stalls for hundreds of
/// milliseconds at a time. Polling returns as soon as the state is reached locally
/// and tolerates brief stalls while retaining a bounded failure deadline.
@MainActor
@discardableResult
func waitUntil(
    _ expectation: @autoclosure () -> String,
    timeout: Duration = .seconds(5),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while true {
        if await condition() { return true }
        if clock.now >= deadline { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out after \(timeout) waiting for \(expectation())", file: file, line: line)
    return false
}
