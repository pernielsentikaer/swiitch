import AppKit
import ApplicationServices

enum PermissionsCheck {
    /// Checks whether the app is a trusted Accessibility client; prompts the user once if not.
    /// Calls the completion with the current state (granted = true means tap can be installed immediately).
    static func ensureAccessibility(completion: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            completion(true)
            return
        }

        // Prompt — opens System Settings to the right pane.
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        completion(trusted)
    }
}
