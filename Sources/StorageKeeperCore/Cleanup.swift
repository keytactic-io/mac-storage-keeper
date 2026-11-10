import Foundation

public struct TrashOutcome: Sendable {
    public var trashed: [String] = []
    public var failed: [(path: String, reason: String)] = []
}

public struct ShellOutcome: Sendable {
    public var status: Int32
    public var output: String
    public var succeeded: Bool { status == 0 }
}

/// Cleanup actions. Everything goes through built-in macOS mechanisms:
/// files are moved to the Trash (recoverable with Put Back), the Trash is emptied by Finder,
/// and tool caches are cleared with each tool's own command.
/// Callers are responsible for asking the user to confirm first.
public enum Cleanup {
    /// Folders that must never be trashed as a whole, whatever the caller asks for.
    public static func isProtected(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let comps = (p as NSString).pathComponents
        if comps.count <= 2 { return true } // "/", "/Users", "/Applications", …
        for sys in ["/System", "/bin", "/sbin", "/usr/bin", "/usr/lib", "/usr/sbin", "/private/var/vm", "/private/var/db", "/Library/Apple"] {
            if p == sys || p.hasPrefix(sys + "/") { return true }
        }
        let home = Paths.home
        if p == home { return true }
        let homeFolders = ["Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Applications", "Public"]
        if homeFolders.contains(where: { p == home + "/" + $0 }) { return true }
        return false
    }

    public static func moveToTrash(_ paths: [String]) -> TrashOutcome {
        var out = TrashOutcome()
        for p in paths {
            if isProtected(p) {
                out.failed.append((p, "protected folder"))
                continue
            }
            if Attributor.shared.safety(of: p) == .system {
                out.failed.append((p, "managed by macOS"))
                continue
            }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                out.trashed.append(p)
            } catch {
                out.failed.append((p, error.localizedDescription))
            }
        }
        return out
    }

    /// Asks Finder to empty the Trash. macOS will ask once for permission to control Finder.
    public static func emptyTrash() -> ShellOutcome {
        run(executable: "/usr/bin/osascript", arguments: ["-e", "tell application \"Finder\" to empty trash"])
    }

    private static let toolLock = NSLock()
    nonisolated(unsafe) private static var toolCache: [String: Bool] = [:]

    /// Whether a command-line tool is on the user's PATH (as their login shell sees it).
    public static func toolAvailable(_ tool: String) -> Bool {
        // The name is interpolated into a shell command, so only allow plain command names.
        guard !tool.isEmpty, tool.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            return false
        }
        toolLock.lock()
        if let v = toolCache[tool] { toolLock.unlock(); return v }
        toolLock.unlock()
        let ok = shell("command -v \(tool) >/dev/null 2>&1", timeout: 20).succeeded
        toolLock.lock(); toolCache[tool] = ok; toolLock.unlock()
        return ok
    }

    /// Runs a command in the user's login shell so PATH matches their Terminal
    /// (Homebrew, nvm, etc.). The command text comes from the built-in recommendation table only.
    public static func shell(_ command: String, timeout: TimeInterval = 600) -> ShellOutcome {
        run(executable: "/bin/zsh", arguments: ["-lic", command], timeout: timeout)
    }

    public static func run(executable: String, arguments: [String], timeout: TimeInterval = 120) -> ShellOutcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var data = Data()
        let readLock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            readLock.lock(); data.append(chunk); readLock.unlock()
        }
        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return ShellOutcome(status: -1, output: error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        readLock.lock(); data.append(rest); readLock.unlock()
        let text = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").filter { !$0.contains("can't change option: zle") }.joined(separator: "\n")
        return ShellOutcome(status: p.terminationStatus, output: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct CleanupResult: Sendable {
    public var success: Bool
    public var message: String
    public var bytes: Int64
}

extension Cleanup {
    /// Names of apps whose data is among `items`, for the confirmation warning.
    public static func appDataOwners(_ items: [RecItem]) -> [String] {
        var seen: [String] = []
        for i in items {
            let a = Attributor.shared.attribution(inDirectory: i.path)
            if a.safety == .appData, !seen.contains(a.owner) { seen.append(a.owner) }
        }
        return seen
    }

    /// Items macOS manages, which `perform` will refuse to trash.
    public static func systemItems(_ items: [RecItem]) -> [RecItem] {
        items.filter { Attributor.shared.safety(of: $0.path) == .system }
    }

    /// Describes exactly what `perform` will do, for the confirmation dialog.
    public static func describe(_ rec: Recommendation, selected: [RecItem]) -> String {
        let total = Fmt.bytes(selected.reduce(0) { $0 + $1.bytes })
        switch rec.effectiveAction {
        case .emptyTrash:
            return "Finder will permanently erase everything in the Trash (\(Fmt.bytes(rec.bytes)))."
        case .command(_, let cmd, _):
            return "This runs:\n\n    \(cmd)\n\nCurrently \(total) in:\n" + selected.prefix(5).map { "• " + Fmt.path($0.path) }.joined(separator: "\n")
        case .trashAll, .review:
            let list = selected.prefix(12).map { "• \(Fmt.path($0.path))  (\(Fmt.bytes($0.bytes)))" }.joined(separator: "\n")
            let more = selected.count > 12 ? "\n…and \(selected.count - 12) more" : ""
            var text = "Move \(selected.count) item\(selected.count == 1 ? "" : "s") (\(total)) to the Trash:\n\n\(list)\(more)\n\nYou can restore them with Put Back. Space is freed when you empty the Trash."
            if rec.id != Leftovers.recommendationID {
                let apps = appDataOwners(selected)
                if !apps.isEmpty {
                    text += "\n\n⚠️ App data for \(apps.joined(separator: ", ")). Deleting it resets the app or removes its content. Quit \(apps.count == 1 ? "it" : "them") first."
                }
            }
            return text
        case .reveal:
            return ""
        }
    }

    /// Runs a recommendation's action. Only call after the user confirmed `describe(...)`.
    public static func perform(_ rec: Recommendation, selected: [RecItem]) -> CleanupResult {
        let total = selected.reduce(0) { $0 + $1.bytes }
        switch rec.effectiveAction {
        case .emptyTrash:
            let r = emptyTrash()
            return CleanupResult(success: r.succeeded, message: r.succeeded ? "Trash emptied." : "Finder could not empty the Trash: \(r.output)", bytes: r.succeeded ? rec.bytes : 0)
        case .command(_, let cmd, _):
            let before = selected.reduce(0) { $0 + DiskScanner.size(of: $1.path) }
            let r = shell(cmd)
            let after = selected.reduce(0) { $0 + DiskScanner.size(of: $1.path) }
            let freed = max(0, before - after)
            let tail = r.output.split(separator: "\n").suffix(6).joined(separator: "\n")
            return CleanupResult(success: r.succeeded,
                                 message: r.succeeded ? "`\(cmd)` finished. Freed \(Fmt.bytes(freed)).\n\(tail)" : "`\(cmd)` failed (exit \(r.status)).\n\(tail)",
                                 bytes: freed)
        case .trashAll, .review:
            let r = moveToTrash(selected.map(\.path))
            let moved = selected.filter { r.trashed.contains($0.path) }.reduce(0) { $0 + $1.bytes }
            var msg = "Moved \(r.trashed.count) item\(r.trashed.count == 1 ? "" : "s") (\(Fmt.bytes(moved))) to the Trash."
            if !r.failed.isEmpty {
                msg += "\nCould not move \(r.failed.count): " + r.failed.prefix(3).map { "\(Fmt.path($0.path)): \($0.reason)" }.joined(separator: "; ")
            }
            return CleanupResult(success: r.failed.isEmpty, message: msg, bytes: moved)
        case .reveal:
            return CleanupResult(success: true, message: "", bytes: total)
        }
    }
}
