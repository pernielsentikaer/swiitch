import SwiftUI

/// A non-interactive status: the tile retains its normal switch/close behavior.
/// Static symbols avoid running a spinner for every window in a large grid.
struct ThumbnailPlaceholder: View {
    let state: ThumbnailState

    var body: some View {
        GeometryReader { geometry in
            // Fill Screen can shrink tiles substantially. Keep the full status in
            // the tooltip and accessibility label instead of clipping tiny text.
            VStack(spacing: 5) {
                Image(systemName: state.symbol)
                    .font(.body)
                    .accessibilityHidden(true)
                if geometry.size.width >= 110, geometry.size.height >= 65 {
                    Text(state.label)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 6)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.label)
        .accessibilityHint(state.help)
        .help(state.help)
    }
}
