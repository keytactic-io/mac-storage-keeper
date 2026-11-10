import Foundation

/// A folder where space grew between two snapshots.
public struct Hotspot: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var attribution: Attribution
    /// Bytes gained. For a residual hotspot, this is growth not explained by any large subfolder.
    public var delta: Int64
    public var before: Int64
    public var after: Int64
    /// True when the growth is spread across many small items directly inside `path`.
    public var isResidual: Bool
}

/// Space used by one app or tool, summed across all its known folders.
public struct OwnerTotal: Identifiable, Sendable, Hashable {
    public var id: String { owner }
    public var owner: String
    public var category: Category
    public var bytes: Int64
    public var delta: Int64
    public var roots: [String]
    public var note: String?
    public var safety: Safety = .unknown
}

public struct GrowthReport: Sendable {
    public var from: Snapshot
    public var to: Snapshot
    public var hotspots: [Hotspot]
    /// Sorted by growth, largest first. Includes owners that shrank.
    public var owners: [OwnerTotal]
    public var totalDelta: Int64 { to.totalBytes - from.totalBytes }
}

public enum Growth {
    /// Builds a parent → children map over the union of two snapshots' folders.
    private static func tree(_ maps: [[String: Int64]]) -> [String: [String]] {
        var children: [String: [String]] = [:]
        var seen = Set<String>()
        for m in maps {
            for p in m.keys where seen.insert(p).inserted && p != "/" {
                children[Paths.parent(p), default: []].append(p)
            }
        }
        return children
    }

    /// Finds where growth happened. Walks down from the scan root and follows any subfolder
    /// that grew by at least `minDelta`. Stops at known app/tool folders so growth is reported
    /// as "Playwright browsers +1.2 GB" rather than as dozens of nested folders.
    public static func hotspots(before: [String: Int64], after: [String: Int64], root: String = "/",
                                minDelta: Int64 = 50_000_000,
                                attributor: Attributor = .shared) -> [Hotspot] {
        let children = tree([before, after])
        func delta(_ p: String) -> Int64 { (after[p] ?? 0) - (before[p] ?? 0) }
        var out: [Hotspot] = []

        func visit(_ p: String) {
            let d = delta(p)
            guard d >= minDelta else { return }
            if p != root, let a = attributor.attribution(forRoot: p) {
                out.append(Hotspot(path: p, attribution: a, delta: d, before: before[p] ?? 0, after: after[p] ?? 0, isResidual: false))
                return
            }
            var explained: Int64 = 0
            var hadChildren = false
            for k in children[p] ?? [] where delta(k) >= minDelta {
                hadChildren = true
                visit(k)
                explained += delta(k)
            }
            let residual = d - explained
            if residual >= minDelta {
                out.append(Hotspot(path: p, attribution: attributor.attribution(inDirectory: p), delta: residual,
                                   before: before[p] ?? 0, after: after[p] ?? 0, isResidual: hadChildren))
            }
        }
        visit(root)
        return out.sorted { $0.delta > $1.delta }
    }

    /// Totals space per owner. Each folder is counted once, under the outermost known location.
    /// Space outside any known location is reported as "Everything else".
    public static func owners(before: [String: Int64], after: [String: Int64], root: String = "/",
                              attributor: Attributor = .shared) -> [OwnerTotal] {
        let children = tree([before, after])
        var agg: [String: OwnerTotal] = [:]
        let compare = !before.isEmpty

        func add(_ a: Attribution, key: String, before b: Int64, after n: Int64, root p: String) {
            var t = agg[key] ?? OwnerTotal(owner: a.owner, category: a.category, bytes: 0, delta: 0, roots: [], note: a.note, safety: a.safety)
            // An owner spread over several folders is flagged by its most sensitive one.
            if a.safety == .system || (a.safety == .appData && t.safety != .system) { t.safety = a.safety }
            t.bytes += n
            t.delta += compare ? n - b : 0
            if !t.roots.contains(p) { t.roots.append(p) }
            agg[key] = t
        }

        func visit(_ p: String) {
            if p != root, let a = attributor.attribution(forRoot: p) {
                add(a, key: a.owner, before: before[p] ?? 0, after: after[p] ?? 0, root: p)
                return
            }
            // Unknown folder: count space not inside any recorded subfolder toward a
            // readable bucket such as "~/Desktop/dev" or "/Library/Application Support".
            let kids = children[p] ?? []
            let ownAfter = (after[p] ?? 0) - kids.reduce(0) { $0 + (after[$1] ?? 0) }
            let ownBefore = (before[p] ?? 0) - kids.reduce(0) { $0 + (before[$1] ?? 0) }
            if ownAfter != 0 || ownBefore != 0 {
                let bucket = attributor.fallbackBucket(for: p)
                add(bucket, key: "folder:" + bucket.root, before: ownBefore, after: ownAfter, root: bucket.root)
            }
            for k in kids { visit(k) }
        }
        visit(root)
        return agg.values.filter { $0.bytes > 0 || $0.delta != 0 }
    }

    public static func report(store: Store, since: Date, minDelta: Int64 = 50_000_000) throws -> GrowthReport? {
        guard let latest = try store.latestSnapshot(),
              let base = try store.snapshot(before: since, root: latest.root, excluding: latest.id) else { return nil }
        let after = try store.dirSizes(latest.id)
        let before = try store.dirSizes(base.id)
        let hs = hotspots(before: before, after: after, root: latest.root, minDelta: minDelta)
        let os = owners(before: before, after: after, root: latest.root).sorted { $0.delta > $1.delta }
        return GrowthReport(from: base, to: latest, hotspots: hs, owners: os)
    }

    /// Current space per owner from the latest snapshot, largest first.
    public static func usage(store: Store) throws -> (Snapshot, [OwnerTotal])? {
        guard let latest = try store.latestSnapshot() else { return nil }
        let sizes = try store.dirSizes(latest.id)
        let list = owners(before: [:], after: sizes, root: latest.root).sorted { $0.bytes > $1.bytes }
        return (latest, list)
    }
}
