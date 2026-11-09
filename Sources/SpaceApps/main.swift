import AppKit

// SpaceApps: a menu bar strip of the apps with windows on the current Space.

let args = CommandLine.arguments

// `SpaceApps --print`: list the apps on this Space and exit (for checking from the terminal).
if args.contains("--print") {
    for app in SpaceScanner.appsOnCurrentSpace() { print(app.name) }
    exit(0)
}

// `SpaceApps --spaces`: list every Space's apps, in Mission Control order, and exit.
if args.contains("--spaces") {
    let spaces = SpaceScanner.orderedSpaces()
    let apps = SpaceScanner.apps(onSpaces: spaces.map(\.id))
    for (index, space) in spaces.enumerated() {
        let label = space.isFullScreen ? "Full Screen" : "Desktop \(index + 1)"
        print("\(label) (space \(space.id), \(space.uuid ?? "no uuid")): " + (apps[space.id] ?? []).map(\.name).joined(separator: ", "))
    }
    exit(0)
}

// `SpaceApps --locks`: show which apps are locked to which desktop, and whether locks are paused.
if args.contains("--locks") {
    let numbers = Dictionary(uniqueKeysWithValues: SpaceScanner.orderedSpaces().filter { !$0.isFullScreen }
        .enumerated().compactMap { i, s in s.uuid.map { ($0, i + 1) } })
    print("Pause with a monitor: \(DesktopLocks.pauseWithMonitor ? "on" : "off"), external display: \(DesktopLocks.externalDisplayConnected ? "yes" : "no"), paused: \(DesktopLocks.isPaused ? "yes" : "no")")
    for (bundleID, uuid) in DesktopLocks.allLocks().sorted(by: { $0.key < $1.key }) {
        print("\(bundleID) → " + (numbers[uuid].map { "Desktop \($0)" } ?? (uuid.isEmpty ? "All Desktops" : "unknown desktop \(uuid)")))
    }
    exit(0)
}

// `SpaceApps --toggle-lock <bundle ID> <desktop number>`: lock or unlock an app, like the menu's lock button.
if let i = args.firstIndex(of: "--toggle-lock"), args.count > i + 2, let n = Int(args[i + 2]) {
    let desktops = SpaceScanner.orderedSpaces().filter { !$0.isFullScreen }
    guard desktops.indices.contains(n - 1), let uuid = desktops[n - 1].uuid else { print("No Desktop \(n)"); exit(1) }
    DesktopLocks.toggle(bundleID: args[i + 1], spaceUUID: uuid)
    print(DesktopLocks.lockedSpace(for: args[i + 1]) == uuid ? "Locked to Desktop \(n)" : "Unlocked")
    exit(0)
}

// `SpaceApps --update-locks`: pause or resume locks for the connected displays, as the app does.
if args.contains("--update-locks") {
    DesktopLocks.update()
    print("Locks are " + (DesktopLocks.isPaused ? "paused" : "active"))
    exit(0)
}

/// Runs a Mission Control move from the terminal and exits when it's done.
func runAndExit(_ work: @escaping @MainActor () async throws -> Void) -> Never {
    Task {
        do {
            try await work()
            print("Done")
            exit(0)
        } catch {
            print("Failed: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
    exit(0)
}

// `SpaceApps --move-app <bundle ID> <desktop number | new>`: move an app's windows to another
// desktop (or a new one), like dragging it in the menu. Needs Accessibility.
if let i = args.firstIndex(of: "--move-app"), args.count > i + 2 {
    let spaces = SpaceScanner.orderedSpaces()
    let desktops = spaces.filter { !$0.isFullScreen }
    let appsBySpace = SpaceScanner.apps(onSpaces: spaces.map(\.id))
    let wanted = args[i + 1].lowercased()
    let found = spaces.lazy.compactMap { space in
        appsBySpace[space.id]?.first { $0.bundleID?.lowercased() == wanted }.map { (space.id, $0) }
    }.first
    guard let (source, app) = found else { print("No windows for \(args[i + 1])"); exit(1) }
    let destination: MissionControl.Destination
    if args[i + 2] == "new" {
        destination = .newDesktop
    } else if let n = Int(args[i + 2]), desktops.indices.contains(n - 1) {
        destination = .desktop(desktops[n - 1].id)
    } else {
        print("No Desktop \(args[i + 2])"); exit(1)
    }
    runAndExit { try await MissionControl.move(app, from: source, to: destination) }
}

// `SpaceApps --move-desktop <from> <to>`: move Desktop <from> into Desktop <to>'s place.
if let i = args.firstIndex(of: "--move-desktop"), args.count > i + 2, let a = Int(args[i + 1]), let b = Int(args[i + 2]) {
    let desktops = SpaceScanner.orderedSpaces().filter { !$0.isFullScreen }
    guard desktops.indices.contains(a - 1), desktops.indices.contains(b - 1) else { print("No such desktop"); exit(1) }
    runAndExit { try await MissionControl.moveDesktop(desktops[a - 1].id, toPlaceOf: desktops[b - 1].id) }
}

// `SpaceApps --bench`: time how long one scan takes and exit.
if args.contains("--bench") {
    let runs = 200
    let start = Date()
    for _ in 0..<runs { _ = SpaceScanner.appsOnCurrentSpace() }
    print(String(format: "%.2f ms per scan (%d runs)", Date().timeIntervalSince(start) * 1000 / Double(runs), runs))
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusController()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only: no Dock icon
app.run()
