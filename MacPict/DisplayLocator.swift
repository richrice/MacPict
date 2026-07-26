import AppKit
import CoreGraphics

enum DisplayLocator {
    /// `CGRect.contains` is half-open: a rect owns its min edges but not its max
    /// edges, so a pointer sitting exactly on the seam between two abutting
    /// displays belongs to the display on the far side of the seam. Where frames
    /// genuinely overlap (mirrored displays), array order decides. Either way the
    /// answer is deterministic.
    static func indexOfScreen(containing point: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    @MainActor
    static func screen(containing point: CGPoint, screens: [NSScreen]) -> NSScreen? {
        if let index = indexOfScreen(containing: point, frames: screens.map(\.frame)) {
            return screens[index]
        }
        // C-5: NSScreen.main is "the screen with the key window", not the primary
        // display. It is only a fallback for a pointer that lands in no frame.
        return NSScreen.main ?? screens.first
    }

    @MainActor
    static func screenUnderPointer() -> NSScreen? {
        // C-4: NSEvent.mouseLocation and NSScreen.frame share AppKit's
        // bottom-left-origin space, so no coordinate conversion is involved here.
        screen(containing: NSEvent.mouseLocation, screens: NSScreen.screens)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        // C-3: "NSScreenNumber" is declared by no SDK header, and the value is
        // boxed as an NSNumber, so the read stays fully optional-safe.
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            AppLogger.capture.error("Screen has no NSScreenNumber device description entry")
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
