import AppKit
import Observation
import PlugboardCore
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppModel {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "app.plugboard.Plugboard"

    // MARK: Data

    private(set) var items: [PluginItem] = []
    private(set) var itemsByID: [String: PluginItem] = [:]
    private(set) var groups: [ProductGroup] = []
    private(set) var groupsByID: [String: ProductGroup] = [:]
    private(set) var groupsByKey: [String: ProductGroup] = [:]
    private(set) var cleanup: CleanupReport = .empty
    private(set) var daws: [DAW] = []
    /// Disk usage of Waves version folders under /Applications/Waves, by path.
    private(set) var folderUsage: [String: DiskUsage] = [:]
    private(set) var phase: ScanPhase = .idle
    private(set) var hasScanned = false
    private(set) var isRemoving = false

    // MARK: UI state

    var sidebarSelection: SidebarItem? = .overview {
        didSet {
            // Deferred: changing the table's selection while the sidebar's outline view is still
            // handling the click is a reentrant table update.
            if oldValue != sidebarSelection { Task { self.pruneSelection() } }
        }
    }
    var selection: Set<String> = []
    var searchText = ""
    var displayMode: DisplayMode = .products {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: Keys.displayMode)
            if oldValue != displayMode { translateSelection(to: displayMode) }
        }
    }
    var locationFilter: LocationFilter = .all
    var kindFilter: KindFilter = .all
    var sortOrder: [KeyPathComparator<PluginRow>] = [KeyPathComparator(\PluginRow.name, comparator: .localizedStandard)]
    var isInspectorPresented = true {
        didSet { UserDefaults.standard.set(isInspectorPresented, forKey: Keys.inspector) }
    }
    var toast: ToastMessage?
    var alert: AlertMessage?
    var removalPlan: RemovalPlan?
    var confirmation: Confirmation?
    var confirmsCacheReset = false

    // MARK: Settings

    var customFolders: [URL] = [] {
        didSet {
            UserDefaults.standard.set(customFolders.map(\.path), forKey: Keys.customFolders)
            restartWatcher()
        }
    }
    var asksBeforeTrash = false {
        didSet { UserDefaults.standard.set(asksBeforeTrash, forKey: Keys.asksBeforeTrash) }
    }
    var watchesFolders = true {
        didSet {
            UserDefaults.standard.set(watchesFolders, forKey: Keys.watchesFolders)
            restartWatcher()
        }
    }

    weak var undoManager: UndoManager?

    private enum Keys {
        static let customFolders = "customFolders"
        static let asksBeforeTrash = "asksBeforeTrash"
        static let watchesFolders = "watchesFolders"
        static let displayMode = "displayMode"
        static let inspector = "showsInspector"
    }

    private let cache: ScanCache
    private let scanner: PluginScanner
    private var watcher: FolderWatcher?
    private var pendingRescan: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var rescanWhenDone = false
    private var started = false

    /// Folders scanned for this session only, never saved. Used by the snapshot runner.
    var temporaryFolders: [URL] = []

    init() {
        cache = ScanCache(fileURL: ScanCache.defaultURL(bundleIdentifier: Self.bundleIdentifier))
        scanner = PluginScanner(cache: cache)

        let defaults = UserDefaults.standard
        customFolders = (defaults.stringArray(forKey: Keys.customFolders) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        asksBeforeTrash = defaults.bool(forKey: Keys.asksBeforeTrash)
        watchesFolders = defaults.object(forKey: Keys.watchesFolders) as? Bool ?? true
        displayMode = DisplayMode(rawValue: defaults.string(forKey: Keys.displayMode) ?? "") ?? .products
        isInspectorPresented = defaults.object(forKey: Keys.inspector) as? Bool ?? true
    }

    func start() {
        guard !started else { return }
        started = true
        restartWatcher()
        rescan()
    }

    // MARK: Locations

    var standardLocations: [ScanLocation] { ScanLocation.standard() }

    var customLocations: [ScanLocation] {
        (customFolders + temporaryFolders).map { ScanLocation(url: $0, format: nil, domain: .custom, maxDepth: 5) }
    }

    var allLocations: [ScanLocation] { standardLocations + customLocations }

    var removalPolicy: RemovalPolicy { RemovalPolicy(locations: allLocations) }

    // MARK: Scanning

    /// Starts a scan, or queues one if a scan is already running, so two never overlap.
    func rescan() {
        if phase.isBusy {
            rescanWhenDone = true
            return
        }
        scanTask = Task {
            await scan()
            if rescanWhenDone {
                rescanWhenDone = false
                rescan()
            }
        }
    }

    private func scan() async {
        phase = .discovering
        let scanner = self.scanner
        let locations = allLocations

        let candidates = await Task.detached(priority: .userInitiated) { scanner.discover(in: locations) }.value
        phase = .reading(done: 0, total: candidates.count)

        let progress = ProgressRelay { [weak self] done, total in
            guard let self, case .reading = self.phase else { return }
            self.phase = .reading(done: done, total: total)
        }
        var scanned = await scanner.read(candidates) { done, total in progress.report(done, total) }
        scanned += await Task.detached(priority: .userInitiated) { scanner.discoverAppExtensions() }.value
        let processed = Catalog.process(scanned)
        let detected = await Task.detached(priority: .userInitiated) { DAWDetector.detect() }.value

        daws = detected
        apply(processed)
        hasScanned = true

        await measureSizes()
        await measureWavesFolders()
        cache.save(keeping: Set(items.map(\.id)))
        phase = .idle
    }

    private func measureSizes() async {
        let pending = items.filter { $0.usage == nil }
        guard !pending.isEmpty else { return }
        phase = .measuring(done: 0, total: pending.count)

        // Results arrive from many threads. Collect them and fold them in a few times a second,
        // so 1,000 bundles don't mean 1,000 table reloads.
        let buffer = UsageBuffer()
        let flusher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                self?.applyUsage(buffer.drain(), pendingTotal: pending.count)
            }
        }
        await scanner.measure(pending) { id, usage in buffer.add(id, usage) }
        flusher.cancel()
        applyUsage(buffer.drain(), pendingTotal: pending.count)
    }

    private func applyUsage(_ results: [(String, DiskUsage)], pendingTotal: Int) {
        guard !results.isEmpty else { return }
        for (id, usage) in results {
            itemsByID[id]?.usage = usage
        }
        items = items.map { itemsByID[$0.id] ?? $0 }
        rebuildGroups()
        if case .measuring(let done, let total) = phase {
            phase = .measuring(done: min(total, done + results.count), total: total)
        }
    }

    private func measureWavesFolders() async {
        let folders = cleanup.wavesVersions.flatMap(\.folders)
        guard !folders.isEmpty else { return }
        let measured = await concurrentMap(folders, maxConcurrency: 2) { url in (url.path, DiskUsageCalculator.usage(of: url)) }
        folderUsage = Dictionary(measured, uniquingKeysWith: { first, _ in first })
    }

    private func apply(_ newItems: [PluginItem]) {
        items = newItems.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rebuildGroups()
        cleanup = CleanupAnalyzer.analyze(items, daws: daws)
        selection = selection.filter { itemsByID[$0] != nil || groupsByID[$0] != nil }
    }

    private func rebuildGroups() {
        groups = Catalog.groups(items)
        groupsByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groupsByKey = Dictionary(groups.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        // Waves version cards need the measured shells.
        if !cleanup.wavesVersions.isEmpty {
            cleanup.wavesVersions = cleanup.wavesVersions.map { version in
                var version = version
                version.shells = version.shells.map { itemsByID[$0.id] ?? $0 }
                version.plugins = version.plugins.map { itemsByID[$0.id] ?? $0 }
                return version
            }
        }
    }

    // MARK: Folder watching

    private func restartWatcher() {
        guard started else { return }
        watcher?.stop()
        watcher = nil
        guard watchesFolders else { return }
        let owner = WeakReference(self)
        let watcher = FolderWatcher {
            Task { @MainActor in owner.value?.scheduleRescan() }
        }
        watcher.watch(ScanLocation.watchRoots(for: allLocations))
        self.watcher = watcher
    }

    private func scheduleRescan() {
        guard !isRemoving else { return }
        pendingRescan?.cancel()
        pendingRescan = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !phase.isBusy, !isRemoving else { return }
            rescan()
        }
    }

    // MARK: Queries

    func items(in scope: SidebarItem?) -> [PluginItem] {
        switch scope ?? .overview {
        case .overview, .all:
            return items.filter { !$0.format.isDriver }
        case .format(let format):
            return items.filter { $0.format == format }
        case .cleanup(let category):
            let ids = cleanup.ids(for: category)
            return items.filter { ids.contains($0.id) }
        }
    }

    func count(for scope: SidebarItem) -> Int {
        switch scope {
        case .cleanup(.olderWaves): olderWavesVersions.count
        case .all: Set(items(in: .all).map(\.productKey)).count
        default: items(in: scope).count
        }
    }

    /// Keeps the same plug-ins selected when rows switch between products and files.
    private func translateSelection(to mode: DisplayMode) {
        switch mode {
        case .files:
            selection = Set(resolve(selection).map(\.id))
        case .products:
            selection = Set(resolve(selection).map { item in
                guard let group = group(for: item), group.items.count > 1 else { return item.id }
                return group.id
            })
        }
    }

    /// Keeps only selected rows that the current list still shows.
    private func pruneSelection() {
        let visible = Set(items(in: sidebarSelection).map(\.id))
        selection = selection.filter { id in
            if let group = groupsByID[id] { return group.items.contains { visible.contains($0.id) } }
            return visible.contains(id)
        }
    }

    var olderWavesVersions: [WavesVersion] { cleanup.wavesVersions.filter { !$0.isNewest } }

    /// Cleanup categories that can ever have something in them on this Mac. They stay in the
    /// sidebar when empty, so the feature is visible. Intel only needs Apple silicon, unused AAX
    /// needs a Mac without Pro Tools and older Waves versions need Waves.
    var applicableCleanupCategories: [CleanupCategory] {
        CleanupCategory.allCases.filter { category in
            switch category {
            case .intelOnly: cleanup.intelCategoryApplies
            case .unusedAAX: cleanup.aaxCategoryApplies
            case .olderWaves: !cleanup.wavesVersions.isEmpty
            default: true
            }
        }
    }

    /// Cleanup categories with something in them right now.
    var activeCleanupCategories: [CleanupCategory] {
        applicableCleanupCategories.filter { count(for: .cleanup($0)) > 0 }
    }

    var visibleFormats: [PluginFormat] {
        let present = Set(items.map(\.format))
        return PluginFormat.pluginFormats.filter(present.contains)
    }

    var visibleDriverFormats: [PluginFormat] {
        let present = Set(items.map(\.format))
        return PluginFormat.driverFormats.filter(present.contains)
    }

    var showsGrouping: Bool { sidebarSelection == .all }
    var hasActiveFilters: Bool { locationFilter != .all || kindFilter != .all }

    func filteredItems(in scope: SidebarItem?) -> [PluginItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return items(in: scope).filter { item in
            locationFilter.matches(item.domain)
                && kindFilter.matches(item.kind)
                && (query.isEmpty || Self.matches(item, query: query))
        }
    }

    static func matches(_ item: PluginItem, query: String) -> Bool {
        let fields = [item.name, item.vendor ?? "", item.format.shortName, item.bundleIdentifier ?? ""]
        if fields.contains(where: { $0.localizedStandardContains(query) }) { return true }
        // Finds a Waves plug-in inside its shell, such as "CLA-76" in "WaveShell1-AU 16.0".
        return item.audioUnitComponents.contains { $0.pluginName.localizedStandardContains(query) }
    }

    func rows(for scope: SidebarItem?) -> [PluginRow] {
        let filtered = filteredItems(in: scope)
        var rows: [PluginRow]
        if scope == .all && displayMode == .products {
            let keys = Set(filtered.map(\.productKey))
            let visibleIDs = Set(filtered.map(\.id))
            rows = keys.compactMap { key -> PluginRow? in
                guard var group = groupsByKey[key] else { return nil }
                group.items = group.items.filter { visibleIDs.contains($0.id) }
                guard !group.items.isEmpty else { return nil }
                return group.items.count == 1 ? PluginRow(item: group.items[0]) : PluginRow(group: group)
            }
        } else {
            rows = filtered.map(PluginRow.init(item:))
        }
        rows.sort(using: sortOrder)
        for index in rows.indices where rows[index].children != nil {
            rows[index].children?.sort(using: sortOrder)
        }
        return rows
    }

    /// Resolves selected row IDs, which may name products, to the files behind them.
    func resolve(_ ids: Set<String>) -> [PluginItem] {
        var seen = Set<String>()
        var result: [PluginItem] = []
        for id in ids.sorted() {
            let members = groupsByID[id]?.items ?? itemsByID[id].map { [$0] } ?? []
            for item in members where seen.insert(item.id).inserted {
                result.append(item)
            }
        }
        return result
    }

    var selectedItems: [PluginItem] { resolve(selection) }

    func group(for item: PluginItem) -> ProductGroup? { groupsByKey[item.productKey] }

    func bytes(of items: [PluginItem]) -> Int64 {
        DiskUsageCalculator.combinedBytes(of: items.compactMap(\.usage))
    }

    func reclaimableBytes(of items: [PluginItem]) -> Int64 {
        DiskUsageCalculator.reclaimableBytes(of: items.compactMap(\.usage))
    }

    func bytes(of version: WavesVersion) -> Int64? {
        let folderUsages = version.folders.compactMap { folderUsage[$0.path] }
        guard folderUsages.count == version.folders.count else { return nil }
        let shellsOutsideFolders = version.shells.filter { shell in !version.folders.contains { shell.url.path.hasPrefix($0.path + "/") } }
        return DiskUsageCalculator.reclaimableBytes(of: folderUsages + shellsOutsideFolders.compactMap(\.usage))
    }

    // MARK: Simple actions

    func select(_ item: PluginItem) {
        if sidebarSelection == .overview || !(sidebarSelection.map { items(in: $0).contains { $0.id == item.id } } ?? false) {
            sidebarSelection = .all
        }
        if sidebarSelection == .all && displayMode == .products, let group = group(for: item), group.items.count > 1 {
            selection = [group.id]
        } else {
            selection = [item.id]
        }
        isInspectorPresented = true
    }

    func revealInFinder(_ items: [PluginItem]) {
        let urls = items.map { $0.containingApp ?? $0.url }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copyPaths(_ items: [PluginItem]) {
        guard !items.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(\.url.path).joined(separator: "\n"), forType: .string)
    }

    // MARK: Removal requests

    func removable(_ items: [PluginItem]) -> [PluginItem] {
        items.filter { $0.format.isRemovable }
    }

    func requestMoveToTrash(_ selected: [PluginItem]) {
        let targets = removable(selected)
        guard !targets.isEmpty else { return }
        let hasDrivers = targets.contains { $0.format.isDriver }
        if asksBeforeTrash || hasDrivers || targets.count >= 10 {
            confirmation = Confirmation(
                action: .trash,
                urls: targets.map(\.url),
                title: targets.count == 1
                    ? String(localized: "Move “\(targets[0].name)” to the Trash?")
                    : String(localized: "Move \(targets.count) plug-ins to the Trash?"),
                message: confirmationMessage(for: targets, deleting: false),
                buttonTitle: String(localized: "Move to Trash"),
                restartsCoreAudio: hasDrivers
            )
        } else {
            Task { await perform(urls: targets.map(\.url), mode: .moveToTrash, restartsCoreAudio: false) }
        }
    }

    func requestDeleteImmediately(_ selected: [PluginItem]) {
        let targets = removable(selected)
        guard !targets.isEmpty else { return }
        let hasDrivers = targets.contains { $0.format.isDriver }
        confirmation = Confirmation(
            action: .delete,
            urls: targets.map(\.url),
            title: targets.count == 1
                ? String(localized: "Delete “\(targets[0].name)” immediately?")
                : String(localized: "Delete \(targets.count) plug-ins immediately?"),
            message: confirmationMessage(for: targets, deleting: true),
            buttonTitle: String(localized: "Delete"),
            restartsCoreAudio: hasDrivers
        )
    }

    private func confirmationMessage(for targets: [PluginItem], deleting: Bool) -> String {
        var parts: [String] = []
        let bytes = reclaimableBytes(of: targets)
        if deleting {
            parts.append(String(localized: "You can't undo this action."))
        } else {
            parts.append(String(localized: "You can put them back with Undo or from the Trash."))
        }
        if bytes > 0 {
            parts.append(String(localized: "Frees \(Formatters.bytes(bytes))."))
        }
        if targets.contains(where: { $0.format.isDriver }) {
            parts.append(String(localized: "Core Audio restarts to unload the driver, so all audio stops for a moment."))
        }
        return parts.joined(separator: " ")
    }

    func confirm(_ confirmation: Confirmation) {
        self.confirmation = nil
        let mode: RemovalMode = confirmation.action == .delete ? .deleteImmediately : .moveToTrash
        Task { await perform(urls: confirmation.urls, mode: mode, restartsCoreAudio: confirmation.restartsCoreAudio) }
    }

    /// Opens the review sheet for a full uninstall: every format plus settings, caches,
    /// presets and support files that belong to the selected products.
    func requestUninstall(_ selected: [PluginItem]) {
        let targets = removable(selected)
        guard !targets.isEmpty else { return }
        let productKeys = Set(targets.map(\.productKey))
        let products = productKeys.compactMap { groupsByKey[$0] }
        let bundles = products.flatMap(\.items).filter(\.format.isRemovable)

        let title: String
        if products.count == 1 {
            title = String(localized: "Uninstall “\(products[0].name)”")
        } else {
            title = String(localized: "Uninstall \(products.count) plug-ins")
        }

        var entries = bundles.map { item in
            RemovalEntry(
                url: item.url,
                category: .pluginBundle,
                title: item.url.lastPathComponent,
                subtitle: [item.format.shortName, item.version, item.domain.title].compactMap { $0 }.joined(separator: " · "),
                isSelected: true,
                usage: item.usage
            )
        }
        let finder = LeftoverFinder()
        for product in products {
            for leftover in finder.leftovers(for: product) where !entries.contains(where: { $0.url == leftover.url }) {
                entries.append(RemovalEntry(
                    url: leftover.url,
                    category: leftover.category,
                    title: leftover.url.lastPathComponent,
                    subtitle: (leftover.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                    isSelected: leftover.isSelectedByDefault,
                    usage: nil
                ))
            }
        }

        var plan = RemovalPlan(
            title: title,
            message: String(localized: "Choose what to remove. Plugboard moves everything to the Trash unless you choose to delete it immediately."),
            entries: entries.sorted { ($0.category, $0.title) < ($1.category, $1.title) }
        )
        plan.restartsCoreAudio = bundles.contains { $0.format.isDriver }
        plan.isLookingUpReceipts = products.count <= 5
        removalPlan = plan
        loadDetails(for: plan, bundles: bundles)
    }

    /// Opens the review sheet for every plug-in in a cleanup category, bundles only.
    /// Leftovers stay, since removing a VST2 copy must not take the VST3 version's presets.
    func requestCleanup(_ category: CleanupCategory) {
        let targets = removable(items(in: .cleanup(category)))
        guard !targets.isEmpty else { return }
        let entries = targets.map { item in
            RemovalEntry(
                url: item.url,
                category: .pluginBundle,
                title: item.url.lastPathComponent,
                subtitle: [item.vendor, item.format.shortName, item.version].compactMap { $0 }.joined(separator: " · "),
                isSelected: true,
                usage: item.usage
            )
        }
        removalPlan = RemovalPlan(
            title: category.headline,
            message: category.explanation,
            entries: entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        )
    }

    func requestRemoval(of version: WavesVersion) {
        let insideFolders = { (url: URL) in version.folders.contains { url.path.hasPrefix($0.path + "/") } }
        var entries = version.folders.map { folder in
            RemovalEntry(
                url: folder,
                category: .pluginBundle,
                title: folder.lastPathComponent,
                subtitle: (folder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                isSelected: true,
                usage: folderUsage[folder.path]
            )
        }
        entries += version.shells.filter { !insideFolders($0.url) }.map { shell in
            RemovalEntry(
                url: shell.url,
                category: .pluginBundle,
                title: shell.url.lastPathComponent,
                subtitle: (shell.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                isSelected: true,
                usage: shell.usage
            )
        }
        removalPlan = RemovalPlan(
            title: String(localized: "Remove Waves V\(version.major)"),
            message: CleanupCategory.olderWaves.explanation,
            entries: entries.sorted { ($0.category, $0.title) < ($1.category, $1.title) }
        )
    }

    private func loadDetails(for plan: RemovalPlan, bundles: [PluginItem]) {
        let planID = plan.id
        let leftoverURLs = plan.entries.filter { $0.category != .pluginBundle }.map(\.url)
        let knownPaths = Set(plan.entries.map(\.url.path))
        let policy = removalPolicy
        let lookUpReceipts = plan.isLookingUpReceipts

        Task {
            let sizes = await concurrentMap(leftoverURLs, maxConcurrency: 4) { url in (url.path, DiskUsageCalculator.usage(of: url)) }
            if removalPlan?.id == planID {
                let byPath = Dictionary(sizes, uniquingKeysWith: { first, _ in first })
                for index in removalPlan!.entries.indices where removalPlan!.entries[index].usage == nil {
                    removalPlan!.entries[index].usage = byPath[removalPlan!.entries[index].url.path]
                }
            }
            guard lookUpReceipts else { return }
            let receipts = await PackageReceipts.receipts(for: bundles.map(\.url), excluding: knownPaths, policy: policy)
            guard removalPlan?.id == planID else { return }
            removalPlan!.receipts = receipts
            removalPlan!.isLookingUpReceipts = false
            for receipt in receipts {
                for url in receipt.otherFiles where !removalPlan!.entries.contains(where: { $0.url == url }) {
                    removalPlan!.entries.append(RemovalEntry(
                        url: url,
                        category: .installerFile,
                        title: url.lastPathComponent,
                        subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                        isSelected: false,
                        usage: DiskUsageCalculator.usage(of: url)
                    ))
                }
            }
        }
    }

    func performPlan(_ plan: RemovalPlan) {
        removalPlan = nil
        let urls = plan.selectedEntries.map(\.url)
        let receipts = plan.forgetsReceipts ? plan.receipts.map(\.id) : []
        guard !urls.isEmpty || !receipts.isEmpty else { return }
        Task {
            await perform(urls: urls, mode: plan.mode, receipts: receipts, restartsCoreAudio: plan.restartsCoreAudio)
        }
    }

    // MARK: Performing

    func perform(urls: [URL], mode: RemovalMode, receipts: [String] = [], restartsCoreAudio: Bool) async {
        isRemoving = true
        defer { isRemoving = false }

        let remover = FileRemover(policy: removalPolicy)
        let prompt = mode == .moveToTrash
            ? String(localized: "Plugboard needs your password to move plug-ins installed for all users to the Trash.")
            : String(localized: "Plugboard needs your password to delete plug-ins installed for all users.")
        let request = RemovalRequest(urls: urls, mode: mode, receiptsToForget: receipts, restartsCoreAudio: restartsCoreAudio, prompt: prompt)
        let result = await remover.perform(request)

        if !result.removed.isEmpty {
            let count = result.removed.count
            let text = mode == .moveToTrash
                ? String(localized: "Moved \(count) items to the Trash")
                : String(localized: "Deleted \(count) items")
            let undoable = mode == .moveToTrash ? result.removed : nil
            show(ToastMessage(text: text, undoItems: undoable))
            if let undoable { registerUndo(undoable) }
            selection = []
        }
        if !result.failures.isEmpty {
            alert = failureAlert(result.failures, mode: mode)
        }
        if !result.removed.isEmpty || !result.forgottenReceipts.isEmpty {
            rescan()
        }
    }

    private func registerUndo(_ removed: [RemovedItem]) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.startRestore(removed) }
        }
        undoManager.setActionName(String(localized: "Move to Trash"))
    }

    private func startRestore(_ removed: [RemovedItem]) {
        Task { await restore(removed, fromUndoManager: true) }
    }

    func restore(_ removed: [RemovedItem], fromUndoManager: Bool = false) async {
        if !fromUndoManager { undoManager?.removeAllActions(withTarget: self) }
        toast = nil
        isRemoving = true
        defer { isRemoving = false }

        let remover = FileRemover(policy: removalPolicy)
        let result = await remover.restore(removed, prompt: String(localized: "Plugboard needs your password to put plug-ins back in the shared Library folder."))
        if !result.removed.isEmpty {
            show(ToastMessage(text: String(localized: "Put back \(result.removed.count) items"), undoItems: nil))
        }
        if !result.failures.isEmpty {
            alert = AlertMessage(
                title: String(localized: "Couldn't put back \(result.failures.count) items"),
                message: String(localized: "They may have been removed from the Trash. Check the Trash in Finder.")
            )
        }
        rescan()
    }

    private func failureAlert(_ failures: [RemovalFailure], mode: RemovalMode) -> AlertMessage {
        let lines = failures.prefix(6).map { failure in
            "\(failure.url.lastPathComponent): \(reasonText(failure.reason))"
        }
        var message = lines.joined(separator: "\n")
        if failures.count > 6 {
            message += "\n" + String(localized: "And \(failures.count - 6) more.")
        }
        let title = mode == .moveToTrash
            ? String(localized: "Couldn't move \(failures.count) items to the Trash")
            : String(localized: "Couldn't delete \(failures.count) items")
        return AlertMessage(title: title, message: message)
    }

    private func reasonText(_ reason: RemovalFailure.Reason) -> String {
        switch reason {
        case .notAllowed:
            String(localized: "Plugboard only removes items inside plug-in and support folders.")
        case .missing:
            String(localized: "It was already moved or deleted.")
        case .inUse:
            String(localized: "An app is using it. Quit your DAW and try again.")
        case .appManagementBlocked:
            String(localized: "macOS blocked changes inside Applications. Allow Plugboard in System Settings > Privacy & Security > App Management, then try again.")
        case .other(let message):
            message.isEmpty ? String(localized: "Quit any DAW that might be using it, then try again.") : message
        }
    }

    private func show(_ message: ToastMessage) {
        withAnimation(.snappy(duration: 0.2)) { toast = message }
        NSAccessibility.post(
            element: NSApp.mainWindow as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message.text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    func dismissToast() {
        withAnimation(.snappy(duration: 0.15)) { toast = nil }
    }

    // MARK: Export

    func export(_ items: [PluginItem]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = String(localized: "Plug-ins") + ".csv"
        panel.canCreateDirectories = true
        let exporter = Self.csvExporter()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exporter.data(for: items).write(to: url, options: .atomic)
            show(ToastMessage(text: String(localized: "Exported \(items.count) plug-ins"), undoItems: nil))
        } catch {
            alert = AlertMessage(
                title: String(localized: "Couldn't export the list"),
                message: String(localized: "Choose a folder you can write to, such as Documents, and try again.")
            )
        }
    }

    static func csvExporter() -> CSVExporter {
        let day: @Sendable (Date?) -> String = { date in
            date.map { $0.formatted(.iso8601.year().month().day()) } ?? ""
        }
        return CSVExporter(columns: [
            .init(title: String(localized: "Name")) { $0.name },
            .init(title: String(localized: "Vendor")) { $0.vendor ?? "" },
            .init(title: String(localized: "Format")) { $0.format.shortName },
            .init(title: String(localized: "Type")) { $0.isShell ? "Shell" : $0.kind.title },
            .init(title: String(localized: "Version")) { $0.version ?? "" },
            .init(title: String(localized: "Architecture")) { $0.architectureSupport.title },
            .init(title: String(localized: "Size (bytes)")) { $0.usage.map { String($0.allocated) } ?? "" },
            .init(title: String(localized: "Installed")) { day($0.created) },
            .init(title: String(localized: "Modified")) { day($0.modified) },
            .init(title: String(localized: "Location")) { $0.domain.title },
            .init(title: String(localized: "Path")) { $0.url.path },
            .init(title: String(localized: "Bundle ID")) { $0.bundleIdentifier ?? "" },
            .init(title: String(localized: "Signed By")) { $0.signature.title },
        ])
    }

    // MARK: Tools

    func resetAudioUnitCache() {
        do {
            try AudioUnitCache.reset()
            show(ToastMessage(text: String(localized: "Audio Unit cache reset. Logic Pro rescans plug-ins on its next launch."), undoItems: nil))
        } catch {
            alert = AlertMessage(
                title: String(localized: "Couldn't reset the Audio Unit cache"),
                message: String(localized: "Quit Logic Pro and GarageBand, then try again.")
            )
        }
    }

    func addCustomFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add Folder")
        panel.message = String(localized: "Choose folders where you keep plug-ins outside the standard locations.")
        guard panel.runModal() == .OK else { return }
        let existing = Set(customFolders.map(\.path))
        customFolders += panel.urls.filter { !existing.contains($0.path) }
        rescan()
    }

    func removeCustomFolder(_ url: URL) {
        customFolders.removeAll { $0 == url }
        rescan()
    }
}

/// Lets a background callback reach the model without keeping it alive.
private final class WeakReference<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?
    init(_ value: Object) { self.value = value }
}

/// Forwards progress from background threads to the main actor, at most ~10 times a second.
private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport = Date.distantPast
    private let handler: @MainActor (Int, Int) -> Void

    init(handler: @escaping @MainActor (Int, Int) -> Void) {
        self.handler = handler
    }

    func report(_ done: Int, _ total: Int) {
        lock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastReport) > 0.1 || done == total
        if due { lastReport = now }
        lock.unlock()
        guard due else { return }
        Task { @MainActor in handler(done, total) }
    }
}

private final class UsageBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [(String, DiskUsage)] = []

    func add(_ id: String, _ usage: DiskUsage) {
        lock.lock()
        results.append((id, usage))
        lock.unlock()
    }

    func drain() -> [(String, DiskUsage)] {
        lock.lock()
        defer { lock.unlock() }
        let drained = results
        results = []
        return drained
    }
}
