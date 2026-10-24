import PlugboardCore
import SwiftUI

// User-facing names for core types. Every string here is looked up in Localizable.strings.

extension PluginFormat {
    var title: String {
        switch self {
        case .audioUnit: String(localized: "Audio Units")
        case .vst3: "VST3"
        case .vst: "VST"
        case .clap: "CLAP"
        case .aax: "AAX"
        case .auv3: String(localized: "AUv3 Extensions")
        case .waves: String(localized: "Waves Plug-ins")
        case .wpapi: "Waves WPAPI"
        case .rtas: String(localized: "RTAS (Legacy)")
        case .mas: "MAS"
        case .audioDriver: String(localized: "Audio Drivers")
        case .midiDriver: String(localized: "MIDI Drivers")
        }
    }

    var symbol: String {
        switch self {
        case .audioUnit: "waveform"
        case .vst3: "cube"
        case .vst: "cube.transparent"
        case .clap: "hands.clap"
        case .aax: "slider.vertical.3"
        case .auv3: "puzzlepiece.extension"
        case .waves: "water.waves"
        case .wpapi: "rectangle.stack"
        case .rtas: "clock.arrow.circlepath"
        case .mas: "music.note.house"
        case .audioDriver: "hifispeaker"
        case .midiDriver: "pianokeys"
        }
    }

    /// Decorative tint for sidebar icons. The format's name always sits beside it.
    var tint: Color {
        switch self {
        case .audioUnit: .purple
        case .vst3: .blue
        case .vst: .orange
        case .clap: .teal
        case .aax: .indigo
        case .auv3: .mint
        case .waves, .wpapi: .cyan
        case .rtas, .mas: .brown
        case .audioDriver: .green
        case .midiDriver: .pink
        }
    }
}

extension PluginKind {
    var title: String {
        switch self {
        case .instrument: String(localized: "Instrument")
        case .effect: String(localized: "Effect")
        case .midiEffect: String(localized: "MIDI Effect")
        case .generator: String(localized: "Generator")
        case .audioDriver: String(localized: "Audio Driver")
        case .midiDriver: String(localized: "MIDI Driver")
        case .other: String(localized: "Other")
        case .unknown: String(localized: "Unknown")
        }
    }

    var symbol: String {
        switch self {
        case .instrument: "pianokeys"
        case .effect: "slider.horizontal.3"
        case .midiEffect: "pianokeys.inverse"
        case .generator: "waveform.path"
        case .audioDriver: "hifispeaker"
        case .midiDriver: "cable.connector"
        case .other, .unknown: "puzzlepiece"
        }
    }
}

extension ArchitectureSupport {
    var title: String {
        switch self {
        case .universal: String(localized: "Universal")
        case .appleSilicon: String(localized: "Apple silicon")
        case .intel: String(localized: "Intel only")
        case .legacy: String(localized: "32-bit")
        case .unknown: String(localized: "Unknown")
        }
    }

    var detail: String {
        switch self {
        case .universal: String(localized: "Runs natively on Apple silicon and Intel")
        case .appleSilicon: String(localized: "Runs natively on Apple silicon")
        case .intel: String(localized: "Needs Rosetta on Apple silicon")
        case .legacy: String(localized: "Can't load on current macOS")
        case .unknown: String(localized: "No executable code found")
        }
    }
}

extension InstallDomain {
    var title: String {
        switch self {
        case .user: String(localized: "User")
        case .system: String(localized: "System")
        case .application: String(localized: "App")
        case .custom: String(localized: "Custom Folder")
        }
    }

    var detail: String {
        switch self {
        case .user: String(localized: "Your Library folder, only for you")
        case .system: String(localized: "The shared Library folder, for every user")
        case .application: String(localized: "Inside an app folder")
        case .custom: String(localized: "A folder you added in Settings")
        }
    }
}

extension SignatureInfo {
    var title: String {
        switch status {
        case .developerID, .appStore: organization ?? String(localized: "Identified developer")
        case .apple: "Apple"
        case .adHoc: String(localized: "Ad-hoc signature")
        case .unsigned: String(localized: "Not signed")
        case .unknown: String(localized: "Unknown")
        }
    }
}

extension CleanupCategory {
    var title: String {
        switch self {
        case .incompatible: String(localized: "Can't Load")
        case .intelOnly: String(localized: "Intel Only")
        case .vst2Duplicates: String(localized: "VST2 Duplicates")
        case .unusedAAX: String(localized: "Unused AAX")
        case .duplicateCopies: String(localized: "Duplicate Copies")
        case .olderWaves: String(localized: "Older Waves Versions")
        }
    }

    var headline: String {
        switch self {
        case .incompatible: String(localized: "These plug-ins can't load on this Mac")
        case .intelOnly: String(localized: "These plug-ins need Rosetta")
        case .vst2Duplicates: String(localized: "VST2 copies of VST3 plug-ins")
        case .unusedAAX: String(localized: "Only Pro Tools loads AAX plug-ins")
        case .duplicateCopies: String(localized: "Installed in more than one place")
        case .olderWaves: String(localized: "Waves keeps every version you install")
        }
    }

    var explanation: String {
        switch self {
        case .incompatible:
            String(localized: "They're 32-bit, PowerPC or RTAS builds, or need a newer macOS. No current DAW can use them.")
        case .intelOnly:
            String(localized: "They only load in a DAW opened with Rosetta, which runs slower. Check the vendor's website for an Apple silicon update before removing them.")
        case .vst2Duplicates:
            String(localized: "Each of these also has a VST3 version, which DAWs prefer. Older projects saved with the VST2 version may not find the plug-in after removal.")
        case .unusedAAX:
            String(localized: "Pro Tools and Media Composer aren't installed on this Mac. Remove these if you don't plan to use Pro Tools here.")
        case .duplicateCopies:
            String(localized: "The same plug-in and format exists in more than one folder, such as your own Library and the shared one. Keep the newer copy.")
        case .olderWaves:
            String(localized: "Remove an older version only if your licenses cover the newest one and you no longer open projects that use it.")
        }
    }

    var symbol: String {
        switch self {
        case .incompatible: "exclamationmark.octagon"
        case .intelOnly: "cpu"
        case .vst2Duplicates: "square.on.square"
        case .unusedAAX: "slider.vertical.3"
        case .duplicateCopies: "doc.on.doc"
        case .olderWaves: "clock.arrow.circlepath"
        }
    }
}

extension Incompatibility {
    var title: String {
        switch self {
        case .legacyArchitecture: String(localized: "32-bit or PowerPC only")
        case .legacyFormat: String(localized: "RTAS, retired in Pro Tools 11")
        case .wrongArchitecture: String(localized: "Built for Apple silicon only")
        case .requiresNewerSystem(let version): String(localized: "Requires macOS \(version)")
        }
    }
}

extension Leftover.Category {
    var title: String {
        switch self {
        case .pluginBundle: String(localized: "Plug-in Files")
        case .preferences: String(localized: "Settings")
        case .cache: String(localized: "Caches")
        case .presets: String(localized: "Presets")
        case .supportFiles: String(localized: "Support Files")
        case .installerFile: String(localized: "Installed by the Same Package")
        }
    }

    var footnote: String? {
        switch self {
        case .presets: String(localized: "May include presets you made yourself.")
        case .supportFiles: String(localized: "May include sound libraries or licenses. Keep them if you might reinstall.")
        case .installerFile: String(localized: "Listed in the installer receipt. Review before removing.")
        default: nil
        }
    }
}

enum Formatters {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
