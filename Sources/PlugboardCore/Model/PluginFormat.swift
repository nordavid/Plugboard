import Foundation

/// Every kind of audio plug-in or driver bundle Plugboard knows how to find on macOS.
public enum PluginFormat: String, CaseIterable, Codable, Sendable, Hashable, Comparable {
    case audioUnit
    case vst3
    case vst
    case clap
    case aax
    case auv3
    case waves
    case wpapi
    case rtas
    case mas
    case audioDriver
    case midiDriver

    /// Formats a DAW loads, in the order the sidebar lists them.
    public static let pluginFormats: [PluginFormat] = [.audioUnit, .vst3, .vst, .clap, .aax, .auv3, .waves, .wpapi, .mas, .rtas]
    public static let driverFormats: [PluginFormat] = [.audioDriver, .midiDriver]

    public var isDriver: Bool { self == .audioDriver || self == .midiDriver }

    /// The abbreviation people know from DAWs and installers. Not localized.
    public var shortName: String {
        switch self {
        case .audioUnit: "AU"
        case .vst3: "VST3"
        case .vst: "VST"
        case .clap: "CLAP"
        case .aax: "AAX"
        case .auv3: "AUv3"
        case .waves: "Waves"
        case .wpapi: "WPAPI"
        case .rtas: "RTAS"
        case .mas: "MAS"
        case .audioDriver: "HAL"
        case .midiDriver: "MIDI"
        }
    }

    /// File extensions a bundle of this format carries. Empty means any bundle directory.
    public var bundleExtensions: Set<String> {
        switch self {
        case .audioUnit: ["component"]
        case .vst3: ["vst3"]
        case .vst: ["vst"]
        case .clap: ["clap"]
        case .aax: ["aaxplugin"]
        case .auv3: ["appex"]
        case .waves, .wpapi, .mas: ["bundle"]
        case .rtas: ["dpm"]
        case .audioDriver: ["driver", "plugin"]
        case .midiDriver: ["plugin"]
        }
    }

    /// Infers the format from a file extension, for folders the user adds by hand.
    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "component": self = .audioUnit
        case "vst3": self = .vst3
        case "vst": self = .vst
        case "clap": self = .clap
        case "aaxplugin": self = .aax
        case "dpm": self = .rtas
        default: return nil
        }
    }

    /// Whether the user can remove a bundle of this format directly.
    /// AUv3 extensions live inside their app and leave with it.
    public var isRemovable: Bool { self != .auv3 }

    private var sortIndex: Int {
        (Self.pluginFormats + Self.driverFormats).firstIndex(of: self) ?? 99
    }

    public static func < (lhs: PluginFormat, rhs: PluginFormat) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }
}

/// Where a plug-in is installed. Decides who can remove it and whether it needs an administrator.
public enum InstallDomain: String, Codable, Sendable, Hashable, Comparable {
    /// Inside the user's home folder, ~/Library.
    case user
    /// /Library, shared by every account on the Mac.
    case system
    /// Inside an application folder, such as /Applications/Waves or an AUv3's host app.
    case application
    /// A folder the user added in Settings.
    case custom

    public static func < (lhs: InstallDomain, rhs: InstallDomain) -> Bool {
        let order: [InstallDomain] = [.user, .system, .application, .custom]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// What a plug-in does, as far as its metadata tells.
public enum PluginKind: String, Codable, Sendable, Hashable, Comparable {
    case instrument
    case effect
    case midiEffect
    case generator
    case audioDriver
    case midiDriver
    case other
    case unknown

    /// Maps an Audio Unit component type code, such as `aumu`.
    public init(audioUnitType: String) {
        switch audioUnitType {
        case "aumu": self = .instrument
        case "aufx", "aumf", "aupn", "aumx", "auol": self = .effect
        case "aumi": self = .midiEffect
        case "augn": self = .generator
        default: self = .other
        }
    }

    /// Maps VST3 sub-categories such as `["Fx", "EQ"]` or `["Instrument", "Synth"]`.
    public init(vst3SubCategories categories: [String]) {
        let tokens = Set(categories.flatMap { $0.split(separator: "|").map { $0.lowercased() } })
        if tokens.contains("instrument") {
            self = .instrument
        } else if tokens.contains("fx") || tokens.contains("analyzer") || tokens.contains("spatial") {
            self = .effect
        } else if tokens.contains("generator") {
            self = .generator
        } else if tokens.isEmpty {
            self = .unknown
        } else {
            self = .other
        }
    }

    private var sortIndex: Int {
        [.instrument, .effect, .midiEffect, .generator, .other, .audioDriver, .midiDriver, .unknown].firstIndex(of: self) ?? 99
    }

    public static func < (lhs: PluginKind, rhs: PluginKind) -> Bool { lhs.sortIndex < rhs.sortIndex }
}
