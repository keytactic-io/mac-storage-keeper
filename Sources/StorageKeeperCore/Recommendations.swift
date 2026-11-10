import Foundation

public struct RecItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var bytes: Int64
    public var detail: String
    public init(path: String, bytes: Int64, detail: String) {
        self.path = path
        self.bytes = bytes
        self.detail = detail
    }
}

public enum CleanupAction: Sendable, Hashable {
    /// Ask Finder to empty the Trash.
    case emptyTrash
    /// Move every listed item to the Trash.
    case trashAll
    /// Let the user pick which listed items to move to the Trash.
    case review
    /// Run the tool's own cleanup command. If the tool is missing, move `items` to the Trash instead.
    case command(tool: String, command: String, trashIfMissing: Bool)
    /// Nothing safe to automate; show the folder in Finder with a hint.
    case reveal
}

public struct Recommendation: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var summary: String
    public var category: Category
    public var bytes: Int64
    public var items: [RecItem]
    public var action: CleanupAction
    /// Shown in the confirmation dialog.
    public var caution: String?
    /// For `.command` actions: whether the tool was found on PATH when this was built.
    public var toolInstalled: Bool = false

    public init(id: String, title: String, summary: String, category: Category, bytes: Int64,
                items: [RecItem], action: CleanupAction, caution: String?, toolInstalled: Bool = false) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.bytes = bytes
        self.items = items
        self.action = action
        self.caution = caution
        self.toolInstalled = toolInstalled
    }

    /// The action that will actually run, after accounting for missing tools.
    public var effectiveAction: CleanupAction {
        if case .command(_, _, let fallback) = action, !toolInstalled {
            return fallback ? .trashAll : .reveal
        }
        return action
    }

    public var actionLabel: String {
        switch effectiveAction {
        case .emptyTrash: return "Empty Trash…"
        case .trashAll: return "Move to Trash…"
        case .review: return "Review…"
        case .command: return "Clean up…"
        case .reveal: return "Show in Finder"
        }
    }
}

public struct RecommendationOptions: Sendable {
    public var oldDownloadAge: TimeInterval = 90 * 86400
    public var oldDownloadMin: Int64 = 50_000_000
    public var installerAge: TimeInterval = 7 * 86400
    public var cacheMin: Int64 = 100_000_000
    public var staleProjectAge: TimeInterval = 30 * 86400
    public var largeFileMin: Int64 = 1_000_000_000
    public init() {}
}

/// Builds cleanup suggestions similar to System Settings → Storage, extended with
/// developer and AI-tool caches. Slow parts (folder sizing) run concurrently; call off the main thread.
public enum Recommendations {
    private struct CacheTarget {
        let id: String
        let title: String
        let paths: [String]
        let category: Category
        let summary: String
        let action: CleanupAction
        let caution: String?
        var minBytes: Int64? = nil
    }

    private static var cacheTargets: [CacheTarget] {
        let quitFirst = "Quit the app first so it can rebuild its cache cleanly."
        return [
            CacheTarget(id: "playwright", title: "Playwright browsers",
                        paths: ["~/Library/Caches/ms-playwright", "~/.cache/ms-playwright"], category: .developer,
                        summary: "Browser builds downloaded by Playwright, often by AI coding agents. Reinstalled on the next `npx playwright install`.",
                        action: .trashAll, caution: nil),
            CacheTarget(id: "puppeteer", title: "Puppeteer browsers", paths: ["~/.cache/puppeteer"], category: .developer,
                        summary: "Chrome builds downloaded by Puppeteer. Re-downloaded on next install.", action: .trashAll, caution: nil),
            CacheTarget(id: "cypress", title: "Cypress binaries", paths: ["~/Library/Caches/Cypress"], category: .developer,
                        summary: "Cached Cypress app versions.", action: .command(tool: "cypress", command: "cypress cache clear", trashIfMissing: true), caution: nil),
            CacheTarget(id: "npm", title: "npm cache", paths: ["~/.npm/_cacache"], category: .packages,
                        summary: "Downloaded package tarballs. npm re-downloads what it needs.",
                        action: .command(tool: "npm", command: "npm cache clean --force", trashIfMissing: true), caution: nil),
            CacheTarget(id: "npx", title: "npx cache", paths: ["~/.npm/_npx"], category: .packages,
                        summary: "Packages fetched by one-off `npx` runs (common with AI agents and MCP servers).", action: .trashAll, caution: nil),
            CacheTarget(id: "pnpm", title: "pnpm store", paths: ["~/Library/pnpm/store", "~/.pnpm-store", "~/.local/share/pnpm/store"], category: .packages,
                        summary: "Removes packages no project references any more.",
                        action: .command(tool: "pnpm", command: "pnpm store prune", trashIfMissing: false), caution: nil),
            CacheTarget(id: "yarn", title: "Yarn cache", paths: ["~/Library/Caches/Yarn"], category: .packages,
                        summary: "Downloaded package archives.", action: .command(tool: "yarn", command: "yarn cache clean", trashIfMissing: true), caution: nil),
            CacheTarget(id: "bun", title: "Bun cache", paths: ["~/.bun/install/cache"], category: .packages,
                        summary: "Downloaded package archives.", action: .command(tool: "bun", command: "bun pm cache rm", trashIfMissing: true), caution: nil),
            CacheTarget(id: "pip", title: "pip cache", paths: ["~/Library/Caches/pip", "~/.cache/pip"], category: .packages,
                        summary: "Downloaded Python wheels.", action: .command(tool: "pip3", command: "pip3 cache purge", trashIfMissing: true), caution: nil),
            CacheTarget(id: "uv", title: "uv cache", paths: ["~/.cache/uv"], category: .packages,
                        summary: "Downloaded Python packages.", action: .command(tool: "uv", command: "uv cache clean", trashIfMissing: true), caution: nil),
            CacheTarget(id: "homebrew", title: "Homebrew downloads", paths: ["~/Library/Caches/Homebrew"], category: .packages,
                        summary: "Old bottles and downloads. Also removes outdated package versions.",
                        action: .command(tool: "brew", command: "brew cleanup --prune=all", trashIfMissing: true), caution: nil),
            CacheTarget(id: "gobuild", title: "Go build cache", paths: ["~/Library/Caches/go-build"], category: .developer,
                        summary: "Compiled build outputs.", action: .command(tool: "go", command: "go clean -cache", trashIfMissing: true), caution: nil),
            CacheTarget(id: "gradle", title: "Gradle caches", paths: ["~/.gradle/caches"], category: .packages,
                        summary: "Downloaded dependencies and build caches.", action: .trashAll, caution: nil),
            CacheTarget(id: "deriveddata", title: "Xcode DerivedData", paths: ["~/Library/Developer/Xcode/DerivedData"], category: .developer,
                        summary: "Build products and indexes. Xcode rebuilds them.", action: .trashAll, caution: "Quit Xcode first."),
            CacheTarget(id: "simulators", title: "Unavailable simulators", paths: ["~/Library/Developer/CoreSimulator/Devices"], category: .developer,
                        summary: "Deletes simulators for runtimes that are no longer installed.",
                        action: .command(tool: "xcrun", command: "xcrun simctl delete unavailable", trashIfMissing: false), caution: nil,
                        minBytes: 1_000_000_000),
            CacheTarget(id: "devicesupport", title: "Xcode device support files", paths: ["~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport"], category: .developer,
                        summary: "Debug symbols for each iOS version you've connected. Recreated when a device connects.", action: .review, caution: nil),
            CacheTarget(id: "docker", title: "Docker data", paths: ["~/Library/Containers/com.docker.docker/Data/vms"], category: .developer,
                        summary: "Removes stopped containers, unused networks, dangling images and build cache. Docker must be running.",
                        action: .command(tool: "docker", command: "docker system prune -f", trashIfMissing: false),
                        caution: "Docker shrinks its disk image gradually after pruning.", minBytes: 2_000_000_000),
            CacheTarget(id: "chrome", title: "Google Chrome cache", paths: ["~/Library/Caches/Google/Chrome"], category: .browser,
                        summary: "Cached web content. Chrome rebuilds it as you browse.", action: .trashAll, caution: quitFirst),
            CacheTarget(id: "edge", title: "Microsoft Edge cache", paths: ["~/Library/Caches/Microsoft Edge"], category: .browser,
                        summary: "Cached web content.", action: .trashAll, caution: quitFirst),
            CacheTarget(id: "brave", title: "Brave cache", paths: ["~/Library/Caches/BraveSoftware"], category: .browser,
                        summary: "Cached web content.", action: .trashAll, caution: quitFirst),
            CacheTarget(id: "editors", title: "Editor caches", paths: [
                "~/Library/Application Support/Code/Cache", "~/Library/Application Support/Code/CachedData", "~/Library/Application Support/Code/CachedExtensionVSIXs",
                "~/Library/Application Support/Cursor/Cache", "~/Library/Application Support/Cursor/CachedData", "~/Library/Application Support/Cursor/CachedExtensionVSIXs",
                "~/Library/Application Support/Kiro/Cache", "~/Library/Application Support/Kiro/CachedData", "~/Library/Application Support/Kiro/CachedExtensionVSIXs",
            ], category: .developer, summary: "VS Code, Cursor and Kiro caches and old extension downloads.", action: .review, caution: quitFirst),
            CacheTarget(id: "huggingface", title: "Hugging Face models", paths: ["~/.cache/huggingface/hub"], category: .aiModels,
                        summary: "Downloaded model weights. Pick models you no longer use.", action: .review, caution: "Models are re-downloaded the next time code loads them."),
            CacheTarget(id: "ollama", title: "Ollama models", paths: ["~/.ollama/models"], category: .aiModels,
                        summary: "Local LLM weights. Run `ollama list`, then `ollama rm <name>` for models you don't use.", action: .reveal, caution: nil),
            CacheTarget(id: "lmstudio", title: "LM Studio models", paths: ["~/.lmstudio/models", "~/.cache/lm-studio/models"], category: .aiModels,
                        summary: "Local LLM weights. Delete unused models in LM Studio → My Models.", action: .reveal, caution: nil),
            CacheTarget(id: "iosbackups", title: "iPhone and iPad backups", paths: ["~/Library/Application Support/MobileSync/Backup"], category: .system,
                        summary: "Manage in Finder: select your device → Manage Backups.", action: .reveal, caution: nil),
        ]
    }

    public static func build(store: Store?, options: RecommendationOptions = RecommendationOptions()) -> [Recommendation] {
        var recs: [Recommendation] = []
        let lock = NSLock()
        func add(_ r: Recommendation?) {
            guard let r else { return }
            lock.lock(); recs.append(r); lock.unlock()
        }

        let targets = cacheTargets
        let jobs: [() -> Void] = [
            { add(trash()) },
            { add(downloads(options)) },
            { add(staleNodeModules(store: store, options: options)) },
            { add(largeFiles(store: store, options: options)) },
            { add(Leftovers.recommendation()) },
        ] + targets.map { t in { add(cache(t, options: options)) } }

        DispatchQueue.concurrentPerform(iterations: jobs.count) { jobs[$0]() }
        return recs.sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Individual recommendations

    static func trash() -> Recommendation? {
        let path = Paths.expand("~/.Trash")
        let readable = (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        let size = readable ? DiskScanner.size(of: path) : 0
        guard !readable || size > 0 else { return nil }
        return Recommendation(
            id: "trash", title: "Empty Trash",
            summary: readable ? "Files in the Trash still use disk space." : "Size unknown. Grant Full Disk Access to measure the Trash.",
            category: .trash, bytes: size, items: [RecItem(path: path, bytes: size, detail: "")],
            action: .emptyTrash, caution: "Items in the Trash will be permanently erased.")
    }

    static func downloads(_ o: RecommendationOptions) -> Recommendation? {
        let dir = Paths.expand("~/Downloads")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let installerExts: Set<String> = ["dmg", "pkg", "iso", "xip", "mpkg"]
        let now = Date()
        var items: [RecItem] = []
        for name in names where !name.hasPrefix(".") {
            let p = dir + "/" + name
            let size = DiskScanner.size(of: p)
            guard size >= 20_000_000 else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let added = FileMetadata.dateAdded(p) ?? FileMetadata.modified(p) ?? now
            let used = FileMetadata.lastUsed(p)
            let lastTouch = max(used ?? added, added)
            let age = now.timeIntervalSince(lastTouch)
            let isInstaller = installerExts.contains(ext)
            let isOld = size >= o.oldDownloadMin && age >= o.oldDownloadAge
            let isOldInstaller = isInstaller && age >= o.installerAge
            guard isOld || isOldInstaller else { continue }
            var detail = used != nil ? "Last opened \(Fmt.relative(used!))" : "Added \(Fmt.relative(added)), never opened"
            if isInstaller { detail = "Installer · " + detail }
            if let prov = FileMetadata.provenance(p) { detail += " · " + prov }
            items.append(RecItem(path: p, bytes: size, detail: detail))
        }
        guard !items.isEmpty else { return nil }
        items.sort { $0.bytes > $1.bytes }
        let days = Int(o.oldDownloadAge / 86400)
        return Recommendation(
            id: "downloads", title: "Old downloads",
            summary: "\(items.count) large item\(items.count == 1 ? "" : "s") not opened in \(days) days, plus installers you've likely already used.",
            category: .downloads, bytes: items.reduce(0) { $0 + $1.bytes }, items: items, action: .review, caution: nil)
    }

    static func staleNodeModules(store: Store?, options o: RecommendationOptions) -> Recommendation? {
        guard let store, let snap = try? store.latestSnapshot(),
              let entries = try? store.dirEntries(snap.id, nameSuffix: "/node_modules") else { return nil }
        let home = Paths.home
        let now = Date()
        var items: [RecItem] = []
        for e in entries {
            let p = e.path
            guard p.hasPrefix(home + "/"), e.bytes >= 50_000_000 else { continue }
            let rel = p.dropFirst(home.count + 1)
            // Skip app data, hidden tool folders (global installs) and nested node_modules.
            guard !rel.hasPrefix("Library/"), !rel.hasPrefix("."),
                  !rel.dropLast("node_modules".count).contains("node_modules"),
                  !rel.contains(".app/"), FileMetadata.exists(p) else { continue }
            let project = Paths.parent(p)
            let touched = [project, project + "/package.json", project + "/package-lock.json",
                           project + "/.git/index", project + "/.git/HEAD"].compactMap(FileMetadata.modified).max() ?? now
            guard now.timeIntervalSince(touched) >= o.staleProjectAge else { continue }
            items.append(RecItem(path: p, bytes: e.bytes,
                                 detail: "\(Fmt.path(project)) · last changed \(Fmt.relative(touched))"))
        }
        guard !items.isEmpty else { return nil }
        return Recommendation(
            id: "node_modules", title: "Unused node_modules",
            summary: "Dependencies in projects you haven't touched in \(Int(o.staleProjectAge / 86400)) days. Restore any time with `npm install`.",
            category: .packages, bytes: items.reduce(0) { $0 + $1.bytes }, items: items, action: .review, caution: nil)
    }

    static func largeFiles(store: Store?, options o: RecommendationOptions) -> Recommendation? {
        guard let store, let snap = try? store.latestSnapshot(),
              let files = try? store.largeFiles(snap.id) else { return nil }
        let home = Paths.home
        var items: [RecItem] = []
        for f in files where f.bytes >= o.largeFileMin {
            let p = f.path
            guard p.hasPrefix(home + "/") else { continue }
            let rel = p.dropFirst(home.count + 1)
            guard !rel.hasPrefix("Library/"), !rel.hasPrefix(".Trash/"),
                  !p.contains(".photoslibrary/"), !p.contains(".app/"), !p.contains(".musiclibrary/"),
                  FileMetadata.exists(p) else { continue }
            var detail = "Modified \(Fmt.relative(f.modified))"
            if let used = FileMetadata.lastUsed(p) { detail = "Last opened \(Fmt.relative(used))" }
            items.append(RecItem(path: p, bytes: f.bytes, detail: detail))
        }
        guard !items.isEmpty else { return nil }
        return Recommendation(
            id: "largefiles", title: "Large files",
            summary: "Files over \(Fmt.bytes(o.largeFileMin)) in your home folder.",
            category: .other, bytes: items.reduce(0) { $0 + $1.bytes }, items: items, action: .review, caution: nil)
    }

    private static func cache(_ t: CacheTarget, options o: RecommendationOptions) -> Recommendation? {
        var items: [RecItem] = []
        for raw in t.paths {
            let p = Paths.expand(raw)
            guard FileMetadata.exists(p) else { continue }
            if case .review = t.action, t.id == "huggingface" || t.id == "devicesupport" {
                // List the individual models / OS versions so the user can pick.
                for name in (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? [] where !name.hasPrefix(".") {
                    let child = p + "/" + name
                    let s = DiskScanner.size(of: child)
                    if s >= 10_000_000 { items.append(RecItem(path: child, bytes: s, detail: Fmt.path(p))) }
                }
            } else {
                let s = DiskScanner.size(of: p)
                if s > 0 { items.append(RecItem(path: p, bytes: s, detail: Fmt.path(p))) }
            }
        }
        let total = items.reduce(0) { $0 + $1.bytes }
        guard total >= (t.minBytes ?? o.cacheMin) else { return nil }
        var rec = Recommendation(id: t.id, title: t.title, summary: t.summary, category: t.category, bytes: total,
                                 items: items.sorted { $0.bytes > $1.bytes }, action: t.action, caution: t.caution)
        if case .command(let tool, _, _) = t.action { rec.toolInstalled = Cleanup.toolAvailable(tool) }
        return rec
    }
}
