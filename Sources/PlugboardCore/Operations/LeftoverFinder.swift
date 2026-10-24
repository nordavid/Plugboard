import Foundation

/// A file or folder an uninstall can remove besides the plug-in bundles.
public struct Leftover: Identifiable, Sendable, Hashable {
    public enum Category: String, Sendable, Hashable, CaseIterable, Comparable {
        case pluginBundle
        case preferences
        case cache
        case presets
        case supportFiles
        case installerFile

        private var order: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (lhs: Category, rhs: Category) -> Bool { lhs.order < rhs.order }
    }

    public var id: String { url.path }
    public var url: URL
    public var category: Category
    /// Settings and caches are safe to remove. Presets and support files may hold the
    /// user's own work or large libraries, so they start unselected.
    public var isSelectedByDefault: Bool

    public init(url: URL, category: Category, isSelectedByDefault: Bool) {
        self.url = url
        self.category = category
        self.isSelectedByDefault = isSelectedByDefault
    }
}

/// Finds preferences, caches, presets and support folders that belong to a product.
/// Matches are exact on normalized names, never substring guesses, and a folder shared by
/// a vendor's products is never proposed, only the product's own subfolder.
public struct LeftoverFinder: Sendable {
    public var home: URL
    private var fileManager: FileManager { .default }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func leftovers(for group: ProductGroup) -> [Leftover] {
        let nameKeys = productNameKeys(for: group)
        let vendorKeys = self.vendorKeys(for: group)
        var found: [Leftover] = []

        // Preferences and caches, matched by bundle identifier.
        let identifiers = Set(group.items.compactMap(\.bundleIdentifier).map(Self.normalizedIdentifier))
        if !identifiers.isEmpty {
            for folder in [home.appending(path: "Library/Preferences"), URL(fileURLWithPath: "/Library/Preferences")] {
                for name in contents(of: folder) where name.hasSuffix(".plist") {
                    let identifier = Self.normalizedIdentifier(String(name.dropLast(6)))
                    if identifiers.contains(identifier) {
                        found.append(Leftover(url: folder.appending(path: name), category: .preferences, isSelectedByDefault: true))
                    }
                }
            }
            let caches = home.appending(path: "Library/Caches")
            for name in contents(of: caches) where identifiers.contains(Self.normalizedIdentifier(name)) {
                found.append(Leftover(url: caches.appending(path: name), category: .cache, isSelectedByDefault: true))
            }
        }

        // Presets: <Presets>/<Vendor>/<Plug-in>, and Logic's own per-plug-in folder.
        let presetRoots = [home.appending(path: "Library/Audio/Presets"), URL(fileURLWithPath: "/Library/Audio/Presets")]
        for root in presetRoots {
            found += productFolders(in: root, vendorKeys: vendorKeys, nameKeys: nameKeys, category: .presets, allowDirect: false)
        }
        let logicSettings = home.appending(path: "Music/Audio Music Apps/Plug-In Settings")
        for name in contents(of: logicSettings) where nameKeys.contains(Catalog.nameKey(name)) {
            found.append(Leftover(url: logicSettings.appending(path: name), category: .presets, isSelectedByDefault: false))
        }

        // Support files: <Application Support>/<Vendor>/<Plug-in>, or a folder named after the product.
        let supportRoots = [
            home.appending(path: "Library/Application Support"),
            URL(fileURLWithPath: "/Library/Application Support"),
            URL(fileURLWithPath: "/Users/Shared"),
        ]
        for root in supportRoots {
            found += productFolders(in: root, vendorKeys: vendorKeys, nameKeys: nameKeys, category: .supportFiles, allowDirect: true)
        }

        let bundlePaths = Set(group.items.map(\.url.path))
        var seen = Set<String>()
        return found.filter { !bundlePaths.contains($0.url.path) && seen.insert($0.url.path).inserted }
    }

    private func productFolders(in root: URL, vendorKeys: Set<String>, nameKeys: Set<String>, category: Leftover.Category, allowDirect: Bool) -> [Leftover] {
        var result: [Leftover] = []
        for vendorFolder in contents(of: root) {
            let vendorURL = root.appending(path: vendorFolder)
            let vendorKey = Catalog.normalizedKey(Catalog.cleanVendorName(vendorFolder))
            if vendorKeys.contains(vendorKey) {
                for productFolder in contents(of: vendorURL) where nameKeys.contains(Catalog.nameKey(productFolder)) {
                    result.append(Leftover(url: vendorURL.appending(path: productFolder), category: category, isSelectedByDefault: false))
                }
            } else if allowDirect, nameKeys.contains(Catalog.nameKey(vendorFolder)), isDirectory(vendorURL) {
                // Only long, specific names, so "Equalizer" never matches a stranger's folder.
                if Catalog.nameKey(vendorFolder).count >= 6 {
                    result.append(Leftover(url: vendorURL, category: category, isSelectedByDefault: false))
                }
            }
        }
        return result
    }

    /// Every name the product goes by, normalized: the bundle names, the AU's plug-in name and
    /// the name without its vendor prefix ("FabFilter Pro-Q 4" → "Pro-Q 4").
    func productNameKeys(for group: ProductGroup) -> Set<String> {
        var names = Set(group.items.map(\.name))
        names.insert(group.name)
        for item in group.items {
            names.formUnion(item.audioUnitComponents.map(\.pluginName))
        }
        var keys = Set(names.map(Catalog.nameKey))
        let vendors = vendorKeys(for: group)
        for key in keys {
            let words = key.split(separator: " ")
            for count in 1..<max(1, words.count) where vendors.contains(Catalog.normalizedKey(words.prefix(count).joined())) {
                keys.insert(words.dropFirst(count).joined(separator: " "))
            }
        }
        return keys.filter { !$0.isEmpty }
    }

    func vendorKeys(for group: ProductGroup) -> Set<String> {
        var vendors = Set(group.items.compactMap(\.vendor))
        vendors.formUnion(group.items.compactMap(\.declaredVendor))
        for item in group.items {
            vendors.formUnion(item.audioUnitComponents.compactMap(\.vendorName))
            if let organization = item.signature.organization { vendors.insert(organization) }
        }
        return Set(vendors.map { Catalog.normalizedKey(Catalog.cleanVendorName($0)) }).filter { !$0.isEmpty }
    }

    /// "com.fabfilter.Pro-Q.Clap.4" and the preference file "com.fabfilter.Pro-Q.4" both become
    /// "com.fabfilter.pro-q.4", since vendors add the format to each build's identifier.
    static func normalizedIdentifier(_ identifier: String) -> String {
        let formatWords: Set<String> = ["au", "vst", "vst2", "vst3", "aax", "clap", "component", "auv3", "audiounit", "plugin", "plugins"]
        return identifier.lowercased()
            .split(separator: ".")
            .filter { !formatWords.contains(String($0)) }
            .joined(separator: ".")
    }

    private func contents(of folder: URL) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// An installer package that put files on this Mac, as recorded by macOS.
public struct PackageReceipt: Identifiable, Sendable, Hashable {
    public var id: String
    public var version: String?
    public var installDate: Date?
    /// Files the package installed that still exist, outside the plug-in bundles themselves.
    public var otherFiles: [URL]
}

/// Looks up installer receipts with `pkgutil`. Each lookup takes about a second, so callers
/// run this in the background.
public enum PackageReceipts {
    public static func receipts(for urls: [URL], excluding knownPaths: Set<String>, policy: RemovalPolicy) async -> [PackageReceipt] {
        let ids = await concurrentMap(urls, maxConcurrency: 4) { url in owners(of: url) }
        let unique = Array(Set(ids.flatMap { $0 })).sorted()
        return await concurrentMap(unique, maxConcurrency: 4) { id in
            receipt(id, excluding: knownPaths, policy: policy)
        }.compactMap { $0 }
    }

    static func owners(of url: URL) -> [String] {
        guard let result = ProcessRunner.run("/usr/sbin/pkgutil", ["--file-info", url.path]), result.status == 0 else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("pkgid: ") else { return nil }
            return String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
    }

    static func receipt(_ id: String, excluding knownPaths: Set<String>, policy: RemovalPolicy) -> PackageReceipt? {
        guard let info = ProcessRunner.run("/usr/sbin/pkgutil", ["--pkg-info", id]), info.status == 0 else { return nil }
        var fields: [String: String] = [:]
        for line in info.output.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let volume = fields["volume"] ?? "/"
        let location = fields["location"] ?? ""
        let base = URL(fileURLWithPath: volume).appending(path: location)

        var others: [URL] = []
        if let files = ProcessRunner.run("/usr/sbin/pkgutil", ["--files", id]), files.status == 0 {
            // Keep only top-level items: a plug-in bundle or a vendor's product folder,
            // never the shared folders a package lists on the way down.
            var seen = Set<String>()
            for relative in files.output.split(separator: "\n") {
                let url = base.appending(path: String(relative)).standardizedFileURL
                guard let top = topLevelItem(url), seen.insert(top.path).inserted,
                      !knownPaths.contains(top.path),
                      FileManager.default.fileExists(atPath: top.path),
                      policy.isAllowed(top) else { continue }
                others.append(top)
            }
        }

        return PackageReceipt(
            id: id,
            version: fields["version"],
            installDate: fields["install-time"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)),
            otherFiles: others.sorted { $0.path < $1.path }
        )
    }

    /// Reduces a path from a receipt to the item an uninstall would remove: the plug-in bundle
    /// for anything inside one, or the product folder under a vendor folder.
    static func topLevelItem(_ url: URL) -> URL? {
        let components = url.pathComponents
        if let index = components.firstIndex(where: { component in
            let ext = (component as NSString).pathExtension.lowercased()
            return PluginFormat(fileExtension: ext) != nil || ["driver", "appex"].contains(ext)
        }) {
            return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])))
        }
        let path = url.path
        for zone in ["/Library/Application Support/", "/Library/Audio/Presets/", "/Users/Shared/"] where path.hasPrefix(zone) {
            let rest = path.dropFirst(zone.count).split(separator: "/")
            guard rest.count >= 2 else { return nil }
            return URL(fileURLWithPath: zone + rest.prefix(2).joined(separator: "/"))
        }
        return nil
    }
}
