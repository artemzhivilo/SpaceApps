import AppKit
import ApplicationServices
import SwipeTap

/// While Mission Control is open, shows each Space's app icons under its "Desktop N" label.
/// Click an icon to go to that desktop and switch to the app; ⌘-click quits the app.
///
/// On macOS 27, Mission Control is drawn by WindowManager. Its accessibility tree has
/// `mc.display` → `mc.spaces` (the Spaces bar) → `mc.spaces.list` → one button per desktop,
/// each with an "Exit To Desktop N" press action. Needs Accessibility permission.
final class MissionControlOverlay: NSObject {
    private struct Desktop {
        let button: AXUIElement
        var labelFrame: CGRect  // top-left origin
        let apps: [SpaceApp]
    }

    private let iconSize: CGFloat = 16
    private let spacing: CGFloat = 3
    private let maxIcons = 4

    private var timer: Timer?
    private var desktops: [Desktop] = []
    private var panels: [IconRowPanel] = []
    private var barBottom: CGFloat = 72

    override init() {
        super.init()
        _ = swipetap_is_trusted(true)  // ask for Accessibility permission if this build lacks it
        let timer = Timer.scheduledTimer(timeInterval: 0.15, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.05
        self.timer = timer
    }

    @objc private func tick() {
        guard spacesBarIsShowing() else {
            if !panels.isEmpty { close() }
            return
        }
        guard AXIsProcessTrusted(),
              let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else { return }
        let app = AXUIElementCreateApplication(wm.processIdentifier)
        guard let bar = AX.find(app, id: "mc.spaces"),
              let list = AX.find(bar, id: "mc.spaces.list", depth: 2) else { return }
        if let barFrame = AX.frame(bar) { barBottom = barFrame.maxY }
        let buttons = AX.children(list)

        if panels.isEmpty {
            let display = AX.find(app, id: "mc.display", depth: 1)
            open(buttons: buttons, display: display)
        } else {
            // Follow the labels if the bar moves, and get out of the way while it's expanded.
            for (index, button) in buttons.enumerated() where index < desktops.count {
                if let frame = AX.frame(button) { desktops[index].labelFrame = frame }
            }
            layout()
        }
    }

    /// Mission Control's Spaces bar is a WindowManager window at layer 14 along the top.
    private func spacesBarIsShowing() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains {
            ($0[kCGWindowOwnerName as String] as? String) == "WindowManager" && ($0[kCGWindowLayer as String] as? Int) == 14
        }
    }

    /// Mission Control tags each window thumbnail like "com.apple.Safari.space.4", which is exactly
    /// what it shows (no hidden or minimized windows).
    private func appsFromMissionControl(_ display: AXUIElement?) -> [UInt64: [SpaceApp]] {
        guard let display else { return [:] }
        var result: [UInt64: [SpaceApp]] = [:]
        var seen: [UInt64: Set<String>] = [:]
        for child in AX.children(display) {
            guard let id = AX.identifier(child), let range = id.range(of: ".space.", options: .backwards),
                  let space = UInt64(id[range.upperBound...]) else { continue }
            let bundleID = String(id[..<range.lowerBound])
            guard seen[space, default: []].insert(bundleID).inserted,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            result[space, default: []].append(SpaceApp(pid: app.processIdentifier, name: app.localizedName ?? bundleID, bundleURL: app.bundleURL))
        }
        for key in result.keys {
            result[key]?.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return result
    }

    private func open(buttons: [AXUIElement], display: AXUIElement?) {
        let spaceIDs = SpaceScanner.orderedSpaceIDs()
        var appsBySpace = appsFromMissionControl(display)
        if appsBySpace.isEmpty { appsBySpace = SpaceScanner.apps(onSpaces: spaceIDs) }
        desktops = []
        for (index, button) in buttons.enumerated() {
            guard let frame = AX.frame(button) else { continue }
            let apps = index < spaceIDs.count ? appsBySpace[spaceIDs[index]] ?? [] : []
            desktops.append(Desktop(button: button, labelFrame: frame, apps: apps))
        }
        panels = desktops.indices.map { index in
            let panel = IconRowPanel()
            panel.onClick = { [weak self] appIndex, quit in self?.clicked(desktop: index, app: appIndex, quit: quit) }
            return panel
        }
        layout()
    }

    private func layout() {
        guard let screen = NSScreen.screens.first else { return }
        let screenHeight = screen.frame.height
        // While the pointer is over the bar it expands into thumbnails that would cover the icons.
        let mouse = NSEvent.mouseLocation
        let mouseInBar = (screenHeight - mouse.y) < barBottom
        for (index, desktop) in desktops.enumerated() where index < panels.count {
            let panel = panels[index]
            let shown = Array(desktop.apps.prefix(maxIcons))
            guard !shown.isEmpty, !mouseInBar else {
                panel.orderOut(nil)
                continue
            }
            panel.set(apps: shown, extra: desktop.apps.count - shown.count, iconSize: iconSize, spacing: spacing)
            let size = panel.contentSize
            let centerX = desktop.labelFrame.midX
            let topY = barBottom + 6  // just under the bar, top-left coordinates
            let origin = NSPoint(x: centerX - size.width / 2, y: screenHeight - topY - size.height)
            panel.setFrameOrigin(origin)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    private func close() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        desktops = []
    }

    private func clicked(desktop index: Int, app appIndex: Int, quit: Bool) {
        guard desktops.indices.contains(index), desktops[index].apps.indices.contains(appIndex) else { return }
        let app = desktops[index].apps[appIndex]
        if quit {
            NSRunningApplication(processIdentifier: app.pid)?.terminate()
            return
        }
        AX.press(desktops[index].button)  // "Exit To Desktop N"
        close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if let url = app.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            } else {
                NSRunningApplication(processIdentifier: app.pid)?.activate()
            }
        }
    }
}

/// A small floating row of app icons that sits above Mission Control.
final class IconRowPanel: NSPanel {
    var onClick: ((_ appIndex: Int, _ quit: Bool) -> Void)?
    private let row = IconRowView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver  // above Mission Control's Spaces bar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = row
        row.onClick = { [weak self] index, quit in self?.onClick?(index, quit) }
    }

    var contentSize: NSSize { row.frame.size }

    func set(apps: [SpaceApp], extra: Int, iconSize: CGFloat, spacing: CGFloat) {
        row.configure(apps: apps, extra: extra, iconSize: iconSize, spacing: spacing)
        setContentSize(row.frame.size)
    }

    override var canBecomeKey: Bool { false }
}

final class IconRowView: NSView {
    var onClick: ((_ appIndex: Int, _ quit: Bool) -> Void)?
    private var icons: [NSImage] = []
    private var extraText: String?
    private var iconSize: CGFloat = 16
    private var spacing: CGFloat = 3
    private let padding: CGFloat = 4

    func configure(apps: [SpaceApp], extra: Int, iconSize: CGFloat, spacing: CGFloat) {
        self.iconSize = iconSize
        self.spacing = spacing
        icons = apps.compactMap { NSRunningApplication(processIdentifier: $0.pid)?.icon }
        extraText = extra > 0 ? "+\(extra)" : nil
        let textWidth = extraText.map { ($0 as NSString).size(withAttributes: textAttributes).width + spacing } ?? 0
        let width = CGFloat(icons.count) * iconSize + CGFloat(max(icons.count - 1, 0)) * spacing + textWidth
        frame = NSRect(x: 0, y: 0, width: width + padding * 2, height: iconSize + padding * 2)
        toolTip = apps.map(\.name).joined(separator: ", ")
        needsDisplay = true
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.black.withAlphaComponent(0.35).setFill()
        background.fill()
        var x = padding
        for icon in icons {
            icon.draw(in: NSRect(x: x, y: padding, width: iconSize, height: iconSize))
            x += iconSize + spacing
        }
        if let extraText {
            let size = (extraText as NSString).size(withAttributes: textAttributes)
            (extraText as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: textAttributes)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(floor((point.x - padding) / (iconSize + spacing)))
        guard index >= 0, index < icons.count else { return }
        onClick?(index, event.modifierFlags.contains(.command))
    }
}
