import Foundation

/// A folder Plugboard searches for plug-in bundles.
public struct ScanLocation: Codable, Sendable, Hashable, Identifiable {
    public var id: String { url.path }

    public var url: URL
    /// The format every bundle here has. Nil means infer it from each bundle's extension.
    public var format: PluginFormat?
    public var domain: InstallDomain
    /// Pro Tools' "(Unused)" folders hold plug-ins it deliberately skips.
    public var isUnusedFolder: Bool
    /// How many folder levels to descend. Vendors nest bundles in subfolders such as VST3/Eiosis.
    public var maxDepth: Int

    public init(url: URL, format: PluginFormat?, domain: InstallDomain, isUnusedFolder: Bool = false, maxDepth: Int = 4) {
        self.url = url
        self.format = format
        self.domain = domain
        self.isUnusedFolder = isUnusedFolder
        self.maxDepth = maxDepth
    }

    /// Every standard location on macOS, for both the user and the shared /Library domain.
    /// Locations that don't exist are included, so a folder watcher can notice when one appears.
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ScanLocation] {
        let system = URL(fileURLWithPath: "/", isDirectory: true)
        var locations: [ScanLocation] = []

        for (root, domain) in [(home, InstallDomain.user), (system, InstallDomain.system)] {
            let plugIns = root.appending(path: "Library/Audio/Plug-Ins", directoryHint: .isDirectory)
            locations += [
                ScanLocation(url: plugIns.appending(path: "Components"), format: .audioUnit, domain: domain),
                ScanLocation(url: plugIns.appending(path: "VST3"), format: .vst3, domain: domain),
                ScanLocation(url: plugIns.appending(path: "VST"), format: .vst, domain: domain),
                ScanLocation(url: plugIns.appending(path: "CLAP"), format: .clap, domain: domain),
                ScanLocation(url: plugIns.appending(path: "HAL"), format: .audioDriver, domain: domain, maxDepth: 1),
                ScanLocation(url: root.appending(path: "Library/Audio/MIDI Drivers"), format: .midiDriver, domain: domain, maxDepth: 1),
            ]
        }

        let sharedPlugIns = system.appending(path: "Library/Audio/Plug-Ins")
        let appSupport = system.appending(path: "Library/Application Support")
        locations += [
            ScanLocation(url: sharedPlugIns.appending(path: "MAS"), format: .mas, domain: .system, maxDepth: 2),
            ScanLocation(url: sharedPlugIns.appending(path: "WPAPI"), format: .wpapi, domain: .system, maxDepth: 1),
            ScanLocation(url: appSupport.appending(path: "Avid/Audio/Plug-Ins"), format: .aax, domain: .system),
            ScanLocation(url: appSupport.appending(path: "Avid/Audio/Plug-Ins (Unused)"), format: .aax, domain: .system, isUnusedFolder: true),
            ScanLocation(url: appSupport.appending(path: "Digidesign/Plug-Ins"), format: .rtas, domain: .system),
            ScanLocation(url: appSupport.appending(path: "Digidesign/Plug-Ins (Unused)"), format: .rtas, domain: .system, isUnusedFolder: true),
        ]

        locations += wavesPluginFolders()
        return locations
    }

    /// The root of a Waves installation.
    public static let wavesRoot = URL(fileURLWithPath: "/Applications/Waves", isDirectory: true)

    /// Waves keeps its plug-ins in one folder per major version, such as "Plug-Ins V14".
    /// DAWs never load these directly; WaveShells do.
    static func wavesPluginFolders(fileManager: FileManager = .default) -> [ScanLocation] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: wavesRoot.path) else { return [] }
        return names
            .filter { WavesNaming.majorVersion(ofPluginFolder: $0) != nil }
            .sorted()
            .map { ScanLocation(url: wavesRoot.appending(path: $0), format: .waves, domain: .application, maxDepth: 1) }
    }

    /// Parent folders worth watching for changes. Watching parents catches a format folder
    /// that doesn't exist yet, such as CLAP before the first CLAP install.
    public static func watchRoots(for locations: [ScanLocation]) -> [URL] {
        var roots = Set<String>()
        for location in locations {
            var url = location.url
            while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 2 {
                url.deleteLastPathComponent()
            }
            roots.insert(url.standardizedFileURL.path)
        }
        return roots.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

/// Naming rules Waves uses for its folders and shells.
public enum WavesNaming {
    /// "Plug-Ins V14" → 14.
    public static func majorVersion(ofPluginFolder name: String) -> Int? {
        version(in: name, prefix: "Plug-Ins V")
    }

    /// "WaveShells V14" → 14.
    public static func majorVersion(ofShellFolder name: String) -> Int? {
        version(in: name, prefix: "WaveShells V")
    }

    /// "WaveShell1-AU 14.12" → 14. Nil for anything that isn't a WaveShell.
    public static func majorVersion(ofShell name: String) -> Int? {
        guard name.hasPrefix("WaveShell") else { return nil }
        guard let space = name.lastIndex(of: " ") else { return nil }
        let versionPart = name[name.index(after: space)...]
        guard let major = versionPart.split(separator: ".").first else { return nil }
        return Int(major)
    }

    public static func isShell(_ name: String) -> Bool {
        name.hasPrefix("WaveShell") && majorVersion(ofShell: name) != nil
    }

    private static func version(in name: String, prefix: String) -> Int? {
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }
}
