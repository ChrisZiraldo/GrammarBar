import AppKit

struct InstalledApp: Identifiable, Hashable {
    let bundleId: String
    let name: String
    let url: URL

    var id: String { bundleId }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.bundleId == rhs.bundleId }
    func hash(into hasher: inout Hasher) { hasher.combine(bundleId) }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

enum InstalledAppsScanner {

    /// Looks up a single already-known bundle ID via Launch Services, which finds an
    /// app regardless of which directory it lives in — used to render blocked-app rows
    /// without needing a full directory scan.
    static func resolve(bundleId: String) -> InstalledApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return InstalledApp(bundleId: bundleId, name: displayName(for: url), url: url)
    }

    /// Scans well-known application directories (plus one level of subfolders, e.g.
    /// "Microsoft Office" or "Utilities") for .app bundles. Touches disk for every
    /// bundle's Info.plist, so callers should run this off the main thread.
    static func scanAll() -> [InstalledApp] {
        let roots: [URL] = {
            var roots = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/System/Applications"),
                URL(fileURLWithPath: "/System/Applications/Utilities"),
                URL(fileURLWithPath: "/System/Library/CoreServices")
            ]
            roots.append(contentsOf: FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask))
            return roots
        }()

        var seen = Set<String>()
        var results: [InstalledApp] = []

        for root in roots {
            for url in appBundleURLs(in: root, depth: 2) {
                guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else { continue }
                guard seen.insert(bundleId).inserted else { continue }
                results.append(InstalledApp(bundleId: bundleId, name: displayName(for: url, bundle: bundle), url: url))
            }
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func displayName(for url: URL, bundle: Bundle? = nil) -> String {
        let bundle = bundle ?? Bundle(url: url)
        return (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private static func appBundleURLs(in directory: URL, depth: Int) -> [URL] {
        guard depth >= 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
              )
        else { return [] }

        var result: [URL] = []
        for entry in entries {
            if entry.pathExtension == "app" {
                result.append(entry)
            } else if depth > 0,
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                result.append(contentsOf: appBundleURLs(in: entry, depth: depth - 1))
            }
        }
        return result
    }
}
