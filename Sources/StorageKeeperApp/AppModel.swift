import AppKit
import Foundation
import Observation
import ServiceManagement
import StorageKeeperCore
import UserNotifications

enum GrowthRange: String, CaseIterable, Identifiable {
    case day = "24 hours", week = "7 days", month = "30 days"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self { case .day: return 86400; case .week: return 7 * 86400; case .month: return 30 * 86400 }
    }
}

/// Recent growth strong enough to show in the menu bar.
struct GrowthSignal {
    enum Level: Int { case active, alert, big }
    var level: Level
    var bytes: Int64
    var owner: String
    var time: Date
}

/// Menu bar status, in priority order.
enum Status {
    case lowSpace, growth(GrowthSignal), scanning, normal

    var isLowSpace: Bool {
        if case .lowSpace = self { return true }
        return false
    }

    var symbol: String {
        switch self {
        case .lowSpace: return "externaldrive.fill.badge.exclamationmark"
        case .growth(let g): return g.level == .active ? "internaldrive.fill" : "externaldrive.fill.badge.plus"
        case .scanning: return "arrow.triangle.2.circlepath"
        case .normal: return "internaldrive"
        }
    }
}

enum GrowthIndicator: String, CaseIterable, Identifiable {
    case badge, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .badge: return "Badge on icon"
        case .off: return "Off"
        }
    }
}

/// App state. A main-actor singleton; background work runs in detached tasks and reports back here.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // Settings (persisted in UserDefaults)
    var alertMB: Int = UserDefaults.standard.object(forKey: "alertMB") as? Int ?? 500 {
        didSet { UserDefaults.standard.set(alertMB, forKey: "alertMB"); applyLiveConfig() }
    }
    var scanIntervalHours: Int = UserDefaults.standard.object(forKey: "scanIntervalHours") as? Int ?? 6 {
        didSet { UserDefaults.standard.set(scanIntervalHours, forKey: "scanIntervalHours") }
    }
    var lowSpaceGB: Int = UserDefaults.standard.object(forKey: "lowSpaceGB") as? Int ?? 20 {
        didSet { UserDefaults.standard.set(lowSpaceGB, forKey: "lowSpaceGB") }
    }
    var showFreeSpaceInMenuBar: Bool = UserDefaults.standard.object(forKey: "showFree") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showFreeSpaceInMenuBar, forKey: "showFree") }
    }
    var notificationsEnabled: Bool = UserDefaults.standard.object(forKey: "notify") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notify") }
    }
    var homeOnly: Bool = UserDefaults.standard.object(forKey: "homeOnly") as? Bool ?? false {
        didSet { UserDefaults.standard.set(homeOnly, forKey: "homeOnly") }
    }
    var growthIndicator: GrowthIndicator = GrowthIndicator(rawValue: UserDefaults.standard.string(forKey: "growthIndicator") ?? "") ?? .badge {
        didSet { UserDefaults.standard.set(growthIndicator.rawValue, forKey: "growthIndicator") }
    }
    var colorMenuBar: Bool = UserDefaults.standard.object(forKey: "colorMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(colorMenuBar, forKey: "colorMenuBar") }
    }
    /// Off by default: the menu uses the standard translucent macOS material.
    var solidBackground: Bool = UserDefaults.standard.object(forKey: "solidBackground") as? Bool ?? false {
        didSet { UserDefaults.standard.set(solidBackground, forKey: "solidBackground") }
    }

    // State
    var disk: DiskInfo?
    var hasFullDiskAccess = Paths.hasFullDiskAccess
    var scanning = false
    var scanProgress: ScanProgress?
    var lastSnapshot: Snapshot?
    var snapshots: [Snapshot] = []
    var usage: [OwnerTotal] = []
    var growthRange: GrowthRange = .week { didSet { reloadGrowth() } }
    var growth: GrowthReport?
    var live: [BucketActivity] = []
    var alerts: [LiveAlert] = []
    var recommendations: [Recommendation] = []
    var loadingRecommendations = false
    var message: String?
    var errorText: String?

    private(set) var store: Store?
    private var monitor: LiveMonitor?
    private var scanner: DiskScanner?
    private var timers: [Timer] = []
    private var started = false
    private var recGeneration = 0

    var status: Status {
        if let d = disk, d.available < Int64(lowSpaceGB) * 1_000_000_000 { return .lowSpace }
        if let g = growthSignal { return .growth(g) }
        if scanning { return .scanning }
        return .normal
    }

    /// Strongest recent growth, ignoring macOS-managed folders (temp files, swap) that churn constantly.
    /// Levels are relative to the alert threshold: active ≥ 1/5 of it (min 100 MB) within 10 min,
    /// alert ≥ threshold (shown for 15 min), big ≥ 5× threshold.
    var growthSignal: GrowthSignal? {
        let threshold = Int64(alertMB) * 1_000_000
        let now = Date()
        var best: GrowthSignal?
        if let a = alerts.first(where: { $0.attribution.category != .system && now.timeIntervalSince($0.time) < 15 * 60 }) {
            let liveNow = live.first { $0.id == a.attribution.root }?.windowBytes ?? 0
            best = GrowthSignal(level: .alert, bytes: max(a.bytes, liveNow), owner: a.attribution.owner, time: a.time)
        }
        if let top = live.filter({ $0.attribution.category != .system }).max(by: { $0.windowBytes < $1.windowBytes }),
           top.windowBytes > (best?.bytes ?? 0) {
            best = GrowthSignal(level: best == nil ? .active : .alert, bytes: top.windowBytes,
                                owner: top.attribution.owner, time: top.lastSeen)
        }
        guard var g = best, g.bytes >= max(100_000_000, threshold / 5) else { return nil }
        if g.bytes >= threshold { g.level = .alert }
        if g.bytes >= threshold * 5 { g.level = .big }
        return g
    }

    /// Preview override for testing badge looks:
    /// `defaults write local.storagekeeper.StorageKeeper debugBadge -string growing|alert|big|low`
    /// and `defaults delete local.storagekeeper.StorageKeeper debugBadge` to clear. Re-read every 2 s.
    var debugBadge: String?

    /// Corner badge on the drive icon: "+" while growing (label color → orange → red), red "!" for low space.
    var iconBadge: IconBadge? {
        if let d = debugBadge {
            let c = colorMenuBar
            switch d {
            case "growing": return IconBadge(glyph: .plus, color: nil)
            case "alert": return IconBadge(glyph: .plus, color: c ? .systemOrange : nil)
            case "big": return IconBadge(glyph: .plus, color: c ? .systemRed : nil)
            case "low": return IconBadge(glyph: .exclamation, color: c ? .systemRed : nil)
            default: break
            }
        }
        let badge: IconBadge?
        switch status {
        case .lowSpace:
            badge = IconBadge(glyph: .exclamation, color: .systemRed)
        case .growth(let g) where growthIndicator == .badge:
            switch g.level {
            case .active: badge = IconBadge(glyph: .plus, color: nil)
            case .alert: badge = IconBadge(glyph: .plus, color: .systemOrange)
            case .big: badge = IconBadge(glyph: .plus, color: .systemRed)
            }
        default:
            badge = nil
        }
        guard var b = badge else { return nil }
        if !colorMenuBar { b.color = nil }
        return b
    }

    /// Optional free-space text next to the menu bar icon.
    var menuBarText: String? {
        showFreeSpaceInMenuBar ? disk.map { Fmt.compact($0.available) } : nil
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                errorText = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        do { store = try Store() } catch { errorText = "Database error: \(error)" }
        refreshDisk()
        reloadFromStore()
        Notifier.shared.setUp()

        let m = LiveMonitor(store: store)
        m.onUpdate = { buckets in MainActor.assumeIsolated { AppModel.shared.live = buckets } }
        m.onAlert = { alert in MainActor.assumeIsolated { AppModel.shared.handle(alert) } }
        monitor = m
        applyLiveConfig()
        m.start()

        timers.append(Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.refreshDisk() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let m = AppModel.shared
                let v = UserDefaults.standard.string(forKey: "debugBadge")
                if v != m.debugBadge { m.debugBadge = v }
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.scanIfDue() }
        })
        // Baseline sweep shortly after first launch, then on the configured schedule.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated { AppModel.shared.scanIfDue() }
        }
        refreshRecommendations()
    }

    private func applyLiveConfig() {
        var c = LiveConfig()
        c.alertBytes = Int64(alertMB) * 1_000_000
        monitor?.config = c
    }

    func refreshDisk() {
        disk = DiskInfo.current()
        hasFullDiskAccess = Paths.hasFullDiskAccess
    }

    private func handle(_ alert: LiveAlert) {
        alerts.insert(alert, at: 0)
        if alerts.count > 30 { alerts.removeLast(alerts.count - 30) }
        if notificationsEnabled { Notifier.shared.post(alert) }
    }

    // MARK: - Scanning

    private var scanRoot: String { homeOnly ? Paths.home : Paths.defaultScanRoot }

    func scanIfDue() {
        guard !scanning else { return }
        let due = lastSnapshot.map { Date().timeIntervalSince($0.startedAt) > Double(scanIntervalHours) * 3600 } ?? true
        if due { scan() }
    }

    func scan() {
        guard !scanning, let store else { return }
        scanning = true
        scanProgress = nil
        let s = DiskScanner()
        scanner = s
        let root = scanRoot
        Task.detached(priority: .utility) {
            let result = s.run(ScanOptions(root: root)) { p in
                Task { @MainActor in AppModel.shared.scanProgress = p }
            }
            var err: String?
            if !result.cancelled {
                do {
                    try store.save(result, disk: DiskInfo.current())
                    try store.prune()
                } catch { err = "\(error)" }
            }
            let saveError = err
            await MainActor.run {
                let m = AppModel.shared
                m.scanning = false
                m.scanProgress = nil
                m.scanner = nil
                if let saveError {
                    m.errorText = "Saving snapshot failed: \(saveError)"
                } else if result.cancelled {
                    m.message = "Scan stopped. Nothing was saved."
                } else {
                    m.message = "Scan finished: \(Fmt.bytes(result.totalBytes)) in \(result.fileCount.formatted()) files."
                }
                m.reloadFromStore()
                m.refreshRecommendations()
            }
        }
    }

    func cancelScan() { scanner?.cancel() }

    // MARK: - Reports

    func reloadFromStore() {
        guard let store else { return }
        snapshots = (try? store.snapshots()) ?? []
        lastSnapshot = snapshots.last
        let range = growthRange
        Task.detached(priority: .userInitiated) {
            let usage = (try? Growth.usage(store: store))?.1 ?? []
            let growth = try? Growth.report(store: store, since: Date().addingTimeInterval(-range.seconds))
            await MainActor.run {
                AppModel.shared.usage = usage
                AppModel.shared.growth = growth
            }
        }
    }

    func reloadGrowth() {
        guard let store else { return }
        let range = growthRange
        Task.detached(priority: .userInitiated) {
            let growth = try? Growth.report(store: store, since: Date().addingTimeInterval(-range.seconds))
            await MainActor.run { AppModel.shared.growth = growth }
        }
    }

    func refreshRecommendations() {
        recGeneration += 1
        let generation = recGeneration
        loadingRecommendations = true
        let store = self.store
        Task.detached(priority: .utility) {
            let recs = Recommendations.build(store: store)
            await MainActor.run {
                let m = AppModel.shared
                // Ignore results from an older refresh that finished late.
                guard generation == m.recGeneration else { return }
                m.recommendations = recs
                m.loadingRecommendations = false
            }
        }
    }

    func recommendation(id: String) -> Recommendation? {
        recommendations.first { $0.id == id }
    }

    // MARK: - Actions

    /// Confirms with the user, then runs the cleanup off the main thread.
    func perform(_ rec: Recommendation, items: [RecItem]? = nil) {
        var selected = items ?? rec.items
        if case .reveal = rec.effectiveAction {
            Finder.reveal(selected.first?.path ?? "")
            return
        }
        guard !selected.isEmpty else { return }
        // macOS-managed items are never trashed; drop them up front and say so.
        if case .command = rec.effectiveAction {} else if case .emptyTrash = rec.effectiveAction {} else {
            let blocked = Cleanup.systemItems(selected)
            if !blocked.isEmpty {
                let first = blocked[0]
                Confirm.explainBlocked(path: first.path, attribution: Attributor.shared.attribution(inDirectory: first.path))
                selected.removeAll { b in blocked.contains { $0.path == b.path } }
                if selected.isEmpty { return }
            }
        }
        guard Confirm.ask(rec: rec, selected: selected) else { return }
        message = "Working on \(rec.title)…"
        errorText = nil
        Task.detached(priority: .userInitiated) {
            let result = Cleanup.perform(rec, selected: selected)
            await MainActor.run {
                let m = AppModel.shared
                if result.success { m.message = result.message; m.errorText = nil }
                else { m.errorText = result.message; m.message = nil }
                m.refreshDisk()
                m.recommendations.removeAll { $0.id == rec.id }
                m.refreshRecommendations()
            }
        }
    }

    /// Moves a single file or folder (from a list row's context menu) to the Trash after confirmation.
    func trash(path: String) {
        // Aggregate rows can point at "/" or a top-level folder; never offer those.
        let attribution = Attributor.shared.attribution(inDirectory: path)
        if attribution.safety == .system {
            Confirm.explainBlocked(path: path, attribution: attribution)
            return
        }
        guard !Cleanup.isProtected(path), FileMetadata.exists(path) else {
            errorText = "\(Fmt.path(path)) can't be moved to the Trash from here."
            return
        }
        Task.detached(priority: .userInitiated) {
            let bytes = DiskScanner.size(of: path)
            await MainActor.run {
                let rec = Recommendation(id: "single", title: Paths.name(path), summary: "", category: .other, bytes: bytes,
                                         items: [RecItem(path: path, bytes: bytes, detail: "")], action: .trashAll, caution: nil)
                AppModel.shared.perform(rec)
            }
        }
    }
}

enum Finder {
    /// Opens the containing folder in Finder with the item selected.
    static func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        var p = path
        while !FileMetadata.exists(p), p != "/" { p = Paths.parent(p) }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    static func openStorageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS applies a new Full Disk Access grant only after the app restarts.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Menu-bar-only apps don't come to the front by themselves, so newly opened windows
/// can land behind other apps. This activates the app and raises the window once SwiftUI has created it.
enum WindowFront {
    static let settingsTitle = "Storage Keeper Settings"
    static let reviewTitle = "Review"

    @MainActor
    static func raise(titled title: String) {
        NSApp.activate(ignoringOtherApps: true)
        // The window may not exist yet on the first pass; retry briefly.
        for delay in [0.05, 0.25, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    NSApp.activate(ignoringOtherApps: true)
                    for w in NSApp.windows where w.isVisible && w.title == title {
                        w.makeKeyAndOrderFront(nil)
                        w.orderFrontRegardless()
                    }
                }
            }
        }
    }
}

enum Confirm {
    /// Explains why a macOS-managed folder can't be trashed, and where to manage it instead.
    @MainActor
    static func explainBlocked(path: String, attribution a: Attribution) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(a.owner) is managed by macOS"
        var info = "\(Fmt.path(path)) can't be moved to the Trash from Storage Keeper. Deleting it by hand can break macOS features, and macOS often recreates it."
        if let note = a.note { info += "\n\n" + note }
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Storage Settings")
        if alert.runModal() == .alertSecondButtonReturn { Finder.openStorageSettings() }
    }

    /// Every destructive action goes through this modal dialog.
    @MainActor
    static func ask(rec: Recommendation, selected: [RecItem]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        let button: String
        switch rec.effectiveAction {
        case .emptyTrash:
            alert.messageText = "Empty the Trash?"
            button = "Empty Trash"
        case .command:
            alert.messageText = "Clean up \(rec.title)?"
            button = "Run Cleanup"
        default:
            alert.messageText = "Move to Trash?"
            button = "Move to Trash"
        }
        var info = Cleanup.describe(rec, selected: selected)
        if let c = rec.caution { info += "\n\n⚠️ \(c)" }
        alert.informativeText = info
        let ok = alert.addButton(withTitle: button)
        ok.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Posts macOS notifications for growth alerts. Clicking one reveals the file in Finder.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    /// Notifications need a bundled app; `swift run` has no bundle identifier.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setUp() {
        guard available else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ a: LiveAlert) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = a.title
        content.body = a.body
        content.sound = .default
        content.userInfo = ["path": a.topFile ?? a.attribution.root]
        let req = UNNotificationRequest(identifier: a.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let p = response.notification.request.content.userInfo["path"] as? String {
            DispatchQueue.main.async { Finder.reveal(p) }
        }
        completionHandler()
    }
}
