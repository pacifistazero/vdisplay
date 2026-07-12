import Cocoa

/// A small on-screen brightness indicator, shown when the brightness keys are
/// intercepted (we swallow the system's own HUD, so we provide a replacement).
final class BrightnessHUD {
    private var window: NSWindow?
    private let bar = NSProgressIndicator()
    private var hideWork: DispatchWorkItem?

    func show(level: Int) {
        let window = ensureWindow()
        bar.doubleValue = Double(level)

        if let screen = NSScreen.main {
            let size = window.frame.size
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.minY + screen.frame.height * 0.12
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        window.alphaValue = 1
        window.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak window] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                window?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private func ensureWindow() -> NSWindow {
        if let window = window { return window }
        let w: CGFloat = 200, h: CGFloat = 66
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: w / 2 - 13, y: h - 34, width: 26, height: 24))
        icon.image = NSImage(systemSymbolName: "sun.max.fill",
                             accessibilityDescription: "Brightness")
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyUpOrDown
        blur.addSubview(icon)

        bar.frame = NSRect(x: 22, y: 18, width: w - 44, height: 8)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.style = .bar
        blur.addSubview(bar)

        window.contentView = blur
        self.window = window
        return window
    }
}
