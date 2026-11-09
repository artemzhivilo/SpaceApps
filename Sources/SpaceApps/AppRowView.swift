import AppKit

/// One app row in the desktops menu: icon, name, then a lock and a quit button on the right.
/// Clicking the row switches to the app (and closes the menu). Holding it, or dragging it, starts
/// a drag onto another desktop. The lock pins the app to this desktop (click again to unpin);
/// the × quits it. Both keep the menu open.
final class AppRowView: NSView, DesktopSectionRow {
    let spaceID: UInt64
    let isDesktop: Bool
    var isDropTarget = false {
        didSet { if oldValue != isDropTarget { needsDisplay = true } }
    }
    /// Dimmed while it's being dragged.
    var isLifted = false {
        didSet { alphaValue = isLifted ? 0.4 : 1 }
    }
    /// Starts a drag. Nil for rows that can't move (full-screen Spaces, apps without a bundle ID).
    var onDrag: (() -> Void)? {
        didSet { toolTip = onDrag == nil ? nil : "Click to switch to \(name). Hold and drag to move it to another desktop." }
    }

    private let name: String
    private let onOpen: () -> Void
    private let onQuit: () -> Void
    private let onLock: (() -> Bool)?
    private var isLocked: Bool
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let quitButton = NSButton()
    private let lockButton = NSButton()
    private var highlighted = false {
        didSet { if oldValue != highlighted { refresh() } }
    }

    /// `onLock` toggles the lock and returns whether the app is now locked. Leave it nil for
    /// rows that can't be locked (full-screen Spaces, apps without a bundle ID).
    init(name: String, icon: NSImage?, spaceID: UInt64, isDesktop: Bool, isLocked: Bool = false,
         onOpen: @escaping () -> Void, onQuit: @escaping () -> Void, onLock: (() -> Bool)? = nil) {
        self.name = name
        self.spaceID = spaceID
        self.isDesktop = isDesktop
        self.onOpen = onOpen
        self.onQuit = onQuit
        self.onLock = onLock
        self.isLocked = isLocked
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 26))
        autoresizingMask = [.width]

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 14, y: 4, width: 18, height: 18)
        addSubview(iconView)

        label.stringValue = name
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 40, y: 4, width: 146, height: 18)
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

        if onLock != nil {
            lockButton.isBordered = false
            lockButton.imagePosition = .imageOnly
            lockButton.target = self
            lockButton.action = #selector(lockClicked)
            lockButton.frame = NSRect(x: 250 - 56, y: 4, width: 18, height: 18)
            lockButton.autoresizingMask = [.minXMargin]
            addSubview(lockButton)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(name)

        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { if !MenuDragSession.isActive { highlighted = true } }
    override func mouseExited(with event: NSEvent) { highlighted = false }

    /// Re-checks the highlight against where the pointer is now (after a drag).
    func refreshHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        highlighted = bounds.contains(point)
    }

    /// A press on the row (not its buttons): a click opens the app, a hold or drag moves it.
    override func mouseDown(with event: NSEvent) {
        guard let onDrag else { return }  // can't move: mouseUp opens it
        switch MenuDragSession.classifyPress() {
        case .click: open()
        case .hold: onDrag()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !quitButton.frame.contains(point), !(onLock != nil && lockButton.frame.contains(point)) else { return }
        open()
    }

    private func open() {
        enclosingMenuItem?.menu?.cancelTracking()
        onOpen()
    }

    /// Quits the app and removes its row, leaving the menu open for more.
    @objc private func quitClicked() {
        onQuit()
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        let index = menu.index(of: item)
        menu.removeItem(item)
        // If that was the desktop's last app, say so instead of leaving an empty section.
        let headerAbove = index > 0 && menu.item(at: index - 1)?.view is DesktopHeaderView
        let separatorBelow = index < menu.numberOfItems && menu.item(at: index)?.isSeparatorItem == true
        if headerAbove && separatorBelow {
            menu.insertItem(EmptyRowView.item(spaceID: spaceID, isDesktop: isDesktop), at: index)
        }
    }

    /// Locks or unlocks the app, leaving the menu open.
    @objc private func lockClicked() {
        guard let onLock else { return }
        isLocked = onLock()
        refresh()
    }

    private func refresh() {
        label.textColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        quitButton.contentTintColor = highlighted ? NSColor.white.withAlphaComponent(0.85) : .tertiaryLabelColor
        lockButton.image = NSImage(systemSymbolName: isLocked ? "lock.fill" : "lock.open",
                                   accessibilityDescription: isLocked ? "Unlock" : "Lock")
        lockButton.toolTip = isLocked ? "\(name) always opens on this desktop. Click to unlock."
                                      : "Lock \(name) to this desktop"
        lockButton.contentTintColor = highlighted ? NSColor.white.withAlphaComponent(0.85)
                                                  : (isLocked ? .controlAccentColor : .tertiaryLabelColor)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawDropTarget()
        guard highlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}
