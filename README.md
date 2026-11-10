# Storage Keeper

A macOS menu bar app and CLI that track where disk space goes, which app or tool is responsible, and what you can safely clean up. It includes hidden folders such as `~/.cache`, `node_modules`, and Playwright browsers.

© 2026 Mo Hassan · [mohassan.net](https://mohassan.net)

Requires macOS 14 or later. Universal: Apple Silicon and Intel.

## Install

1. Download `StorageKeeper-<version>.dmg` from the [Releases](../../releases/latest) page.
2. Open it and drag **Storage Keeper** to **Applications**.
3. **First launch:** the app isn't notarized by Apple, so macOS blocks the first open. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Storage Keeper.app"
   ```
4. **Full Disk Access** (recommended, so scans include Mail, Safari, Trash and app containers): **System Settings → Privacy & Security → Full Disk Access** → add Storage Keeper, then use **Relaunch** in the app's banner.

**CLI (optional):** download `skeeper-<version>-macos.zip`, unzip, and move `skeeper` somewhere on your `PATH`, e.g. `~/.local/bin`. Run `xattr -d com.apple.quarantine skeeper` if macOS blocks it.

Check downloads against `SHA256SUMS.txt` with `shasum -a 256 -c SHA256SUMS.txt`.

## What it does

- **Disk sweep:** totals every folder on the Data volume, the way `du` does, and keeps snapshots so you can see growth over time.
- **Who is responsible:** attributes space to apps and tools (Playwright, npm, Xcode, Docker, Hugging Face, browsers, project `node_modules`…). For downloads it names the app that downloaded the file.
- **Live monitor:** watches the disk as it changes. A badge on the menu bar icon shows a `+` while a folder grows, orange or red for large bursts, and a red `!` when space is low.
- **Clean up:** suggestions similar to System Settings → Storage, plus developer and AI-tool caches, unused `node_modules`, old downloads, large files, and leftovers from removed apps. Every action asks you to confirm first. Files go to the Trash, where Put Back works, and tool caches are cleared with the tool's own command.
- **Safety:** folders holding app data get an orange dot, and macOS-managed folders a red dot. Moving macOS-managed folders to the Trash is blocked.

Everything stays on your Mac. The app makes no network connections. Its data lives in `~/Library/Application Support/StorageKeeper/`.

## CLI

```
skeeper scan | top | growth --since 7d | recommend | clean ID | watch | activity --since 24h | snapshots | safety PATH | --version
```

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
scripts/build-app.sh --install   # → /Applications/Storage Keeper.app and ~/.local/bin/skeeper
scripts/release.sh               # → dist/: universal DMG, CLI zip, SHA256SUMS.txt
scripts/release.sh --publish     # also tags v<version> and creates the GitHub release
scripts/set-version.sh 1.1.0     # bump the version (Info.plist + Version.swift)
```

Builds are signed with a self-signed certificate, "Storage Keeper Local Signing", which the scripts create in your login keychain on the first build. Because the signature stays the same, Full Disk Access keeps working across rebuilds and updates. To remove the certificate: `security delete-identity -c "Storage Keeper Local Signing"`.

## How it works

- **Sweep** (`DiskScanner`): fts(3) walk of the APFS Data volume, allocated sizes, hard links counted once. Folders ≥ 16 MB and files ≥ 250 MB are stored per snapshot in SQLite.
- **Attribution** (`Attributor`): macOS doesn't record which process wrote a file. Ownership comes from a table of known locations, bundle-ID folders, project folders, and the quarantine attribute on downloads.
- **Live monitor** (`LiveMonitor`): FSEvents on `/`, per-file size tracking, alerts at 500 MB in 10 minutes or a single 1 GB file.
- **Leftovers** (`Leftovers`): `~/Library` data folders whose app isn't installed or running and that haven't been touched for 30+ days, or 90+ days for folders named after an app rather than a bundle ID.
