import Cocoa
import VirtualDisplayKit

/// A menu-bar app to toggle virtual displays defined in the saved profiles.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

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

        // Re-apply the chosen monitor layout once displays have settled.
        if let layout = SettingsStore.shared.load().startupLayout, !layout.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                _ = LayoutStore.shared.restore(layout)
            }
        }
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

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let manager = DisplayManager.shared
        if manager.isActive(name) {
            manager.stop(name)
        } else if let profile = ProfileStore.shared.loadOrCreate().first(where: { $0.name == name }) {
            if manager.start(profile) == nil {
                showError("Failed to create “\(name)”.",
                          "The private display API may have changed on this macOS version.")
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
