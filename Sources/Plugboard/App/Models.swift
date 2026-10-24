import Foundation
import PlugboardCore

/// What the sidebar can show.
enum SidebarItem: Hashable, Codable {
    case overview
    case all
    case format(PluginFormat)
    case cleanup(CleanupCategory)

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .all: String(localized: "All Plug-ins")
        case .format(let format): format.title
        case .cleanup(let category): category.title
        }
    }

    var isTable: Bool {
        switch self {
        case .overview, .cleanup(.olderWaves): false
        default: true
        }
    }
}

/// "All Plug-ins" can show one row per product with its formats inside, or one row per file.
enum DisplayMode: String, CaseIterable, Identifiable {
    case products
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .products: String(localized: "Plug-ins")
        case .files: String(localized: "Files")
        }
    }
}

enum LocationFilter: String, CaseIterable, Identifiable {
    case all
    case user
    case system
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All Locations")
        case .user: String(localized: "User")
        case .system: String(localized: "System")
        case .other: String(localized: "Apps and Custom Folders")
        }
    }

    func matches(_ domain: InstallDomain) -> Bool {
        switch self {
        case .all: true
        case .user: domain == .user
        case .system: domain == .system
        case .other: domain == .application || domain == .custom
        }
    }
}

enum KindFilter: String, CaseIterable, Identifiable {
    case all
    case instruments
    case effects
    case midi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All Types")
        case .instruments: String(localized: "Instruments")
        case .effects: String(localized: "Effects")
        case .midi: String(localized: "MIDI Effects")
        }
    }

    func matches(_ kind: PluginKind) -> Bool {
        switch self {
        case .all: true
        case .instruments: kind == .instrument || kind == .generator
        case .effects: kind == .effect
        case .midi: kind == .midiEffect
        }
    }
}

/// One table row: a single file, or a product with its formats as children.
struct PluginRow: Identifiable, Hashable {
    let id: String
    let name: String
    let vendor: String?
    let formats: [PluginFormat]
    let kind: PluginKind
    let isShell: Bool
    let version: String?
    let architecture: ArchitectureSupport
    let bytes: Int64?
    let created: Date?
    let modified: Date?
    let domains: [InstallDomain]
    let itemIDs: [String]
    var children: [PluginRow]?

    init(item: PluginItem) {
        id = item.id
        name = item.name
        vendor = item.vendor
        formats = [item.format]
        kind = item.kind
        isShell = item.isShell
        version = item.version
        architecture = item.architectureSupport
        bytes = item.usage?.allocated
        created = item.created
        modified = item.modified
        domains = [item.domain]
        itemIDs = [item.id]
        children = nil
    }

    init(group: ProductGroup) {
        id = group.id
        name = group.name
        vendor = group.vendor
        formats = group.formats
        kind = group.kind
        isShell = group.isShell
        version = group.commonVersion
        architecture = group.architectureSupport
        bytes = group.isFullyMeasured ? group.combinedBytes : nil
        created = group.created
        modified = group.modified
        domains = Array(group.domains).sorted()
        itemIDs = group.items.map(\.id)
        children = group.items.map(PluginRow.init(item:))
    }

    // Comparable keys for the table's sort descriptors.
    var vendorSort: String { vendor ?? "\u{10FFFF}" }
    var formatSort: String { formats.map(\.shortName).joined(separator: " ") }
    var kindSort: String { isShell ? "Shell" : kind.title }
    var versionSort: String { version ?? "" }
    var architectureSort: Int { [.universal, .appleSilicon, .intel, .legacy, .unknown].firstIndex(of: architecture) ?? 9 }
    var bytesSort: Int64 { bytes ?? -1 }
    var createdSort: Date { created ?? .distantPast }
    var modifiedSort: Date { modified ?? .distantPast }
    var locationSort: String { domains.map(\.title).joined(separator: ", ") }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    /// Items a press on Undo puts back.
    var undoItems: [RemovedItem]?

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool { lhs.id == rhs.id }
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum ScanPhase: Equatable {
    case idle
    case discovering
    case reading(done: Int, total: Int)
    case measuring(done: Int, total: Int)

    var isBusy: Bool { self != .idle }
}

/// A line in the removal review sheet.
struct RemovalEntry: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var category: Leftover.Category
    var title: String
    var subtitle: String?
    var isSelected: Bool
    var usage: DiskUsage?
}

/// Everything the review sheet needs to show and do.
struct RemovalPlan: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
    var entries: [RemovalEntry]
    var receipts: [PackageReceipt] = []
    var isLookingUpReceipts = false
    var forgetsReceipts = true
    var mode: RemovalMode = .moveToTrash
    var restartsCoreAudio = false

    var selectedEntries: [RemovalEntry] { entries.filter(\.isSelected) }
}

/// A destructive action waiting for the user's answer.
struct Confirmation: Identifiable {
    enum Action {
        case trash
        case delete
    }

    let id = UUID()
    var action: Action
    var urls: [URL]
    var title: String
    var message: String
    var buttonTitle: String
    var restartsCoreAudio: Bool
}
