import PlugboardCore
import SwiftUI

/// Lists everything an uninstall or cleanup would remove, grouped by kind, so the user decides
/// item by item. Nothing happens until the primary button is pressed.
@MainActor
struct RemovalSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let plan = model.removalPlan {
            content(plan)
        }
    }

    private func content(_ plan: RemovalPlan) -> some View {
        let selected = plan.selectedEntries
        let bytes = DiskUsageCalculator.reclaimableBytes(of: selected.compactMap(\.usage))
        let categories = Leftover.Category.allCases.filter { category in plan.entries.contains { $0.category == category } }

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let message = plan.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            List {
                ForEach(categories, id: \.self) { category in
                    Section {
                        ForEach(plan.entries.filter { $0.category == category }) { entry in
                            EntryRow(entry: entry, isSelected: binding(for: entry))
                        }
                    } header: {
                        HStack {
                            Text(category.title)
                            Spacer()
                            let entries = plan.entries.filter { $0.category == category }
                            if entries.count > 1 {
                                Button(entries.allSatisfy(\.isSelected) ? String(localized: "Deselect All") : String(localized: "Select All")) {
                                    toggleAll(in: category)
                                }
                                .buttonStyle(.link)
                                .font(.callout)
                            }
                        }
                    } footer: {
                        if let footnote = category.footnote {
                            Text(footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if plan.isLookingUpReceipts {
                    Section("Installer receipts") {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking for installer receipts…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !plan.receipts.isEmpty {
                    Section("Installer receipts") {
                        Toggle(isOn: Binding(
                            get: { model.removalPlan?.forgetsReceipts ?? false },
                            set: { model.removalPlan?.forgetsReceipts = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Forget installer receipts")
                                Text(plan.receipts.map(\.id).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .frame(minHeight: 220)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { model.removalPlan?.mode == .deleteImmediately },
                    set: { model.removalPlan?.mode = $0 ? .deleteImmediately : .moveToTrash }
                )) {
                    Text("Delete immediately instead of moving to the Trash")
                }
                if plan.mode == .deleteImmediately {
                    Label("You can't undo this action.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.multicolor)
                }
                if plan.restartsCoreAudio {
                    Label("Core Audio restarts to unload the driver, so all audio stops for a moment.", systemImage: "speaker.wave.2")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(summary(count: selected.count, bytes: bytes))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        model.removalPlan = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(primaryTitle(plan: plan, count: selected.count), role: plan.mode == .deleteImmediately ? .destructive : nil) {
                        model.performPlan(plan)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty && !(plan.forgetsReceipts && !plan.receipts.isEmpty))
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 460, idealHeight: 560)
    }

    private func binding(for entry: RemovalEntry) -> Binding<Bool> {
        Binding(
            get: { model.removalPlan?.entries.first { $0.id == entry.id }?.isSelected ?? false },
            set: { newValue in
                guard let index = model.removalPlan?.entries.firstIndex(where: { $0.id == entry.id }) else { return }
                model.removalPlan?.entries[index].isSelected = newValue
            }
        )
    }

    private func toggleAll(in category: Leftover.Category) {
        guard let entries = model.removalPlan?.entries else { return }
        let target = !entries.filter { $0.category == category }.allSatisfy(\.isSelected)
        for index in entries.indices where entries[index].category == category {
            model.removalPlan?.entries[index].isSelected = target
        }
    }

    private func summary(count: Int, bytes: Int64) -> String {
        let items = String(localized: "\(count) items selected")
        return bytes > 0 ? "\(items) · \(Formatters.bytes(bytes))" : items
    }

    private func primaryTitle(plan: RemovalPlan, count: Int) -> String {
        plan.mode == .deleteImmediately
            ? String(localized: "Delete \(count) Items")
            : String(localized: "Move \(count) Items to Trash")
    }
}

@MainActor
private struct EntryRow: View {
    let entry: RemovalEntry
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = entry.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                SizeText(bytes: entry.usage?.allocated)
                    .foregroundStyle(.secondary)
            }
        }
        .help(entry.url.path)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        }
    }
}
