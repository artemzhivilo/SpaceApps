import AppKit

// MARK: Desktop sections

/// A row in the desktops menu that belongs to one desktop's section: its header, an app, or
/// "No windows". Drags look these up to find what's under the pointer.
protocol DesktopSectionRow: NSView {
    var spaceID: UInt64 { get }
    /// Full-screen Spaces can't take apps or be reordered.
    var isDesktop: Bool { get }
    var isDropTarget: Bool { get set }
}

extension DesktopSectionRow {
    /// Drawn behind the row, so a whole section lights up as one block.
    func drawDropTarget() {
        guard isDropTarget else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        bounds.insetBy(dx: 5, dy: 0).fill()
    }
}

/// A desktop's name above its apps, in light grey. Hold and drag it to reorder desktops.
final class DesktopHeaderView: NSView, DesktopSectionRow {
    let spaceID: UInt64
    let isDesktop: Bool
    var isDropTarget = false {
        didSet { if oldValue != isDropTarget { needsDisplay = true } }
    }
    var isLifted = false {
        didSet { alphaValue = isLifted ? 0.4 : 1 }
    }
    var onDrag: (() -> Void)? {
        didSet { toolTip = onDrag == nil ? nil : "Hold and drag to reorder desktops" }
    }

    init(title: String, spaceID: UInt64, isDesktop: Bool) {
        self.spaceID = spaceID
        self.isDesktop = isDesktop
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        autoresizingMask = [.width]
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 14, y: 3, width: 222, height: 16)
        label.autoresizingMask = [.width]
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        guard let onDrag, MenuDragSession.classifyPress() == .hold else { return }
        onDrag()
    }

    override func draw(_ dirtyRect: NSRect) { drawDropTarget() }
}

/// "No windows", under a desktop with nothing open.
final class EmptyRowView: NSView, DesktopSectionRow {
    let spaceID: UInt64
    let isDesktop: Bool
    var isDropTarget = false {
        didSet { if oldValue != isDropTarget { needsDisplay = true } }
    }

    static func item(spaceID: UInt64, isDesktop: Bool) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = EmptyRowView(spaceID: spaceID, isDesktop: isDesktop)
        return item
    }

    init(spaceID: UInt64, isDesktop: Bool) {
        self.spaceID = spaceID
        self.isDesktop = isDesktop
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        autoresizingMask = [.width]
        let label = NSTextField(labelWithString: "No windows")
        label.font = .menuFont(ofSize: 0)
        label.textColor = .disabledControlTextColor
        label.frame = NSRect(x: 14, y: 3, width: 222, height: 18)
        label.autoresizingMask = [.width]
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) { drawDropTarget() }
}

/// Shown after the desktops while an app is being dragged: drop it here to give it a new desktop.
final class NewDesktopRowView: NSView {
    var isDropTarget = false {
        didSet { if oldValue != isDropTarget { refresh() } }
    }
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "New Desktop")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 34))
        autoresizingMask = [.width]
        iconView.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        iconView.frame = NSRect(x: 16, y: 9, width: 16, height: 16)
        addSubview(iconView)
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 40, y: 8, width: 190, height: 18)
        label.autoresizingMask = [.width]
        addSubview(label)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refresh() {
        let color: NSColor = isDropTarget ? .controlAccentColor : .secondaryLabelColor
        iconView.contentTintColor = color
        label.textColor = isDropTarget ? .labelColor : .secondaryLabelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 6.5, dy: 3.5), xRadius: 5, yRadius: 5)
        if isDropTarget {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            box.fill()
        }
        (isDropTarget ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        box.lineWidth = 1
        box.setLineDash([4, 3], count: 2, phase: 0)
        box.stroke()
    }
}

// MARK: Dragging

/// Tracks a hold-and-drag inside the open desktops menu: lifts the row, shows a label under the
/// pointer, highlights where it would land, and returns the drop. The menu stays open throughout,
/// and a cancelled drag leaves it as it was.
final class MenuDragSession {
    enum Item {
        case app(name: String, icon: NSImage?, from: UInt64)
        case desktop(UInt64, name: String)
    }

    enum Drop: Equatable {
        case desktop(UInt64)    // an app onto another desktop
        case newDesktop         // an app onto "New Desktop"
        case placeOf(UInt64)    // a desktop into another desktop's place
    }

    enum Outcome: Equatable {
        case drop(Drop)
        case cancel
        /// Held, then let go without moving: treat it as a slow click.
        case stayedPut
    }

    enum Press { case click, hold }

    private(set) static var isActive = false

    private let menu: NSMenu
    private let item: Item
    private let source: NSView
    private let newDesktopIndex: Int
    private let names: [UInt64: String]
    private var inserted: [NSMenuItem] = []
    private var newDesktopRow: NewDesktopRowView?
    private let chip = DragChip()
    private let line = InsertionLine()
    private var drop: Drop?

    /// `newDesktopIndex` is where "New Desktop" goes in the menu (after the last desktop).
    /// `names` gives each Space's title ("Desktop 2") for the label under the pointer.
    init(menu: NSMenu, item: Item, source: NSView, newDesktopIndex: Int, names: [UInt64: String]) {
        self.menu = menu
        self.item = item
        self.source = source
        self.newDesktopIndex = newDesktopIndex
        self.names = names
    }

    /// After a mouse-down on a row, waits to see whether it's a click or the start of a drag:
    /// holding still for 0.3 s, or moving more than a few points, makes it a drag.
    static func classifyPress() -> Press {
        let start = NSEvent.mouseLocation
        let deadline = Date().addingTimeInterval(0.3)
        while let event = NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: deadline,
                                          inMode: .eventTracking, dequeue: true) {
            if event.type == .leftMouseUp { return .click }
            let now = NSEvent.mouseLocation
            if hypot(now.x - start.x, now.y - start.y) > 4 { return .hold }
        }
        return .hold
    }

    /// Runs until the mouse button comes up (or Escape is pressed).
    func run() -> Outcome {
        Self.isActive = true
        let start = NSEvent.mouseLocation
        var moved = false
        prepare()
        defer {
            finish()
            Self.isActive = false
        }
        track(start)
        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            switch event.type {
            case .leftMouseDragged:
                let point = NSEvent.mouseLocation
                if hypot(point.x - start.x, point.y - start.y) > 4 { moved = true }
                track(point)
            case .leftMouseUp:
                if let drop { return .drop(drop) }
                return moved ? .cancel : .stayedPut
            case .keyDown where event.keyCode == 53:  // Escape
                return .cancel
            default:
                break
            }
        }
        return .cancel
    }

    // MARK: Steps

    private func prepare() {
        lift(true)
        if case .app = item {
            let row = NewDesktopRowView()
            let rowItem = NSMenuItem()
            rowItem.view = row
            let separator = NSMenuItem.separator()
            let index = min(newDesktopIndex, menu.numberOfItems)
            menu.insertItem(rowItem, at: index)
            menu.insertItem(separator, at: index + 1)
            inserted = [rowItem, separator]
            newDesktopRow = row
        }
        switch item {
        case .app(let name, let icon, _): chip.show(icon: icon, text: name)
        case .desktop(_, let name): chip.show(icon: nil, text: name)
        }
    }

    private func track(_ point: NSPoint) {
        chip.move(to: point)
        switch item {
        case .app(_, _, let from): setDrop(appDrop(at: point, from: from))
        case .desktop(let id, _): setDrop(slotDrop(at: point, moving: id))
        }
    }

    private func finish() {
        chip.close()
        line.close()
        setDrop(nil)
        lift(false)
        for item in inserted { menu.removeItem(item) }
        // Hover events were held back during the drag, so set row highlights from scratch.
        for row in rows() { (row as? AppRowView)?.refreshHover() }
    }

    // MARK: Where it would land

    private func appDrop(at point: NSPoint, from: UInt64) -> Drop? {
        guard menuFrame.insetBy(dx: -20, dy: -20).contains(point) else { return nil }
        if let row = newDesktopRow, screenFrame(row).contains(point) { return .newDesktop }
        if let row = rows().first(where: { screenFrame($0).contains(point) }) {
            return row.isDesktop && row.spaceID != from ? .desktop(row.spaceID) : nil
        }
        return drop  // in the gap between two sections: keep the highlight steady
    }

    /// Reordering: the pointer picks a gap between desktops; a line shows where it lands.
    private func slotDrop(at point: NSPoint, moving id: UInt64) -> Drop? {
        let sections = desktopSections()
        guard menuFrame.insetBy(dx: -20, dy: -20).contains(point),
              let from = sections.firstIndex(where: { $0.id == id }) else {
            line.hide()
            return nil
        }
        let gap = sections.filter { $0.frame.midY > point.y }.count  // sections above the pointer
        let to = gap > from ? gap - 1 : gap
        guard to != from else {
            line.hide()
            return nil
        }
        let y: CGFloat
        if gap == 0 {
            y = sections[0].frame.maxY
        } else if gap == sections.count {
            y = sections[gap - 1].frame.minY
        } else {
            y = (sections[gap - 1].frame.minY + sections[gap].frame.maxY) / 2
        }
        let frame = sections[0].frame
        line.show(x: frame.minX + 10, y: y, width: frame.width - 20)
        return .placeOf(sections[to].id)
    }

    private func setDrop(_ new: Drop?) {
        guard new != drop else { return }
        drop = new
        var target: UInt64?
        if case .desktop(let id) = new { target = id }
        for row in rows() { row.isDropTarget = row.spaceID == target }
        newDesktopRow?.isDropTarget = new == .newDesktop
        if case .app(let name, _, _) = item {
            switch new {
            case .desktop(let id): chip.text = "\(name) → \(names[id] ?? "Desktop")"
            case .newDesktop: chip.text = "\(name) → New Desktop"
            default: chip.text = name
            }
        }
    }

    // MARK: Helpers

    private func lift(_ lifted: Bool) {
        (source as? AppRowView)?.isLifted = lifted
        (source as? DesktopHeaderView)?.isLifted = lifted
    }

    private var menuFrame: NSRect { source.window?.frame ?? .zero }

    private func rows() -> [any DesktopSectionRow] {
        menu.items.compactMap { $0.view as? any DesktopSectionRow }
    }

    /// Each desktop's section (header plus rows) as one frame, top to bottom.
    private func desktopSections() -> [(id: UInt64, frame: NSRect)] {
        var sections: [(id: UInt64, frame: NSRect)] = []
        for row in rows() where row.isDesktop {
            let frame = screenFrame(row)
            if let last = sections.last, last.id == row.spaceID {
                sections[sections.count - 1].frame = last.frame.union(frame)
            } else {
                sections.append((row.spaceID, frame))
            }
        }
        return sections
    }

    private func screenFrame(_ view: NSView) -> NSRect {
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

// MARK: Overlays

/// A borderless window that floats above open menus and lets clicks through.
private func overlayPanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    return panel
}

/// The label that follows the pointer while dragging: icon and name, then where it will go.
private final class DragChip {
    private let panel = overlayPanel()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.masksToBounds = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        label.font = .menuFont(ofSize: 0)
        label.textColor = .labelColor
        background.addSubview(iconView)
        background.addSubview(label)
        panel.contentView = background
        panel.hasShadow = true
    }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            layout()
        }
    }

    func show(icon: NSImage?, text: String) {
        iconView.image = icon
        iconView.isHidden = icon == nil
        self.text = text
        panel.orderFrontRegardless()
    }

    func move(to point: NSPoint) {
        panel.setFrameOrigin(NSPoint(x: point.x + 12, y: point.y - panel.frame.height - 10))
    }

    func close() { panel.orderOut(nil) }

    private func layout() {
        let height: CGFloat = 28
        let textX: CGFloat = iconView.isHidden ? 10 : 32
        let textSize = label.fittingSize
        iconView.frame = NSRect(x: 8, y: 5, width: 18, height: 18)
        label.frame = NSRect(x: textX, y: (height - textSize.height) / 2, width: textSize.width, height: textSize.height)
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: textX + textSize.width + 10, height: height)
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
    }
}

/// The accent line between two desktops that shows where a dragged desktop will land.
private final class InsertionLine {
    private let panel = overlayPanel()

    init() {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        bar.layer?.cornerRadius = 1.5
        panel.contentView = bar
    }

    func show(x: CGFloat, y: CGFloat, width: CGFloat) {
        panel.setFrame(NSRect(x: x, y: y - 1.5, width: width, height: 3), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
    func close() { panel.orderOut(nil) }
}
