import Cocoa

/// Fork: helpers shared by the Jump switcher's sources. Kept free of JubTab internals so the sources can be
/// compiled into a standalone harness (scripts/fork/jump-harness.sh) and checked from a terminal.
enum JumpSupport {
    static let logUrl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/JubTab-jump.log")

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logUrl) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logUrl)
        }
    }

    /// Runs a command and returns its stdout, or nil on launch failure, non-zero exit or timeout.
    static func run(_ path: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval = 2) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            log("run \(path) failed: \(error)")
            return nil
        }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            log("run \(path) \(args.first ?? "") exited \(process.terminationStatus)")
            return nil
        }
        return data
    }

    static func appUrl(_ bundleId: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    static func appIcon(_ bundleId: String) -> NSImage? {
        appUrl(bundleId).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    static func activate(_ bundleId: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate(options: [])
    }
}

/// Mozilla's "mozLz40\0" container: an 8-byte magic, a little-endian u32 decompressed size, then one LZ4 block.
enum MozLz4 {
    static func decode(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 12, bytes.prefix(8).elementsEqual(Array("mozLz40\0".utf8)) else { return nil }
        let size = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
        var out = [UInt8]()
        out.reserveCapacity(size)
        var i = 12
        func length(_ initial: Int) -> Int? {
            var n = initial
            guard n == 15 else { return n }
            while i < bytes.count {
                let b = Int(bytes[i])
                i += 1
                n += b
                if b != 255 { return n }
            }
            return nil
        }
        while i < bytes.count {
            let token = Int(bytes[i])
            i += 1
            guard let literal = length(token >> 4), i + literal <= bytes.count else { return nil }
            out.append(contentsOf: bytes[i..<i + literal])
            i += literal
            if i >= bytes.count { break }
            guard i + 1 < bytes.count else { return nil }
            let offset = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
            guard offset > 0, offset <= out.count, let match = length(token & 15) else { return nil }
            let start = out.count - offset
            // Byte by byte: a match may overlap the bytes it is producing.
            for k in 0..<(match + 4) { out.append(out[start + k]) }
        }
        return Data(out)
    }
}
