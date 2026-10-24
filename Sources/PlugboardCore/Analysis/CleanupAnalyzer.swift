import Foundation

/// Groups of plug-ins that are safe or worth reviewing for removal.
public enum CleanupCategory: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    /// Can't load on this Mac at all: 32-bit, PowerPC, RTAS or a newer macOS required.
    case incompatible
    /// Loads only in a DAW running under Rosetta.
    case intelOnly
    /// VST2 builds of plug-ins that also have a VST3 build.
    case vst2Duplicates
    /// AAX plug-ins when no AAX host is installed.
    case unusedAAX
    /// The same plug-in and format installed in more than one place.
    case duplicateCopies
    /// Waves major versions older than the newest one installed.
    case olderWaves

    public var id: String { rawValue }
}

/// Why a plug-in can't load on this Mac.
public enum Incompatibility: Sendable, Hashable {
    case legacyArchitecture
    case legacyFormat
    case wrongArchitecture
    case requiresNewerSystem(String)
}

/// One installed Waves major version and everything that belongs to it.
public struct WavesVersion: Identifiable, Sendable, Hashable {
    public var id: Int { major }
    public var major: Int
    /// "Plug-Ins V14" and "WaveShells V14" under /Applications/Waves.
    public var folders: [URL]
    /// Shell copies in the plug-in folders that DAWs scan.
    public var shells: [PluginItem]
    /// The plug-in bundles inside "Plug-Ins V14".
    public var plugins: [PluginItem]
    public var isNewest: Bool
}

public struct CleanupReport: Sendable {
    public var incompatible: [String: Incompatibility] = [:]
    public var intelOnly: Set<String> = []
    public var vst2Duplicates: Set<String> = []
    public var unusedAAX: Set<String> = []
    public var duplicateCopies: Set<String> = []
    public var wavesVersions: [WavesVersion] = []
    /// False when an AAX host is installed, so the category doesn't apply.
    public var aaxCategoryApplies = false
    public var intelCategoryApplies = false

    public func ids(for category: CleanupCategory) -> Set<String> {
        switch category {
        case .incompatible: Set(incompatible.keys)
        case .intelOnly: intelOnly
        case .vst2Duplicates: vst2Duplicates
        case .unusedAAX: unusedAAX
        case .duplicateCopies: duplicateCopies
        case .olderWaves: Set(wavesVersions.filter { !$0.isNewest }.flatMap { ($0.shells + $0.plugins).map(\.id) })
        }
    }

    public static let empty = CleanupReport()
}

public enum CleanupAnalyzer {
    public static func analyze(
        _ items: [PluginItem],
        daws: [DAW],
        host: ArchitectureSet = MachOReader.hostArchitecture,
        systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        fileManager: FileManager = .default
    ) -> CleanupReport {
        var report = CleanupReport()
        let removable = items.filter { $0.format.isRemovable && !$0.format.isDriver }

        for item in removable {
            if let reason = incompatibility(of: item, host: host, systemVersion: systemVersion) {
                report.incompatible[item.id] = reason
            } else if host.contains(.arm64), item.architectureSupport == .intel {
                report.intelOnly.insert(item.id)
            }
        }
        report.intelCategoryApplies = host.contains(.arm64)

        let products = Dictionary(grouping: removable, by: \.productKey)
        for members in products.values {
            let formats = Set(members.map(\.format))
            if formats.contains(.vst), formats.contains(.vst3) {
                report.vst2Duplicates.formUnion(members.filter { $0.format == .vst && !$0.isShell }.map(\.id))
            }
            for sameFormat in Dictionary(grouping: members.filter { !$0.isShell }, by: \.format).values where sameFormat.count > 1 {
                report.duplicateCopies.formUnion(sameFormat.map(\.id))
            }
        }

        let hasAAXHost = daws.contains { $0.formats.contains(.aax) }
        report.aaxCategoryApplies = !hasAAXHost
        if !hasAAXHost {
            report.unusedAAX = Set(removable.filter { $0.format == .aax }.map(\.id))
        }

        report.wavesVersions = wavesVersions(in: items, fileManager: fileManager)
        return report
    }

    static func incompatibility(of item: PluginItem, host: ArchitectureSet, systemVersion: OperatingSystemVersion) -> Incompatibility? {
        if item.format == .rtas { return .legacyFormat }
        switch item.architectureSupport {
        case .legacy: return .legacyArchitecture
        case .appleSilicon where !host.contains(.arm64): return .wrongArchitecture
        default: break
        }
        if let minimum = item.minimumSystemVersion, isNewer(minimum, than: systemVersion) {
            return .requiresNewerSystem(minimum)
        }
        return nil
    }

    static func isNewer(_ version: String, than system: OperatingSystemVersion) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let required = OperatingSystemVersion(
            majorVersion: parts.count > 0 ? parts[0] : 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        return (required.majorVersion, required.minorVersion, required.patchVersion)
            > (system.majorVersion, system.minorVersion, system.patchVersion)
    }

    static func wavesVersions(in items: [PluginItem], fileManager: FileManager) -> [WavesVersion] {
        var majors = Set(items.compactMap(\.wavesMajorVersion))
        var folders: [Int: [URL]] = [:]
        let root = ScanLocation.wavesRoot
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let major = WavesNaming.majorVersion(ofPluginFolder: name) ?? WavesNaming.majorVersion(ofShellFolder: name) else { continue }
            majors.insert(major)
            folders[major, default: []].append(root.appending(path: name))
        }
        let newest = majors.max()
        return majors.sorted(by: >).map { major in
            WavesVersion(
                major: major,
                folders: (folders[major] ?? []).sorted { $0.path < $1.path },
                shells: items.filter { $0.isShell && $0.wavesMajorVersion == major },
                plugins: items.filter { $0.format == .waves && $0.wavesMajorVersion == major },
                isNewest: major == newest
            )
        }
    }
}
