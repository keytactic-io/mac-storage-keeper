import CoreServices
import Darwin
import Foundation

/// Recent growth in one folder, as seen by the live monitor.
public struct BucketActivity: Identifiable, Sendable, Hashable {
    public var id: String { attribution.root }
    public var attribution: Attribution
    /// Net bytes added in the last hour.
    public var hourBytes: Int64
    /// Net bytes added in the alert window (default 10 minutes).
    public var windowBytes: Int64
    public var firstSeen: Date
    public var lastSeen: Date
    /// The file that grew the most, used for "Show in Finder".
    public var topFile: String?
    public var topFileBytes: Int64
}

public struct LiveAlert: Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var time: Date
    public var attribution: Attribution
    public var bytes: Int64
    public var duration: TimeInterval
    public var topFile: String?
    /// For downloads: "via Google Chrome · github.com".
    public var provenance: String?

    public var title: String { "\(attribution.owner) \(Fmt.delta(bytes))" }
    public var body: String {
        var s = "\(Fmt.path(topFile.map(Paths.parent) ?? attribution.root))"
        if let provenance { s += " · \(provenance)" }
        let mins = max(1, Int(duration / 60))
        return s + " · in \(mins) min"
    }
}

public struct LiveConfig: Sendable {
    /// Alert when one folder grows by this much within `window`.
    public var alertBytes: Int64 = 500_000_000
    public var window: TimeInterval = 600
    /// Alert immediately when a single file reaches this size.
    public var largeFileBytes: Int64 = 1_000_000_000
    public init() {}
}

/// Watches the whole disk with FSEvents and attributes growth to folders as it happens.
/// For every created/changed file it compares the new allocated size with the last size seen.
public final class LiveMonitor: @unchecked Sendable {
    public var config: LiveConfig
    /// Called on the main queue at most once per second with folders that grew in the last hour.
    public var onUpdate: (([BucketActivity]) -> Void)?
    /// Called on the main queue when a folder or file crosses an alert threshold.
    public var onAlert: ((LiveAlert) -> Void)?

    private let store: Store?
    private let queue = DispatchQueue(label: "StorageKeeper.LiveMonitor", qos: .utility)
    private var stream: FSEventStreamRef?

    private struct Bucket {
        var attribution: Attribution
        var samples: [(time: Date, bytes: Int64)] = []
        var firstSeen: Date
        var lastSeen: Date
        var files: [String: Int64] = [:]
        var lastAlert: Date?
        var pendingFlush: Int64 = 0
    }

    private var known: [String: Int64] = [:]
    private var buckets: [String: Bucket] = [:]
    private var alertedFiles = Set<String>()
    private var lastPublish = Date.distantPast
    private var dirty = false
    private var lastFlush = Date()
    private let ignoredPrefixes: [String]

    public init(store: Store?, config: LiveConfig = LiveConfig()) {
        self.store = store
        self.config = config
        ignoredPrefixes = [Paths.supportDir.path, "/Volumes/", "/private/var/db/", "/.Spotlight-V100", "/.fseventsd",
                           "/private/var/vm/", "/System/Volumes/"]
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<LiveMonitor>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let fl = Array(UnsafeBufferPointer(start: flags, count: count))
            me.handle(paths: list, flags: fl)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes |
                           kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, ["/"] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s

        // Publish periodically so windows roll over even when the disk is quiet.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.tick() }
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        queue.sync { flush(force: true) }
    }

    private func tick() {
        guard stream != nil else { return }
        dirty = true
        publish(force: true)
        flush(force: false)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.tick() }
    }

    // MARK: - Event handling (on `queue`)

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let now = Date()
        let isFile = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        let relevant = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified |
                                               kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed |
                                               kFSEventStreamEventFlagItemInodeMetaMod)

        for (raw, f) in zip(paths, flags) {
            guard f & isFile != 0, f & relevant != 0 else { continue }
            let path = Paths.normalize(raw)
            if ignoredPrefixes.contains(where: { path.hasPrefix($0) }) { continue }

            var st = stat()
            let delta: Int64
            var size: Int64 = 0
            if lstat(path, &st) == 0 {
                size = Int64(st.st_blocks) * 512
                let prev: Int64
                if let k = known[path] {
                    prev = k
                } else {
                    // First time we see this file. Count it as new only if it was just created;
                    // otherwise assume it was already on disk (e.g. an old file being touched).
                    let born = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec))
                    prev = (f & created != 0 || now.timeIntervalSince(born) < 300) ? 0 : size
                }
                known[path] = size
                delta = size - prev
            } else {
                delta = -(known.removeValue(forKey: path) ?? 0)
            }
            if known.count > 300_000 { known.removeAll(keepingCapacity: true) }
            guard delta != 0 else { continue }

            let a = Attributor.shared.attribution(containingFile: path)
            var b = buckets[a.root] ?? Bucket(attribution: a, firstSeen: now, lastSeen: now)
            b.lastSeen = now
            if let last = b.samples.last, now.timeIntervalSince(last.time) < 10 {
                b.samples[b.samples.count - 1].bytes += delta
            } else {
                b.samples.append((now, delta))
            }
            b.pendingFlush += delta
            if delta > 0 {
                b.files[path, default: 0] += delta
                if b.files.count > 20, let smallest = b.files.min(by: { $0.value < $1.value }) {
                    b.files.removeValue(forKey: smallest.key)
                }
            }
            buckets[a.root] = b
            dirty = true

            if size >= config.largeFileBytes, delta > 0, !alertedFiles.contains(path) {
                alertedFiles.insert(path)
                emitAlert(bucket: b, bytes: size, duration: now.timeIntervalSince(b.firstSeen), topFile: path)
            }
        }
        checkWindowAlerts(now: now)
        publish(force: false)
        flush(force: false)
    }

    private func windowSum(_ b: Bucket, since: Date) -> Int64 {
        b.samples.reduce(0) { $1.time >= since ? $0 + $1.bytes : $0 }
    }

    private func checkWindowAlerts(now: Date) {
        let since = now.addingTimeInterval(-config.window)
        for (key, b) in buckets {
            let sum = windowSum(b, since: since)
            guard sum >= config.alertBytes else { continue }
            if let last = b.lastAlert, now.timeIntervalSince(last) < config.window { continue }
            buckets[key]?.lastAlert = now
            let start = b.samples.first(where: { $0.time >= since })?.time ?? now
            let top = b.files.max(by: { $0.value < $1.value })?.key
            emitAlert(bucket: b, bytes: sum, duration: now.timeIntervalSince(start), topFile: top)
        }
    }

    private func emitAlert(bucket b: Bucket, bytes: Int64, duration: TimeInterval, topFile: String?) {
        var prov: String?
        if let topFile, b.attribution.category == .downloads { prov = FileMetadata.provenance(topFile) }
        let alert = LiveAlert(time: Date(), attribution: b.attribution, bytes: bytes, duration: duration,
                              topFile: topFile, provenance: prov)
        DispatchQueue.main.async { [weak self] in self?.onAlert?(alert) }
    }

    private func publish(force: Bool) {
        let now = Date()
        guard dirty, force || now.timeIntervalSince(lastPublish) >= 1 else { return }
        lastPublish = now
        dirty = false
        let hourAgo = now.addingTimeInterval(-3600)
        let windowStart = now.addingTimeInterval(-config.window)
        var out: [BucketActivity] = []
        for (key, var b) in buckets {
            b.samples.removeAll { $0.time < hourAgo }
            if b.samples.isEmpty && b.pendingFlush == 0 { buckets.removeValue(forKey: key); continue }
            buckets[key] = b
            let hour = windowSum(b, since: hourAgo)
            guard hour >= 1_000_000 else { continue }
            let top = b.files.max(by: { $0.value < $1.value })
            out.append(BucketActivity(attribution: b.attribution, hourBytes: hour, windowBytes: windowSum(b, since: windowStart),
                                      firstSeen: b.firstSeen, lastSeen: b.lastSeen,
                                      topFile: top?.key, topFileBytes: top?.value ?? 0))
        }
        out.sort { $0.hourBytes > $1.hourBytes }
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(out) }
    }

    /// Writes per-minute totals to the database so the CLI can show past activity.
    private func flush(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastFlush) >= 60 else { return }
        lastFlush = now
        var rows: [ActivityRow] = []
        for (key, b) in buckets where abs(b.pendingFlush) >= 1_000_000 {
            let sample = b.files.max(by: { $0.value < $1.value })?.key ?? b.attribution.root
            rows.append(ActivityRow(time: now, bucket: key, owner: b.attribution.owner, category: b.attribution.category,
                                    bytes: b.pendingFlush, samplePath: sample))
            buckets[key]?.pendingFlush = 0
        }
        try? store?.recordActivity(rows)
    }
}
