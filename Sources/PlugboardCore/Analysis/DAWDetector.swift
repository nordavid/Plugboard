import Foundation

/// A music app that loads plug-ins.
public struct DAW: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public var name: String
    public var url: URL
    public var bundleIdentifier: String
    public var version: String?
    public var formats: Set<PluginFormat>
}

/// Finds installed DAWs, so Plugboard can tell which plug-in formats anything on this Mac uses.
public enum DAWDetector {
    private struct Host {
        var identifierPrefix: String
        var name: String
        var formats: Set<PluginFormat>
    }

    private static let hosts: [Host] = [
        Host(identifierPrefix: "com.apple.logic10", name: "Logic Pro", formats: [.audioUnit, .auv3]),
        Host(identifierPrefix: "com.apple.garageband10", name: "GarageBand", formats: [.audioUnit, .auv3]),
        Host(identifierPrefix: "com.apple.mainstage3", name: "MainStage", formats: [.audioUnit, .auv3]),
        Host(identifierPrefix: "com.image-line.flstudio", name: "FL Studio", formats: [.audioUnit, .vst, .vst3, .clap]),
        Host(identifierPrefix: "com.ableton.live", name: "Ableton Live", formats: [.audioUnit, .vst, .vst3, .auv3]),
        Host(identifierPrefix: "com.avid.ProTools", name: "Pro Tools", formats: [.aax]),
        Host(identifierPrefix: "com.avid.mediacomposer", name: "Media Composer", formats: [.aax]),
        Host(identifierPrefix: "com.steinberg.cubase", name: "Cubase", formats: [.vst3, .vst]),
        Host(identifierPrefix: "com.steinberg.nuendo", name: "Nuendo", formats: [.vst3, .vst]),
        Host(identifierPrefix: "com.bitwig.BitwigStudio", name: "Bitwig Studio", formats: [.vst, .vst3, .clap]),
        Host(identifierPrefix: "com.cockos.reaper", name: "REAPER", formats: [.audioUnit, .vst, .vst3, .clap, .auv3]),
        Host(identifierPrefix: "com.presonus.studioone", name: "Studio One", formats: [.audioUnit, .vst, .vst3]),
        Host(identifierPrefix: "com.reasonstudios.reason", name: "Reason", formats: [.vst, .vst3]),
        Host(identifierPrefix: "se.propellerheads.reason", name: "Reason", formats: [.vst, .vst3]),
        Host(identifierPrefix: "com.motu.DigitalPerformer", name: "Digital Performer", formats: [.audioUnit, .vst, .vst3, .mas]),
        Host(identifierPrefix: "com.renoise.renoise", name: "Renoise", formats: [.audioUnit, .vst, .vst3, .clap]),
        Host(identifierPrefix: "com.tracktion.waveform", name: "Waveform", formats: [.audioUnit, .vst, .vst3]),
        Host(identifierPrefix: "org.ardour.Ardour", name: "Ardour", formats: [.audioUnit, .vst, .vst3]),
        Host(identifierPrefix: "com.waves.SuperRack", name: "Waves SuperRack", formats: [.wpapi]),
        Host(identifierPrefix: "com.waves.StudioRack", name: "Waves StudioRack", formats: [.wpapi]),
    ]

    public static func detect(fileManager: FileManager = .default) -> [DAW] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appending(path: "Applications"),
        ]
        var found: [String: DAW] = [:]
        for root in roots {
            for app in applications(in: root, depth: 2, fileManager: fileManager) {
                guard let plist = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
                      let identifier = plist["CFBundleIdentifier"] as? String,
                      let host = hosts.first(where: { identifier.lowercased().hasPrefix($0.identifierPrefix.lowercased()) }) else { continue }
                let daw = DAW(
                    name: host.name,
                    url: app,
                    bundleIdentifier: identifier,
                    version: plist["CFBundleShortVersionString"] as? String,
                    formats: host.formats
                )
                found[app.path] = daw
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func applications(in folder: URL, depth: Int, fileManager: FileManager) -> [URL] {
        guard depth > 0, let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
        var apps: [URL] = []
        for name in names where !name.hasPrefix(".") {
            let url = folder.appending(path: name)
            if name.hasSuffix(".app") {
                apps.append(url)
            } else {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    apps += applications(in: url, depth: depth - 1, fileManager: fileManager)
                }
            }
        }
        return apps
    }
}
