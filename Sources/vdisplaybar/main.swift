import Cocoa
import VirtualDisplayKit

/// A menu-bar app to toggle virtual displays defined in the saved profiles.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let mediaKeys = MediaKeyController()
    private var saveVirtualBrightness: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2",
                                   accessibilityDescription: "Virtual Displays")
                ?? NSImage(systemSymbolName: "display",
                           accessibilityDescription: "Virtual Displays")
        }
        menu.delegate = self
        statusItem.menu = menu

        // Start any profiles flagged to launch at login.
        for profile in ProfileStore.shared.loadOrCreate() where profile.autostart {
            _ = DisplayManager.shared.start(profile)
        }

        // Re-apply the chosen monitor layout once displays have settled at login.
        reapplyLayout(after: 4)

        // Route brightness / volume keys to the external monitor if enabled and permitted.
        // At launch, ask for Accessibility if it is missing: the ad-hoc signature changes
        // with every rebuild, so the grant is routinely dropped and the keys would
        // otherwise just quietly stop working.
        resumeKeyRouting(promptForAccess: true)

        // Routing only sticks while a monitor answers on DDC, so re-try whenever the
        // display set changes - otherwise docking after launch leaves the keys off.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() {
        mediaKeys.refreshLayout()
        applyVirtualBrightness()
        // Give the monitor a moment to come up before asking it anything over DDC.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.resumeKeyRouting() }
    }

    /// Re-apply the saved software brightness to every live virtual display. They are
    /// recreated from scratch at each launch, so the overlay has to be put back.
    private func applyVirtualBrightness() {
        let live = DisplayManager.shared.activeDisplayIDs
        DisplayShade.shared.prune(keeping: Set(live))
        let level = SettingsStore.shared.load().virtualBrightness
        guard level < 100 else { return }
        for id in live {
            DisplayShade.shared.set(level: level, for: id)
        }
    }

    /// Bring key routing in line with the saved preference, quietly - this also runs
    /// on every display change, so a monitor that can't answer just stays unrouted.
    private func resumeKeyRouting(promptForAccess: Bool = false) {
        let settings = SettingsStore.shared.load()
        guard settings.brightnessKeys != mediaKeys.routesBrightness
                || settings.volumeKeys != mediaKeys.routesVolume else { return }
        guard settings.brightnessKeys || settings.volumeKeys else { return }
        guard MediaKeyController.hasAccessibility(prompt: promptForAccess) else {
            log("key routing wanted but Accessibility is not granted to this binary")
            if promptForAccess { waitForAccessibility() }
            return
        }
        if let err = mediaKeys.update(brightness: settings.brightnessKeys,
                                      volume: settings.volumeKeys) {
            log("key routing did not start: \(err)")
        } else {
            log("key routing on - brightness: \(mediaKeys.routesBrightness), "
              + "volume: \(mediaKeys.routesVolume)")
        }
    }

    /// The permission dialog is answered outside this process, so watch for the grant and
    /// start routing the moment it lands - otherwise the keys stay dead until the next
    /// display change or a trip through the menu.
    private func waitForAccessibility() {
        var attempts = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
            attempts += 1
            if MediaKeyController.hasAccessibility(prompt: false) {
                timer.invalidate()
                self.resumeKeyRouting()
            } else if attempts >= 24 {   // stop pestering after two minutes
                timer.invalidate()
                self.log("gave up waiting for Accessibility; use the menu item when ready")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Goes to /tmp/vdisplaybar.log via the LaunchAgent, the only place a background
    /// menu-bar app can say something without interrupting the user.
    private func log(_ message: String) {
        FileHandle.standardError.write("vdisplaybar: \(message)\n".data(using: .utf8)!)
    }

    /// Creating or destroying a virtual display makes WindowServer reshuffle the
    /// physical monitor arrangement. If the user keeps a layout, re-apply it once
    /// the displays settle so toggling a display doesn't scramble their setup.
    private func reapplyLayout(after delay: TimeInterval = 2) {
        guard let layout = layoutToReapply() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // No alert - this fires at login and after every display toggle. Log it, so a
            // layout that can no longer be applied is visible instead of silently skipped.
            if let err = LayoutStore.shared.restore(layout) {
                self.log("could not restore layout “\(layout)”: \(err)")
            }
        }
    }

    /// The layout to snap back to: the explicit "Restore at Login" choice, or a
    /// layout literally named "default" if one was saved.
    private func layoutToReapply() -> String? {
        if let configured = SettingsStore.shared.load().startupLayout, !configured.isEmpty {
            return configured
        }
        return LayoutStore.shared.list().contains("default") ? "default" : nil
    }

    // Rebuild the menu each time it opens so state is always fresh.
    //
    // Layout: what you switch on at the top, what you drag in the middle, what you set
    // once tucked into submenus at the bottom.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let profiles = ProfileStore.shared.loadOrCreate()
        let manager = DisplayManager.shared
        let settings = SettingsStore.shared.load()
        let needsAccess = (settings.brightnessKeys || settings.volumeKeys)
            && !MediaKeyController.hasAccessibility(prompt: false)
        let width = Self.rowWidth(for: profiles.map(\.label))

        menu.addItem(disabledItem("Virtual Displays"))
        if profiles.isEmpty {
            menu.addItem(disabledItem("No profiles"))
        }
        for profile in profiles {
            let item = NSMenuItem(title: profile.label,
                                  action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.name
            item.state = manager.isActive(profile.name) ? .on : .off
            menu.addItem(item)
        }
        if !manager.activeNames.isEmpty {
            let stopAll = NSMenuItem(title: "Stop All Displays",
                                     action: #selector(stopAll), keyEquivalent: "")
            stopAll.target = self
            menu.addItem(stopAll)
        }

        // The monitor's own hardware controls, over DDC. Both sliders are continuous and
        // write asynchronously, so dragging stays smooth despite ~80ms per DDC exchange.
        let brightness = DDCControl.brightness.isAvailable ? DDCControl.brightness.get() : nil
        let volume = DDCControl.volume.isAvailable ? DDCControl.volume.get() : nil
        if brightness != nil || volume != nil {
            menu.addItem(.separator())
            menu.addItem(disabledItem("Monitor"))
            if let brightness {
                menu.addItem(sliderRow(symbol: "sun.max.fill", tip: "Monitor brightness (DDC)",
                                       value: brightness, width: width,
                                       action: #selector(brightnessChanged(_:))))
            }
            if let volume {
                menu.addItem(sliderRow(symbol: "speaker.wave.2.fill", tip: "Monitor volume (DDC)",
                                       value: volume, width: width,
                                       action: #selector(volumeChanged(_:))))
            }
        }

        // Virtual displays have no backlight, so they dim with an overlay instead.
        if !manager.activeDisplayIDs.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabledItem("Virtual Display"))
            menu.addItem(sliderRow(symbol: "circle.lefthalf.filled",
                                   tip: "Dim the virtual display (overlay)",
                                   value: settings.virtualBrightness, width: width,
                                   action: #selector(virtualBrightnessChanged(_:))))
        }

        menu.addItem(.separator())
        menu.addItem(layoutMenuItem())
        menu.addItem(settingsMenuItem(profiles: profiles, settings: settings))

        menu.addItem(.separator())
        if needsAccess {
            let fix = NSMenuItem(title: "⚠️ Grant Accessibility…",
                                 action: #selector(grantAccessibility), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Saved monitor arrangements: restore, pick one for login, save, delete.
    private func layoutMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Monitor Layout", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let saved = LayoutStore.shared.list()

        if saved.isEmpty {
            submenu.addItem(disabledItem("No saved layouts"))
        } else {
            for name in saved {
                let restore = NSMenuItem(title: "Restore “\(name)”",
                                         action: #selector(restoreLayout(_:)), keyEquivalent: "")
                restore.target = self
                restore.representedObject = name
                submenu.addItem(restore)
            }

            let atLogin = NSMenuItem(title: "Restore at Login", action: nil, keyEquivalent: "")
            let atLoginMenu = NSMenu()
            let current = SettingsStore.shared.load().startupLayout
            let none = NSMenuItem(title: "None",
                                  action: #selector(setStartupLayout(_:)), keyEquivalent: "")
            none.target = self
            none.representedObject = ""
            none.state = (current?.isEmpty ?? true) ? .on : .off
            atLoginMenu.addItem(none)
            for name in saved {
                let pick = NSMenuItem(title: name,
                                      action: #selector(setStartupLayout(_:)), keyEquivalent: "")
                pick.target = self
                pick.representedObject = name
                pick.state = (current == name) ? .on : .off
                atLoginMenu.addItem(pick)
            }
            atLogin.submenu = atLoginMenu
            submenu.addItem(atLogin)
        }

        submenu.addItem(.separator())
        let save = NSMenuItem(title: "Save Current Layout…",
                              action: #selector(saveLayoutPrompt), keyEquivalent: "")
        save.target = self
        submenu.addItem(save)

        if !saved.isEmpty {
            let delete = NSMenuItem(title: "Delete Layout", action: nil, keyEquivalent: "")
            let deleteMenu = NSMenu()
            for name in saved {
                let item = NSMenuItem(title: "\(name)…",
                                      action: #selector(deleteLayout(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                deleteMenu.addItem(item)
            }
            delete.submenu = deleteMenu
            submenu.addItem(delete)
        }

        item.submenu = submenu
        return item
    }

    /// Set-once preferences, kept out of the way of the controls above.
    private func settingsMenuItem(profiles: [DisplayProfile], settings: Settings) -> NSMenuItem {
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if !profiles.isEmpty {
            let auto = NSMenuItem(title: "Auto-start at Login", action: nil, keyEquivalent: "")
            let autoMenu = NSMenu()
            for profile in profiles {
                let sub = NSMenuItem(title: profile.name,
                                     action: #selector(toggleAuto(_:)), keyEquivalent: "")
                sub.target = self
                sub.representedObject = profile.name
                sub.state = profile.autostart ? .on : .off
                autoMenu.addItem(sub)
            }
            auto.submenu = autoMenu
            submenu.addItem(auto)
            submenu.addItem(.separator())
        }

        submenu.addItem(keysItem("Use Brightness Keys (F1/F2)",
                                 on: mediaKeys.routesBrightness,
                                 action: #selector(toggleBrightnessKeys)))
        submenu.addItem(keysItem("Use Volume Keys (F10-F12)",
                                 on: mediaKeys.routesVolume,
                                 action: #selector(toggleVolumeKeys)))

        submenu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit Profiles…",
                              action: #selector(editProfiles), keyEquivalent: "")
        edit.target = self
        submenu.addItem(edit)

        item.submenu = submenu
        return item
    }

    /// Width for the slider rows: a custom view does not stretch to the menu, so match the
    /// widest ordinary item instead of leaving a ragged gap down the right-hand side.
    private static func rowWidth(for extraTitles: [String]) -> CGFloat {
        let titles = extraTitles + ["Virtual Displays", "Stop All Displays", "Monitor Layout",
                                    "⚠️ Grant Accessibility…", "Settings", "Quit"]
        let font = NSFont.menuFont(ofSize: 0)
        let widest = titles
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        // Leave room for the state column on the left and the submenu arrow on the right.
        return min(360, max(230, ceil(widest) + 56))
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A full-width slider row: icon on the left, slider filling the rest of the width.
    private func sliderRow(symbol: String, tip: String, value: Int,
                           width: CGFloat, action: Selector) -> NSMenuItem {
        let height: CGFloat = 24
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.toolTip = tip

        let icon = NSImageView(frame: NSRect(x: 14, y: 3, width: 17, height: 17))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(icon)

        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: 100,
                              target: self, action: action)
        slider.frame = NSRect(x: 37, y: 1, width: width - 37 - 14, height: 20)
        slider.controlSize = .small
        // Continuous: the DDC writes behind these are queued and coalesced, so tracking
        // the knob live no longer means a blocking round trip per tick.
        slider.isContinuous = true
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    @objc private func virtualBrightnessChanged(_ sender: NSSlider) {
        let level = sender.integerValue
        for id in DisplayManager.shared.activeDisplayIDs {
            DisplayShade.shared.set(level: level, for: id)
        }
        // The overlay follows the knob immediately; the file write waits for the drag to
        // settle instead of rewriting JSON on every tick.
        saveVirtualBrightness?.cancel()
        let work = DispatchWorkItem {
            var settings = SettingsStore.shared.load()
            settings.virtualBrightness = level
            SettingsStore.shared.save(settings)
        }
        saveVirtualBrightness = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        DDCControl.brightness.setSoon(sender.integerValue)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        DDCControl.volume.setSoon(sender.integerValue)
    }

    private func keysItem(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleBrightnessKeys() {
        var settings = SettingsStore.shared.load()
        settings.brightnessKeys = !mediaKeys.routesBrightness
        applyKeyRouting(settings)
    }

    @objc private func toggleVolumeKeys() {
        var settings = SettingsStore.shared.load()
        settings.volumeKeys = !mediaKeys.routesVolume
        applyKeyRouting(settings)
    }

    /// Start/stop the key tap to match `settings`, then persist. When macOS hasn't
    /// granted Accessibility yet it shows its own dialog; we keep the intent so the
    /// routing starts by itself on the next launch once granted.
    private func applyKeyRouting(_ settings: Settings) {
        let wanted = settings.brightnessKeys || settings.volumeKeys
        if !wanted || MediaKeyController.hasAccessibility(prompt: true) {
            if let err = mediaKeys.update(brightness: settings.brightnessKeys,
                                          volume: settings.volumeKeys) {
                showError("Couldn’t route the keys", err)
            }
        }
        SettingsStore.shared.save(settings)
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let manager = DisplayManager.shared
        if manager.isActive(name) {
            manager.stop(name)
            DisplayShade.shared.prune(keeping: Set(manager.activeDisplayIDs))
            reapplyLayout()
        } else if let profile = ProfileStore.shared.loadOrCreate().first(where: { $0.name == name }) {
            guard let id = manager.start(profile) else {
                showError("Failed to create “\(name)”.",
                          "The private display API may have changed on this macOS version.")
                return
            }
            // A new display comes up at full brightness; put the saved dimming back.
            DisplayShade.shared.set(level: SettingsStore.shared.load().virtualBrightness, for: id)
            reapplyLayout()
        }
    }

    @objc private func toggleAuto(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var profiles = ProfileStore.shared.loadOrCreate()
        guard let idx = profiles.firstIndex(where: { $0.name == name }) else { return }
        profiles[idx].autostart.toggle()
        ProfileStore.shared.save(profiles)
    }

    @objc private func stopAll() {
        DisplayManager.shared.stopAll()
        DisplayShade.shared.clearAll()
        reapplyLayout()
    }

    @objc private func restoreLayout(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if let err = LayoutStore.shared.restore(name) {
            showError("Couldn’t restore “\(name)”", err)
        }
    }

    @objc private func deleteLayout(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let prompt = NSAlert()
        prompt.messageText = "Delete layout “\(name)”?"
        prompt.informativeText = "The saved arrangement is removed. Your displays stay as they are."
        prompt.addButton(withTitle: "Delete")
        prompt.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        LayoutStore.shared.delete(name)
    }

    @objc private func setStartupLayout(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String ?? ""
        var settings = SettingsStore.shared.load()
        settings.startupLayout = name.isEmpty ? nil : name
        SettingsStore.shared.save(settings)
    }

    @objc private func saveLayoutPrompt() {
        let prompt = NSAlert()
        prompt.messageText = "Save Current Layout"
        prompt.informativeText = "Name this monitor arrangement:"
        prompt.addButton(withTitle: "Save")
        prompt.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = "default"
        prompt.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let err = LayoutStore.shared.save(name) {
            showError("Couldn’t save layout", err)
        }
    }

    @objc private func grantAccessibility() {
        // Prompts if macOS is willing; otherwise the pane is where the stale entry lives.
        if MediaKeyController.hasAccessibility(prompt: true) {
            resumeKeyRouting()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Grant Accessibility to vdisplaybar"
        alert.informativeText = """
        The brightness and volume keys need Accessibility permission, and macOS drops it         whenever vdisplaybar is rebuilt.

        If vdisplaybar is already listed and ticked, the tick belongs to the old build:         remove the entry with the “−” button, then add         ~/.local/bin/vdisplaybar again (or toggle it off and on).
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func editProfiles() {
        _ = ProfileStore.shared.loadOrCreate() // ensure the file exists
        NSWorkspace.shared.open(URL(fileURLWithPath: ProfileStore.shared.path))
    }

    @objc private func quit() {
        DisplayShade.shared.clearAll()
        DisplayManager.shared.stopAll()
        NSApp.terminate(nil)
    }

    private func showError(_ message: String, _ info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
