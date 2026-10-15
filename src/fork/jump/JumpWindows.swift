import Cocoa

/// Fork: JubTab's own window list as Jump items, most recently focused first. Main thread only: `Windows.list`
/// is main-thread state.
enum JumpWindows {
    static func items() -> [JumpItem] {
        let own = Bundle.main.bundleIdentifier
        let now = Date()
        let windows = Windows.list
            .filter { !$0.isWindowlessApp && !$0.isPhantom && $0.cgWindowId != nil && $0.application.runningApplication.bundleIdentifier != own }
            .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
        return windows.enumerated().compactMap { order, window in
            guard let wid = window.cgWindowId else { return nil }
            let app = window.application.runningApplication.localizedName ?? ""
            return JumpItem(id: "window-\(wid)", section: .windows, title: window.title.isEmpty ? app : window.title,
                subtitle: app, iconKey: window.application.runningApplication.bundleIdentifier ?? "",
                action: { DispatchQueue.main.async { Windows.list.first { $0.cgWindowId == wid }?.focus() } },
                // Windows have a focus order, not a timestamp; spacing them a minute apart lets them interleave
                // with timestamped tabs and workspaces when breaking ties.
                keywords: app, recency: now.addingTimeInterval(-Double(order) * 60))
        }
    }
}
