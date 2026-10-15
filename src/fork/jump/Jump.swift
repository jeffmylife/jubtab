import Cocoa

/// Fork: the Jump switcher. ⌥Tab or a double-tap of ⌥ opens a search over local servers, cmux workspaces, Zen tabs
/// and every window. Type to filter; ↑↓ / Tab (even with ⌥ still held) move, Return or a click jumps, Esc or a
/// click outside closes. Releasing ⌥ never jumps: nothing opens unless it was picked.
/// Keys come through a dedicated event tap: JubTab's Carbon hotkey handler consumes every hotkey on the dispatcher
/// target, so a hotkey would never reach us. The panel never becomes key, so in search mode the tap also does the
/// typing.
enum Jump {
    private static let model = JumpModel()
    private static var panel: JumpPanel?
    private static var tap: CFMachPort?
    private static var isShowing = false
    private static var isSearching = false
    /// Everything the sources returned, before search filters it. The hover side menu reads this too.
    private(set) static var items = [JumpItem]()
    private static var lastLoad = Date.distantPast
    private static let loadQueue = DispatchQueue(label: "jubtab.jump.load")
    private static var isRefreshing = false
    /// Double-tap ⌥ detection: when the bare ⌥ went down, and when the last quick bare tap ended.
    private static var optionDownAt: Date?
    private static var lastOptionTap: Date?

    /// Each ⌥ press of a double tap is at most `optionTapMax` long, and the second starts within `doubleTapGap`.
    private static let optionTapMax: TimeInterval = 0.3
    private static let doubleTapGap: TimeInterval = 0.4

    private enum Key {
        static let tab: Int64 = 48, backtick: Int64 = 50, returnKey: Int64 = 36, enter: Int64 = 76, escape: Int64 = 53
        static let up: Int64 = 126, down: Int64 = 125, left: Int64 = 123, right: Int64 = 124, delete: Int64 = 51
        static let a: Int64 = 0, c: Int64 = 8, v: Int64 = 9, x: Int64 = 7, n: Int64 = 45, p: Int64 = 35, space: Int64 = 49
    }

    static func start() {
        panel = JumpPanel(model, onPick: { index in
            model.selected = index
            commit()
        }, onStop: { index in
            if model.items.indices.contains(index) { stop(item: model.items[index]) }
        })
        installTap()
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            guard isShowing, let panel, !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) else { return }
            hide()
        }
        JumpFlyout.start()
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

    /// Returns the event to let it through, nil to swallow it. Runs on the main thread (the tap's run loop).
    private static func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return event
        }
        if isSearching { return handleSearchKey(type, event) }
        let flags = event.flags
        let chordHeld = flags.contains(.maskAlternate) && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
        if type == .flagsChanged {
            if !isShowing { trackOptionDoubleTap(flags) }
            return event
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown {
            optionDownAt = nil
            lastOptionTap = nil
        }
        // The ⌘Tab switcher may come up without its panel becoming key; start the hover side menu's watch either way.
        if type == .keyDown && key == Key.tab && flags.contains(.maskCommand) {
            DispatchQueue.main.async { JumpFlyout.startWatching() }
        }
        guard type == .keyDown, key == Key.tab, chordHeld, SwitcherSession.current == nil else { return event }
        DispatchQueue.main.async { enterSearch() }
        return nil
    }

    /// Two quick presses of ⌥ alone open search. Any other key or modifier in between cancels it, so ⌥ used as
    /// a modifier (⌥-letters, ⌥-arrows, ⌥⌘ shortcuts) never counts.
    private static func trackOptionDoubleTap(_ flags: CGEventFlags) {
        let modifiers = flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])
        let now = Date()
        if modifiers == .maskAlternate && optionDownAt == nil {
            optionDownAt = now
        } else if modifiers.isEmpty, let down = optionDownAt {
            optionDownAt = nil
            guard now.timeIntervalSince(down) < optionTapMax else { return lastOptionTap = nil }
            if let last = lastOptionTap, now.timeIntervalSince(last) < doubleTapGap, SwitcherSession.current == nil {
                lastOptionTap = nil
                DispatchQueue.main.async { enterSearch() }
            } else {
                lastOptionTap = now
            }
        } else {
            optionDownAt = nil
            lastOptionTap = nil
        }
    }

    /// Search mode owns the keyboard: printable keys type, the rest navigate or edit like a text field (⌘A, ⌘C,
    /// ⌘X, ⌘V). Other ⌘/⌃ shortcuts are ignored, except the system switchers (⌘Tab, ⌘`, ⌘Space), which close
    /// search and go through.
    private static func handleSearchKey(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        guard type == .keyDown else { return type == .keyUp ? nil : event }
        let flags = event.flags
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let command = flags.contains(.maskCommand), control = flags.contains(.maskControl)
        switch key {
            case Key.tab where command, Key.backtick where command, Key.space where command:
                DispatchQueue.main.async { hide() }
                return event
            case Key.escape: DispatchQueue.main.async { hide() }
            case Key.returnKey, Key.enter: DispatchQueue.main.async { commit() }
            case Key.down: DispatchQueue.main.async { model.move(1) }
            case Key.up: DispatchQueue.main.async { model.move(-1) }
            case Key.tab: DispatchQueue.main.async { model.move(flags.contains(.maskShift) ? -1 : 1) }
            case Key.n where control: DispatchQueue.main.async { model.move(1) }
            case Key.p where control: DispatchQueue.main.async { model.move(-1) }
            case Key.delete:
                let clear = command, word = flags.contains(.maskAlternate)
                DispatchQueue.main.async {
                    setQuery(clear || model.queryIsSelected ? "" : word ? dropLastWord(model.query) : String(model.query.dropLast()))
                }
            case Key.left, Key.right: DispatchQueue.main.async { model.queryIsSelected = false }
            case Key.a where command: DispatchQueue.main.async { model.queryIsSelected = !model.query.isEmpty }
            case Key.c where command, Key.x where command:
                let cut = key == Key.x
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.query, forType: .string)
                    if cut { setQuery("") }
                }
            case Key.v where command:
                let pasted = NSPasteboard.general.string(forType: .string)?.components(separatedBy: .newlines).first ?? ""
                DispatchQueue.main.async { typeText(pasted) }
            default:
                guard !command && !control else { return nil }
                // ⌥ may still be held from ⌥Tab; type the plain letter rather than ⌥'s special character.
                let nsEvent = NSEvent(cgEvent: event)
                let raw = flags.contains(.maskAlternate) ? nsEvent?.charactersIgnoringModifiers : nsEvent?.characters
                let typed = (raw ?? "").filter { isPrintable($0) }
                guard !typed.isEmpty else { return nil }
                DispatchQueue.main.async { typeText(typed) }
        }
        return nil
    }

    /// Appends, or replaces the query when ⌘A selected it.
    private static func typeText(_ text: String) {
        setQuery(model.queryIsSelected ? text : model.query + text)
    }

    private static func isPrintable(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }
    }

    private static func dropLastWord(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard let space = trimmed.lastIndex(where: { $0 == " " }) else { return "" }
        return String(trimmed[...space])
    }

    private static func setQuery(_ query: String) {
        guard isSearching else { return }
        model.queryIsSelected = false
        model.query = query
        display(resetSelection: true)
    }

    private static func enterSearch() {
        guard !isShowing else { return }
        isShowing = true
        isSearching = true
        model.isSearching = true
        model.query = ""
        model.isLoading = items.isEmpty
        display(resetSelection: true)
        panel?.present()
        refresh()
    }

    private static func hide() {
        isShowing = false
        isSearching = false
        model.isSearching = false
        model.query = ""
        model.queryIsSelected = false
        panel?.orderOut(nil)
    }

    private static func commit() {
        guard isShowing else { return }
        let item = model.selectedItem
        hide()
        guard let item else { return }
        JumpSearch.recordPick(item)
        JumpSupport.log("jump: \(item.section.title) → \(item.title)")
        DispatchQueue.global(qos: .userInitiated).async { item.action() }
    }

    /// A server row's ×: stop it, drop its row at once, then reload to confirm it is gone.
    static func stop(item: JumpItem) {
        guard let stop = item.stop else { return }
        stop()
        items.removeAll { $0.id == item.id }
        display()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refresh(force: true) }
    }

    /// Hold mode lists the loaded sources as they are; search adds the windows and ranks by the query.
    private static func display(resetSelection: Bool = false) {
        guard isSearching else {
            model.spans = [:]
            model.replace(items, resetSelection: resetSelection)
            return
        }
        let results = JumpSearch.results(items + JumpWindows.items(), model.query)
        model.spans = results.spans
        model.replace(results.items, resetSelection: resetSelection)
        panel?.refit()
    }

    /// Sources take ~1s (lsof + HTTP probes + the cmux CLI), so the panel shows the last result at once and
    /// updates in place when the fresh one lands.
    static func refresh(force: Bool = false) {
        guard !isRefreshing, force || Date().timeIntervalSince(lastLoad) > 2 else { return }
        isRefreshing = true
        loadQueue.async {
            let started = Date()
            let loaded = JumpItems.load()
            let counts = JumpItem.Section.allCases.map { s in "\(loaded.filter { $0.section == s }.count) \(s.title)" }
            JumpSupport.log(String(format: "jump: loaded %@ in %.0fms", counts.joined(separator: ", "), Date().timeIntervalSince(started) * 1000))
            DispatchQueue.main.async {
                isRefreshing = false
                lastLoad = Date()
                model.isLoading = false
                items = loaded
                display()
                panel?.refit()
            }
        }
    }
}
