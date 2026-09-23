import Foundation
import Combine
import CoreGraphics

/// A single scoped recorder owner. Replacing a recorder cannot leave the global
/// interceptor suspended; only the current owner may end the session.
final class ShortcutRecordingSession: NSObject, ObservableObject {
    static let shared = ShortcutRecordingSession()
    static let didBegin = Notification.Name("SwiitchShortcutRecordingDidBegin")
    @Published private(set) var owner: UUID?
    private var handler: ((Int, CGEventFlags) -> Void)?
    var isRecording: Bool { owner != nil }

    func begin(owner: UUID, handler: ((Int, CGEventFlags) -> Void)? = nil) {
        self.owner = owner
        self.handler = handler
        NotificationCenter.default.post(name: Self.didBegin, object: self)
    }

    func end(owner: UUID) {
        if self.owner == owner {
            handler = nil
            self.owner = nil
        }
    }

    /// Route to the recorder before macOS handles reserved shortcuts such as Cmd-Tab.
    /// Ordinary switcher interpretation stays suspended for the entire session.
    func consume(keyCode: Int, flags: CGEventFlags) -> Bool {
        guard isRecording, let handler else { return false }
        handler(keyCode, flags)
        return true
    }
}
