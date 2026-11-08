// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation
#if canImport(AppKit)
import AppKit
#endif

public enum UnivocalAvailability: Sendable, Equatable {
    case notInstalled
    /// `running` == discovery file present and its pid alive.
    case installed(appURL: URL, running: Bool)
    /// Installed, not running, and older than `UnivocalConfiguration.minimumServerVersion`:
    /// launching it would not bring up a listener. Offer an update instead.
    case outdated(appURL: URL, version: String)
}

/// Installation, discovery and launch helpers (SPEC §4). All synchronous except `launch`.
public enum UnivocalLocator {
    public static let downloadURL = URL(string: "https://univocalapp.com")!

    public static func availability(configuration: UnivocalConfiguration) -> UnivocalAvailability {
        let located = configuration.appLocator(configuration.serverBundleId)
        // A running server is usable wherever it was started from.
        if let running = discovery(in: configuration.connectDirectory),
           let url = located ?? runningAppURL(pid: running.pid) {
            return .installed(appURL: url, running: true)
        }
        guard let url = located else { return .notInstalled }
        if let minimum = configuration.minimumServerVersion, let version = appVersion(at: url),
           !isVersion(version, atLeast: minimum) {
            return .outdated(appURL: url, version: version)
        }
        return .installed(appURL: url, running: false)
    }

    /// Parses `<dir>/connect.json`. `nil` if missing, unreadable, not Univocal Connect,
    /// or stale (its `pid` is not alive).
    public static func discovery(in connectDirectory: URL) -> UnivocalDiscovery? {
        let url = UnivocalPaths.discoveryFileURL(in: connectDirectory)
        guard let data = try? Data(contentsOf: url),
              let d = try? JSONDecoder().decode(UnivocalDiscovery.self, from: data),
              UnivocalPaths.processIsAlive(d.pid)
        else { return nil }
        return d
    }

    /// LaunchServices lookup: the newest registered copy in an Applications
    /// folder (see `isInstallLocation`); `nil` when there is none.
    ///
    /// LaunchServices' own pick (`urlForApplication`) can be any copy it has
    /// ever seen — a hidden backup, a build folder, a mounted disk image —
    /// and launching an old one brings up no listener.
    public static func installedAppURL(bundleId: String) -> URL? {
        #if canImport(AppKit)
        let candidates = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleId)
        return preferredAppURL(candidates, version: appVersion(at:))
        #else
        return nil
        #endif
    }

    /// Of `candidates`, the newest one installed in an Applications folder
    /// that still exists; ties keep the earlier one.
    static func preferredAppURL(_ candidates: [URL], version: (URL) -> String?) -> URL? {
        var best: (url: URL, version: String)?
        for url in candidates where isInstallLocation(url)
            && FileManager.default.fileExists(atPath: url.path) {
            let v = version(url) ?? "0"
            if best == nil || !isVersion(best!.version, atLeast: v) { best = (url, v) }
        }
        return best?.url
    }

    /// Where an installed copy lives: inside an `Applications` folder
    /// (`/Applications`, `~/Applications`, their subfolders, or another
    /// volume's), not hidden, not in the Trash. Excludes mounted disk images,
    /// build products and Sparkle's or an installer's leftovers.
    static func isInstallLocation(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.contains("Applications") else { return false }
        return !parts.contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }

    /// `CFBundleShortVersionString`, read from disk (not `Bundle`'s cache,
    /// which keeps a version across an in-place update).
    public static func appVersion(at appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// Numeric dotted-version comparison ("0.3.29" < "0.3.100"); missing
    /// components count as 0, a non-numeric suffix ("1.2b3") is ignored.
    public static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        func numbers(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = numbers(version), b = numbers(minimum)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }

    static func runningAppURL(pid: Int32) -> URL? {
        #if canImport(AppKit)
        return NSRunningApplication(processIdentifier: pid)?.bundleURL
        #else
        return nil
        #endif
    }

    /// Launches the server in the background with `--connect` (SPEC §4.3).
    public static func launch(appURL: URL, bundleId: String) async throws {
        #if canImport(AppKit)
        let launched: Bool = await withCheckedContinuation { cont in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.arguments = ["--connect"]
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
                cont.resume(returning: app != nil && error == nil)
            }
        }
        if launched { return }
        #endif
        try launchWithOpen(appURL: appURL)
    }

    /// `open -g -a <appURL> --args --connect`: that copy, not whichever one
    /// `open -b` would pick.
    static func launchWithOpen(appURL: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-a", appURL.path, "--args", "--connect"]
        do {
            try p.run()
        } catch {
            throw UnivocalError(code: .launchTimedOut, message: "Could not launch Univocal: \(error.localizedDescription)")
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UnivocalError(code: .launchTimedOut, message: "Could not launch Univocal (open exited \(p.terminationStatus)).")
        }
    }
}
