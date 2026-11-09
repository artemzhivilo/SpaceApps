import AppKit

/// An app with at least one normal window on a Space.
struct SpaceApp: Equatable {
    let pid: pid_t
    let name: String
    let bundleURL: URL?
    let bundleID: String?
}

extension SpaceApp {
    /// Switches to the app. If its windows are on another desktop, macOS moves you there.
    func activate() {
        if let bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config)
        } else {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }
}

/// A Space (desktop) on the main display, in Mission Control order.
struct Space {
    let id: UInt64
    let uuid: String?  // what macOS's "Assign To This Desktop" locks refer to
    let isFullScreen: Bool
}

// Private SkyLight calls (the same ones yabai and AltTab use). Public APIs can't tell which
// Space a window is on, or whether a window on another Space is actually shown.
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace") func CGSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

enum SpaceScanner {
    /// Apps with normal windows on the current Space, alphabetical so icons don't jump around.
    /// Reads window owners only (no titles), so it needs no Screen Recording permission.
    static func appsOnCurrentSpace() -> [SpaceApp] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let cid = CGSMainConnectionID()
        let activeSpace = CGSGetActiveSpace(cid)
        var seen = Set<pid_t>()
        var apps: [SpaceApp] = []
        for w in windows {
            guard let (pid, wid, app) = normalAppWindow(w), !seen.contains(pid),
                  spaces(of: wid, cid: cid)?.contains(activeSpace) ?? true else { continue }
            seen.insert(pid)
            apps.append(SpaceApp(pid: pid, name: app.localizedName ?? "App", bundleURL: app.bundleURL, bundleID: app.bundleIdentifier))
        }
        return sorted(apps)
    }

    /// The main display's Spaces, in the order Mission Control shows them.
    static func orderedSpaces() -> [Space] {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]],
              let main = displays.first,
              let spaces = main["Spaces"] as? [[String: Any]] else { return [] }
        return spaces.compactMap { info in
            guard let id = (info["id64"] as? NSNumber ?? info["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
            return Space(id: id, uuid: info["uuid"] as? String, isFullScreen: (info["type"] as? NSNumber)?.intValue == 4)
        }
    }

    static var activeSpaceID: UInt64 { CGSGetActiveSpace(CGSMainConnectionID()) }

    /// Apps with windows actually shown on each of the given Spaces, including Spaces you're
    /// not on. Hidden, minimized and closed-but-kept windows don't count.
    static func apps(onSpaces spaceIDs: [UInt64]) -> [UInt64: [SpaceApp]] {
        var result: [UInt64: [SpaceApp]] = [:]
        guard let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return result
        }
        let cid = CGSMainConnectionID()
        let wanted = Set(spaceIDs)
        var seen: [UInt64: Set<pid_t>] = [:]
        for w in windows {
            guard let (pid, wid, app) = normalAppWindow(w), !app.isHidden,
                  isOrderedIn(wid, cid: cid),
                  let windowSpaces = spaces(of: wid, cid: cid) else { continue }
            for space in windowSpaces where wanted.contains(space) {
                if seen[space, default: []].insert(pid).inserted {
                    result[space, default: []].append(SpaceApp(pid: pid, name: app.localizedName ?? "App", bundleURL: app.bundleURL, bundleID: app.bundleIdentifier))
                }
            }
        }
        for key in result.keys { result[key] = sorted(result[key] ?? []) }
        return result
    }

    // MARK: Helpers

    /// A normal-level, reasonably sized window belonging to a regular (Dock) app.
    private static func normalAppWindow(_ w: [String: Any]) -> (pid_t, Int, NSRunningApplication)? {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              pid != ProcessInfo.processInfo.processIdentifier,
              let wid = w[kCGWindowNumber as String] as? Int else { return nil }
        if let alpha = w[kCGWindowAlpha as String] as? Double, alpha <= 0 { return nil }
        if let b = w[kCGWindowBounds as String] as? [String: CGFloat],
           (b["Width"] ?? 0) < 60 || (b["Height"] ?? 0) < 40 { return nil }  // tiny helper windows
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else { return nil }           // skip menu bar–only apps
        return (pid, wid, app)
    }

    /// The Spaces a window is on, or nil if macOS doesn't answer.
    private static func spaces(of wid: Int, cid: Int32) -> [UInt64]? {
        let ids = [NSNumber(value: wid)] as CFArray
        return (CGSCopySpacesForWindows(cid, 0x7, ids)?.takeRetainedValue() as? [NSNumber])?.map(\.uint64Value)
    }

    /// Whether a window is actually shown (minimized and closed windows are "ordered out").
    /// Looked up at runtime; if macOS ever drops the call, every window counts as shown.
    private typealias OrderedInFunction = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Bool>) -> Int32
    private static let orderedInFunction: OrderedInFunction? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(skyLight, "SLSWindowIsOrderedIn") else { return nil }
        return unsafeBitCast(symbol, to: OrderedInFunction.self)
    }()

    private static func isOrderedIn(_ wid: Int, cid: Int32) -> Bool {
        guard let function = orderedInFunction else { return true }
        var orderedIn = false
        return function(cid, UInt32(wid), &orderedIn) == 0 ? orderedIn : true
    }

    private static func sorted(_ apps: [SpaceApp]) -> [SpaceApp] {
        apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
