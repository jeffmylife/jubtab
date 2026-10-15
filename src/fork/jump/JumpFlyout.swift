import Cocoa

/// Fork: in the ⌘Tab switcher, resting the mouse on a cmux or Zen tile opens a side menu of what is inside it
/// (cmux workspaces; Zen servers and tabs). Hover a row and click it, or let go of ⌘, to jump there.
/// Everything is read from the switcher's own state while it is up, so the switcher code needs no hooks except
/// `commitIfHovered` in `App.focusTarget`.
enum JumpFlyout {
    private static let model = JumpModel(width: 380)
    private static var panel: JumpPanel?
    private static var timer: Timer?
    /// The tile the menu belongs to, and the tile the pointer has been resting on since `restingSince`.
    private static var shownFor: ObjectIdentifier?
    private static var resting: (tile: ObjectIdentifier, since: Date)?
    private static var leftAt: Date?

    private static let openDelay: TimeInterval = 0.25
    private static let closeGrace: TimeInterval = 0.3

    private static let sectionsByApp: [String: [JumpItem.Section]] = [
        CmuxWorkspaces.bundleId: [.workspaces],
        ZenTabs.bundleId: [.servers, .tabs],
    ]

    static func start() {
        panel = JumpPanel(model, onPick: { index in
            model.selected = index
            pick()
        }, onStop: { index in
            guard model.items.indices.contains(index) else { return }
            let id = model.items[index].id
            Jump.stop(item: model.items[index])
            model.items.removeAll { $0.id == id }
        })
        panel?.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            if note.object is TilesPanel { startWatching() }
        }
    }

    /// Called when the switcher commits (⌘ released). True when a flyout row was under the pointer: that row is
    /// the destination, and the caller must dismiss the switcher instead of focusing its selected window.
    static func commitIfHovered() -> Bool {
        guard let panel, panel.isVisible, NSMouseInRect(NSEvent.mouseLocation, panel.frame, false), model.selectedItem != nil else { return false }
        run()
        return true
    }

    static func startWatching() {
        guard timer == nil else { return }
        Jump.refresh()
        let t = Timer(timeInterval: 0.04, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func stopWatching() {
        timer?.invalidate()
        timer = nil
        resting = nil
        hide()
    }

    private static func tick() {
        guard SwitcherSession.current != nil, TilesPanel.shared.isVisible else { return stopWatching() }
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if panel.isVisible && NSMouseInRect(mouse, panel.frame, false) {
            leftAt = nil
            return
        }
        let hovered = SwitcherSession.current?.hoveredIndex
            .flatMap { TilesView.recycledViews.indices.contains($0) ? TilesView.recycledViews[$0] : nil }
            .flatMap { tile in tile.window_.map { (tile, $0) } }
        guard let (tile, window) = hovered, let bundleId = window.application.runningApplication.bundleIdentifier,
              let sections = sectionsByApp[bundleId] else {
            resting = nil
            closeAfterGrace()
            return
        }
        let id = ObjectIdentifier(tile)
        if resting?.tile != id { resting = (id, Date()) }
        let items = Jump.items.filter { sections.contains($0.section) }
        if shownFor == id && panel.isVisible {
            leftAt = nil
            if items.map(\.id) != model.items.map(\.id) {
                model.replace(items)
                place(panel, beside: tile)
            }
            return
        }
        guard let since = resting?.since, Date().timeIntervalSince(since) >= openDelay, !items.isEmpty else {
            if shownFor != id { closeAfterGrace() }
            return
        }
        shownFor = id
        leftAt = nil
        model.items = items
        model.selected = -1
        place(panel, beside: tile)
        panel.orderFrontRegardless()
    }

    /// The pointer often crosses a gap or a neighbouring tile on its way into the menu; only close once it has
    /// stayed away for a moment.
    private static func closeAfterGrace() {
        guard panel?.isVisible == true else { return }
        let now = Date()
        if let leftAt, now.timeIntervalSince(leftAt) >= closeGrace { hide() } else if leftAt == nil { leftAt = now }
    }

    private static func hide() {
        panel?.orderOut(nil)
        shownFor = nil
        leftAt = nil
    }

    /// Right of the tile, overlapping it slightly so the pointer goes straight in; flips left near the screen edge.
    private static func place(_ panel: JumpPanel, beside tile: NSView) {
        guard let tileWindow = tile.window, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let tileFrame = tileWindow.convertToScreen(tile.convert(tile.bounds, to: nil))
        let screen = (tileWindow.screen ?? NSScreen.main)?.visibleFrame ?? tileFrame
        var x = tileFrame.maxX - 12
        if x + size.width > screen.maxX { x = tileFrame.minX - size.width + 12 }
        var y = tileFrame.maxY - size.height
        y = min(max(y, screen.minY), screen.maxY - size.height)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private static func pick() {
        guard model.selectedItem != nil else { return }
        run()
        App.hideUi()
    }

    private static func run() {
        guard let item = model.selectedItem else { return }
        hide()
        JumpSupport.log("flyout: \(item.section.title) → \(item.title)")
        DispatchQueue.global(qos: .userInitiated).async { item.action() }
    }
}
