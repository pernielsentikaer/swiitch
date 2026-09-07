import SwiftUI

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diagnostics").font(.title2.weight(.semibold))
            Text("Review before sharing. Includes app/OS versions, permission states, and anonymous counts and timings. No window titles, URLs, screenshots, paths, or app list.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(report ?? String(localized: "Collecting diagnostics…"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Copy Report") {
                    guard let report else { return }
                    message = DiagnosticsReport.copy(report) ? String(localized: "Copied to clipboard.") : String(localized: "Couldn’t copy the report. Please try again.")
                }
                .disabled(report == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 500)
        .task {
            do { report = try DiagnosticsReport.render(await DiagnosticsReport.current()) }
            catch { message = String(localized: "Couldn’t create the diagnostics report. Please try again.") }
        }
    }
}
