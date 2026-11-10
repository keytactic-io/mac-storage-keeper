import Darwin
import Foundation

public struct DirEntry: Sendable, Hashable {
    public var path: String
    public var bytes: Int64
    public var files: Int64
    public init(path: String, bytes: Int64, files: Int64) {
        self.path = path
        self.bytes = bytes
        self.files = files
    }
}

public struct FileEntry: Sendable, Hashable {
    public var path: String
    public var bytes: Int64
    public var modified: Date
    public init(path: String, bytes: Int64, modified: Date) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
    }
}

public struct ScanResult: Sendable {
    public var root: String
    public var startedAt: Date
    public var finishedAt: Date
    public var totalBytes: Int64
    public var fileCount: Int64
    public var dirCount: Int64
    /// Folders the scan could not read (usually missing Full Disk Access, or root-only system data).
    public var unreadable: Int64
    public var dirs: [DirEntry]
    public var largeFiles: [FileEntry]
    public var cancelled: Bool
}

public struct ScanProgress: Sendable {
    public var files: Int64
    public var bytes: Int64
    public var currentPath: String
    public var elapsed: TimeInterval
}

public struct ScanOptions: Sendable {
    public var root: String
    /// Only folders at least this large are stored. Keeps snapshots small.
    public var dirThreshold: Int64
    /// Individual files at least this large are recorded.
    public var largeFileThreshold: Int64
    public var excluded: Set<String>

    public init(root: String = Paths.defaultScanRoot,
                dirThreshold: Int64 = 16_000_000,
                largeFileThreshold: Int64 = 250_000_000,
                excluded: Set<String> = []) {
        self.root = root
        self.dirThreshold = dirThreshold
        self.largeFileThreshold = largeFileThreshold
        self.excluded = excluded
    }
}

/// Walks one volume with fts(3) and totals the allocated size of every folder,
/// the same way `du` does. Hard links are counted once and other volumes are skipped.
public final class DiskScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    private struct InodeKey: Hashable { let dev: Int32; let ino: UInt64 }

    public func run(_ options: ScanOptions, progress: ((ScanProgress) -> Void)? = nil) -> ScanResult {
        let started = Date()
        var dirs: [DirEntry] = []
        var large: [FileEntry] = []
        var fileCount: Int64 = 0
        var dirCount: Int64 = 0
        var unreadable: Int64 = 0
        var total: Int64 = 0
        var seenLinks = Set<InodeKey>()
        var stack: [(bytes: Int64, files: Int64)] = []
        var lastProgress = Date()
        var cancelled = false
        let excluded = Set(options.excluded.map { Paths.expand($0) })

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(options.root), nil]
        defer { argv.forEach { free($0) } }

        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return ScanResult(root: options.root, startedAt: started, finishedAt: Date(), totalBytes: 0,
                              fileCount: 0, dirCount: 0, unreadable: 1, dirs: [], largeFiles: [], cancelled: false)
        }
        defer { fts_close(fts) }

        func fold() {
            // Pops the current folder and adds its totals to its parent.
            guard let acc = stack.popLast() else { return }
            if stack.isEmpty {
                total += acc.bytes
            } else {
                stack[stack.count - 1].bytes += acc.bytes
                stack[stack.count - 1].files += acc.files
            }
        }

        var counter = 0
        while let e = fts_read(fts) {
            let ent = e.pointee
            let level = Int(ent.fts_level)
            switch Int32(ent.fts_info) {
            case FTS_D:
                if !excluded.isEmpty {
                    let p = Paths.normalize(String(cString: ent.fts_path))
                    if excluded.contains(p) {
                        fts_set(fts, e, FTS_SKIP)
                        // fts will still deliver an FTS_DP for this folder; push an empty accumulator for it.
                        stack.append((0, 0))
                        continue
                    }
                }
                dirCount += 1
                stack.append((Int64(ent.fts_statp.pointee.st_blocks) * 512, 0))

            case FTS_DP:
                guard stack.count == level + 1, let acc = stack.last else { continue }
                if acc.bytes >= options.dirThreshold {
                    dirs.append(DirEntry(path: Paths.normalize(String(cString: ent.fts_path)), bytes: acc.bytes, files: acc.files))
                }
                fold()

            case FTS_DNR:
                // Unreadable folder: fts sends FTS_D then FTS_DNR, with no FTS_DP.
                unreadable += 1
                if stack.count == level + 1 { fold() }

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                let st = ent.fts_statp.pointee
                var size = Int64(st.st_blocks) * 512
                if st.st_nlink > 1 {
                    if !seenLinks.insert(InodeKey(dev: st.st_dev, ino: st.st_ino)).inserted { size = 0 }
                }
                fileCount += 1
                if !stack.isEmpty {
                    stack[stack.count - 1].bytes += size
                    stack[stack.count - 1].files += 1
                } else {
                    total += size
                }
                if size >= options.largeFileThreshold {
                    let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                    large.append(FileEntry(path: Paths.normalize(String(cString: ent.fts_path)), bytes: size, modified: mtime))
                }

            case FTS_NS, FTS_ERR:
                unreadable += 1

            default:
                break
            }

            counter += 1
            if counter % 5000 == 0 {
                if isCancelled { cancelled = true; break }
                let now = Date()
                if let progress, now.timeIntervalSince(lastProgress) > 0.25 {
                    lastProgress = now
                    let running = total + stack.reduce(0) { $0 + $1.bytes }
                    progress(ScanProgress(files: fileCount, bytes: running,
                                          currentPath: Paths.normalize(String(cString: ent.fts_path)),
                                          elapsed: now.timeIntervalSince(started)))
                }
            }
        }
        while !stack.isEmpty { fold() }

        return ScanResult(root: Paths.normalize(options.root), startedAt: started, finishedAt: Date(),
                          totalBytes: total, fileCount: fileCount, dirCount: dirCount, unreadable: unreadable,
                          dirs: dirs, largeFiles: large, cancelled: cancelled)
    }

    /// Allocated size of a single file or folder (like `du -s`). Used to size cleanup targets.
    public static func size(of path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) != S_IFDIR { return Int64(st.st_blocks) * 512 }
        let r = DiskScanner().run(ScanOptions(root: path, dirThreshold: .max, largeFileThreshold: .max))
        return r.totalBytes
    }
}
