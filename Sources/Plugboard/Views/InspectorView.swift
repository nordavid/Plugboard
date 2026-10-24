import PlugboardCore
import SwiftUI

@MainActor
struct InspectorView: View {
    let model: AppModel

    var body: some View {
        let selected = model.selectedItems
        Group {
            if selected.isEmpty {
                ContentUnavailableView {
                    Label("No selection", systemImage: "sidebar.trailing")
                } description: {
                    Text("Select a plug-in to see where it's installed and what it contains.")
                }
            } else if selected.count == 1 {
                ItemInspector(model: model, item: selected[0])
            } else if model.selection.count == 1, let id = model.selection.first, let group = model.groupsByID[id] {
                ProductInspector(model: model, group: group)
            } else {
                MultipleInspector(model: model, items: selected)
            }
        }
        .frame(minWidth: 260)
    }
}

// MARK: - Single file

@MainActor
private struct ItemInspector: View {
    let model: AppModel
    let item: PluginItem

    var body: some View {
        Form {
            Section {
                InspectorHeader(
                    name: item.name,
                    vendor: item.vendor,
                    kind: item.kind,
                    format: item.format,
                    formats: [item.format],
                    isShell: item.isShell
                )
            }

            WarningsSection(model: model, items: [item])

            Section("Details") {
                LabeledContent("Version", value: item.version ?? "—")
                LabeledContent("Type", value: item.isShell ? String(localized: "Shell") : (item.kind == .unknown ? "—" : item.kind.title))
                LabeledContent("Architecture") {
                    ArchitectureLabel(support: item.architectureSupport)
                }
                LabeledContent("Size") {
                    SizeText(bytes: item.usage?.allocated)
                }
                if let usage = item.usage, usage.hardLinkedBytes > 0 {
                    LabeledContent("Shared") {
                        Text("\(Formatters.bytes(usage.hardLinkedBytes)) also used by other copies")
                            .multilineTextAlignment(.trailing)
                    }
                    .help(String(localized: "These files are hard links. Their space is freed only when every copy is removed."))
                }
                LabeledContent("Installed") { DateText(date: item.created) }
                LabeledContent("Modified") { DateText(date: item.modified) }
                LabeledContent("Location") {
                    Text(item.domain.title).help(item.domain.detail)
                }
                if let minimum = item.minimumSystemVersion {
                    LabeledContent("Requires", value: String(localized: "macOS \(minimum) or later"))
                }
                if item.pluginCount > 1 {
                    LabeledContent("Contains", value: String(localized: "\(item.pluginCount) plug-ins"))
                }
            }

            Section("Identity") {
                LabeledContent("Bundle ID") {
                    Text(item.bundleIdentifier ?? "—")
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Signed by", value: item.signature.title)
                if let team = item.signature.teamID {
                    LabeledContent("Team ID") {
                        Text(team).monospaced().textSelection(.enabled)
                    }
                }
            }

            if !item.audioUnitComponents.isEmpty {
                AudioUnitSection(components: item.audioUnitComponents)
            }

            Section("File") {
                PathView(url: item.url)
                if let destination = item.symlinkDestination {
                    LabeledContent("Links to") {
                        Text((destination.path as NSString).abbreviatingWithTildeInPath)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let app = item.containingApp {
                    LabeledContent("Part of", value: app.deletingPathExtension().lastPathComponent)
                }
            }

            if let group = model.group(for: item), group.items.count > 1 {
                Section("Other formats") {
                    ForEach(group.items.filter { $0.id != item.id }) { sibling in
                        SiblingRow(model: model, item: sibling)
                    }
                }
            }

            ActionsSection(model: model, items: [item])
        }
        .formStyle(.grouped)
    }
}

// MARK: - Product with several formats

@MainActor
private struct ProductInspector: View {
    let model: AppModel
    let group: ProductGroup

    var body: some View {
        Form {
            Section {
                InspectorHeader(
                    name: group.name,
                    vendor: group.vendor,
                    kind: group.kind,
                    format: group.formats.first ?? .audioUnit,
                    formats: group.formats,
                    isShell: group.isShell
                )
            }

            WarningsSection(model: model, items: group.items)

            Section("Details") {
                LabeledContent("Version", value: group.commonVersion ?? String(localized: "Differs by format"))
                LabeledContent("Type", value: group.isShell ? String(localized: "Shell") : (group.kind == .unknown ? "—" : group.kind.title))
                LabeledContent("Total size") {
                    SizeText(bytes: group.isFullyMeasured ? group.combinedBytes : nil)
                }
                LabeledContent("Installed") { DateText(date: group.created) }
                LabeledContent("Location", value: group.domains.sorted().map(\.title).joined(separator: ", "))
            }

            Section("Formats") {
                ForEach(group.items) { item in
                    SiblingRow(model: model, item: item)
                }
            }

            ActionsSection(model: model, items: group.items)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Several selected

@MainActor
private struct MultipleInspector: View {
    let model: AppModel
    let items: [PluginItem]

    var body: some View {
        let measured = items.allSatisfy { $0.usage != nil }
        let formats = Dictionary(grouping: items, by: \.format).sorted { $0.key < $1.key }
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(items.count) files selected")
                        .font(.title3.weight(.semibold))
                    Text("\(Set(items.map(\.productKey)).count) plug-ins from \(Set(items.compactMap(\.vendor)).count) vendors")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Details") {
                LabeledContent("Total size") {
                    SizeText(bytes: measured ? model.bytes(of: items) : nil)
                }
                if measured, model.reclaimableBytes(of: items) < model.bytes(of: items) {
                    LabeledContent("Freed when removed") {
                        SizeText(bytes: model.reclaimableBytes(of: items))
                    }
                    .help(String(localized: "Some files are hard links shared with copies that stay installed."))
                }
                ForEach(formats, id: \.key) { format, members in
                    LabeledContent(format.title, value: String(localized: "\(members.count) files"))
                }
            }

            ActionsSection(model: model, items: items)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Building blocks

@MainActor
private struct InspectorHeader: View {
    let name: String
    let vendor: String?
    let kind: PluginKind
    let format: PluginFormat
    let formats: [PluginFormat]
    let isShell: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProductIcon(kind: kind, format: format, isShell: isShell)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(vendor ?? String(localized: "Unknown vendor"))
                    .foregroundStyle(.secondary)
                FormatBadges(formats: formats)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct WarningsSection: View {
    let model: AppModel
    let items: [PluginItem]

    var body: some View {
        let warnings = self.warnings
        if !warnings.isEmpty {
            Section {
                ForEach(warnings, id: \.title) { warning in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.title).fontWeight(.medium)
                            Text(warning.detail)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: warning.symbol).foregroundStyle(warning.color)
                    }
                }
            }
        }
    }

    private struct Warning {
        var title: String
        var detail: String
        var symbol: String
        var color: Color
    }

    private var warnings: [Warning] {
        let ids = Set(items.map(\.id))
        var result: [Warning] = []
        let report = model.cleanup
        let incompatible = items.compactMap { report.incompatible[$0.id] }
        if let reason = incompatible.first {
            result.append(Warning(title: String(localized: "Can't load on this Mac"), detail: reason.title, symbol: "xmark.octagon.fill", color: .red))
        }
        if !report.intelOnly.isDisjoint(with: ids) {
            result.append(Warning(
                title: String(localized: "Intel only"),
                detail: String(localized: "Loads only in a DAW opened with Rosetta."),
                symbol: "exclamationmark.triangle.fill",
                color: .yellow
            ))
        }
        if !report.duplicateCopies.isDisjoint(with: ids) {
            result.append(Warning(
                title: String(localized: "Installed more than once"),
                detail: String(localized: "The same format exists in another folder too."),
                symbol: "doc.on.doc.fill",
                color: .orange
            ))
        }
        if items.contains(where: \.isInUnusedFolder) {
            result.append(Warning(
                title: String(localized: "Turned off in Pro Tools"),
                detail: String(localized: "It's in the “Plug-Ins (Unused)” folder, which Pro Tools skips."),
                symbol: "pause.circle.fill",
                color: .secondary
            ))
        }
        return result
    }
}

@MainActor
private struct AudioUnitSection: View {
    let components: [AudioUnitComponent]
    @State private var isExpanded = false

    var body: some View {
        Section("Audio Unit") {
            if components.count == 1, let component = components.first {
                codes(component)
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(components, id: \.self) { component in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(component.pluginName)
                            Text(verbatim: "\(component.type) \(component.subtype) \(component.manufacturer)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } label: {
                    Text("\(components.count) components")
                }
            }
        }
    }

    @ViewBuilder
    private func codes(_ component: AudioUnitComponent) -> some View {
        LabeledContent("Name", value: component.pluginName)
        LabeledContent("Codes") {
            Text(verbatim: "\(component.type) \(component.subtype) \(component.manufacturer)")
                .monospaced()
                .textSelection(.enabled)
        }
        .help(String(localized: "Type, subtype and manufacturer, as used by auval."))
    }
}

@MainActor
private struct PathView: View {
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(.link)
        }
    }
}

@MainActor
private struct SiblingRow: View {
    let model: AppModel
    let item: PluginItem

    var body: some View {
        Button {
            model.select(item)
        } label: {
            HStack(spacing: 8) {
                FormatBadge(format: item.format)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text([item.version, item.domain.title].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                SizeText(bytes: item.usage?.allocated)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help((item.url.path as NSString).abbreviatingWithTildeInPath)
        .accessibilityHint(Text("Shows this format's details"))
    }
}

@MainActor
private struct ActionsSection: View {
    let model: AppModel
    let items: [PluginItem]

    var body: some View {
        let removable = model.removable(items)
        Section {
            if removable.isEmpty {
                Text("This extension is part of its app. To remove it, remove the app.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show App in Finder") { model.revealInFinder(items) }
            } else {
                HStack {
                    Button("Uninstall…") { model.requestUninstall(removable) }
                        .help(String(localized: "Review every format and leftover file before removing them."))
                    Spacer()
                    Menu("More") {
                        Button("Move to Trash") { model.requestMoveToTrash(removable) }
                        Button("Delete Immediately…", role: .destructive) { model.requestDeleteImmediately(removable) }
                        Divider()
                        Button("Copy Path") { model.copyPaths(items) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .disabled(model.isRemoving)
            }
        }
    }
}
