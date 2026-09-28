import Cocoa
import VirtualDisplayKit

/// A menu-bar app to toggle virtual displays defined in the saved profiles.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let mediaKeys = MediaKeyController()

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
        resumeKeyRouting()

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
    private func resumeKeyRouting() {
        let settings = SettingsStore.shared.load()
        guard settings.brightnessKeys != mediaKeys.routesBrightness
                || settings.volumeKeys != mediaKeys.routesVolume else { return }
        guard settings.brightnessKeys || settings.volumeKeys else { return }
        guard MediaKeyController.hasAccessibility(prompt: false) else {
            log("key routing wanted but Accessibility is not granted to this binary")
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
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let profiles = ProfileStore.shared.loadOrCreate()
        let manager = DisplayManager.shared

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

        menu.addItem(.separator())

        if !profiles.isEmpty {
            let autoItem = NSMenuItem(title: "Auto-start at Login",
                                      action: nil, keyEquivalent: "")
            let autoMenu = NSMenu()
            for profile in profiles {
                let sub = NSMenuItem(title: profile.name,
                                     action: #selector(toggleAuto(_:)), keyEquivalent: "")
                sub.target = self
                sub.representedObject = profile.name
                sub.state = profile.autostart ? .on : .off
                autoMenu.addItem(sub)
            }
            autoItem.submenu = autoMenu
            menu.addItem(autoItem)

            let stopAll = NSMenuItem(title: "Stop All Displays",
                                     action: #selector(stopAll), keyEquivalent: "")
            stopAll.target = self
            menu.addItem(stopAll)
        }

        menu.addItem(.separator())

        // Monitor arrangement save/restore.
        let layoutItem = NSMenuItem(title: "Monitor Layout", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu()
        let saved = LayoutStore.shared.list()
        if saved.isEmpty {
            layoutMenu.addItem(disabledItem("No saved layouts"))
        } else {
            for name in saved {
                let item = NSMenuItem(title: "Restore “\(name)”",
                                      action: #selector(restoreLayout(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                layoutMenu.addItem(item)
            }
        }
        if !saved.isEmpty {
            let atLogin = NSMenuItem(title: "Restore at Login", action: nil, keyEquivalent: "")
            let atLoginMenu = NSMenu()
            let current = SettingsStore.shared.load().startupLayout
            let none = NSMenuItem(title: "None",
                                  action: #selector(setStartupLayout(_:)), keyEquivalent: "")
            none.target = self
            none.representedObject = ""
            none.state = (current == nil || current!.isEmpty) ? .on : .off
            atLoginMenu.addItem(none)
            for name in saved {
                let item = NSMenuItem(title: name,
                                      action: #selector(setStartupLayout(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.state = (current == name) ? .on : .off
                atLoginMenu.addItem(item)
            }
            atLogin.submenu = atLoginMenu
            layoutMenu.addItem(atLogin)
        }

        layoutMenu.addItem(.separator())
        let saveLayout = NSMenuItem(title: "Save Current Layout…",
                                    action: #selector(saveLayoutPrompt), keyEquivalent: "")
        saveLayout.target = self
        layoutMenu.addItem(saveLayout)

        if !saved.isEmpty {
            let deleteItem = NSMenuItem(title: "Delete Layout", action: nil, keyEquivalent: "")
            let deleteMenu = NSMenu()
            for name in saved {
                let item = NSMenuItem(title: "\(name)…",
                                      action: #selector(deleteLayout(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                deleteMenu.addItem(item)
            }
            deleteItem.submenu = deleteMenu
            layoutMenu.addItem(deleteItem)
        }
        layoutItem.submenu = layoutMenu
        menu.addItem(layoutItem)

        // Physical-monitor brightness over DDC (only when m1ddc is installed). The
        // slider needs a monitor that answers; the keys toggle is always shown so
        // there is something to click once one is connected.
        // ponytail: each section costs one synchronous m1ddc read per menu open;
        // cache + refresh in the background if the menu ever feels sluggish.
        if DDCControl.brightness.isAvailable {
            menu.addItem(.separator())
            menu.addItem(disabledItem("Monitor Brightness"))
            if let brightness = sliderItem(for: .brightness, action: #selector(brightnessChanged(_:))) {
                menu.addItem(brightness)
            }

            menu.addItem(keysItem("Use Brightness Keys (F1/F2)",
                                  on: mediaKeys.routesBrightness,
                                  action: #selector(toggleBrightnessKeys)))
        }

        // Virtual displays have no backlight, so they dim with an overlay instead of DDC.
        if !DisplayManager.shared.activeDisplayIDs.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabledItem("Virtual Display Brightness"))
            let level = SettingsStore.shared.load().virtualBrightness
            menu.addItem(sliderItem(value: level,
                                    action: #selector(virtualBrightnessChanged(_:)),
                                    continuous: true))
        }

        // Monitor speaker volume over DDC - macOS can't drive it when the panel's
        // own speakers are the output (HDMI/DP digital out has no software volume).
        if DDCControl.volume.isAvailable {
            menu.addItem(.separator())
            menu.addItem(disabledItem("Monitor Volume"))
            if let volume = sliderItem(for: .volume, action: #selector(volumeChanged(_:))) {
                menu.addItem(volume)
            }
            menu.addItem(keysItem("Use Volume Keys (F10-F12)",
                                  on: mediaKeys.routesVolume,
                                  action: #selector(toggleVolumeKeys)))
        }

        // The keys silently do nothing without Accessibility, and the grant is dropped
        // every time the binary is rebuilt - so say so where it can be acted on.
        let settings = SettingsStore.shared.load()
        if settings.brightnessKeys || settings.volumeKeys,
           !MediaKeyController.hasAccessibility(prompt: false) {
            menu.addItem(.separator())
            let fix = NSMenuItem(title: "⚠️ Keys need Accessibility — Grant…",
                                 action: #selector(grantAccessibility), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }

        menu.addItem(.separator())

        let edit = NSMenuItem(title: "Edit Profiles…",
                              action: #selector(editProfiles), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A menu item hosting a slider for a DDC feature, or nil if the engine
    /// (m1ddc) isn't installed or the monitor doesn't report that feature
    /// (e.g. volume on a panel with no speakers).
    private func sliderItem(for control: DDCControl, action: Selector) -> NSMenuItem? {
        guard control.isAvailable, let current = control.get() else { return nil }
        // DDC writes are slow; fire on release rather than on every drag tick.
        return sliderItem(value: current, action: action, continuous: false)
    }

    private func sliderItem(value: Int, action: Selector, continuous: Bool) -> NSMenuItem {
        let width: CGFloat = 220, height: CGFloat = 28
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: 100,
                              target: self, action: action)
        slider.frame = NSRect(x: 20, y: 4, width: width - 40, height: 20)
        slider.isContinuous = continuous
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    @objc private func virtualBrightnessChanged(_ sender: NSSlider) {
        for id in DisplayManager.shared.activeDisplayIDs {
            DisplayShade.shared.set(level: sender.integerValue, for: id)
        }
        var settings = SettingsStore.shared.load()
        settings.virtualBrightness = sender.integerValue
        SettingsStore.shared.save(settings)
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        apply(.brightness, sender.integerValue)
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        apply(.volume, sender.integerValue)
    }

    private func apply(_ control: DDCControl, _ value: Int) {
        if let err = control.set(value) {
            showError("Couldn’t set \(control.label)", err)
        }
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
