import AppKit
import StorageKeeperCore
import SwiftUI

@main
struct StorageKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(model)
        } label: {
            StatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        WindowGroup(WindowFront.reviewTitle, id: "review", for: String.self) { $recID in
            ReviewView(recID: recID ?? "")
                .environment(model)
        }
        .windowResizability(.contentSize)

        // A regular window (not the `Settings` scene) so the app can open it and raise it to the front.
        Window(WindowFront.settingsTitle, id: "settings") {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon; lives in the menu bar (also set via LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in AppModel.shared.start() }

        // Debug aid: `StorageKeeper --render-ui DIR` writes PNGs of each tab and the icon states, then quits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-ui"), i + 1 < args.count {
            let dir = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                MainActor.assumeIsolated {
                    self.renderDebugImages(to: dir)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @MainActor
    private func renderDebugImages(to dir: String) {
        func write(_ view: some View, _ name: String) {
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
        for tab in Tab.allCases {
            // ImageRenderer can't draw ScrollView contents or AppKit controls, so render the tab body directly.
            let view = VStack(alignment: .leading, spacing: 8) {
                switch tab {
                case .overview: OverviewView()
                case .growth:
                    if let g = AppModel.shared.growth { GrowthReportView(report: g) } else { EmptyNote("No growth report yet.") }
                case .cleanup: ForEach(AppModel.shared.recommendations) { RecommendationCard(rec: $0) {} }
                }
            }
            .padding(14).frame(width: 460)
            .environment(AppModel.shared)
            .background(Color(nsColor: .windowBackgroundColor))
            write(view, tab.rawValue)
        }
        // Every menu bar icon state, on a light and a dark bar.
        let states: [(String, IconBadge?)] = [
            ("quiet", nil),
            ("growing", IconBadge(glyph: .plus, color: nil)),
            ("alert", IconBadge(glyph: .plus, color: .systemOrange)),
            ("big", IconBadge(glyph: .plus, color: .systemRed)),
            ("low", IconBadge(glyph: .exclamation, color: .systemRed)),
        ]
        for dark in [false, true] {
            let row = HStack(spacing: 24) {
                ForEach(states, id: \.0) { s in
                    VStack(spacing: 4) {
                        Image(nsImage: DriveIcon.image(badge: s.1, appearance: NSAppearance(named: dark ? .darkAqua : .aqua)))
                            .scaleEffect(3)
                            .frame(width: 66, height: 54)
                        Text(s.0).font(.caption).foregroundStyle(dark ? .white : .black)
                    }
                }
            }
            .padding(16)
            .background(dark ? Color(white: 0.15) : Color(white: 0.93))
            write(row, dark ? "icons-dark" : "icons-light")
        }
    }
}

/// A small badge in the drive icon's top-right corner.
struct IconBadge: Equatable {
    enum Glyph { case plus, exclamation }
    var glyph: Glyph
    /// nil = the menu bar's own text color (monochrome).
    var color: NSColor?
}

/// Draws the drive symbol with an optional corner badge, like other menu bar apps that
/// mark a state on their icon. Drawn lazily so the drive takes the menu bar's text color
/// (white on a dark bar, black on a light one).
enum DriveIcon {
    static func image(badge: IconBadge?, appearance: NSAppearance? = nil) -> NSImage {
        // Without a badge the image is just the drive, so it centers like other menu bar icons.
        // With a badge it widens to make room for the badge in the top-right corner.
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let drive = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()
        let ds = drive.size
        let driveWidth = ceil(ds.width)
        let size = NSSize(width: badge == nil ? driveWidth : driveWidth + 4, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let draw = {
                let label = NSColor.labelColor
                let x = (driveWidth - ds.width) / 2
                let y = badge == nil ? (rect.height - ds.height) / 2 : (rect.height - ds.height) / 2 - 1.5
                let driveRect = NSRect(x: x, y: y, width: ds.width, height: ds.height)
                tinted(drive, label).draw(in: driveRect)

                guard let badge, let ctx = NSGraphicsContext.current?.cgContext else { return }
                // Small badge in the top-right corner, mostly outside the drive's outline.
                let d: CGFloat = 8
                let circle = CGRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)

                // Clear a thin ring around the badge so it reads as separate from the drive.
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: circle.insetBy(dx: -1.2, dy: -1.2))
                ctx.restoreGState()

                (badge.color ?? label).setFill()
                ctx.fillEllipse(in: circle)

                // Glyph: white on a colored badge; cut out of a monochrome one.
                ctx.saveGState()
                if badge.color == nil { ctx.setBlendMode(.clear) } else { NSColor.white.setFill() }
                let cx = circle.midX, cy = circle.midY, t: CGFloat = 1.4
                switch badge.glyph {
                case .plus:
                    let len: CGFloat = 4.6
                    ctx.fill(CGRect(x: cx - len / 2, y: cy - t / 2, width: len, height: t))
                    ctx.fill(CGRect(x: cx - t / 2, y: cy - len / 2, width: t, height: len))
                case .exclamation:
                    ctx.fill(CGRect(x: cx - t / 2, y: cy - 0.6, width: t, height: 3.0))
                    ctx.fillEllipse(in: CGRect(x: cx - t / 2, y: cy - 2.6, width: t, height: t))
                }
                ctx.restoreGState()
            }
            if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
            return true
        }
        // Non-template so the badge keeps its color; the drive is drawn in the label color itself.
        image.isTemplate = badge == nil
        return image
    }

    private static func tinted(_ symbol: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }
}

/// The menu bar item: the drive icon with a state badge, plus optional free-space text.
struct StatusLabel: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // `scheme` is read so the icon is redrawn when the menu bar switches light/dark.
        let image = DriveIcon.image(badge: model.iconBadge, appearance: NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        if let text = model.menuBarText {
            HStack(spacing: 3) {
                Image(nsImage: image)
                Text(text).monospacedDigit()
            }
        } else {
            Image(nsImage: image)
        }
    }
}
