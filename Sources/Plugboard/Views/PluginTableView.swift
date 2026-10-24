import PlugboardCore
import SwiftUI

@MainActor
struct PluginTableView: View {
    @Bindable var model: AppModel
    let scope: SidebarItem
    @SceneStorage("PluginTableColumns") private var columns = TableColumnCustomization<PluginRow>()

    var body: some View {
        let rows = model.rows(for: scope)
        VStack(spacing: 0) {
            if case .cleanup(let category) = scope {
                CleanupBanner(model: model, category: category)
                Divider()
            }
            if !model.hasScanned {
                ProgressView("Scanning plug-in folders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A fresh table per list and layout, so new rows and a new selection never
                // arrive in the same update of one NSTableView.
                table(rows)
                    .id(tableIdentity)
            }
        }
    }

    private var tableIdentity: String {
        "\(scope)-\(scope == .all ? model.displayMode.rawValue : "")"
    }

    private func table(_ rows: [PluginRow]) -> some View {
        Table(rows, children: \.children, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                HStack(spacing: 6) {
                    KindIcon(kind: row.kind, isShell: row.isShell)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.name)
                }
            }
            .width(min: 160, ideal: 230)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Vendor", value: \.vendorSort, comparator: .localizedStandard) { row in
                Text(row.vendor ?? "—")
                    .foregroundStyle(row.vendor == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .help(row.vendor ?? "")
            }
            .width(min: 90, ideal: 130)
            .customizationID("vendor")

            TableColumn("Format", value: \.formatSort) { row in
                FormatBadges(formats: row.formats)
            }
            .width(min: 60, ideal: 120)
            .customizationID("format")

            TableColumn("Size", value: \.bytesSort) { row in
                SizeText(bytes: row.bytes)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 76)
            .alignment(.trailing)
            .customizationID("size")

            TableColumn("Type", value: \.kindSort) { row in
                Text(row.isShell ? String(localized: "Shell") : (row.kind == .unknown ? "—" : row.kind.title))
                    .foregroundStyle(row.kind == .unknown && !row.isShell ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 90)
            .customizationID("type")

            TableColumn("Version", value: \.versionSort, comparator: .localizedStandard) { row in
                Text(row.version ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(row.version == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                    .help(row.version ?? "")
            }
            .width(min: 50, ideal: 80)
            .customizationID("version")

            TableColumn("Architecture", value: \.architectureSort) { row in
                ArchitectureLabel(support: row.architecture)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 120)
            .customizationID("architecture")

            TableColumn("Installed", value: \.createdSort) { row in
                DateText(date: row.created).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
            .customizationID("installed")

            TableColumn("Modified", value: \.modifiedSort) { row in
                DateText(date: row.modified).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
            .customizationID("modified")
            .defaultVisibility(.hidden)

            TableColumn("Location", value: \.locationSort) { row in
                Text(row.domains.map(\.title).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 90)
            .customizationID("location")
        }
        .contextMenu(forSelectionType: String.self) { ids in
            PluginActionsMenu(model: model, items: model.resolve(ids))
        } primaryAction: { ids in
            model.revealInFinder(model.resolve(ids))
        }
        .onDeleteCommand {
            model.requestMoveToTrash(model.selectedItems)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if model.hasActiveFilters {
            ContentUnavailableView {
                Label("No plug-ins match these filters", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Choose another location or type to see more.")
            } actions: {
                Button("Clear Filters") {
                    model.locationFilter = .all
                    model.kindFilter = .all
                }
            }
        } else if case .cleanup = scope {
            ContentUnavailableView {
                Label("All clean", systemImage: "checkmark.circle")
            } description: {
                Text("Plugboard found nothing in this category.")
            }
        } else if case .format(let format) = scope {
            ContentUnavailableView {
                Label(format.title, systemImage: format.symbol)
            } description: {
                Text("Plugboard found no plug-ins in this format on this Mac.")
            }
        } else {
            ContentUnavailableView {
                Label("No plug-ins found", systemImage: "puzzlepiece.extension")
            } description: {
                Text("Plugboard looks in every standard plug-in folder. If you keep plug-ins somewhere else, add that folder in Settings.")
            } actions: {
                SettingsLink { Text("Open Settings") }
            }
        }
    }
}

/// The actions shared by the context menu, the inspector and the menu bar.
@MainActor
struct PluginActionsMenu: View {
    let model: AppModel
    let items: [PluginItem]

    var body: some View {
        let removable = model.removable(items)
        Button(items.contains { $0.containingApp != nil } ? String(localized: "Show App in Finder") : String(localized: "Show in Finder")) {
            model.revealInFinder(items)
        }
        Button("Copy Path") { model.copyPaths(items) }
        if !removable.isEmpty {
            Divider()
            Button("Uninstall…") { model.requestUninstall(removable) }
            Button("Move to Trash") { model.requestMoveToTrash(removable) }
            Button("Delete Immediately…", role: .destructive) { model.requestDeleteImmediately(removable) }
        }
    }
}

@MainActor
struct CleanupBanner: View {
    let model: AppModel
    let category: CleanupCategory

    var body: some View {
        let items = model.removable(model.items(in: .cleanup(category)))
        let reclaimable = model.reclaimableBytes(of: items)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: category.symbol)
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(category.headline)
                    .font(.headline)
                Text(category.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if reclaimable > 0 {
                    Text("Removing all of them frees \(Formatters.bytes(reclaimable)).")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            Spacer(minLength: 12)
            if !items.isEmpty {
                Button("Review and Remove…") { model.requestCleanup(category) }
                    .disabled(model.isRemoving)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
