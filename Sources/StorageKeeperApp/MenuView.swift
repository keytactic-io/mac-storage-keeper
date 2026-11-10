import AppKit
import Charts
import StorageKeeperCore
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case overview = "Now", growth = "Growth", cleanup = "Clean Up"
    var id: String { rawValue }
}

/// Type scale for the menu. Kept in one place so sizes stay consistent and readable:
/// nothing below 12 pt, and secondary text only for supporting details.
extension StorageKeeperCore.Category {
    /// Tile color, in the style of System Settings icons. White glyphs on these read well on both
    /// the translucent menu material and the solid background, in light and dark mode.
    var color: Color {
        switch self {
        case .developer: return .indigo
        case .packages: return .brown
        case .aiModels: return .purple
        case .browser: return .blue
        case .communication: return .green
        case .downloads: return .teal
        case .trash: return .gray
        case .cloud: return .cyan
        case .media: return .pink
        case .apps: return .orange
        case .system: return .gray
        case .other: return Color(nsColor: .systemGray)
        }
    }

    var filledSymbol: String {
        switch self {
        case .developer: return "hammer.fill"
        case .packages: return "shippingbox.fill"
        case .aiModels: return "cpu.fill"
        case .browser: return "globe"
        case .communication: return "bubble.left.and.bubble.right.fill"
        case .downloads: return "arrow.down"
        case .trash: return "trash.fill"
        case .cloud: return "icloud.fill"
        case .media: return "photo.fill"
        case .apps: return "square.grid.2x2.fill"
        case .system: return "gearshape.fill"
        case .other: return "folder.fill"
        }
    }
}

/// A small rounded colored square with a white SF Symbol, like System Settings.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// Card fill that suits the current background mode.
struct CardBackground: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(model.solidBackground ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.quaternary.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(model.solidBackground ? 0.12 : 0.08)))
    }
}

enum Typo {
    static let title = Font.system(size: 13, weight: .medium)
    static let detail = Font.system(size: 12)
    static let value = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let section = Font.system(size: 13, weight: .bold)
    static let note = Font.system(size: 12)
}

struct MenuView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab

    init(tab: Tab = .overview) { _tab = State(initialValue: tab) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DiskHeader()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let e = model.errorText {
                Banner(text: e, symbol: "exclamationmark.triangle.fill", tint: .red) { model.errorText = nil }
            } else if let m = model.message {
                Banner(text: m, symbol: "checkmark.circle.fill", tint: .green) { model.message = nil }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .overview: OverviewView()
                    case .growth: GrowthView()
                    case .cleanup: CleanupView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            .frame(height: 470)

            Divider()
            Footer()
        }
        .padding(14)
        .frame(width: 460)
        // Translucent menu material by default; opaque when "Solid background" is on in Settings.
        .background(model.solidBackground ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .onAppear { model.refreshDisk() }
    }
}

// MARK: - Header and footer

struct DiskHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: DriveIcon.image(badge: model.iconBadge))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 29, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Macintosh HD").font(.system(size: 15, weight: .semibold))
                    // Standard secondary text for legibility on the translucent menu; the badge carries the color.
                    Text(statusLine).font(Typo.detail).foregroundStyle(.secondary)
                }
                Spacer()
                if let d = model.disk {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Fmt.bytes(d.available)) free").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        Text("of \(Fmt.bytes(d.total))").font(Typo.detail).foregroundStyle(.secondary)
                    }
                }
            }
            if let d = model.disk {
                let used = d.total > 0 ? Double(d.used) / Double(d.total) : 0
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(model.status.isLowSpace ? Color.red : Color.primary.opacity(0.85))
                            .frame(width: max(6, geo.size.width * used))
                    }
                }
                .frame(height: 6)
                .help("\(Fmt.bytes(d.used)) used of \(Fmt.bytes(d.total))")
            }
        }
    }

    private var statusLine: String {
        switch model.status {
        case .lowSpace: return "Low on space"
        case .growth(let g):
            return g.level == .active
                ? "\(g.owner) is growing: \(Fmt.delta(g.bytes)) in 10 min"
                : "\(g.owner) grew \(Fmt.bytes(g.bytes)) · \(Fmt.relative(g.time))"
        case .scanning: return "Scanning…"
        case .normal:
            if let s = model.lastSnapshot { return "Last scan \(Fmt.relative(s.finishedAt))" }
            return "No scan yet"
        }
    }
}

struct Footer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            if model.scanning {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    if let p = model.scanProgress {
                        Text("\(Fmt.bytes(p.bytes)) · \(p.files.formatted()) files").font(Typo.detail).monospacedDigit()
                        Text(Fmt.path(p.currentPath)).font(Typo.detail).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("Starting scan…").font(Typo.detail)
                    }
                }
                Spacer()
                Button("Stop") { model.cancelScan() }
            } else {
                Button { model.scan() } label: { Label("Scan Now", systemImage: "arrow.triangle.2.circlepath") }
                Spacer()
                Button { Finder.openStorageSettings() } label: { Image(systemName: "internaldrive").font(.system(size: 14)) }
                    .buttonStyle(.borderless).help("Open System Settings → Storage")
                Button {
                    openWindow(id: "settings")
                    WindowFront.raise(titled: WindowFront.settingsTitle)
                } label: { Image(systemName: "gearshape").font(.system(size: 14)) }
                    .buttonStyle(.borderless).help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").font(.system(size: 14)) }
                    .buttonStyle(.borderless).help("Quit Storage Keeper")
            }
        }
    }
}

// MARK: - Now tab

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.hasFullDiskAccess {
            Banner(text: "Full Disk Access is off for this app, so Mail, Safari, Trash and app containers are skipped. If you just turned it on, relaunch to apply it.",
                   symbol: "lock.fill", tint: .orange,
                   actionTitle: "Open Settings", action: { Finder.openFullDiskAccessSettings() },
                   secondaryTitle: "Relaunch", secondary: { Finder.relaunch() })
        }

        SectionTitle("Growing right now", subtitle: "last hour")
        if model.live.isEmpty {
            EmptyNote("No folder has grown by more than 1 MB in the last hour.")
        } else {
            ForEach(model.live.prefix(8)) { b in
                ActivityRow(activity: b)
            }
        }

        if !model.alerts.isEmpty {
            SectionTitle("Alerts", subtitle: "over \(Fmt.bytes(Int64(model.alertMB) * 1_000_000)) in 10 min")
            ForEach(model.alerts.prefix(5)) { a in
                ItemRow(symbol: "bell.badge.fill", tint: .red, title: a.title, subtitle: a.body,
                        trailing: Fmt.relative(a.time), path: a.topFile ?? a.attribution.root)
            }
        }

        SectionTitle("Largest", subtitle: model.lastSnapshot.map { "scan \(Fmt.relative($0.finishedAt))" } ?? nil)
        if model.usage.isEmpty {
            EmptyNote(model.scanning ? "Building the baseline. The first full scan takes about a minute." : "No scan yet. Click Scan Now.")
        } else {
            let maxBytes = model.usage.first?.bytes ?? 1
            ForEach(model.usage.prefix(12)) { o in
                OwnerRow(owner: o, value: Fmt.bytes(o.bytes), fraction: Double(o.bytes) / Double(max(maxBytes, 1)))
            }
        }
    }
}

struct ActivityRow: View {
    let activity: BucketActivity
    var body: some View {
        let a = activity.attribution
        let recent = Date().timeIntervalSince(activity.lastSeen) < 60
        ItemRow(symbol: a.category.filledSymbol, tint: a.category.color,
                title: a.owner,
                subtitle: activity.topFile.map { "\(Paths.name($0)) in \(Fmt.path(Paths.parent($0)))" } ?? Fmt.path(a.root),
                trailing: Fmt.delta(activity.hourBytes),
                path: activity.topFile ?? a.root,
                badge: recent ? "bolt.fill" : nil,
                safety: a.safety)
    }
}

// MARK: - Growth tab

struct GrowthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Since", selection: $model.growthRange) {
            ForEach(GrowthRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        if model.snapshots.count >= 2 {
            Chart(model.snapshots) { s in
                LineMark(x: .value("Date", s.startedAt), y: .value("Used", Double(s.totalBytes) / 1e9))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Date", s.startedAt), y: .value("Used", Double(s.totalBytes) / 1e9))
                    .symbolSize(16)
            }
            .chartYAxisLabel("GB used")
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 100)
            .padding(.vertical, 4)
        }

        if let g = model.growth {
            GrowthReportView(report: g)
        } else {
            EmptyNote(model.snapshots.count < 2
                ? "Growth needs two scans. Storage Keeper scans every \(model.scanIntervalHours) hours; you can also click Scan Now later."
                : "Loading…")
        }
    }
}

struct GrowthReportView: View {
    let report: GrowthReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Fmt.delta(report.totalDelta)) since \(Fmt.dateTime(report.from.startedAt))")
                .font(Typo.title)

            SectionTitle("Who grew", subtitle: nil)
            let grew = report.owners.filter { $0.delta >= 10_000_000 }
            if grew.isEmpty { EmptyNote("No app or tool grew by more than 10 MB.") }
            let maxDelta = grew.first?.delta ?? 1
            ForEach(grew.prefix(10)) { o in
                OwnerRow(owner: o, value: Fmt.delta(o.delta), fraction: Double(o.delta) / Double(max(maxDelta, 1)))
            }

            SectionTitle("Where", subtitle: "folders that grew 50 MB or more")
            if report.hotspots.isEmpty { EmptyNote("No single folder grew by 50 MB or more.") }
            ForEach(report.hotspots.prefix(15)) { h in
                ItemRow(symbol: h.attribution.category.filledSymbol, tint: h.attribution.category.color,
                        title: Fmt.path(h.path) + (h.isResidual ? " (other items)" : ""),
                        subtitle: "\(h.attribution.owner) · now \(Fmt.bytes(h.after))",
                        trailing: Fmt.delta(h.delta), path: h.path, safety: h.attribution.safety)
            }

            let shrank = report.owners.filter { $0.delta <= -50_000_000 }.sorted { $0.delta < $1.delta }
            if !shrank.isEmpty {
                SectionTitle("Freed", subtitle: nil)
                ForEach(shrank.prefix(5)) { o in
                    OwnerRow(owner: o, value: Fmt.delta(o.delta), fraction: 0)
                }
            }
        }
    }
}

// MARK: - Clean Up tab

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            let total = model.recommendations.filter { $0.effectiveAction != .reveal }.reduce(0) { $0 + $1.bytes }
            Text(model.recommendations.isEmpty ? "Recommendations" : "Up to \(Fmt.bytes(total)) can be freed")
                .font(Typo.section)
            Spacer()
            if model.loadingRecommendations { ProgressView().controlSize(.small) }
            Button { model.refreshRecommendations() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(model.loadingRecommendations).help("Check again")
        }
        if model.recommendations.isEmpty && !model.loadingRecommendations {
            EmptyNote("Nothing to suggest right now.")
        }
        ForEach(model.recommendations) { rec in
            RecommendationCard(rec: rec) {
                if case .review = rec.effectiveAction {
                    openWindow(id: "review", value: rec.id)
                    WindowFront.raise(titled: WindowFront.reviewTitle)
                } else {
                    model.perform(rec)
                }
            }
        }
        Button { Finder.openStorageSettings() } label: {
            Label("More in System Settings → Storage (Photos, Mail, Messages…)", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.link).font(Typo.note)
        .padding(.top, 4)
    }
}

struct RecommendationCard: View {
    let rec: Recommendation
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: rec.category.filledSymbol, color: rec.category.color, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rec.title).font(Typo.title)
                    Spacer()
                    Text(rec.bytes > 0 ? Fmt.bytes(rec.bytes) : "Size unknown").font(Typo.value)
                }
                Text(rec.summary).font(Typo.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if case .command(_, let cmd, _) = rec.effectiveAction {
                    Text(cmd).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Button(rec.actionLabel, action: action)
                    if rec.effectiveAction != .reveal, rec.effectiveAction != .emptyTrash, let first = rec.items.first {
                        Button("Show in Finder") { Finder.reveal(first.path) }.buttonStyle(.link).font(Typo.detail)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(CardBackground())
    }
}

// MARK: - Shared components

struct SectionTitle: View {
    let title: String
    let subtitle: String?
    init(_ title: String, subtitle: String?) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Typo.section)
            if let subtitle { Text(subtitle).font(Typo.detail).foregroundStyle(.secondary) }
        }
        .padding(.top, 8)
    }
}

struct EmptyNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Typo.note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color
    var actionTitle: String? = nil
    let action: () -> Void
    var secondaryTitle: String? = nil
    var secondary: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).font(Typo.detail).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 0)
                if actionTitle == nil {
                    Button(action: action) { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            }
            if let actionTitle {
                HStack {
                    Spacer()
                    if let secondaryTitle, let secondary { Button(secondaryTitle, action: secondary) }
                    Button(actionTitle, action: action)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15)))
    }
}

/// A row with an icon, two lines of text and a value. Click (or the folder button) shows it in Finder.
struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let trailing: String
    let path: String
    var badge: String? = nil
    /// Shows a small dot for sensitive folders (app data, managed by macOS).
    var safety: Safety? = nil
    @State private var hovering = false

    private var tooltip: String {
        var t = Fmt.path(path)
        if let s = safety, s.isFlagged { t += "\n\n" + s.explanation(owner: title) }
        return t
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                IconTile(symbol: symbol, color: tint)
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(.orange))
                        .offset(x: 5, y: 5)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(Typo.title).lineLimit(1).truncationMode(.middle)
                    if let s = safety, s.isFlagged { SafetyDot(safety: s) }
                }
                Text(subtitle).font(Typo.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button { Finder.reveal(path) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Show in Finder")
                .opacity(hovering ? 1 : 0)
            Text(trailing).font(Typo.value)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { Finder.reveal(path) }
        .contextMenu {
            Button("Show in Finder") { Finder.reveal(path) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            Divider()
            if (safety ?? Attributor.shared.safety(of: path)) == .system {
                Button("Managed by macOS — can't move to Trash") {}.disabled(true)
            } else {
                Button("Move to Trash…") { model.trash(path: path) }
            }
        }
        .help(tooltip)
    }
}

/// 6 pt dot next to a row title: orange = app data, red = managed by macOS.
struct SafetyDot: View {
    let safety: Safety
    var body: some View {
        Circle()
            .fill(safety == .system ? Color.red : Color.orange)
            .frame(width: 6, height: 6)
            .accessibilityLabel(safety.label)
    }
}

struct OwnerRow: View {
    let owner: OwnerTotal
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ItemRow(symbol: owner.category.filledSymbol, tint: owner.category.color, title: owner.owner,
                    subtitle: owner.roots.count != 1 ? "\(owner.roots.count) folders"
                        : Fmt.path(owner.roots[0]) == owner.owner ? "Files not in a known app or tool folder"
                        : Fmt.path(owner.roots[0]),
                    trailing: value, path: owner.roots.first ?? "/", safety: owner.safety)
            if fraction > 0 {
                GeometryReader { geo in
                    Capsule().fill(owner.category.color.opacity(0.75))
                        .frame(width: max(3, geo.size.width * fraction), height: 4)
                }
                .frame(height: 4)
                .padding(.leading, 40)
                .padding(.trailing, 6)
            }
        }
    }
}
