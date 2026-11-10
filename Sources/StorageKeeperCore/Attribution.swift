import AppKit
import Foundation

public enum Category: String, Codable, CaseIterable, Sendable {
    case developer, packages, aiModels, browser, communication, downloads, trash, cloud, media, apps, system, other

    public var label: String {
        switch self {
        case .developer: return "Developer"
        case .packages: return "Packages"
        case .aiModels: return "AI models"
        case .browser: return "Browsers"
        case .communication: return "Messaging"
        case .downloads: return "Downloads"
        case .trash: return "Trash"
        case .cloud: return "Cloud"
        case .media: return "Media"
        case .apps: return "Apps"
        case .system: return "System"
        case .other: return "Other"
        }
    }

    /// SF Symbol name used in the UI.
    public var symbol: String {
        switch self {
        case .developer: return "hammer"
        case .packages: return "shippingbox"
        case .aiModels: return "cpu"
        case .browser: return "globe"
        case .communication: return "bubble.left.and.bubble.right"
        case .downloads: return "arrow.down.circle"
        case .trash: return "trash"
        case .cloud: return "icloud"
        case .media: return "photo"
        case .apps: return "app"
        case .system: return "gearshape"
        case .other: return "folder"
        }
    }
}

/// How safe a folder is to delete. Only `.appData` and `.system` are flagged in the UI.
public enum Safety: String, Codable, Sendable {
    /// Rebuilt or re-downloaded automatically (caches, build output, node_modules).
    case safe
    /// Your data, or slow/expensive to get back (downloads, models, archives).
    case review
    /// Belongs to an app; deleting resets the app or loses its settings/content.
    case appData
    /// Managed by macOS or shared system software; deleting by hand can break things. Trash is blocked.
    case system
    /// Not in the table (usually your own files).
    case unknown

    /// Whether to show a marker for this level.
    public var isFlagged: Bool { self == .appData || self == .system }

    public var label: String {
        switch self {
        case .safe: return "Safe to clear"
        case .review: return "Review first"
        case .appData: return "App data"
        case .system: return "Managed by macOS"
        case .unknown: return "Your files"
        }
    }

    public func explanation(owner: String) -> String {
        switch self {
        case .appData: return "App data for \(owner). Deleting it resets the app or removes its content."
        case .system: return "Managed by macOS. Don't delete it by hand; it can break features or come back."
        case .safe: return "Rebuilt automatically when needed."
        case .review: return "Review before deleting; it may be slow or impossible to get back."
        case .unknown: return ""
        }
    }
}

/// Who or what is responsible for a folder.
public struct Attribution: Hashable, Sendable {
    public var owner: String
    public var category: Category
    /// Absolute path of the folder that this attribution covers.
    public var root: String
    public var note: String?
    public var safety: Safety

    public init(owner: String, category: Category, root: String, note: String? = nil, safety: Safety = .unknown) {
        self.owner = owner
        self.category = category
        self.root = root
        self.note = note
        self.safety = safety
    }
}

/// Maps paths to the app or tool that owns them, using a table of known locations.
/// macOS does not record which process wrote a file, so this is a heuristic:
/// known cache/data locations, bundle-ID folders, project dependency folders,
/// and (for downloads) the quarantine attribute that names the downloading app.
public final class Attributor: @unchecked Sendable {
    public static let shared = Attributor()

    private struct Rule {
        let owner: String
        let category: Category
        let note: String?
        var safety: Safety
    }

    private struct WildcardRule {
        let category: Category
        let suffix: String
        let resolveBundleID: Bool
        let safety: Safety
    }

    /// Default safety for a rule, from its category. Rules whose note says they regenerate are safe.
    private static func defaultSafety(_ cat: Category, note: String?, regen: String) -> Safety {
        if let note, note.contains(regen) { return .safe }
        switch cat {
        case .packages, .trash: return .safe
        case .developer, .aiModels, .downloads: return .review
        case .browser, .communication, .media, .apps, .cloud: return .appData
        case .system: return .system
        case .other: return .unknown
        }
    }

    private var exact: [String: Rule] = [:]
    private var wildcard: [String: WildcardRule] = [:]
    private let lock = NSLock()
    private var nameCache: [String: String] = [:]
    private var containingCache: [String: Attribution] = [:]

    private init() {
        let regen = "Regenerated automatically when needed."
        func add(_ path: String, _ owner: String, _ cat: Category, _ note: String? = nil, safety: Safety? = nil) {
            exact[Paths.expand(path)] = Rule(owner: owner, category: cat, note: note,
                                             safety: safety ?? Attributor.defaultSafety(cat, note: note, regen: regen))
        }
        func wild(_ parent: String, _ cat: Category, suffix: String = "", bundle: Bool = true, safety: Safety) {
            wildcard[Paths.expand(parent)] = WildcardRule(category: cat, suffix: suffix, resolveBundleID: bundle, safety: safety)
        }
        /// Overrides the safety of a rule added above.
        func level(_ path: String, _ s: Safety) {
            exact[Paths.expand(path)]?.safety = s
        }

        // Browser automation, often installed by AI coding agents and test runners.
        add("~/Library/Caches/ms-playwright", "Playwright browsers", .developer, "Chromium/Firefox/WebKit builds downloaded by Playwright. \(regen)")
        add("~/.cache/ms-playwright", "Playwright browsers", .developer, regen)
        add("~/Library/Caches/ms-playwright-go", "Playwright (Go)", .developer, regen)
        add("~/.cache/puppeteer", "Puppeteer browsers", .developer, regen)
        add("~/Library/Caches/Cypress", "Cypress", .developer, regen)
        add("~/.cache/selenium", "Selenium drivers", .developer, regen)

        // JavaScript
        add("~/.npm", "npm cache", .packages, regen)
        add("~/Library/pnpm", "pnpm store", .packages)
        add("~/.pnpm-store", "pnpm store", .packages)
        add("~/.local/share/pnpm", "pnpm store", .packages)
        add("~/Library/Caches/Yarn", "Yarn cache", .packages, regen)
        add("~/.yarn", "Yarn", .packages)
        add("~/.bun", "Bun", .packages)
        add("~/.nvm", "nvm (Node versions)", .developer)
        add("~/.volta", "Volta (Node versions)", .developer)
        add("~/Library/Application Support/fnm", "fnm (Node versions)", .developer)
        add("~/.cache/node", "Corepack", .packages)
        add("~/Library/Caches/node-gyp", "node-gyp headers", .developer, regen)
        add("~/.deno", "Deno", .developer)
        add("~/Library/Caches/deno", "Deno cache", .packages, regen)

        // Python
        add("~/Library/Caches/pip", "pip cache", .packages, regen)
        add("~/.cache/pip", "pip cache", .packages, regen)
        add("~/.cache/uv", "uv cache", .packages, regen)
        add("~/.local/share/uv", "uv (Python versions)", .developer)
        add("~/.pyenv", "pyenv (Python versions)", .developer)
        add("~/Library/Caches/pypoetry", "Poetry cache", .packages, regen)
        add("~/miniconda3", "Conda", .developer)
        add("~/anaconda3", "Conda", .developer)
        add("~/miniforge3", "Conda", .developer)
        add("~/.conda", "Conda", .developer)

        // Other languages
        add("~/.cargo", "Rust (cargo)", .packages)
        add("~/.rustup", "Rust toolchains", .developer)
        add("~/go", "Go modules", .packages)
        add("~/Library/Caches/go-build", "Go build cache", .developer, regen)
        add("~/.gradle", "Gradle", .packages)
        add("~/.m2", "Maven", .packages)
        add("~/.android", "Android tools", .developer)
        add("~/Library/Android", "Android SDK", .developer)
        add("~/.gem", "Ruby gems", .packages)
        add("~/.cocoapods", "CocoaPods", .packages)
        add("~/Library/Caches/CocoaPods", "CocoaPods cache", .packages, regen)
        add("~/.swiftpm", "Swift packages", .packages)
        add("~/Library/Caches/org.swift.swiftpm", "Swift package cache", .packages, regen)

        // Apple developer tools
        add("~/Library/Developer/Xcode/DerivedData", "Xcode DerivedData", .developer, "Build products and indexes. \(regen)")
        add("~/Library/Developer/Xcode/Archives", "Xcode Archives", .developer, "App archives you built for distribution.")
        add("~/Library/Developer/Xcode/iOS DeviceSupport", "Xcode device support", .developer, "Debug symbols copied from connected devices.")
        add("~/Library/Developer/Xcode/watchOS DeviceSupport", "Xcode device support", .developer)
        add("~/Library/Developer/CoreSimulator", "iOS Simulators", .developer)
        add("~/Library/Caches/com.apple.dt.Xcode", "Xcode cache", .developer, regen)
        add("/Library/Developer/CoreSimulator", "Simulator runtimes", .developer)
        add("/Library/Developer/CommandLineTools", "Command Line Tools", .developer)
        add("/Applications/Xcode.app", "Xcode", .developer)

        // Package managers and containers
        add("~/Library/Caches/Homebrew", "Homebrew downloads", .packages, "Old bottles and source downloads.")
        add("/opt/homebrew", "Homebrew packages", .packages)
        add("/usr/local/Homebrew", "Homebrew", .packages)
        add("/usr/local/Cellar", "Homebrew packages", .packages)
        add("~/Library/Containers/com.docker.docker", "Docker", .developer, "Docker's VM disk image holds all images, containers and volumes.")
        add("~/.docker", "Docker", .developer)
        add("~/.orbstack", "OrbStack", .developer)
        add("~/Library/Group Containers/HUAQ24HBR6.dev.orbstack", "OrbStack", .developer)
        add("~/.colima", "Colima", .developer)
        add("~/.lima", "Lima VMs", .developer)

        // Editors and AI tools
        add("~/.vscode", "VS Code extensions", .developer)
        add("~/.cursor", "Cursor extensions", .developer)
        add("~/.kiro", "Kiro", .developer)
        add("~/.windsurf", "Windsurf extensions", .developer)
        add("~/.claude", "Claude Code", .developer)
        add("~/.codex", "Codex CLI", .developer)
        add("~/.gemini", "Gemini CLI", .developer)
        add("~/Library/Application Support/Code", "VS Code", .developer)
        add("~/Library/Application Support/Cursor", "Cursor", .developer)
        add("~/Library/Application Support/Kiro", "Kiro", .developer)
        add("~/Library/Application Support/Windsurf", "Windsurf", .developer)
        add("~/Library/Application Support/Claude", "Claude desktop", .developer)

        // AI models
        add("~/.cache/huggingface", "Hugging Face models", .aiModels, "Downloaded model weights and datasets.")
        add("~/.ollama", "Ollama models", .aiModels, "Remove models with `ollama rm <name>`.")
        add("~/.lmstudio", "LM Studio models", .aiModels)
        add("~/.cache/lm-studio", "LM Studio models", .aiModels)
        add("~/.cache/torch", "PyTorch hub", .aiModels)
        add("~/.cache/whisper", "Whisper models", .aiModels)
        add("~/.keras", "Keras models", .aiModels)
        add("~/Library/Application Support/DiffusionBee", "DiffusionBee models", .aiModels)

        // Browsers
        add("~/Library/Caches/Google", "Google Chrome cache", .browser, regen)
        add("~/Library/Application Support/Google", "Google Chrome data", .browser)
        add("~/Library/Application Support/Microsoft Edge", "Microsoft Edge data", .browser)
        add("~/Library/Caches/Microsoft Edge", "Microsoft Edge cache", .browser, regen)
        add("~/Library/Application Support/BraveSoftware", "Brave data", .browser)
        add("~/Library/Caches/BraveSoftware", "Brave cache", .browser, regen)
        add("~/Library/Application Support/Arc", "Arc data", .browser)
        add("~/Library/Application Support/Firefox", "Firefox data", .browser)
        add("~/Library/Caches/Firefox", "Firefox cache", .browser, regen)
        add("~/Library/Safari", "Safari", .browser)

        // Messaging
        add("~/Library/Application Support/Slack", "Slack", .communication)
        add("~/Library/Containers/com.tinyspeck.slackmacgap", "Slack", .communication)
        add("~/Library/Application Support/discord", "Discord", .communication)
        add("~/Library/Application Support/zoom.us", "Zoom", .communication)
        add("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared", "WhatsApp", .communication)
        add("~/Library/Mail", "Mail", .communication)
        add("~/Library/Messages", "Messages", .communication)

        // Media and cloud
        add("~/Pictures/Photos Library.photoslibrary", "Photos Library", .media)
        add("~/Music/Music", "Music", .media)
        add("~/Music/Logic", "Logic Pro", .media)
        add("/Library/Application Support/GarageBand", "GarageBand sounds", .media)
        add("/Library/Application Support/Logic", "Logic sounds", .media)
        add("~/Library/Mobile Documents", "iCloud Drive", .cloud)
        add("~/Dropbox", "Dropbox", .cloud)

        // System and user folders
        add("~/.Trash", "Trash", .trash, "Files you deleted. Space is freed when the Trash is emptied.")
        add("~/Downloads", "Downloads", .downloads)
        add("~/Library/Application Support/MobileSync", "iPhone/iPad backups", .system, "Manage in Finder → your device → Manage Backups.")
        add("~/Library/Logs", "Logs", .system)
        add("/private/var/vm", "Swap & sleep image", .system, "Managed by macOS.")
        add("/private/var/folders", "Temporary files", .system, "Managed by macOS; cleared on restart.")
        add("/Library/Updates", "macOS updates", .system)
        add("/System/Library/AssetsV2", "macOS downloaded assets", .system, "Apple Intelligence models, voices, dictation and fonts that macOS downloads on demand. To shrink it, turn off Apple Intelligence (System Settings → Apple Intelligence & Siri) or remove extra voices (Accessibility → Spoken Content → System Voice → Manage Voices).")
        add("/private/var/MobileSoftwareUpdate", "macOS updates", .system)
        add("/Library/Caches", "System caches", .system)
        add("~/Library/Keychains", "Keychains (passwords)", .system, "Your saved passwords and certificates. Never delete by hand.")
        add("~/Library/Preferences", "App preferences", .apps, "Settings files for each app.")
        add("~/Library/Biome", "macOS activity data", .system)
        add("~/Library/Daemon Containers", "macOS service data", .system)
        add("~/Library/Metadata", "macOS metadata", .system)

        // Safety overrides where the category default is wrong.
        level("~/Library/Logs", .safe)                                   // logs are safe to remove
        level("~/Library/Application Support/MobileSync", .review)       // managed in Finder, but your call
        level("~/Library/Developer/Xcode/iOS DeviceSupport", .safe)       // recreated when a device connects
        level("~/Library/Developer/Xcode/watchOS DeviceSupport", .safe)
        level("/Library/Developer/CoreSimulator", .system)                // remove runtimes in Xcode → Settings → Platforms
        level("/Library/Developer/CommandLineTools", .system)
        for p in ["/opt/homebrew", "/usr/local/Homebrew", "/usr/local/Cellar", "~/.cargo", "~/go", "~/.gem",
                  "~/.swiftpm", "~/.yarn", "~/.bun", "~/Library/pnpm", "~/.local/share/pnpm"] {
            level(p, .review)                                            // installed tools live here, not just caches
        }
        for p in ["~/Library/Application Support/Code", "~/Library/Application Support/Cursor",
                  "~/Library/Application Support/Kiro", "~/Library/Application Support/Windsurf",
                  "~/Library/Application Support/Claude", "~/.claude", "~/.codex", "~/.gemini", "~/.kiro"] {
            level(p, .appData)                                           // editor/agent settings, history, extensions
        }
        level("/Library/Application Support/GarageBand", .review)        // re-downloadable from the app
        level("/Library/Application Support/Logic", .review)

        // Folders named after the owning app or bundle ID.
        wild("~/Library/Caches", .apps, suffix: " cache", safety: .safe)
        wild("~/Library/Containers", .apps, safety: .appData)
        wild("~/Library/Group Containers", .apps, safety: .appData)
        wild("~/Library/Application Support", .apps, safety: .appData)
        wild("/Library/Application Support", .apps, safety: .appData)
        wild("/Applications", .apps, bundle: false, safety: .review)
        wild("~/Applications", .apps, bundle: false, safety: .review)
        wild("~/Library/CloudStorage", .cloud, bundle: false, safety: .appData)
    }

    /// Safety of any path: the level of the outermost known location containing it,
    /// or a level based on where it lives (system folders, ~/Library) for unknown paths.
    public func safety(of path: String) -> Safety {
        attribution(inDirectory: path).safety
    }

    /// Safety for paths not covered by a rule.
    private static func fallbackSafety(_ dir: String) -> Safety {
        let home = Paths.home
        if dir == home || dir.hasPrefix(home + "/") {
            return dir.hasPrefix(home + "/Library/") || dir == home + "/Library" ? .appData : .unknown
        }
        if dir.hasPrefix("/usr/local") { return .unknown }
        for p in ["/System", "/private", "/usr", "/bin", "/sbin", "/Library", "/cores", "/opt"] where dir == p || dir.hasPrefix(p + "/") {
            return .system
        }
        return .unknown
    }

    /// Attribution when `path` itself is the root of a known location.
    public func attribution(forRoot path: String) -> Attribution? {
        if let r = exact[path] {
            return Attribution(owner: r.owner, category: r.category, root: path, note: r.note, safety: r.safety)
        }
        let name = Paths.name(path)
        let parent = Paths.parent(path)
        if let w = wildcard[parent], !name.hasPrefix(".") {
            let display = displayName(forFolder: name, resolveBundleID: w.resolveBundleID)
            let owner = display + w.suffix
            // Apple background services (no app, e.g. com.apple.wallpaper.agent) are part of macOS.
            // Apple apps (com.apple.MobileSMS → Messages) hold your data, so they count as app data.
            let apple = name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.")
            let isAppleService = apple && display == name
            return Attribution(owner: owner, category: w.category, root: path,
                               safety: isAppleService && w.safety == .appData ? .system : w.safety)
        }
        // Project dependency folders (often created by AI agents running `npm install`).
        switch name {
        case "node_modules":
            return Attribution(owner: "node_modules · \(Paths.name(parent))", category: .packages, root: path,
                               note: "Reinstall with `npm install` in the project.", safety: .safe)
        case ".venv", "venv":
            return Attribution(owner: "Python venv · \(Paths.name(parent))", category: .packages, root: path, safety: .safe)
        case "Pods":
            return Attribution(owner: "CocoaPods · \(Paths.name(parent))", category: .packages, root: path, safety: .safe)
        default:
            return nil
        }
    }

    /// The outermost known location containing the file at `path`, or a readable folder bucket.
    public func attribution(containingFile path: String) -> Attribution {
        attribution(inDirectory: Paths.parent(path))
    }

    /// The outermost known location that is `dir` or one of its ancestors, or a folder bucket.
    /// Cached because the live monitor calls this for every file event.
    public func attribution(inDirectory dir: String) -> Attribution {
        lock.lock()
        if let cached = containingCache[dir] { lock.unlock(); return cached }
        lock.unlock()

        let result = computeContaining(dir: dir)
        lock.lock()
        if containingCache.count > 50_000 { containingCache.removeAll(keepingCapacity: true) }
        containingCache[dir] = result
        lock.unlock()
        return result
    }

    private func computeContaining(dir: String) -> Attribution {
        // Walk from the top down so the outermost root wins (e.g. a project's node_modules,
        // not a nested node_modules inside it).
        var comps = (dir as NSString).pathComponents
        if comps.first == "/" { comps.removeFirst() }
        var current = ""
        for c in comps {
            current += "/" + c
            if let a = attribution(forRoot: current) { return a }
        }
        return fallbackBucket(for: dir)
    }

    /// Groups unknown paths into a readable folder: two levels below home, or three below "/".
    public func fallbackBucket(for dir: String) -> Attribution {
        let home = Paths.home
        let rel: [String]
        let base: String
        let depth: Int
        if dir == home || dir.hasPrefix(home + "/") {
            base = home
            rel = dir.dropFirst(home.count).split(separator: "/").map(String.init)
            depth = 2
        } else {
            base = ""
            rel = dir.split(separator: "/").map(String.init)
            depth = 3
        }
        let take = rel.prefix(depth)
        let root = take.isEmpty ? (base.isEmpty ? "/" : base) : base + "/" + take.joined(separator: "/")
        return Attribution(owner: Fmt.path(root), category: .other, root: root, safety: Attributor.fallbackSafety(dir))
    }

    /// Turns "com.google.Chrome" into "Google Chrome" when that app is installed.
    public func displayName(forFolder name: String, resolveBundleID: Bool) -> String {
        var base = name
        if base.hasSuffix(".app") { base = String(base.dropLast(4)) }
        guard resolveBundleID, base.contains(".") else { return base }
        lock.lock()
        if let cached = nameCache[base] { lock.unlock(); return cached }
        lock.unlock()

        var candidates = [base]
        // Group containers look like "group.com.foo.bar" or "TEAMID.com.foo.bar".
        if base.hasPrefix("group.") { candidates.append(String(base.dropFirst(6))) }
        let parts = base.split(separator: ".")
        if parts.count > 2, parts[0].count == 10, parts[0].uppercased() == parts[0] {
            candidates.append(parts.dropFirst().joined(separator: "."))
        }
        var resolved = base
        for id in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                resolved = FileManager.default.displayName(atPath: url.path)
                if resolved.hasSuffix(".app") { resolved = String(resolved.dropLast(4)) }
                break
            }
        }
        lock.lock()
        nameCache[base] = resolved
        lock.unlock()
        return resolved
    }
}
