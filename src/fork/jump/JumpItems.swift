import Cocoa

/// Fork: one destination in the Jump switcher.
struct JumpItem {
    enum Section: Int, CaseIterable {
        case servers, workspaces, tabs
        var title: String { ["Servers", "cmux", "Zen"][rawValue] }
    }

    let id: String
    let section: Section
    let title: String
    let subtitle: String
    let iconKey: String
    let action: () -> Void
}

/// Fork: reads every source and links them. A server is tied to the cmux workspace that owns its port or its
/// folder, and to the Zen tab already showing it, so selecting the server reuses that tab instead of opening one.
enum JumpItems {
    static func load() -> [JumpItem] {
        var servers = [LocalServers.Server]()
        var workspaces = [CmuxWorkspaces.Workspace]()
        var tabs = [ZenTabs.Tab]()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { servers = LocalServers.read() }
        DispatchQueue.global().async(group: group) { workspaces = CmuxWorkspaces.read() }
        DispatchQueue.global().async(group: group) { tabs = ZenTabs.read() }
        group.wait()
        return build(servers, workspaces, tabs)
    }

    static func build(_ servers: [LocalServers.Server], _ workspaces: [CmuxWorkspaces.Workspace], _ tabs: [ZenTabs.Tab]) -> [JumpItem] {
        var items = [JumpItem]()
        for server in servers {
            let workspace = workspaces.first { $0.ports.contains(server.port) }
                ?? workspaces.filter { w in server.cwd.map { cwd in w.cwd.map { cwd.hasPrefix($0) } ?? false } ?? false }
                    .max { ($0.cwd?.count ?? 0) < ($1.cwd?.count ?? 0) }
            let tab = tabs.filter { port(of: $0.url) == server.port }.max { ($0.lastAccessed ?? .distantPast) < ($1.lastAccessed ?? .distantPast) }
            let title = server.title ?? server.project ?? server.process
            let context = [workspace.map { cleanTitle($0.title) } ?? server.project, server.process].compactMap { $0 }
            let subtitle = (["localhost:\(server.port)"] + context + (tab == nil ? [] : ["open in Zen"])).joined(separator: "  ·  ")
            items.append(JumpItem(id: "server-\(server.port)", section: .servers, title: title, subtitle: subtitle,
                iconKey: "server", action: {
                    if let tab { ZenTabs.activate(tab) } else { ZenTabs.open(server.url) }
                }))
        }
        for workspace in workspaces.sorted(by: { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }) {
            let folder = workspace.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
            let ports = workspace.ports.map { ":\($0)" }
            let subtitle = ([folder].compactMap { $0 } + ports).joined(separator: "  ·  ")
            items.append(JumpItem(id: "cmux-\(workspace.id)", section: .workspaces, title: cleanTitle(workspace.title),
                subtitle: subtitle, iconKey: CmuxWorkspaces.bundleId, action: { CmuxWorkspaces.select(workspace) }))
        }
        for tab in tabs.sorted(by: { ($0.lastAccessed ?? .distantPast) > ($1.lastAccessed ?? .distantPast) }) {
            let host = URL(string: tab.url).flatMap { u in u.host.map { h in u.port.map { "\(h):\($0)" } ?? h } } ?? tab.url
            items.append(JumpItem(id: "zen-\(tab.url)-\(tab.title)", section: .tabs, title: tab.title, subtitle: host,
                iconKey: tab.favicon ?? ZenTabs.bundleId, action: { ZenTabs.activate(tab) }))
        }
        return items
    }

    static func port(of url: String) -> Int? {
        guard let u = URL(string: url), let host = u.host, ["localhost", "127.0.0.1", "[::1]", "::1", "0.0.0.0"].contains(host) else { return nil }
        return u.port ?? (u.scheme == "https" ? 443 : 80)
    }

    /// cmux prefixes workspace titles with an activity glyph (◐ ◑ ✳ …); the switcher shows plain names.
    static func cleanTitle(_ title: String) -> String {
        var t = Substring(title)
        while let first = t.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first), first != "(" && first != "[" {
            t = t.dropFirst()
        }
        return t.trimmingCharacters(in: .whitespaces).isEmpty ? title : String(t).trimmingCharacters(in: .whitespaces)
    }
}
