import Foundation

/// Pure grid sizing shared by the picker, keyboard row navigation, and the Preferences
/// preview. No model state: every input is a parameter, so it is safe from any context.
enum SwitcherLayout {
    struct GridMetrics: Equatable {
        let columns: Int
        let cellWidth: CGFloat
        let thumbnailHeight: CGFloat
    }

    static func appGridColumns(count: Int, maxWidth: CGFloat) -> Int {
        max(1, min(count, Int(maxWidth / (110 + 14))))
    }

    /// Calculates one layout used by both SwiftUI and keyboard row navigation. Automatic
    /// mode preserves the chosen thumbnail size. Fill mode instead finds the largest tiles
    /// that consume the configured width while keeping the complete grid on screen.
    static func gridMetrics(
        count: Int,
        maxWidth: CGFloat,
        availableHeight: CGFloat,
        thumbnailSize: Preferences.ThumbnailSize,
        fitAll: Bool,
        columnSpacing: CGFloat = 12,
        rowSpacing: CGFloat = 14
    ) -> GridMetrics {
        guard count > 0 else {
            return GridMetrics(
                columns: 1,
                cellWidth: thumbnailSize.cellWidth,
                thumbnailHeight: thumbnailSize.thumbHeight
            )
        }

        let width = max(120, maxWidth)
        let preferredWidth = thumbnailSize.cellWidth
        let aspectRatio = thumbnailSize.thumbHeight / preferredWidth

        if !fitAll {
            let columns = max(1, min(count, Int((width + columnSpacing) / (preferredWidth + columnSpacing))))
            return GridMetrics(
                columns: columns,
                cellWidth: preferredWidth,
                thumbnailHeight: thumbnailSize.thumbHeight
            )
        }

        // Fill mode may go smaller than the user's preferred thumbnail size, but retain
        // a usable lower bound. Automatic mode never changes the chosen size.
        let minimumWidth: CGFloat = 72
        let height = max(120, availableHeight)
        let labelHeight: CGFloat = 34

        // Try the fewest columns first. Because each candidate expands to consume the
        // complete configured width, the first layout that fits vertically also produces
        // the largest useful thumbnails. This restores Budapest's visibly distinct Fill
        // behavior instead of collapsing to Automatic whenever full-size tiles fit.
        for columns in 1...count {
            let candidateWidth = (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
            guard candidateWidth >= minimumWidth else { continue }
            let cellWidth = candidateWidth
            let thumbnailHeight = cellWidth * aspectRatio
            let rows = Int(ceil(Double(count) / Double(columns)))
            let totalHeight = CGFloat(rows) * (thumbnailHeight + labelHeight)
                + CGFloat(max(0, rows - 1)) * rowSpacing
            if totalHeight <= height {
                return GridMetrics(
                    columns: columns,
                    cellWidth: cellWidth,
                    thumbnailHeight: thumbnailHeight
                )
            }
        }

        // Extremely large sets cannot fit without making tiles unusably small. Use every
        // viable column at the lower bound; the panel's bounded ScrollView handles only
        // this final overflow case instead of letting the panel leave the screen.
        let columns = max(1, min(count, Int((width + columnSpacing) / (minimumWidth + columnSpacing))))
        let candidateWidth = (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellWidth = max(minimumWidth, min(preferredWidth, candidateWidth))
        return GridMetrics(
            columns: columns,
            cellWidth: cellWidth,
            thumbnailHeight: cellWidth * aspectRatio
        )
    }
}
