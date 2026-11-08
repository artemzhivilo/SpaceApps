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
        print("\(label) (space \(space.id)): " + (apps[space.id] ?? []).map(\.name).joined(separator: ", "))
    }
    exit(0)
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
