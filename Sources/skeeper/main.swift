import Foundation
import StorageKeeperCore

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
skeeper \(AppInfo.version) — track where disk space goes on your Mac
\(AppInfo.copyright)

USAGE
  skeeper scan [--root PATH]          Sweep the disk and save a snapshot (default: whole Data volume)
  skeeper top [--limit N]             Space used per app/tool in the latest snapshot
  skeeper growth [--since 7d] [--min 50MB]
                                      Where space grew since an earlier snapshot, and who's responsible
  skeeper recommend                   Cleanup suggestions (like System Settings → Storage)
  skeeper clean ID                    Run one suggestion's action, after confirmation
  skeeper watch [--alert 500MB]       Live feed of folders that are growing right now
  skeeper activity [--since 24h]      Growth recorded by the live monitor / menu bar app
  skeeper snapshots                   List saved snapshots
  skeeper safety PATH…                Who owns a path and whether it's safe to delete

Data: \(Fmt.path(Paths.databaseURL.path))
"""

// MARK: - Helpers

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

func lpad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
}

/// Marker for sensitive folders, matching the app's dots: "[app data]" or "[macOS]".
func flag(_ s: Safety) -> String {
    switch s {
    case .appData: return "  [app data]"
    case .system: return "  [macOS]"
    default: return ""
    }
}

func openStore() -> Store {
    do { return try Store() } catch { fail("Could not open database: \(error)") }
}

func ask(_ prompt: String) -> String {
    print(prompt, terminator: " ")
    return readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
}

/// Parses "1,3-5" into [0,2,3,4].
func parseSelection(_ s: String, count: Int) -> [Int] {
    var out: [Int] = []
    for part in s.split(separator: ",") {
        let r = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if r.count == 1 { out.append(r[0]) }
        else if r.count == 2, r[0] <= r[1] { out.append(contentsOf: r[0]...r[1]) }
    }
    return Array(Set(out.filter { $0 >= 1 && $0 <= count }.map { $0 - 1 })).sorted()
}

// MARK: - Commands

func runScan() {
    let store = openStore()
    let root = option("--root").map(Paths.expand) ?? Paths.defaultScanRoot
    if !Paths.hasFullDiskAccess {
        print("⚠️  This terminal doesn't have Full Disk Access, so some folders (Mail, Safari, Trash, app containers)")
        print("   will be skipped. Grant it in System Settings → Privacy & Security → Full Disk Access.\n")
    }
    print("Scanning \(Paths.normalize(root)) …")
    let scanner = DiskScanner()
    signal(SIGINT, SIG_IGN)
    let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigSrc.setEventHandler { scanner.cancel() }
    sigSrc.resume()

    let result = scanner.run(ScanOptions(root: root)) { p in
        let path = Fmt.path(p.currentPath)
        let shown = path.count > 60 ? "…" + path.suffix(59) : path
        print("\r\u{1B}[K  \(Fmt.bytes(p.bytes)) · \(p.files) files · \(Int(p.elapsed))s · \(shown)", terminator: "")
        fflush(stdout)
    }
    print("\r\u{1B}[K", terminator: "")
    if result.cancelled { fail("Scan cancelled; nothing saved.") }
    do {
        try store.save(result, disk: DiskInfo.current())
        try store.prune()
    } catch { fail("Could not save snapshot: \(error)") }
    let secs = Int(result.finishedAt.timeIntervalSince(result.startedAt))
    print("Scanned \(Fmt.bytes(result.totalBytes)) in \(result.fileCount) files (\(secs)s). \(result.unreadable) folders unreadable.\n")
    printTop(store: store, limit: 15)
    if (try? store.snapshots(root: result.root).count) ?? 0 > 1 {
        print("\nRun `skeeper growth` to see what changed since the previous snapshot.")
    }
}

func printTop(store: Store, limit: Int) {
    guard let (snap, owners) = try? Growth.usage(store: store) else { fail("No snapshots yet. Run `skeeper scan` first.") }
    print("Space by owner · snapshot \(Fmt.dateTime(snap.startedAt))")
    for o in owners.prefix(limit) {
        let where_ = o.roots.count == 1 ? Fmt.path(o.roots[0]) : "\(o.roots.count) folders"
        print("  \(lpad(Fmt.bytes(o.bytes), 10))  \(pad(o.owner, 34)) \(pad(o.category.label, 11)) \(where_)\(flag(o.safety))")
    }
}

func runGrowth() {
    let store = openStore()
    let sinceText = option("--since") ?? "7d"
    guard let since = Fmt.parseDuration(sinceText) else { fail("Bad --since value: \(sinceText)") }
    let min = option("--min").flatMap(Fmt.parseBytes) ?? 50_000_000
    guard let report = try? Growth.report(store: store, since: Date().addingTimeInterval(-since), minDelta: min) else {
        fail("Need at least two snapshots. Run `skeeper scan` again later (or use the menu bar app, which scans on a schedule).")
    }
    print("Growth from \(Fmt.dateTime(report.from.startedAt)) to \(Fmt.dateTime(report.to.startedAt)): \(Fmt.delta(report.totalDelta)) total\n")
    print("Who grew")
    let grew = report.owners.filter { abs($0.delta) >= min }
    if grew.isEmpty { print("  Nothing changed by more than \(Fmt.bytes(min)).") }
    for o in grew {
        print("  \(lpad(Fmt.delta(o.delta), 10))  \(pad(o.owner, 34)) now \(Fmt.bytes(o.bytes))\(flag(o.safety))")
    }
    print("\nWhere")
    if report.hotspots.isEmpty { print("  No folder grew by more than \(Fmt.bytes(min)).") }
    for h in report.hotspots.prefix(25) {
        let note = h.isResidual ? " (spread across small items)" : ""
        print("  \(lpad(Fmt.delta(h.delta), 10))  \(Fmt.path(h.path))\(note)  [\(h.attribution.owner)]\(flag(h.attribution.safety))")
    }
}

func runRecommend() -> [Recommendation] {
    let store = try? Store()
    print("Checking caches, downloads and large files …\n")
    let recs = Recommendations.build(store: store)
    if recs.isEmpty { print("Nothing to suggest. 🎉") }
    for r in recs {
        print("\(lpad(r.bytes > 0 ? Fmt.bytes(r.bytes) : "?", 10))  \(r.title)   [id: \(r.id)]")
        print("            \(r.summary)")
        switch r.effectiveAction {
        case .command(_, let cmd, _): print("            Action: run `\(cmd)`")
        case .emptyTrash: print("            Action: empty the Trash via Finder")
        case .trashAll: print("            Action: move \(r.items.count) item(s) to the Trash")
        case .review: print("            Action: choose items to move to the Trash (\(r.items.count) listed)")
        case .reveal: print("            Action: review manually · \(r.items.first.map { Fmt.path($0.path) } ?? "")")
        }
        print("")
    }
    if !recs.isEmpty { print("Run `skeeper clean ID` to act on one. You'll be asked to confirm.") }
    return recs
}

func runClean() {
    guard let id = args.first else { fail("Usage: skeeper clean ID   (see `skeeper recommend` for IDs)") }
    let store = try? Store()
    print("Checking …")
    guard let rec = Recommendations.build(store: store).first(where: { $0.id == id }) else {
        fail("No current suggestion with id '\(id)'. Run `skeeper recommend`.")
    }
    var selected = rec.items
    switch rec.effectiveAction {
    case .reveal:
        print("\(rec.title): \(rec.summary)")
        for i in rec.items { print("  \(lpad(Fmt.bytes(i.bytes), 10))  \(Fmt.path(i.path))") }
        return
    case .review:
        print("\(rec.title) — \(rec.summary)\n")
        for (n, i) in rec.items.enumerated() {
            print("  \(lpad("\(n + 1).", 4)) \(lpad(Fmt.bytes(i.bytes), 10))  \(Fmt.path(i.path))")
            if !i.detail.isEmpty { print("                    \(i.detail)") }
        }
        let pick = ask("\nItems to move to the Trash (e.g. 1,3-5, 'all', or blank to cancel):")
        if pick.isEmpty { print("Cancelled."); return }
        selected = pick.lowercased() == "all" ? rec.items : parseSelection(pick, count: rec.items.count).map { rec.items[$0] }
        if selected.isEmpty { print("Nothing selected."); return }
    default:
        break
    }
    print("\n" + Cleanup.describe(rec, selected: selected))
    if let c = rec.caution { print("\n⚠️  \(c)") }
    guard ask("\nProceed? [y/N]").lowercased() == "y" else { print("Cancelled."); return }
    let result = Cleanup.perform(rec, selected: selected)
    print(result.message)
    if !result.success { exit(1) }
}

func runWatch() {
    let store = try? Store()
    var config = LiveConfig()
    if let a = option("--alert").flatMap(Fmt.parseBytes) { config.alertBytes = a }
    let monitor = LiveMonitor(store: store, config: config)
    var lastPrinted: [String: Int64] = [:]
    monitor.onUpdate = { buckets in
        for b in buckets {
            let prev = lastPrinted[b.id] ?? 0
            guard abs(b.hourBytes - prev) >= 5_000_000 else { continue }
            lastPrinted[b.id] = b.hourBytes
            let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            print("\(t)  \(lpad(Fmt.delta(b.hourBytes), 10)) last hour  \(pad(b.attribution.owner, 30)) \(Fmt.path(b.attribution.root))")
        }
    }
    monitor.onAlert = { a in
        print("🔔 \(a.title) — \(a.body)")
        if let f = a.topFile { print("   \(Fmt.path(f))") }
    }
    monitor.start()
    print("Watching for growth (alert at \(Fmt.bytes(config.alertBytes)) in \(Int(config.window / 60)) min). Ctrl-C to stop.")
    signal(SIGINT, SIG_IGN)
    let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigSrc.setEventHandler { monitor.stop(); print("\nStopped."); exit(0) }
    sigSrc.resume()
    dispatchMain()
}

func runActivity() {
    let store = openStore()
    let sinceText = option("--since") ?? "24h"
    guard let since = Fmt.parseDuration(sinceText) else { fail("Bad --since value: \(sinceText)") }
    let rows = (try? store.activity(since: Date().addingTimeInterval(-since))) ?? []
    let shown = rows.filter { $0.bytes >= 5_000_000 }
    if shown.isEmpty { print("No growth over 5 MB recorded in the last \(sinceText). The menu bar app or `skeeper watch` records activity while running."); return }
    print("Live growth in the last \(sinceText)")
    for r in shown.prefix(30) {
        print("  \(lpad(Fmt.delta(r.bytes), 10))  \(pad(r.owner, 32)) \(Fmt.path(r.bucket))   last \(Fmt.relative(r.time))")
    }
}

/// Read-only: who owns each path and how safe it is to delete.
func runSafety() {
    guard !args.isEmpty else { fail("Usage: skeeper safety PATH [PATH…]") }
    for raw in args {
        let p = Paths.normalize((Paths.expand(raw) as NSString).standardizingPath)
        let a = Attributor.shared.attribution(inDirectory: p)
        let blocked = a.safety == .system || Cleanup.isProtected(p)
        print("\(Fmt.path(p))")
        print("  Owner:   \(a.owner)  (\(a.category.label))")
        print("  Safety:  \(a.safety.label)\(blocked ? "  — Trash blocked" : "")")
        let why = a.safety.explanation(owner: a.owner)
        if !why.isEmpty { print("  Why:     \(why)") }
        if let n = a.note { print("  Note:    \(n)") }
    }
}

func runSnapshots() {
    let store = openStore()
    let snaps = (try? store.snapshots()) ?? []
    if snaps.isEmpty { print("No snapshots yet. Run `skeeper scan`."); return }
    for s in snaps {
        let secs = Int(s.finishedAt.timeIntervalSince(s.startedAt))
        print("  #\(s.id)  \(Fmt.dateTime(s.startedAt))  \(lpad(Fmt.bytes(s.totalBytes), 10))  \(s.fileCount) files  \(secs)s  root \(s.root)")
    }
}

switch command {
case "scan": runScan()
case "top": printTop(store: openStore(), limit: option("--limit").flatMap(Int.init) ?? 30)
case "growth": runGrowth()
case "recommend", "rec": _ = runRecommend()
case "clean": runClean()
case "watch": runWatch()
case "activity": runActivity()
case "snapshots": runSnapshots()
case "safety": runSafety()
case "help", "-h", "--help": print(usage)
case "version", "-v", "--version": print("skeeper \(AppInfo.version) (\(AppInfo.build)) · \(AppInfo.copyright)")
default: print(usage); exit(1)
}
