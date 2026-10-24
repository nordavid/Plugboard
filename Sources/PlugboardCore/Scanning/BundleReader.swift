import Foundation

/// Reads a plug-in bundle's metadata without loading its code.
public enum BundleReader {
    public static func read(
        url: URL,
        format: PluginFormat,
        domain: InstallDomain,
        isInUnusedFolder: Bool = false
    ) -> PluginItem {
        let name = url.deletingPathExtension().lastPathComponent
        var item = PluginItem(url: url, format: format, domain: domain, name: name, isInUnusedFolder: isInUnusedFolder)

        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey])
        item.created = values?.creationDate
        item.modified = values?.contentModificationDate

        var bundleURL = url
        if values?.isSymbolicLink == true {
            let destination = url.resolvingSymlinksInPath()
            item.symlinkDestination = destination
            bundleURL = destination
        }

        let plist = infoPlist(of: bundleURL)
        apply(plist: plist, to: &item)

        let components = audioUnitComponents(in: plist)
        if format == .audioUnit || format == .auv3 {
            item.audioUnitComponents = components
        }
        if let first = components.first {
            item.declaredVendor = first.vendorName
            item.kind = commonKind(of: components)
        }
        item.pluginCount = max(components.count, 1)

        if format == .vst3, let module = VST3ModuleInfo.read(bundle: bundleURL) {
            item.declaredVendor = module.vendor ?? item.declaredVendor
            if item.kind == .unknown { item.kind = module.kind }
            item.pluginCount = max(item.pluginCount, module.audioClassCount)
            if item.version == nil { item.version = module.version }
        }

        switch format {
        case .audioDriver: item.kind = .audioDriver
        case .midiDriver: item.kind = .midiDriver
        case .waves:
            item.declaredVendor = "Waves"
            item.wavesMajorVersion = WavesNaming.majorVersion(ofPluginFolder: url.deletingLastPathComponent().lastPathComponent)
        default: break
        }

        if WavesNaming.isShell(name) {
            item.isShell = true
            item.kind = .other
            item.declaredVendor = "Waves"
            item.wavesMajorVersion = WavesNaming.majorVersion(ofShell: name)
        }

        item.vendor = item.declaredVendor
        if let executable = executableURL(of: bundleURL, plist: plist) {
            item.architectures = MachOReader.architectures(of: executable)
        }
        item.signature = CodeSignatureReader.read(bundleURL)
        return item
    }

    /// Reads an AUv3 app extension, which declares its components under NSExtension.
    public static func readAppExtension(url: URL) -> PluginItem? {
        let plist = infoPlist(of: url)
        let attributes = (plist["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any] ?? [:]
        let components = audioUnitComponents(in: attributes)
        guard !components.isEmpty else { return nil }

        let app = containingApp(of: url)
        let displayName = components.count == 1
            ? components[0].pluginName
            : (plist["CFBundleDisplayName"] as? String ?? url.deletingPathExtension().lastPathComponent)

        var item = read(url: url, format: .auv3, domain: .application)
        item.name = displayName
        item.audioUnitComponents = components
        item.pluginCount = components.count
        item.declaredVendor = components.first?.vendorName
        item.vendor = item.declaredVendor
        item.kind = commonKind(of: components)
        item.containingApp = app
        return item
    }

    // MARK: - Pieces

    static func infoPlist(of bundle: URL) -> [String: Any] {
        let candidates = [
            bundle.appending(path: "Contents/Info.plist"),
            bundle.appending(path: "Info.plist"),
        ]
        for candidate in candidates {
            if let data = try? Data(contentsOf: candidate),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return plist
            }
        }
        return [:]
    }

    static func apply(plist: [String: Any], to item: inout PluginItem) {
        item.bundleIdentifier = nonEmpty(plist["CFBundleIdentifier"] as? String)
        item.version = cleanVersion(plist["CFBundleShortVersionString"] as? String)
            ?? cleanVersion(plist["CFBundleVersion"] as? String)
        item.minimumSystemVersion = nonEmpty(plist["LSMinimumSystemVersion"] as? String)
    }

    static func audioUnitComponents(in dictionary: [String: Any]) -> [AudioUnitComponent] {
        guard let raw = dictionary["AudioComponents"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let type = entry["type"] as? String else { return nil }
            return AudioUnitComponent(
                type: type,
                subtype: entry["subtype"] as? String ?? "",
                manufacturer: entry["manufacturer"] as? String ?? "",
                name: entry["name"] as? String ?? ""
            )
        }
    }

    /// The kind all components share, or `.other` for a mixed shell.
    static func commonKind(of components: [AudioUnitComponent]) -> PluginKind {
        let kinds = Set(components.map { PluginKind(audioUnitType: $0.type) })
        if kinds.count == 1 { return kinds.first! }
        return kinds.isEmpty ? .unknown : .other
    }

    static func executableURL(of bundle: URL, plist: [String: Any]) -> URL? {
        let macOS = bundle.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        if let name = plist["CFBundleExecutable"] as? String, !name.isEmpty {
            let url = macOS.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: macOS, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return contents.first { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    static func containingApp(of url: URL) -> URL? {
        var candidate = url.deletingLastPathComponent()
        while candidate.pathComponents.count > 1 {
            if candidate.pathExtension == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    static func cleanVersion(_ raw: String?) -> String? {
        guard var version = nonEmpty(raw) else { return nil }
        if version.lowercased().hasPrefix("v"), version.dropFirst().first?.isNumber == true {
            version.removeFirst()
        }
        return version
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// The `moduleinfo.json` that VST3 SDK 3.7 and later write into each bundle.
struct VST3ModuleInfo {
    var vendor: String?
    var version: String?
    var kind: PluginKind
    var audioClassCount: Int

    static func read(bundle: URL) -> VST3ModuleInfo? {
        let candidates = [
            bundle.appending(path: "Contents/Resources/moduleinfo.json"),
            bundle.appending(path: "Contents/moduleinfo.json"),
        ]
        guard let data = candidates.lazy.compactMap({ try? Data(contentsOf: $0) }).first else { return nil }
        return parse(data)
    }

    /// The SDK writes JSON5, with trailing commas, so plain JSON parsing would reject it.
    static func parse(_ data: Data) -> VST3ModuleInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
            return nil
        }
        let factory = root["Factory Info"] as? [String: Any]
        let classes = (root["Classes"] as? [[String: Any]] ?? []).filter {
            ($0["Category"] as? String) == "Audio Module Class"
        }
        let subCategories = classes.flatMap { $0["Sub Categories"] as? [String] ?? [] }
        let vendor = BundleReader.nonEmpty(factory?["Vendor"] as? String)
            ?? BundleReader.nonEmpty(classes.first?["Vendor"] as? String)
        return VST3ModuleInfo(
            vendor: vendor,
            version: BundleReader.nonEmpty(root["Version"] as? String),
            kind: PluginKind(vst3SubCategories: subCategories),
            audioClassCount: classes.count
        )
    }
}
