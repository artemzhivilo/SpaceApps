import AppKit
import ServiceManagement

/// The menu bar item: a strip of app icons for the current Space.
/// Click it for the desktops menu: every desktop with its apps. Click an app to go to it,
/// its lock to pin it to that desktop, or its × to quit it. Hold and drag an app onto another
/// desktop (or "New Desktop") to move it, or a desktop's name to reorder desktops.
final class StatusController: NSObject, NSMenuDelegate {
    private let iconSize: CGFloat = 18
    private let spacing: CGFloat = 4
    private let maxIcons = 8

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var apps: [SpaceApp] = []
    private var lastTickApps: [SpaceApp] = []
    private var iconCache: [pid_t: NSImage] = [:]

    override init() {
        super.init()
        item.autosaveName = "SpaceApps"
        item.button?.imagePosition = .imageOnly
        // A standard status item menu: macOS positions it under the icons. Its contents are
        // rebuilt each time it opens (menuNeedsUpdate), so the lists are always current.
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        observeChanges()
        apply(SpaceScanner.appsOnCurrentSpace(), force: true)
        DesktopLocks.update()  // a monitor may have been plugged in or out while we weren't running
    }

    // MARK: Watching for changes

    private func observeChanges() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            ws.addObserver(self, selector: #selector(appsChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(themeChanged), name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)

        // Opening or closing a window inside an app sends no event, so also look once a second.
        // It only applies a result seen twice in a row, so a half-finished swipe is ignored.
        let timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.3
    }

    @objc private func spaceChanged() {
        refresh()
        // Look again shortly after, in case windows were slow to settle.
        recheck(after: [0.1, 0.3, 0.7])
    }

    @objc private func appsChanged() {
        refresh()
        recheck(after: [0.25])
    }

    /// Displays send several changes while a monitor connects, so wait for them to settle.
    private var displayWork: DispatchWorkItem?
    @objc private func displaysChanged() {
        displayWork?.cancel()
        let work = DispatchWorkItem { DesktopLocks.update() }
        displayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    @objc private func themeChanged() {
        apply(apps, force: true)  // the "+N" text colour follows light/dark
    }

    @objc private func tick() {
        let now = SpaceScanner.appsOnCurrentSpace()
        if now == lastTickApps { apply(now) }
        lastTickApps = now
    }

    private func recheck(after delays: [Double]) {
        for delay in delays {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                self.refresh()
            }
        }
    }

    private func refresh() {
        apply(SpaceScanner.appsOnCurrentSpace())
    }

    // MARK: Drawing the strip

    private func apply(_ newApps: [SpaceApp], force: Bool = false) {
        guard force || newApps != apps else { return }
        apps = newApps
        guard let button = item.button else { return }
        if apps.isEmpty {
            let empty = NSImage(systemSymbolName: "square.dashed", accessibilityDescription: "No apps on this Space")
            empty?.isTemplate = true
            button.image = empty
            button.toolTip = "No windows on this Space"
        } else {
            button.image = stripImage()
            button.toolTip = apps.map(\.name).joined(separator: ", ")
        }
    }

    private func icon(for app: SpaceApp) -> NSImage? {
        if let cached = iconCache[app.pid] { return cached }
        let image = NSRunningApplication(processIdentifier: app.pid)?.icon
        iconCache[app.pid] = image
        return image
    }

    private func stripImage() -> NSImage {
        let shown = Array(apps.prefix(maxIcons))
        let extra = apps.count - shown.count
        let extraText = extra > 0 ? "+\(extra)" as NSString : nil
        let isDark = item.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: isDark ? NSColor.white : NSColor.black,
        ]
        let textSize = extraText?.size(withAttributes: attrs) ?? .zero
        let iconsWidth = CGFloat(shown.count) * iconSize + CGFloat(max(shown.count - 1, 0)) * spacing
        let width = iconsWidth + (extraText == nil ? 0 : spacing + textSize.width)
        let icons = shown.map { icon(for: $0) }

        return render(width: width, height: iconSize) {
            var x: CGFloat = 0
            for icon in icons {
                icon?.draw(in: NSRect(x: x, y: 0, width: iconSize, height: iconSize))
                x += iconSize + spacing
            }
            extraText?.draw(at: NSPoint(x: x, y: (iconSize - textSize.height) / 2), withAttributes: attrs)
        }
    }

    /// Draws at 2x into an image sized in points, so it's sharp on Retina.
    private func render(width: CGFloat, height: CGFloat, draw: () -> Void) -> NSImage {
        let scale: CGFloat = 2
        let image = NSImage(size: NSSize(width: width, height: height))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((width * scale).rounded(.up)),
                                         pixelsHigh: Int((height * scale).rounded(.up)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    // MARK: The desktops menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let spaces = SpaceScanner.orderedSpaces()
        let active = SpaceScanner.activeSpaceID
        let appsBySpace = SpaceScanner.apps(onSpaces: spaces.map(\.id))
        let names = spaceNames(spaces)
        let desktops = spaces.filter { !$0.isFullScreen }

        for space in spaces {
            let isDesktop = !space.isFullScreen
            var title = names[space.id] ?? "Desktop"
            if space.id == active { title += "  ·  current" }
            let header = DesktopHeaderView(title: title, spaceID: space.id, isDesktop: isDesktop)
            if isDesktop && desktops.count > 1 {
                header.onDrag = { [weak self, weak menu, weak header] in
                    guard let self, let menu, let header else { return }
                    self.dragDesktop(space.id, header: header, in: menu, names: names)
                }
                header.setAccessibilityCustomActions(reorderActions(for: space.id, in: desktops, menu: menu))
            }
            let headerItem = NSMenuItem()
            headerItem.view = header
            menu.addItem(headerItem)

            let spaceApps = appsBySpace[space.id] ?? []
            if spaceApps.isEmpty {
                menu.addItem(EmptyRowView.item(spaceID: space.id, isDesktop: isDesktop))
            }
            for app in spaceApps {
                var onLock: (() -> Bool)?
                var isLocked = false
                if isDesktop, let uuid = space.uuid, let bundleID = app.bundleID {
                    isLocked = DesktopLocks.lockedSpace(for: bundleID) == uuid
                    onLock = {
                        DesktopLocks.toggle(bundleID: bundleID, spaceUUID: uuid)
                        return DesktopLocks.lockedSpace(for: bundleID) == uuid
                    }
                }
                let row = AppRowView(
                    name: app.name, icon: icon(for: app), spaceID: space.id, isDesktop: isDesktop, isLocked: isLocked,
                    onOpen: { app.activate() },
                    onQuit: { NSRunningApplication(processIdentifier: app.pid)?.terminate() },
                    onLock: onLock)
                if isDesktop && app.bundleID != nil {
                    row.onDrag = { [weak self, weak menu, weak row] in
                        guard let self, let menu, let row else { return }
                        self.dragApp(app, from: space.id, row: row, in: menu, names: names)
                    }
                    row.setAccessibilityCustomActions(moveActions(for: app, from: space.id, desktops: desktops, names: names, menu: menu))
                }
                let item = NSMenuItem()
                item.view = row
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let pause = NSMenuItem(title: "Pause Locks with a Monitor", action: #selector(togglePauseWithMonitor), keyEquivalent: "")
        pause.target = self
        pause.state = DesktopLocks.pauseWithMonitor ? .on : .off
        pause.toolTip = "When an external display is connected, apps open wherever you are. Locks come back when you unplug."
        menu.addItem(pause)
        firstFooterItem = pause
        if DesktopLocks.isPaused {
            let note = NSMenuItem(title: "Locks paused while the monitor is connected", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        let login = NSMenuItem(title: loginTitle(), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit SpaceApps", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// "Desktop 1", "Desktop 2"… and "Full Screen", as the menu and Mission Control name them.
    private func spaceNames(_ spaces: [Space]) -> [UInt64: String] {
        var names: [UInt64: String] = [:]
        var number = 0
        for space in spaces {
            if space.isFullScreen {
                names[space.id] = "Full Screen"
            } else {
                number += 1
                names[space.id] = "Desktop \(number)"
            }
        }
        return names
    }

    // MARK: Moving apps and desktops

    /// The first item after the desktops; "New Desktop" appears just above it during a drag.
    private weak var firstFooterItem: NSMenuItem?

    private func dragApp(_ app: SpaceApp, from spaceID: UInt64, row: AppRowView, in menu: NSMenu, names: [UInt64: String]) {
        let footer = firstFooterItem.map { menu.index(of: $0) } ?? menu.numberOfItems
        let session = MenuDragSession(menu: menu, item: .app(name: app.name, icon: icon(for: app), from: spaceID),
                                      source: row, newDesktopIndex: footer, names: names)
        switch session.run() {
        case .stayedPut:
            menu.cancelTracking()
            app.activate()
        case .cancel, .drop(.placeOf):
            break
        case .drop(.desktop(let target)):
            menu.cancelTracking()
            Task { await move(app, from: spaceID, to: .desktop(target)) }
        case .drop(.newDesktop):
            menu.cancelTracking()
            Task { await move(app, from: spaceID, to: .newDesktop) }
        }
    }

    private func dragDesktop(_ spaceID: UInt64, header: DesktopHeaderView, in menu: NSMenu, names: [UInt64: String]) {
        let session = MenuDragSession(menu: menu, item: .desktop(spaceID, name: names[spaceID] ?? "Desktop"),
                                      source: header, newDesktopIndex: 0, names: names)
        guard case .drop(.placeOf(let target)) = session.run() else { return }
        menu.cancelTracking()
        Task { await moveDesktop(spaceID, toPlaceOf: target, name: names[spaceID] ?? "Desktop") }
    }

    /// Moves the app with Mission Control. If it was locked to the desktop it left, the lock follows it.
    private func move(_ app: SpaceApp, from source: UInt64, to destination: MissionControl.Destination) async {
        try? await Task.sleep(for: .milliseconds(200))  // let the menu close first
        guard askForAccessibilityIfNeeded() else { return }
        let uuidOf = { (id: UInt64) in SpaceScanner.orderedSpaces().first { $0.id == id }?.uuid }
        let wasLockedHere = app.bundleID.map { id in uuidOf(source).map { DesktopLocks.lockedSpace(for: id) == $0 } ?? false } ?? false
        do {
            try await MissionControl.move(app, from: source, to: destination)
            if wasLockedHere, let bundleID = app.bundleID {
                let newUUID: String? = switch destination {
                case .desktop(let id): uuidOf(id)
                case .newDesktop: SpaceScanner.orderedSpaces().last { !$0.isFullScreen }?.uuid
                }
                if let newUUID { DesktopLocks.toggle(bundleID: bundleID, spaceUUID: newUUID) }
            }
        } catch MissionControl.Failure.busy {
            // A move is already running; ignore the second one.
        } catch {
            showProblem("Unable to Move \(app.name)", error)
        }
        refresh()
    }

    private func moveDesktop(_ spaceID: UInt64, toPlaceOf target: UInt64, name: String) async {
        try? await Task.sleep(for: .milliseconds(200))
        guard askForAccessibilityIfNeeded() else { return }
        do {
            try await MissionControl.moveDesktop(spaceID, toPlaceOf: target)
        } catch MissionControl.Failure.busy {
            // A move is already running; ignore the second one.
        } catch {
            showProblem("Unable to Move \(name)", error)
        }
    }

    /// VoiceOver actions on an app row: the same moves as dragging it.
    private func moveActions(for app: SpaceApp, from source: UInt64, desktops: [Space], names: [UInt64: String],
                             menu: NSMenu) -> [NSAccessibilityCustomAction] {
        var targets: [(String, MissionControl.Destination)] = desktops.filter { $0.id != source }
            .map { ("Move to \(names[$0.id] ?? "Desktop")", .desktop($0.id)) }
        targets.append(("Move to New Desktop", .newDesktop))
        return targets.map { title, destination in
            NSAccessibilityCustomAction(name: title) { [weak self, weak menu] in
                menu?.cancelTracking()
                Task { await self?.move(app, from: source, to: destination) }
                return true
            }
        }
    }

    /// VoiceOver actions on a desktop header: move it up or down one place.
    private func reorderActions(for spaceID: UInt64, in desktops: [Space], menu: NSMenu) -> [NSAccessibilityCustomAction] {
        guard let index = desktops.firstIndex(where: { $0.id == spaceID }) else { return [] }
        let name = "Desktop \(index + 1)"
        var actions: [NSAccessibilityCustomAction] = []
        for (title, neighbour) in [("Move Up", index - 1), ("Move Down", index + 1)] where desktops.indices.contains(neighbour) {
            let target = desktops[neighbour].id
            actions.append(NSAccessibilityCustomAction(name: title) { [weak self, weak menu] in
                menu?.cancelTracking()
                Task { await self?.moveDesktop(spaceID, toPlaceOf: target, name: name) }
                return true
            })
        }
        return actions
    }

    /// Moving needs Accessibility. The first time, macOS asks (and lists SpaceApps in Settings);
    /// after that, explains why and offers the settings.
    private func askForAccessibilityIfNeeded() -> Bool {
        if MissionControl.isAllowed { return true }
        let askedKey = "AskedForAccessibility"
        if !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            MissionControl.showSystemPrompt()
            return false
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Turn On Accessibility for SpaceApps"
        alert.informativeText = "Only Mission Control can move windows and desktops, so SpaceApps opens it and drags for you. "
            + "Turn on SpaceApps in Privacy & Security → Accessibility, then try again."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func showProblem(_ title: String, _ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = switch error as? MissionControl.Failure {
        case .didNotOpen?, .couldNotSwitch?: "Mission Control didn't open in time. Try again."
        case .windowNotFound?: "Mission Control didn't show the app's windows. Try again."
        default: "Mission Control didn't finish the move. Try again."
        }
        alert.runModal()
    }

    private func loginTitle() -> String {
        SMAppService.mainApp.status == .requiresApproval ? "Launch at Login (approve in System Settings)" : "Launch at Login"
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add SpaceApps in System Settings → General → Login Items instead."
            alert.runModal()
        }
    }

    @objc private func togglePauseWithMonitor() {
        DesktopLocks.pauseWithMonitor.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
