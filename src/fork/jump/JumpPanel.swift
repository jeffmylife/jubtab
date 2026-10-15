import Cocoa
import SwiftUI

/// Fork: what the Jump panel shows. `selected` indexes `items`; sections are only a visual grouping.
final class JumpModel: ObservableObject {
    @Published var items = [JumpItem]()
    @Published var selected = 0
    @Published var isLoading = false
    /// Bumped by keyboard moves only: the list scrolls to keep the selection visible, but must not scroll under
    /// a hovering mouse.
    @Published var keyboardMoves = 0
    /// Row frames in the panel's coordinates, reported by the view, for mouse hit-testing.
    var rowFrames = [Int: CGRect]()

    var selectedItem: JumpItem? { items.indices.contains(selected) ? items[selected] : nil }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
        keyboardMoves += 1
    }

    func row(at point: CGPoint) -> Int? {
        rowFrames.first { $0.value.contains(point) }?.key
    }

    /// Keeps the same destination selected when a refresh reorders or adds items.
    func replace(_ newItems: [JumpItem]) {
        let keep = selectedItem?.id
        items = newItems
        selected = keep.flatMap { id in newItems.firstIndex { $0.id == id } } ?? min(selected, max(newItems.count - 1, 0))
    }
}

/// Fork: icons by `JumpItem.iconKey` — an SF Symbol name, an app bundle id, or a favicon URL (loaded once, cached).
final class JumpIcons: ObservableObject {
    static let shared = JumpIcons()
    /// Bumped when a favicon arrives so rows redraw; the cache itself isn't published because sync lookups
    /// fill it during view updates.
    @Published private var loaded = 0
    private var cache = [String: NSImage]()
    private var loading = Set<String>()

    func image(_ key: String) -> NSImage? {
        if let image = cache[key] { return image }
        if key == "server" { return NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil) }
        if !key.contains(":") { return remember(key, JumpSupport.appIcon(key)) }
        load(key)
        return JumpSupport.appIcon(ZenTabs.bundleId)
    }

    private func remember(_ key: String, _ image: NSImage?) -> NSImage? {
        if let image { cache[key] = image }
        return image
    }

    private func load(_ key: String) {
        guard !loading.contains(key), let url = URL(string: key), ["http", "https", "data"].contains(url.scheme ?? "") else { return }
        loading.insert(key)
        DispatchQueue.global().async {
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self.cache[key] = image
                self.loaded += 1
            }
        }
    }
}

struct JumpRowFrames: PreferenceKey {
    static var defaultValue = [Int: CGRect]()
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct JumpView: View {
    @ObservedObject var model: JumpModel
    @ObservedObject var icons = JumpIcons.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.items.isEmpty {
                Text(model.isLoading ? "Looking for servers, workspaces and tabs…" : "Nothing to jump to")
                    .foregroundColor(.secondary).padding(24)
            } else {
                ScrollViewReader { proxy in
                    SwiftUI.ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                                if index == 0 || model.items[index - 1].section != item.section {
                                    Text(item.section.title.uppercased())
                                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                                        .padding(.horizontal, 12).padding(.top, index == 0 ? 4 : 12).padding(.bottom, 4)
                                }
                                row(item, isSelected: index == model.selected)
                                    .id(index)
                                    .background(GeometryReader { geo in
                                        Color.clear.preference(key: JumpRowFrames.self, value: [index: geo.frame(in: .named("jump"))])
                                    })
                            }
                        }.padding(8)
                    }
                    .onChange(of: model.keyboardMoves) { _ in proxy.scrollTo(model.selected, anchor: .center) }
                }
            }
        }
        .frame(width: 640)
        .frame(maxHeight: 560)
        .coordinateSpace(name: "jump")
        .onPreferenceChange(JumpRowFrames.self) { model.rowFrames = $0 }
    }

    private func row(_ item: JumpItem, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = icons.image(item.iconKey) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                }
            }.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 11.5)).foregroundColor(isSelected ? .white.opacity(0.85) : .secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(isSelected ? .white : .primary)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor : Color.clear))
    }
}

/// Fork: a non-activating floating panel, so showing it never steals focus from the app you are leaving.
final class JumpPanel: NSPanel {
    init(_ model: JumpModel, onPick: @escaping (Int) -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 200), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        let hosting = JumpHostingView(model: model, onPick: onPick)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    /// Centers on the screen under the mouse, a little above the middle like Spotlight.
    func present() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2,
            width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }

    /// Re-fits after items change while visible, keeping the top edge where it was.
    func refit() {
        guard isVisible, let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}

/// Fork: mouse support. The panel never becomes key (it must not take focus from the app being left), and
/// SwiftUI's hover and tap handling only run in the key window of the active app, so this view tracks the mouse
/// itself: moving over a row selects it, clicking a row jumps to it.
final class JumpHostingView: NSHostingView<JumpView> {
    private let model: JumpModel
    private let onPick: (Int) -> Void

    init(model: JumpModel, onPick: @escaping (Int) -> Void) {
        self.model = model
        self.onPick = onPick
        super.init(rootView: JumpView(model: model))
    }

    @MainActor required init(rootView: JumpView) { fatalError("use init(model:onPick:)") }
    required init?(coder: NSCoder) { fatalError("use init(model:onPick:)") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self && $0.userInfo?["jump"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: ["jump": true]))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        if let index = row(event), index != model.selected { model.selected = index }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = row(event) { onPick(index) } else { super.mouseDown(with: event) }
    }

    private func row(_ event: NSEvent) -> Int? {
        var point = convert(event.locationInWindow, from: nil)
        if !isFlipped { point.y = bounds.height - point.y }
        return model.row(at: point)
    }
}
