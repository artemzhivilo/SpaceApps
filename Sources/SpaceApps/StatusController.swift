import AppKit
import ServiceManagement

/// The menu bar item: a strip of app icons for the current Space.
/// Click it for the desktops menu: every desktop with its apps. Click an app to go to it,
/// or its × to quit it.
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

        var desktopNumber = 0
        for space in spaces {
            var title: String
            if space.isFullScreen {
                title = "Full Screen"
            } else {
                desktopNumber += 1
                title = "Desktop \(desktopNumber)"
            }
            if space.id == active { title += "  ·  current" }
            menu.addItem(NSMenuItem.sectionHeader(title: title))

            let spaceApps = appsBySpace[space.id] ?? []
            if spaceApps.isEmpty {
                let none = NSMenuItem(title: "No windows", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            for app in spaceApps {
                let row = NSMenuItem()
                row.view = AppRowView(
                    name: app.name, icon: icon(for: app),
                    onOpen: { [weak self] in self?.activate(app) },
                    onQuit: { NSRunningApplication(processIdentifier: app.pid)?.terminate() })
                menu.addItem(row)
            }
            menu.addItem(.separator())
        }

        let login = NSMenuItem(title: loginTitle(), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit SpaceApps", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Switches to the app. If its windows are on another desktop, macOS moves you there.
    private func activate(_ app: SpaceApp) {
        if let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            NSRunningApplication(processIdentifier: app.pid)?.activate()
        }
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
