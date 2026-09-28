import Cocoa
import VirtualDisplayKit

/// Which display a brightness key press should act on, and how.
///
/// MonitorControl's model: the keys act on the display the pointer is on, not on one
/// fixed monitor. That matters because we swallow the keys - without it, moving to the
/// built-in screen would leave its brightness keys dead.
enum BrightnessTarget {
    /// A display macOS already handles itself: let the key through untouched.
    case system
    /// One of our virtual displays: no backlight, so dim it with an overlay.
    case virtual(CGDirectDisplayID)
    /// An external panel: drive its backlight over DDC.
    case ddc

    /// Snapshot of the display layout, so the hit test can run on the tap thread without
    /// touching AppKit. CG bounds share the event's top-left origin, so no flipping.
    struct Layout {
        private let displays: [(bounds: CGRect, id: CGDirectDisplayID, builtin: Bool, virtual: Bool)]

        init() {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(16, &ids, &count) == .success else {
                displays = []
                return
            }
            let ours = Set(DisplayManager.shared.activeDisplayIDs)
            displays = ids[0 ..< Int(count)].map {
                (CGDisplayBounds($0), $0, CGDisplayIsBuiltin($0) != 0, ours.contains($0))
            }
        }

        func target(at point: CGPoint) -> BrightnessTarget {
            guard let hit = displays.first(where: { $0.bounds.contains(point) }) else { return .ddc }
            if hit.virtual { return .virtual(hit.id) }
            // The built-in panel's own keys work fine; anything else is a candidate for DDC.
            return hit.builtin ? .system : .ddc
        }
    }
}
