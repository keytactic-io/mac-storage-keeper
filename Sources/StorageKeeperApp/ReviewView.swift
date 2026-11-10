import AppKit
import ServiceManagement
import StorageKeeperCore
import SwiftUI

/// Lets the user pick which items of a recommendation to move to the Trash.
struct ReviewView: View {
    let recID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()

    var body: some View {
        if let rec = model.recommendation(id: recID) {
            content(rec)
        } else {
            VStack(spacing: 8) {
                Text("This suggestion is no longer available.")
                Button("Close") { dismiss() }
            }
            .padding(40)
        }
    }

    private func content(_ rec: Recommendation) -> some View {
        let chosen = rec.items.filter { selection.contains($0.path) }
        let total = chosen.reduce(0) { $0 + $1.bytes }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconTile(symbol: rec.category.filledSymbol, color: rec.category.color, size: 36)
                VStack(alignment: .leading) {
                    Text(rec.title).font(.title3.weight(.semibold))
                    Text(rec.summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let c = rec.caution {
                Label(c, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }

            Table(rec.items, selection: $selection) {
                TableColumn("") { item in
                    Toggle("", isOn: Binding(
                        get: { selection.contains(item.path) },
                        set: { on in if on { selection.insert(item.path) } else { selection.remove(item.path) } }
                    ))
                    .labelsHidden()
                }
                .width(24)
                TableColumn("Name") { item in
                    VStack(alignment: .leading, spacing: 1) {
                        let safety = Attributor.shared.safety(of: item.path)
                        HStack(spacing: 5) {
                            Text(Paths.name(item.path)).lineLimit(1).truncationMode(.middle)
                            if safety.isFlagged { SafetyDot(safety: safety).help(safety.label) }
                        }
                        Text(item.detail).font(Typo.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .help(Fmt.path(item.path))
                }
                TableColumn("Size") { item in
                    Text(Fmt.bytes(item.bytes)).monospacedDigit()
                }
                .width(80)
                TableColumn("") { item in
                    Button { Finder.reveal(item.path) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
                .width(28)
            }
            .frame(minHeight: 260)

            HStack {
                Button("Select All") { selection = Set(rec.items.map(\.path)) }
                Button("Select None") { selection.removeAll() }
                Spacer()
                Text(chosen.isEmpty ? "Nothing selected" : "\(chosen.count) selected · \(Fmt.bytes(total))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Button("Move to Trash…") {
                    model.perform(rec, items: chosen)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 640, height: 460)
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Live alerts") {
                Picker("Alert when a folder grows by", selection: $model.alertMB) {
                    Text("250 MB").tag(250)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                    Text("2 GB").tag(2000)
                    Text("5 GB").tag(5000)
                }
                Text("…within 10 minutes. Single files over 1 GB always alert.").font(Typo.detail).foregroundStyle(.secondary)
                Toggle("Show notifications", isOn: $model.notificationsEnabled)
            }
            Section("Scans") {
                Picker("Scan every", selection: $model.scanIntervalHours) {
                    Text("3 hours").tag(3)
                    Text("6 hours").tag(6)
                    Text("12 hours").tag(12)
                    Text("24 hours").tag(24)
                }
                Toggle("Scan only my home folder (faster)", isOn: $model.homeOnly)
                if !model.hasFullDiskAccess {
                    HStack {
                        Text("Full Disk Access is off, so protected folders are skipped.").font(Typo.detail)
                        Spacer()
                        Button("Relaunch") { Finder.relaunch() }
                        Button("Open Settings") { Finder.openFullDiskAccessSettings() }
                    }
                }
            }
            Section("Menu bar") {
                Picker("Warn when free space is below", selection: $model.lowSpaceGB) {
                    Text("10 GB").tag(10)
                    Text("20 GB").tag(20)
                    Text("50 GB").tag(50)
                    Text("100 GB").tag(100)
                }
                Picker("Growth indicator", selection: $model.growthIndicator) {
                    ForEach(GrowthIndicator.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Use color for alerts", isOn: $model.colorMenuBar)
                Text("A + appears on the drive while a folder grows by \(Fmt.bytes(max(100_000_000, Int64(model.alertMB) * 200_000))) or more in 10 minutes. It turns orange over your alert size and red at 5× that. A red ! means low disk space. Temp files and swap are ignored.")
                    .font(Typo.detail).foregroundStyle(.secondary)
                Toggle("Always show free space", isOn: $model.showFreeSpaceInMenuBar)
                Toggle("Solid menu background", isOn: $model.solidBackground)
                Text("Off uses the standard translucent macOS menu. On adds an opaque background for more contrast.")
                    .font(Typo.detail).foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        model.launchAtLogin = on
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
            Section("About") {
                LabeledContent("Version", value: "\(AppInfo.version) (\(AppInfo.build))")
                HStack {
                    Text(AppInfo.copyright).font(Typo.detail)
                    Spacer()
                    Link("mohassan.net", destination: URL(string: AppInfo.website)!)
                }
            }
            Section("Data") {
                LabeledContent("Snapshots", value: "\(model.snapshots.count)")
                HStack {
                    Text(Fmt.path(Paths.databaseURL.path)).font(Typo.detail).textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") { Finder.reveal(Paths.databaseURL.path) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
