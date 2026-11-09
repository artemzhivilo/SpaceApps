import AppKit

/// Moves apps between desktops, adds desktops and reorders them by working Mission Control.
/// macOS 27 only lets Mission Control do these (apps can't move another app's windows), so
/// SpaceApps opens it and drags for you, the way you would by hand. It shows for a second or two
/// and needs Accessibility permission.
///
/// Mission Control's accessibility tree: `mc.display` holds a button per window on the current
/// desktop, tagged `<bundle id>.space.<space id>`, and `mc.spaces` → `mc.spaces.list` holds a button
/// per Space in order, then `mc.spaces.add`. Window buttons report a normal frame, but Space
/// buttons report their centre as their position, so drops aim at that point.
enum MissionControl {
    enum Destination: Equatable {
        case desktop(UInt64)
        case newDesktop
    }

    enum Failure: Error {
        case notAllowed, busy, couldNotSwitch, didNotOpen, windowNotFound, desktopNotFound, didNotMove
    }

    // MARK: Permission

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own Accessibility prompt, which also adds SpaceApps to the list (switched off).
    static func showSystemPrompt() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Moving an app

    private static var isBusy = false

    /// Moves the app's windows on `source` to another desktop, or to a new desktop at the end.
    /// Mission Control only shows the current desktop's windows, so if the app is on another
    /// desktop it goes there first, then comes back to where you were.
    static func move(_ app: SpaceApp, from source: UInt64, to destination: Destination) async throws {
        guard isAllowed else { throw Failure.notAllowed }
        guard !isBusy else { throw Failure.busy }
        guard let bundleID = app.bundleID else { throw Failure.windowNotFound }
        isBusy = true
        defer { isBusy = false }
        let home = SpaceScanner.activeSpaceID
        let cursor = CGEvent(source: nil)?.location
        defer { if let cursor { CGWarpMouseCursorPosition(cursor) } }

        if source != home { try await go(to: source) }

        let windowID = "\(bundleID.lowercased()).space.\(source)"
        let wm = try open()
        var closed = false
        defer { if !closed { toggle() } }

        guard await wait(upTo: 2.5, until: { !windowButtons(windowID).isEmpty }) else { throw Failure.windowNotFound }
        try await settle { windowButtons(windowID).first.flatMap(frame) }

        // The desktop to drop on, found again before each drop because the bar moves around.
        let target: () -> AXUIElement?
        switch destination {
        case .desktop(let spaceID):
            target = { spaceButton(for: spaceID, in: wm) }
        case .newDesktop:
            let before = spaceButtons(wm).count
            guard let add = child(of: spacesBar(wm), id: "mc.spaces.add") else { throw Failure.desktopNotFound }
            AXUIElementPerformAction(add, kAXPressAction as CFString)
            guard await wait(upTo: 2, until: { spaceButtons(wm).count == before + 1 }) else { throw Failure.desktopNotFound }
            try await pause(0.3)
            target = { spaceButtons(wm).last }
        }

        // One drag per window; each moved window leaves Mission Control's main area.
        for _ in 0..<8 {
            guard let window = windowButtons(windowID).first, let start = frame(window)?.center else { break }
            try await dragWindow(from: start, onto: target)
            try await pause(0.45)
        }
        guard windowButtons(windowID).isEmpty else { throw Failure.didNotMove }

        if source != home {
            // "Exit To Desktop N": close Mission Control on the desktop you started from.
            if let button = spaceButton(for: home, in: wm),
               AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                closed = true
            }
        }
    }

    /// Switches desktop through Mission Control ("Exit To Desktop N"). Activating the app
    /// instead isn't allowed from the background, and picks the wrong desktop for apps on several.
    private static func go(to spaceID: UInt64) async throws {
        let wm = try open()
        guard await wait(upTo: 2.5, until: { spaceButton(for: spaceID, in: wm) != nil }),
              let button = spaceButton(for: spaceID, in: wm) else {
            toggle()
            throw Failure.didNotOpen
        }
        try await settle { position(button) }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard await wait(upTo: 2.5, until: { SpaceScanner.activeSpaceID == spaceID }) else { throw Failure.couldNotSwitch }
        try await pause(0.35)
    }

    // MARK: Reordering desktops

    /// Moves a desktop into the place of another one (the others shift along), like dragging it
    /// in Mission Control's Spaces bar.
    static func moveDesktop(_ spaceID: UInt64, toPlaceOf targetID: UInt64) async throws {
        guard isAllowed else { throw Failure.notAllowed }
        guard !isBusy else { throw Failure.busy }
        let order = SpaceScanner.orderedSpaces().map(\.id)
        guard let from = order.firstIndex(of: spaceID), let to = order.firstIndex(of: targetID) else { throw Failure.desktopNotFound }
        guard from != to else { return }
        isBusy = true
        defer { isBusy = false }
        let cursor = CGEvent(source: nil)?.location
        defer { if let cursor { CGWarpMouseCursorPosition(cursor) } }

        let wm = try open()
        defer { toggle() }
        guard await wait(upTo: 2.5, until: { spaceButtons(wm).count == order.count }) else { throw Failure.didNotOpen }
        try await settle { spaceButtons(wm).first.flatMap(position) }

        // Hover over the bar so it expands into thumbnails, then drag at the expanded size.
        guard let collapsed = position(spaceButtons(wm)[from]) else { throw Failure.desktopNotFound }
        post(.mouseMoved, CGPoint(x: collapsed.x, y: 40))
        try await pause(0.5)
        let buttons = spaceButtons(wm)
        guard buttons.count == order.count, let start = position(buttons[from]), let over = position(buttons[to]) else {
            throw Failure.desktopNotFound
        }
        let end = CGPoint(x: over.x + (to > from ? 50 : -50), y: start.y)
        post(.mouseMoved, start)
        try await pause(0.08)
        post(.leftMouseDown, start)
        try await pause(0.15)
        try await glide(from: start, to: end, steps: 24)
        try await pause(0.35)
        post(.leftMouseUp, end)
        try await pause(0.4)
        guard SpaceScanner.orderedSpaces().map(\.id).firstIndex(of: spaceID) == to else { throw Failure.didNotMove }
    }

    // MARK: Opening and closing

    private static func windowManager() -> AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    /// Opens Mission Control and returns WindowManager's accessibility root, which draws it.
    private static func open() throws -> AXUIElement {
        guard let wm = windowManager() else { throw Failure.didNotOpen }
        toggle()
        return wm
    }

    /// Opening the Mission Control app toggles it, like pressing F3.
    private static func toggle() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    }

    // MARK: Finding things

    private static func display() -> AXUIElement? {
        guard let wm = windowManager() else { return nil }
        return children(wm).first { identifier($0) == "mc.display" }
    }

    private static func windowButtons(_ id: String) -> [AXUIElement] {
        guard let display = display() else { return [] }
        return children(display).filter { identifier($0)?.lowercased() == id }
    }

    private static func spacesBar(_ wm: AXUIElement) -> AXUIElement? {
        children(wm).first { identifier($0) == "mc.display" }.flatMap { child(of: $0, id: "mc.spaces") }
    }

    /// One button per Space on the main display, in Mission Control order.
    private static func spaceButtons(_ wm: AXUIElement) -> [AXUIElement] {
        child(of: spacesBar(wm), id: "mc.spaces.list").map(children) ?? []
    }

    /// The bar's button for a Space, matched by position in the order.
    private static func spaceButton(for spaceID: UInt64, in wm: AXUIElement) -> AXUIElement? {
        let order = SpaceScanner.orderedSpaces().map(\.id)
        let buttons = spaceButtons(wm)
        guard buttons.count == order.count, let index = order.firstIndex(of: spaceID) else { return nil }
        return buttons[index]
    }

    // MARK: Dragging

    private static let eventSource = CGEventSource(stateID: .hidSystemState)

    private static func post(_ type: CGEventType, _ point: CGPoint) {
        CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func glide(from a: CGPoint, to b: CGPoint, steps: Int) async throws {
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try await pause(0.012)
        }
    }

    /// Drags a window thumbnail up to the Spaces bar, waits for the bar to expand, then drops it
    /// on the desktop's thumbnail.
    private static func dragWindow(from start: CGPoint, onto target: () -> AXUIElement?) async throws {
        guard let first = target().flatMap(position) else { throw Failure.desktopNotFound }
        post(.mouseMoved, start)
        try await pause(0.05)
        post(.leftMouseDown, start)
        try await pause(0.12)
        let nearBar = CGPoint(x: first.x, y: 70)
        try await glide(from: start, to: nearBar, steps: 18)
        try await pause(0.45)
        let end = target().flatMap(position) ?? first
        try await glide(from: nearBar, to: end, steps: 8)
        try await pause(0.25)
        post(.leftMouseUp, end)
    }

    // MARK: Waiting

    private static func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private static func wait(upTo timeout: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Waits for Mission Control's opening animation to finish: the value stops changing.
    private static func settle<T: Equatable>(_ value: () -> T?) async throws {
        var last = value()
        for _ in 0..<15 {
            try await pause(0.08)
            let now = value()
            if now != nil, now == last { return }
            last = now
        }
    }

    // MARK: Accessibility helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func identifier(_ element: AXUIElement) -> String? {
        attribute(element, kAXIdentifierAttribute) as? String
    }

    private static func child(of element: AXUIElement?, id: String) -> AXUIElement? {
        element.flatMap { children($0).first { identifier($0) == id } }
    }

    private static func position(_ element: AXUIElement) -> CGPoint? {
        guard let value = attribute(element, kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = position(element), let value = attribute(element, kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
