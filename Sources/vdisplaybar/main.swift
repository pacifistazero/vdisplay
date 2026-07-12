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

        // Route brightness keys to the external monitor if enabled and permitted.
        if SettingsStore.shared.load().brightnessKeys,
           MediaKeyController.hasAccessibility(prompt: false) {
            _ = mediaKeys.start()
        }
    }

    /// Creating or destroying a virtual display makes WindowServer reshuffle the
    /// physical monitor arrangement. If the user keeps a layout, re-apply it once
    /// the displays settle so toggling a display doesn't scramble their setup.
    private func reapplyLayout(after delay: TimeInterval = 2) {
        guard let layout = layoutToReapply() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            _ = LayoutStore.shared.restore(layout)
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
        layoutItem.submenu = layoutMenu
        menu.addItem(layoutItem)

        // Physical-monitor brightness over DDC (only when m1ddc is installed).
        if let brightness = brightnessMenuItem() {
            menu.addItem(.separator())
            menu.addItem(disabledItem("Monitor Brightness"))
            menu.addItem(brightness)

            let keys = NSMenuItem(title: "Use Brightness Keys (F1/F2)",
                                  action: #selector(toggleBrightnessKeys(_:)), keyEquivalent: "")
            keys.target = self
            keys.state = mediaKeys.isRunning ? .on : .off
            menu.addItem(keys)
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

    /// A menu item hosting a slider for physical-monitor brightness, or nil if
    /// the DDC engine (m1ddc) isn't installed.
    private func brightnessMenuItem() -> NSMenuItem? {
        guard BrightnessController.shared.isAvailable else { return nil }
        let width: CGFloat = 220, height: CGFloat = 28
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let slider = NSSlider(value: Double(BrightnessController.shared.get() ?? 100),
                              minValue: 0, maxValue: 100,
                              target: self, action: #selector(brightnessChanged(_:)))
        slider.frame = NSRect(x: 20, y: 4, width: width - 40, height: 20)
        // DDC writes are slow; fire on release rather than on every drag tick.
        slider.isContinuous = false
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        if let err = BrightnessController.shared.set(sender.integerValue) {
            showError("Couldn’t set brightness", err)
        }
    }

    @objc private func toggleBrightnessKeys(_ sender: NSMenuItem) {
        var settings = SettingsStore.shared.load()
        if mediaKeys.isRunning {
            mediaKeys.stop()
            settings.brightnessKeys = false
            SettingsStore.shared.save(settings)
            return
        }
        // Enabling: needs Accessibility permission to install a swallowing tap.
        guard MediaKeyController.hasAccessibility(prompt: true) else {
            settings.brightnessKeys = true   // remember intent; starts once granted
            SettingsStore.shared.save(settings)
            promptForAccessibility()
            return
        }
        if mediaKeys.start() {
            settings.brightnessKeys = true
        } else {
            settings.brightnessKeys = false
            promptForAccessibility()
        }
        SettingsStore.shared.save(settings)
    }

    private func promptForAccessibility() {
        let a = NSAlert()
        a.messageText = "Accessibility permission needed"
        a.informativeText = """
        To use the brightness keys on your external monitor, grant vdisplaybar \
        access under System Settings › Privacy & Security › Accessibility, then \
        enable this again.
        """
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let manager = DisplayManager.shared
        if manager.isActive(name) {
            manager.stop(name)
            reapplyLayout()
        } else if let profile = ProfileStore.shared.loadOrCreate().first(where: { $0.name == name }) {
            if manager.start(profile) == nil {
                showError("Failed to create “\(name)”.",
                          "The private display API may have changed on this macOS version.")
            } else {
                reapplyLayout()
            }
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
        reapplyLayout()
    }

    @objc private func restoreLayout(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if let err = LayoutStore.shared.restore(name) {
            showError("Couldn’t restore “\(name)”", err)
        }
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

    @objc private func editProfiles() {
        _ = ProfileStore.shared.loadOrCreate() // ensure the file exists
        NSWorkspace.shared.open(URL(fileURLWithPath: ProfileStore.shared.path))
    }

    @objc private func quit() {
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
