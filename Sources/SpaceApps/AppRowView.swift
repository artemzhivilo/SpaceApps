import AppKit

/// One app row in the desktops menu: icon, name, and a quit button on the right.
/// Clicking the row switches to the app (and closes the menu); clicking the × quits it
/// and keeps the menu open.
final class AppRowView: NSView {
    private let onOpen: () -> Void
    private let onQuit: () -> Void
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let quitButton = NSButton()
    private var highlighted = false {
        didSet { if oldValue != highlighted { refresh() } }
    }

    init(name: String, icon: NSImage?, onOpen: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onQuit = onQuit
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 26))
        autoresizingMask = [.width]

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 14, y: 4, width: 18, height: 18)
        addSubview(iconView)

        label.stringValue = name
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 40, y: 4, width: 170, height: 18)
        label.autoresizingMask = [.width]
        addSubview(label)

        quitButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Quit \(name)")
        quitButton.isBordered = false
        quitButton.imagePosition = .imageOnly
        quitButton.toolTip = "Quit \(name)"
        quitButton.target = self
        quitButton.action = #selector(quitClicked)
        quitButton.frame = NSRect(x: 250 - 32, y: 4, width: 18, height: 18)
        quitButton.autoresizingMask = [.minXMargin]
        addSubview(quitButton)

        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { highlighted = true }
    override func mouseExited(with event: NSEvent) { highlighted = false }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !quitButton.frame.contains(point) else { return }
        closeMenu()
        onOpen()
    }

    /// Quits the app and removes its row, leaving the menu open for more.
    @objc private func quitClicked() {
        onQuit()
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        let index = menu.index(of: item)
        menu.removeItem(item)
        // If that was the desktop's last app, say so instead of leaving an empty section.
        let headerAbove = index > 0 && menu.item(at: index - 1)?.isSectionHeader == true
        let separatorBelow = index < menu.numberOfItems && menu.item(at: index)?.isSeparatorItem == true
        if headerAbove && separatorBelow {
            let none = NSMenuItem(title: "No windows", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.insertItem(none, at: index)
        }
    }

    private func closeMenu() {
        enclosingMenuItem?.menu?.cancelTracking()
    }

    private func refresh() {
        label.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        quitButton.contentTintColor = highlighted ? NSColor.white.withAlphaComponent(0.85) : .tertiaryLabelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}
