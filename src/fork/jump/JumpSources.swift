import Cocoa

/// Fork: Zen tabs, read from Zen's session file. It is rewritten within ~15s of any tab change, which is fresh
/// enough to list tabs; switching to one goes through Accessibility (see `ZenTabs.activate`).
enum ZenTabs {
    static let bundleId = "app.zen-browser.zen"

    struct Tab {
        let title: String
        let url: String
        let favicon: String?
        let lastAccessed: Date?
        let isActive: Bool
    }

    static func sessionFile() -> URL? {
        let profiles = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/zen/Profiles")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? []
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return dirs.map { $0.appendingPathComponent("sessionstore-backups/recovery.jsonlz4") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .max { modified($0) < modified($1) }
    }

    static func read() -> [Tab] {
        guard let file = sessionFile(), let raw = try? Data(contentsOf: file), let json = MozLz4.decode(raw),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let windows = root["windows"] as? [[String: Any]] else {
            JumpSupport.log("zen: session file unreadable")
            return []
        }
        var tabs = [Tab]()
        for window in windows {
            for tab in window["tabs"] as? [[String: Any]] ?? [] {
                guard let entries = tab["entries"] as? [[String: Any]], !entries.isEmpty else { continue }
                let index = min(max((tab["index"] as? Int ?? entries.count) - 1, 0), entries.count - 1)
                let entry = entries[index]
                guard let url = entry["url"] as? String, !url.hasPrefix("about:") else { continue }
                let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
                let lastAccessed = (tab["lastAccessed"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                tabs.append(Tab(title: title, url: url, favicon: tab["image"] as? String, lastAccessed: lastAccessed,
                    isActive: tab["_zenIsActiveTab"] as? Bool ?? false))
            }
        }
        return tabs
    }

    /// Switches Zen to the tab by pressing its tab-strip element through Accessibility. Falls back to opening the
    /// URL when the tab isn't exposed (e.g. it lives in another Zen space), which duplicates it.
    static func activate(_ tab: Tab) {
        if !press(tab.title) { open(tab.url) }
    }

    /// Presses the tab titled `title` in Zen's tab strip and brings Zen forward. False when Zen isn't running or
    /// no such tab is exposed.
    @discardableResult
    static func press(_ title: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first,
              let element = findTabElement(AXUIElementCreateApplication(app.processIdentifier), title) else {
            JumpSupport.log("zen: no AX tab element titled \"\(title)\"")
            return false
        }
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        app.activate(options: [])
        JumpSupport.log("zen: pressed tab \"\(title)\" status \(status.rawValue)")
        return status == .success
    }

    static func open(_ url: String) {
        guard let target = URL(string: url) else { return }
        if let zen = JumpSupport.appUrl(bundleId) {
            NSWorkspace.shared.open([target], withApplicationAt: zen, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    /// Breadth-first through Zen's browser chrome. Web content (`AXWebArea`) is skipped: it is huge and never
    /// holds the tab strip.
    private static func findTabElement(_ app: AXUIElement, _ title: String) -> AXUIElement? {
        var queue = [app]
        var visited = 0
        let tabRoles: Set<String> = ["AXRadioButton", "AXTab", "AXButton", "AXGroup", "AXListItem"]
        while !queue.isEmpty, visited < 4000 {
            let element = queue.removeFirst()
            visited += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea" { continue }
            if tabRoles.contains(role), let subrole = attribute(element, kAXSubroleAttribute) as? String, subrole == "AXTabButton" || role == "AXRadioButton" {
                let name = (attribute(element, kAXTitleAttribute) as? String) ?? (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
                if name == title { return element }
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        JumpSupport.log("zen: searched \(visited) AX elements")
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

/// Fork: local web servers — listening TCP ports whose `/` answers with an HTML page.
enum LocalServers {
    struct Server {
        let pid: Int32
        let port: Int
        let process: String
        var cwd: String?
        var title: String?
        var url: String { "http://localhost:\(port)/" }
        var project: String? { cwd.flatMap { $0 == "/" ? nil : URL(fileURLWithPath: $0).lastPathComponent } }
    }

    static func read() -> [Server] {
        let candidates = listening().filter { !isBundledApp($0.pid) }
        guard !candidates.isEmpty else { return [] }
        let cwds = workingDirectories(Set(candidates.map(\.pid)))
        var servers = [Server?](repeating: nil, count: candidates.count)
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            var server = candidates[i]
            guard let title = probe(server.port) else { return }
            server.title = title.isEmpty ? nil : title
            server.cwd = cwds[server.pid]
            servers[i] = server
        }
        return servers.compactMap { $0 }.sorted { $0.port < $1.port }
    }

    /// SIGTERM so the server can shut down cleanly; SIGKILL if it is still running a few seconds later.
    static func stop(_ server: Server) {
        JumpSupport.log("server: stopping :\(server.port) pid \(server.pid) (\(server.process))")
        kill(server.pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            guard kill(server.pid, 0) == 0 else { return }
            JumpSupport.log("server: pid \(server.pid) ignored SIGTERM; killing")
            kill(server.pid, SIGKILL)
        }
    }

    /// GUI apps (LM Studio, Notion, AirPlay's ControlCenter…) serve their own pages; dev servers are plain CLI
    /// processes. Python is the exception: framework builds run as Python.app.
    private static func isBundledApp(_ pid: Int32) -> Bool {
        guard let data = JumpSupport.run("/bin/ps", ["-o", "comm=", "-p", String(pid)]),
              let path = String(data: data, encoding: .utf8) else { return false }
        return path.contains(".app/") && !path.contains("/Python.app/")
    }

    /// `lsof -F` emits one field per line: `p<pid>`, `c<command>`, `n<address>`.
    private static func listening() -> [Server] {
        guard let data = JumpSupport.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        var pid: Int32 = 0
        var command = ""
        var seen = Set<Int>()
        var result = [Server]()
        for line in text.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
                case "p": pid = Int32(value) ?? 0
                case "c": command = value.replacingOccurrences(of: "\\x20", with: " ")
                case "n":
                    guard pid != ownPid, let port = value.split(separator: ":").last.flatMap({ Int($0) }),
                          !seen.contains(port) else { continue }
                    seen.insert(port)
                    result.append(Server(pid: pid, port: port, process: command))
                default: break
            }
        }
        return result
    }

    private static func workingDirectories(_ pids: Set<Int32>) -> [Int32: String] {
        let list = pids.map(String.init).joined(separator: ",")
        guard let data = JumpSupport.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", list, "-Fpn"]),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var pid: Int32 = 0
        var result = [Int32: String]()
        for line in text.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) ?? 0 }
            if line.first == "n" { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    /// Returns the page title ("" when the page has none), or nil when the port isn't serving HTML.
    private static func probe(_ port: Int) -> String? {
        guard let url = URL(string: "http://localhost:\(port)/") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 0.8)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.8
        config.timeoutIntervalForResource = 1.2
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        var title: String?
        session.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard let http = response as? HTTPURLResponse,
                  (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/html"),
                  let data, let html = String(data: data.prefix(64_000), encoding: .utf8) ?? String(data: data.prefix(64_000), encoding: .isoLatin1) else { return }
            title = extractTitle(html) ?? ""
        }.resume()
        _ = done.wait(timeout: .now() + 1.5)
        return title
    }

    static func extractTitle(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: tagEnd.upperBound..<html.endIndex) else { return nil }
        let raw = html[tagEnd.upperBound..<close.lowerBound]
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}

/// Fork: cmux workspaces, through the cmux CLI (which talks to cmux's control socket).
enum CmuxWorkspaces {
    static let bundleId = "com.cmuxterm.app"

    struct Workspace {
        let id: String
        let title: String
        let cwd: String?
        let ports: [Int]
        let isSelected: Bool
        let lastActive: Date?
    }

    static var cli: String? {
        JumpSupport.appUrl(bundleId).map { $0.appendingPathComponent("Contents/Resources/bin/cmux").path }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    static func read() -> [Workspace] {
        guard let cli, let data = JumpSupport.run(cli, ["workspace", "list", "--json"], env: ["CMUX_QUIET": "1"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = root["workspaces"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return workspaces.compactMap { w in
            guard let id = w["id"] as? String else { return nil }
            let title = (w["title"] as? String) ?? (w["custom_title"] as? String) ?? "Workspace"
            return Workspace(id: id, title: title, cwd: w["current_directory"] as? String,
                ports: w["listening_ports"] as? [Int] ?? [], isSelected: w["selected"] as? Bool ?? false,
                lastActive: (w["latest_submitted_at"] as? String).flatMap { iso.date(from: $0) })
        }
    }

    static func select(_ workspace: Workspace) {
        if let cli { _ = JumpSupport.run(cli, ["select-workspace", "--workspace", workspace.id], env: ["CMUX_QUIET": "1"]) }
        JumpSupport.activate(bundleId)
    }
}
