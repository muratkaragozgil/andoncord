import CoreGraphics

/// Whether an app's windows fill a screen — the test for "something is in
/// fullscreen on the board's display".
///
/// A zoomed window stops at the menu bar and the Dock, so only a window that
/// covers the screen's whole frame counts. Window bounds come from
/// `CGWindowListCopyWindowInfo`, which measures from the top-left of the
/// primary display, while screens are measured from its bottom-left; the
/// conversion is the part worth testing.
public enum ScreenCover {
    public static func isCovered(
        screen: CGRect, byWindows windows: [CGRect], primaryScreenMaxY: CGFloat
    ) -> Bool {
        windows.contains { bounds in
            let flipped = CGRect(
                x: bounds.minX, y: primaryScreenMaxY - bounds.maxY,
                width: bounds.width, height: bounds.height)
            // A point of slack for windows placed at fractional coordinates.
            return flipped.insetBy(dx: -1, dy: -1).contains(screen)
        }
    }
}
