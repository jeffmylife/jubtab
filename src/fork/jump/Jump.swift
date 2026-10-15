import Cocoa

/// Fork: the Jump switcher. Hold ⌥⌘ and press Tab to list local servers, cmux workspaces and Zen tabs; Tab /
/// ⇧Tab (or ↑↓) move, releasing ⌥ or ⌘ (or Return) jumps, ` cancels. Keys come through a dedicated event tap:
/// JubTab's Carbon hotkey handler consumes every hotkey on the dispatcher target, so a hotkey would never reach us.
enum Jump {
    private static let model = JumpModel()
    private static var panel: JumpPanel?
    private static var tap: CFMachPort?
    private static var isShowing = false
    private static var lastLoad = Date.distantPast
    private static let loadQueue = DispatchQueue(label: "jubtab.jump.load")
    private static var isRefreshing = false

    private enum Key {
        static let tab: Int64 = 48, backtick: Int64 = 50, returnKey: Int64 = 36, up: Int64 = 126, down: Int64 = 125
    }

    static func start() {
        panel = JumpPanel(model) { index in
            model.selected = index
            commit()
        }
        installTap()
        refresh()
        JumpSupport.log("jump: started (tap \(tap == nil ? "FAILED" : "ok"))")
    }

    private static func installTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
                Jump.handle(type, event).map { Unmanaged.passUnretained($0) }
            }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns the event to let it through, nil to swallow it.
    private static func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return event
        }
        let flags = event.flags
        let chordHeld = flags.contains(.maskCommand) && flags.contains(.maskAlternate) && !flags.contains(.maskControl)
        if type == .flagsChanged {
            if isShowing && !chordHeld { DispatchQueue.main.async { commit() } }
            return event
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if !isShowing {
            guard type == .keyDown, key == Key.tab, chordHeld, SwitcherSession.current == nil else { return event }
            DispatchQueue.main.async { show() }
            return nil
        }
        guard type == .keyDown else { return [Key.tab, Key.backtick, Key.returnKey, Key.up, Key.down].contains(key) ? nil : event }
        switch key {
            case Key.tab: DispatchQueue.main.async { model.move(flags.contains(.maskShift) ? -1 : 1) }
            case Key.down: DispatchQueue.main.async { model.move(1) }
            case Key.up: DispatchQueue.main.async { model.move(-1) }
            case Key.returnKey: DispatchQueue.main.async { commit() }
            case Key.backtick: DispatchQueue.main.async { hide() }
            default: return event
        }
        return nil
    }

    private static func show() {
        guard !isShowing else { return }
        isShowing = true
        model.selected = 0
        model.isLoading = model.items.isEmpty
        panel?.present()
        refresh()
    }

    private static func hide() {
        isShowing = false
        panel?.orderOut(nil)
    }

    private static func commit() {
        guard isShowing else { return }
        let item = model.selectedItem
        hide()
        guard let item else { return }
        JumpSupport.log("jump: \(item.section.title) → \(item.title)")
        DispatchQueue.global(qos: .userInitiated).async { item.action() }
    }

    /// Sources take ~1s (lsof + HTTP probes + the cmux CLI), so the panel shows the last result at once and
    /// updates in place when the fresh one lands.
    private static func refresh() {
        guard !isRefreshing, Date().timeIntervalSince(lastLoad) > 2 else { return }
        isRefreshing = true
        loadQueue.async {
            let started = Date()
            let items = JumpItems.load()
            let counts = JumpItem.Section.allCases.map { s in "\(items.filter { $0.section == s }.count) \(s.title)" }
            JumpSupport.log(String(format: "jump: loaded %@ in %.0fms", counts.joined(separator: ", "), Date().timeIntervalSince(started) * 1000))
            DispatchQueue.main.async {
                isRefreshing = false
                lastLoad = Date()
                model.isLoading = false
                model.replace(items)
                panel?.refit()
            }
        }
    }
}
