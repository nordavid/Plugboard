import Foundation

/// The formats of one product, such as the AU, VST3, AAX and CLAP builds of "Pro-Q 4".
public struct ProductGroup: Identifiable, Sendable, Hashable {
    public var id: String { "product:" + key }
    public var key: String
    public var name: String
    public var vendor: String?
    public var items: [PluginItem]

    public var formats: [PluginFormat] { Array(Set(items.map(\.format))).sorted() }
    public var kind: PluginKind {
        let kinds = Set(items.map(\.kind)).subtracting([.unknown])
        return kinds.count == 1 ? kinds.first! : (kinds.isEmpty ? .unknown : .other)
    }
    public var isShell: Bool { items.contains(where: \.isShell) }
    public var usages: [DiskUsage] { items.compactMap(\.usage) }
    public var isFullyMeasured: Bool { items.allSatisfy { $0.usage != nil } }
    public var combinedBytes: Int64 { DiskUsageCalculator.combinedBytes(of: usages) }
    public var created: Date? { items.compactMap(\.created).min() }
    public var modified: Date? { items.compactMap(\.modified).max() }
    public var domains: Set<InstallDomain> { Set(items.map(\.domain)) }

    /// The weakest architecture support among the formats, so a single Intel-only
    /// build isn't hidden behind native siblings.
    public var architectureSupport: ArchitectureSupport {
        items.map(\.architectureSupport).filter { $0 != .unknown }.max() ?? .unknown
    }

    /// The version shared by every format, or nil when they differ.
    public var commonVersion: String? {
        let versions = Set(items.compactMap(\.version))
        return versions.count == 1 ? versions.first : nil
    }
}

/// Fills in what a single bundle can't tell on its own: the vendor of a CLAP or AAX build
/// that only its AU sibling names, the product it belongs to and its kind.
public enum Catalog {
    public static func process(_ input: [PluginItem]) -> [PluginItem] {
        var items = input
        resolveVendors(&items)
        assignProductKeys(&items)
        inferKinds(&items)
        return items
    }

    public static func groups(_ items: [PluginItem]) -> [ProductGroup] {
        Dictionary(grouping: items, by: \.productKey).map { key, members in
            let sorted = members.sorted { ($0.format, $0.domain, $0.url.path) < ($1.format, $1.domain, $1.url.path) }
            return ProductGroup(key: key, name: displayName(for: sorted), vendor: sorted.lazy.compactMap(\.vendor).first, items: sorted)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The most common bundle name, preferring the AU's, since that's what Logic shows.
    static func displayName(for items: [PluginItem]) -> String {
        if let au = items.first(where: { $0.format == .audioUnit }) { return au.name }
        let counts = Dictionary(grouping: items, by: \.name).mapValues(\.count)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? items[0].name
    }

    // MARK: Vendors

    static func resolveVendors(_ items: inout [PluginItem]) {
        var byTeam: [String: [String]] = [:]
        var byPrefix: [String: [String]] = [:]

        for item in items {
            guard let declared = item.declaredVendor.map(cleanVendorName) else { continue }
            if let team = item.signature.teamID { byTeam[team, default: []].append(declared) }
            if let prefix = bundlePrefix(item.bundleIdentifier) { byPrefix[prefix, default: []].append(declared) }
        }
        let teamVendor = byTeam.mapValues(mostCommon)
        let prefixVendor = byPrefix.mapValues(mostCommon)

        for index in items.indices {
            let item = items[index]
            items[index].vendor = item.declaredVendor.map(cleanVendorName)
                ?? item.signature.teamID.flatMap { teamVendor[$0] }
                ?? bundlePrefix(item.bundleIdentifier).flatMap { prefixVendor[$0] }
                ?? item.signature.organization.map(cleanVendorName)
                ?? vendorFromBundleIdentifier(item.bundleIdentifier)
        }

        // One spelling per vendor: "FabFilter" and "Fabfilter" become whichever appears most.
        let spellings = Dictionary(grouping: items.compactMap(\.vendor), by: normalizedKey).mapValues(mostCommon)
        for index in items.indices {
            if let vendor = items[index].vendor {
                items[index].vendor = spellings[normalizedKey(vendor)] ?? vendor
            }
        }
    }

    private static let legalSuffixes: Set<String> = [
        "gmbh", "inc", "llc", "ltd", "limited", "bv", "b.v", "ab", "ag", "sa", "s.a", "sas", "sl", "s.l",
        "pty", "co", "corp", "corporation", "oy", "aps", "kg", "ug", "srl", "s.r.l", "s.r.o", "e.k", "plc", "gbr", "as", "a/s",
    ]

    /// "Native Instruments GmbH" → "Native Instruments", "Plugin Alliance LLC" → "Plugin Alliance".
    public static func cleanVendorName(_ raw: String) -> String {
        var words = raw.split(separator: " ").map(String.init)
        while words.count > 1 {
            let last = words.last!.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
            guard legalSuffixes.contains(last) else { break }
            words.removeLast()
            if let tail = words.last, tail.hasSuffix(",") {
                words[words.count - 1] = String(tail.dropLast())
            }
        }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// "com.fabfilter.Pro-Q.4" → "com.fabfilter".
    static func bundlePrefix(_ identifier: String?) -> String? {
        guard let parts = identifier?.lowercased().split(separator: "."), parts.count >= 3 else { return nil }
        let prefix = parts.prefix(2).joined(separator: ".")
        return genericPrefixes.contains(prefix) ? nil : prefix
    }

    private static let genericPrefixes: Set<String> = ["com.yourcompany", "com.mycompany", "com.juce", "com.company", "com.example", "com.apple"]

    /// Last resort: "com.fabfilter.Pro-Q.4" → "Fabfilter".
    static func vendorFromBundleIdentifier(_ identifier: String?) -> String? {
        guard let prefix = bundlePrefix(identifier), let word = prefix.split(separator: ".").last else { return nil }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    static func mostCommon(_ values: [String]) -> String {
        let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
    }

    // MARK: Products

    private static let formatTokens: Set<String> = ["au", "vst", "vst2", "vst3", "aax", "clap", "x64", "wpapi", "auv3", "component", "64bit"]

    /// "FabFilter Pro-Q 4 (VST3)" → "fabfilter pro q 4".
    public static func nameKey(_ name: String) -> String {
        let lowered = name.lowercased().replacingOccurrences(of: "wpapi_2", with: " ")
        let tokens = lowered
            .split { !($0.isLetter || $0.isNumber || $0 == ".") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty && !formatTokens.contains($0) }
        return tokens.joined(separator: " ")
    }

    public static func normalizedKey(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Bundles with the same name belong together unless they clearly come from different
    /// vendors. Sharing a signing team or a vendor name links them, and so does a missing vendor.
    static func assignProductKeys(_ items: inout [PluginItem]) {
        let buckets = Dictionary(grouping: items.indices, by: { nameKey(items[$0].name) })

        for (key, indices) in buckets {
            var parent = Array(0..<indices.count)
            func find(_ x: Int) -> Int {
                var x = x
                while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
                return x
            }
            for a in 0..<indices.count {
                for b in (a + 1)..<max(a + 1, indices.count) where sameProduct(items[indices[a]], items[indices[b]]) {
                    parent[find(a)] = find(b)
                }
            }
            for (offset, index) in indices.enumerated() {
                let root = find(offset)
                // Bundles that share a name but not a vendor get their own product.
                items[index].productKey = root == find(0) ? key : "\(key)#\(items[indices[root]].vendor.map(normalizedKey) ?? "\(root)")"
            }
        }
    }

    static func sameProduct(_ a: PluginItem, _ b: PluginItem) -> Bool {
        if a.format.isDriver != b.format.isDriver { return false }
        if let teamA = a.signature.teamID, let teamB = b.signature.teamID, teamA == teamB { return true }
        guard let vendorA = a.vendor, let vendorB = b.vendor else { return true }
        return normalizedKey(vendorA) == normalizedKey(vendorB)
    }

    /// A CLAP or AAX build rarely says whether it's an instrument, but its AU sibling does.
    static func inferKinds(_ items: inout [PluginItem]) {
        var known: [String: PluginKind] = [:]
        for item in items where ![.unknown, .other].contains(item.kind) && !item.isShell {
            known[item.productKey] = known[item.productKey] ?? item.kind
        }
        for index in items.indices where items[index].kind == .unknown {
            if let kind = known[items[index].productKey] { items[index].kind = kind }
        }

        // Waves plug-in bundles say nothing about themselves, but every WaveShell lists its
        // plug-ins as Audio Unit components, such as "CLA-76 (m)" of type aufx.
        var wavesKinds: [String: PluginKind] = [:]
        for shell in items where shell.isShell {
            for component in shell.audioUnitComponents {
                wavesKinds[wavesBaseKey(component.pluginName)] = wavesKinds[wavesBaseKey(component.pluginName)] ?? PluginKind(audioUnitType: component.type)
            }
        }
        for index in items.indices where items[index].format == .waves && items[index].kind == .unknown {
            if let kind = wavesKinds[wavesBaseKey(items[index].name)] { items[index].kind = kind }
        }
    }

    /// "CLA-76 (m)" and "CLA-76 Stereo" → the key of "CLA-76".
    static func wavesBaseKey(_ name: String) -> String {
        var base = name
        if let open = base.firstIndex(of: "("), base.hasSuffix(")") {
            base = String(base[..<open])
        }
        var words = base.split(separator: " ")
        while let last = words.last, ["mono", "stereo"].contains(last.lowercased()) {
            words.removeLast()
        }
        return nameKey(words.joined(separator: " "))
    }
}
