import AppKit

/// Desktop locks: macOS's own "Assign To This Desktop" (the Dock's Options menu), managed from
/// SpaceApps. macOS keeps them in `com.apple.spaces` under `app-bindings`, as
/// lowercased bundle ID → desktop UUID, and the Dock reads them when it starts. The Dock ignores
/// keys that aren't lowercase, so every bundle ID is lowercased here.
///
/// With "Pause Locks with a Monitor" on, plugging in an external display stashes the locks
/// and clears them, so apps open wherever you are. Unplugging puts them back.
/// While paused, locking or unlocking an app edits the stash, so it applies once you unplug.
enum DesktopLocks {
    private static let domain = "com.apple.spaces" as CFString
    private static let key = "app-bindings" as CFString
    private static let pauseSettingKey = "PauseLocksWithMonitor"

    /// Where the locks wait while a monitor is connected. Its existence means "paused".
    private static let stashURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpaceApps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("paused-locks.plist")
    }()

    // MARK: Settings and state

    static var pauseWithMonitor: Bool {
        get { UserDefaults.standard.object(forKey: pauseSettingKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: pauseSettingKey)
            update()
        }
    }

    static var isPaused: Bool { FileManager.default.fileExists(atPath: stashURL.path) }

    /// Whether any connected display isn't the Mac's own screen.
    /// Set SPACEAPPS_FAKE_MONITOR=1 to test pausing without plugging anything in.
    static var externalDisplayConnected: Bool {
        if let fake = ProcessInfo.processInfo.environment["SPACEAPPS_FAKE_MONITOR"] { return fake == "1" }
        return NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(id.uint32Value) == 0
        }
    }

    // MARK: Locks

    /// The desktop UUID an app is locked to, from the stash while paused.
    static func lockedSpace(for bundleID: String) -> String? {
        (isPaused ? stashed() : live())[bundleID.lowercased()]
    }

    /// Every lock in effect (or waiting, while paused).
    static func allLocks() -> [String: String] { isPaused ? stashed() : live() }

    /// Locks the app to the desktop, or unlocks it if it's already locked there.
    static func toggle(bundleID: String, spaceUUID: String) {
        let key = bundleID.lowercased()
        var locks = isPaused ? stashed() : live()
        if locks[key] == spaceUUID {
            locks.removeValue(forKey: key)
        } else {
            locks[key] = spaceUUID
        }
        if isPaused {
            writeStash(locks)
        } else {
            setLive(locks)
            restartDock()
        }
    }

    // MARK: Monitor-aware pausing

    /// Pauses or resumes the locks to match the setting and the connected displays.
    static func update() {
        fixKeyCase()
        let shouldPause = pauseWithMonitor && externalDisplayConnected
        if shouldPause && !isPaused {
            let locks = live()
            writeStash(locks)
            if !locks.isEmpty {
                setLive([:])
                restartDock()
            }
        } else if !shouldPause && isPaused {
            // Locks made in the Dock while paused are kept; the stash wins on a clash.
            let locks = live().merging(stashed()) { _, stashed in stashed }
            try? FileManager.default.removeItem(at: stashURL)
            if locks != live() {
                setLive(locks)
                restartDock()
            }
        }
    }

    // MARK: Storage

    /// Lowercases any lock keys saved by older versions of SpaceApps, so the Dock honours them.
    private static func fixKeyCase() {
        let locks = live()
        let fixed = Dictionary(locks.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        if fixed != locks {
            setLive(fixed)
            restartDock()
        }
        let stash = stashed()
        if isPaused, !stash.isEmpty {
            writeStash(Dictionary(stash.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    private static func live() -> [String: String] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [String: String] ?? [:]
    }

    private static func setLive(_ locks: [String: String]) {
        CFPreferencesSetAppValue(key, locks.isEmpty ? nil : locks as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
    }

    private static func stashed() -> [String: String] {
        guard let data = try? Data(contentsOf: stashURL),
              let locks = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return locks
    }

    private static func writeStash(_ locks: [String: String]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: locks, format: .xml, options: 0) else { return }
        try? data.write(to: stashURL, options: .atomic)
    }

    /// The Dock only reads the locks when it starts. It restarts in about a second.
    private static func restartDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
    }
}
