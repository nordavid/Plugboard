import Foundation

/// CPU architectures found in a bundle's Mach-O executable.
public struct ArchitectureSet: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let arm64 = ArchitectureSet(rawValue: 1 << 0)
    public static let x86_64 = ArchitectureSet(rawValue: 1 << 1)
    public static let i386 = ArchitectureSet(rawValue: 1 << 2)
    public static let ppc = ArchitectureSet(rawValue: 1 << 3)
}

/// How a plug-in runs on this Mac, derived from its architectures.
public enum ArchitectureSupport: String, Codable, Sendable, Hashable, Comparable {
    /// Native on Apple silicon and Intel.
    case universal
    case appleSilicon
    case intel
    /// 32-bit or PowerPC only. macOS stopped loading these in 10.15.
    case legacy
    /// No executable found, or a format Plugboard can't read.
    case unknown

    public init(_ archs: ArchitectureSet) {
        if archs.contains(.arm64) && archs.contains(.x86_64) {
            self = .universal
        } else if archs.contains(.arm64) {
            self = .appleSilicon
        } else if archs.contains(.x86_64) {
            self = .intel
        } else if !archs.isEmpty {
            self = .legacy
        } else {
            self = .unknown
        }
    }

    private var sortIndex: Int {
        [.universal, .appleSilicon, .intel, .legacy, .unknown].firstIndex(of: self)!
    }

    public static func < (lhs: ArchitectureSupport, rhs: ArchitectureSupport) -> Bool { lhs.sortIndex < rhs.sortIndex }
}

/// Who signed a bundle, read without validating every file.
public struct SignatureInfo: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable {
        case developerID
        case appStore
        case apple
        case adHoc
        case unsigned
        case unknown
    }

    public var status: Status
    /// Organization from the leaf certificate, such as "FabFilter B.V.".
    public var organization: String?
    public var teamID: String?

    public init(status: Status, organization: String? = nil, teamID: String? = nil) {
        self.status = status
        self.organization = organization
        self.teamID = teamID
    }

    public static let unknown = SignatureInfo(status: .unknown)
}

/// One Audio Unit component declared in a bundle's Info.plist.
public struct AudioUnitComponent: Codable, Sendable, Hashable {
    public var type: String
    public var subtype: String
    public var manufacturer: String
    /// Usually "Vendor: Plug-in name".
    public var name: String

    public init(type: String, subtype: String, manufacturer: String, name: String) {
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
        self.name = name
    }

    public var vendorName: String? {
        guard let colon = name.firstIndex(of: ":") else { return nil }
        let vendor = name[..<colon].trimmingCharacters(in: .whitespaces)
        return vendor.isEmpty ? nil : vendor
    }

    public var pluginName: String {
        guard let colon = name.firstIndex(of: ":") else { return name }
        return name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
}

/// One hard-linked file inside a bundle. Waves installs its shells this way, so the same
/// bytes appear under /Applications/Waves and in every plug-in folder.
public struct HardLink: Codable, Sendable, Hashable {
    public var device: Int32
    public var inode: UInt64
    public var bytes: Int64
    public var linkCount: Int

    public init(device: Int32, inode: UInt64, bytes: Int64, linkCount: Int) {
        self.device = device
        self.inode = inode
        self.bytes = bytes
        self.linkCount = linkCount
    }

    public struct Key: Hashable, Sendable {
        public var device: Int32
        public var inode: UInt64
    }

    public var key: Key { Key(device: device, inode: inode) }
}

/// Disk usage of a bundle on disk.
public struct DiskUsage: Codable, Sendable, Hashable {
    /// Allocated bytes of every file, including hard-linked ones.
    public var allocated: Int64
    public var fileCount: Int
    public var hardLinks: [HardLink]

    public init(allocated: Int64, fileCount: Int, hardLinks: [HardLink] = []) {
        self.allocated = allocated
        self.fileCount = fileCount
        self.hardLinks = hardLinks
    }

    public static let zero = DiskUsage(allocated: 0, fileCount: 0)

    public var hardLinkedBytes: Int64 { hardLinks.reduce(0) { $0 + $1.bytes } }
    public var exclusiveBytes: Int64 { allocated - hardLinkedBytes }
}

/// A single plug-in bundle on disk.
public struct PluginItem: Identifiable, Codable, Sendable, Hashable {
    /// The absolute path. Stable across scans as long as the bundle stays put.
    public var id: String { url.path }

    public var url: URL
    public var format: PluginFormat
    public var domain: InstallDomain
    /// The file name without its extension, as Finder and most DAWs show it.
    public var name: String
    public var bundleIdentifier: String?
    public var version: String?
    public var vendor: String?
    /// Vendor read straight from plug-in metadata, before any inference.
    public var declaredVendor: String?
    public var kind: PluginKind
    public var architectures: ArchitectureSet
    public var signature: SignatureInfo
    public var minimumSystemVersion: String?
    public var created: Date?
    public var modified: Date?
    public var usage: DiskUsage?
    public var audioUnitComponents: [AudioUnitComponent]
    /// Number of plug-ins the bundle exposes. Above 1 for shells such as Waves.
    public var pluginCount: Int
    public var isShell: Bool
    /// The bundle is a symbolic link to somewhere else.
    public var symlinkDestination: URL?
    /// For AUv3 extensions, the app that contains it.
    public var containingApp: URL?
    /// Pro Tools' own "Plug-Ins (Unused)" folder, which it skips.
    public var isInUnusedFolder: Bool
    /// The Waves major version, such as 14, for shells and Waves plug-in bundles.
    public var wavesMajorVersion: Int?

    /// Groups the formats of one product, such as the AU, VST3 and AAX of "Pro-Q 4".
    public var productKey: String = ""

    public init(
        url: URL,
        format: PluginFormat,
        domain: InstallDomain,
        name: String,
        bundleIdentifier: String? = nil,
        version: String? = nil,
        vendor: String? = nil,
        kind: PluginKind = .unknown,
        architectures: ArchitectureSet = [],
        signature: SignatureInfo = .unknown,
        minimumSystemVersion: String? = nil,
        created: Date? = nil,
        modified: Date? = nil,
        usage: DiskUsage? = nil,
        audioUnitComponents: [AudioUnitComponent] = [],
        pluginCount: Int = 1,
        isShell: Bool = false,
        symlinkDestination: URL? = nil,
        containingApp: URL? = nil,
        isInUnusedFolder: Bool = false,
        wavesMajorVersion: Int? = nil
    ) {
        self.url = url
        self.format = format
        self.domain = domain
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.vendor = vendor
        self.declaredVendor = vendor
        self.kind = kind
        self.architectures = architectures
        self.signature = signature
        self.minimumSystemVersion = minimumSystemVersion
        self.created = created
        self.modified = modified
        self.usage = usage
        self.audioUnitComponents = audioUnitComponents
        self.pluginCount = pluginCount
        self.isShell = isShell
        self.symlinkDestination = symlinkDestination
        self.containingApp = containingApp
        self.isInUnusedFolder = isInUnusedFolder
        self.wavesMajorVersion = wavesMajorVersion
    }

    public var architectureSupport: ArchitectureSupport {
        if symlinkDestination != nil && architectures.isEmpty { return .unknown }
        return ArchitectureSupport(architectures)
    }

    public var sizeBytes: Int64? { usage?.allocated }

    // Non-optional keys for sorting in tables.
    public var sortName: String { name }
    public var sortVendor: String { vendor ?? "\u{10FFFF}" }
    public var sortVersion: String { version ?? "" }
    public var sortSize: Int64 { usage?.allocated ?? -1 }
    public var sortCreated: Date { created ?? .distantPast }
    public var sortModified: Date { modified ?? .distantPast }
}
