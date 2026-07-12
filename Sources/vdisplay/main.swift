import Foundation
import VirtualDisplayKit

let store = ProfileStore.shared
let manager = DisplayManager.shared
let args = Array(CommandLine.arguments.dropFirst())

func die(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func usage() {
    print("""
    vdisplay — virtual displays for macOS

    usage:
      vdisplay [-w W -h H] [-r HZ] [-n NAME] [--no-hidpi]
                                 create an ad-hoc display and hold it (Ctrl-C removes)
      vdisplay run <profile>     create a saved profile and hold it
      vdisplay list              list saved profiles (● = active)
      vdisplay add <name> <W> <H> [HZ]
      vdisplay remove <name>
      vdisplay path              print the profiles file location

      vdisplay layouts           list saved monitor arrangements
      vdisplay save-layout [name]     snapshot the current arrangement (default: "default")
      vdisplay restore-layout [name]  re-apply a saved arrangement
      vdisplay startup-layout [name|none]
                                 get/set the layout auto-restored at login
      vdisplay --help

    Profiles live at ~/.config/vdisplay/profiles.json
    """)
}

/// Create the display and block until Ctrl-C.
func hold(_ profile: DisplayProfile) -> Never {
    guard let id = manager.start(profile) else { die("failed to create display") }
    print("✅ \(profile.label)  (display id \(id))")
    print("   press Ctrl-C to remove it.")
    signal(SIGINT) { _ in print("\n👋 removed"); exit(0) }
    RunLoop.main.run()
    exit(0)
}

guard let command = args.first else {
    hold(DisplayProfile(name: "Virtual 16:9", width: 1920, height: 1080))
}

switch command {
case "--help", "-?", "help":
    usage()

case "list":
    for p in store.loadOrCreate() {
        let mark = manager.isActive(p.name) ? "●" : "○"
        print("\(mark) \(p.label)\(p.autostart ? "  [auto]" : "")")
    }

case "path":
    print(store.path)

case "layouts":
    let saved = LayoutStore.shared.list()
    if saved.isEmpty { print("(no saved layouts)") } else { saved.forEach { print($0) } }

case "save-layout":
    let name = args.count >= 2 ? args[1] : "default"
    if let err = LayoutStore.shared.save(name) { die(err) }
    print("✅ saved current arrangement as “\(name)”")

case "restore-layout":
    let name = args.count >= 2 ? args[1] : "default"
    if let err = LayoutStore.shared.restore(name) { die(err) }
    print("✅ restored arrangement “\(name)”")

case "startup-layout":
    if args.count >= 2 {
        var settings = SettingsStore.shared.load()
        settings.startupLayout = args[1].lowercased() == "none" ? nil : args[1]
        guard SettingsStore.shared.save(settings) else { die("could not write settings") }
        print("login layout set to: \(settings.startupLayout ?? "none")")
    } else {
        print(SettingsStore.shared.load().startupLayout ?? "none")
    }

case "check":
    // Non-blocking probe: try to create the display, report ok/fail, exit.
    // usage: vdisplay check <W> <H> [--no-hidpi]
    guard args.count >= 3, let w = UInt32(args[1]), let h = UInt32(args[2]) else {
        die("usage: vdisplay check <W> <H> [--no-hidpi]")
    }
    let hidpi = !args.contains("--no-hidpi")
    let backing = hidpi ? "\(w * 2)×\(h * 2)" : "\(w)×\(h)"
    let profile = DisplayProfile(name: "check", width: w, height: h, hiDPI: hidpi)
    if manager.start(profile) != nil {
        print("✅ ok    \(w)×\(h) hidpi=\(hidpi) (backing \(backing))")
        manager.stop("check")
    } else {
        print("❌ FAIL  \(w)×\(h) hidpi=\(hidpi) (backing \(backing))")
    }

case "run":
    guard args.count >= 2 else { die("run needs a profile name — try: vdisplay list") }
    guard let p = store.loadOrCreate().first(where: { $0.name == args[1] }) else {
        die("no profile named “\(args[1])” — try: vdisplay list")
    }
    hold(p)

case "add":
    guard args.count >= 4, let w = UInt32(args[2]), let h = UInt32(args[3]) else {
        die("usage: vdisplay add <name> <W> <H> [HZ]")
    }
    let hz = args.count >= 5 ? (Double(args[4]) ?? 60) : 60
    var profiles = store.loadOrCreate()
    profiles.removeAll { $0.name == args[1] }
    profiles.append(DisplayProfile(name: args[1], width: w, height: h, refreshRate: hz))
    guard store.save(profiles) else { die("could not write \(store.path)") }
    print("added “\(args[1])” — \(w)×\(h) @\(Int(hz))Hz")

case "remove":
    guard args.count >= 2 else { die("usage: vdisplay remove <name>") }
    var profiles = store.loadOrCreate()
    let before = profiles.count
    profiles.removeAll { $0.name == args[1] }
    guard profiles.count < before else { die("no profile named “\(args[1])”") }
    guard store.save(profiles) else { die("could not write \(store.path)") }
    print("removed “\(args[1])”")

default:
    // Ad-hoc flag form: vdisplay -w 1920 -h 1080 ...
    var w: UInt32 = 1920, h: UInt32 = 1080, r = 60.0, name = "Virtual 16:9", hidpi = true
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "-w", "--width":   if let v = it.next(), let n = UInt32(v) { w = n }
        case "-h", "--height":  if let v = it.next(), let n = UInt32(v) { h = n }
        case "-r", "--refresh": if let v = it.next(), let n = Double(v) { r = n }
        case "-n", "--name":    if let v = it.next() { name = v }
        case "--no-hidpi":      hidpi = false
        default: die("unknown argument “\(a)” — try: vdisplay --help")
        }
    }
    hold(DisplayProfile(name: name, width: w, height: h, refreshRate: r, hiDPI: hidpi))
}
