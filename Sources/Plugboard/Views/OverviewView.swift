import PlugboardCore
import SwiftUI

@MainActor
struct OverviewView: View {
    let model: AppModel

    var body: some View {
        if !model.hasScanned {
            ProgressView("Scanning plug-in folders…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StatsRow(model: model)
                    CleanupSuggestions(model: model)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            FormatStorageChart(model: model)
                            VendorStorageChart(model: model)
                        }
                        VStack(spacing: 16) {
                            FormatStorageChart(model: model)
                            VendorStorageChart(model: model)
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            DAWSummary(model: model)
                            LargestPlugins(model: model)
                        }
                        VStack(spacing: 16) {
                            DAWSummary(model: model)
                            LargestPlugins(model: model)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Stat tiles

@MainActor
private struct StatsRow: View {
    let model: AppModel

    var body: some View {
        let items = model.items(in: .all)
        let measured = items.allSatisfy { $0.usage != nil }
        let tiles = [
            StatTile(label: String(localized: "Plug-ins"), value: Set(items.map(\.productKey)).count.formatted()),
            StatTile(label: String(localized: "Files"), value: items.count.formatted()),
            StatTile(label: String(localized: "Disk space"), value: measured ? Formatters.bytes(model.bytes(of: items)) : nil),
            StatTile(label: String(localized: "Vendors"), value: Set(items.compactMap(\.vendor)).count.formatted()),
        ]
        // Four across when they fit, otherwise two by two, so no tile sits alone on a row.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                ForEach(tiles.indices, id: \.self) { tiles[$0].frame(minWidth: 150) }
            }
            Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                GridRow { tiles[0]; tiles[1] }
                GridRow { tiles[2]; tiles[3] }
            }
        }
    }
}

@MainActor
private struct StatTile: View {
    let label: String
    /// Nil while it's still being calculated.
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.title.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 34, alignment: .leading)
                    .accessibilityLabel(Text("Calculating"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cleanup suggestions

@MainActor
private struct CleanupSuggestions: View {
    let model: AppModel

    var body: some View {
        let categories = model.activeCleanupCategories
        VStack(alignment: .leading, spacing: 10) {
            Text("Cleanup suggestions")
                .font(.title3.weight(.semibold))
            if categories.isEmpty {
                Label {
                    Text("Nothing to clean up. Plugboard checks again with every scan.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                        if index > 0 { Divider().padding(.leading, 48) }
                        CleanupRow(model: model, category: category)
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

@MainActor
private struct CleanupRow: View {
    let model: AppModel
    let category: CleanupCategory

    var body: some View {
        Button {
            model.sidebarSelection = .cleanup(category)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: category.symbol)
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).fontWeight(.medium)
                    Text(category.headline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(summary)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        if category == .olderWaves {
            let versions = model.olderWavesVersions
            let bytes = versions.compactMap { model.bytes(of: $0) }.reduce(0, +)
            let count = String(localized: "\(versions.count) versions")
            return bytes > 0 ? "\(count) · \(Formatters.bytes(bytes))" : count
        }
        let items = model.items(in: .cleanup(category))
        let count = String(localized: "\(items.count) files")
        let bytes = model.reclaimableBytes(of: items)
        return bytes > 0 ? "\(count) · \(Formatters.bytes(bytes))" : count
    }
}

// MARK: - Charts

/// One bar per category, sized by disk space. A single series, so it uses one hue and
/// needs no legend; the card title names what's plotted and hover shows exact values.
private struct StorageBar: Identifiable {
    var id: String
    var label: String
    var bytes: Int64
    var count: Int
    var scope: SidebarItem?
}

@MainActor
private struct FormatStorageChart: View {
    let model: AppModel

    var body: some View {
        let items = model.items(in: .all)
        let bars = Dictionary(grouping: items, by: \.format)
            .map { format, members in
                StorageBar(id: format.rawValue, label: format.shortName, bytes: model.bytes(of: members), count: members.count, scope: .format(format))
            }
            .sorted { $0.bytes > $1.bytes }
        StorageChartCard(
            title: String(localized: "Disk space by format"),
            bars: bars,
            isMeasured: items.allSatisfy { $0.usage != nil },
            labelWidth: 56,
            onSelect: { model.sidebarSelection = $0.scope }
        )
    }
}

@MainActor
private struct VendorStorageChart: View {
    let model: AppModel

    var body: some View {
        let items = model.items(in: .all)
        let byVendor = Dictionary(grouping: items) { $0.vendor ?? String(localized: "Unknown vendor") }
            .map { vendor, members in
                StorageBar(id: vendor, label: vendor, bytes: model.bytes(of: members), count: members.count, scope: nil)
            }
            .sorted { $0.bytes > $1.bytes }
        StorageChartCard(
            title: String(localized: "Largest vendors"),
            bars: Array(byVendor.prefix(8)),
            isMeasured: items.allSatisfy { $0.usage != nil },
            onSelect: { bar in
                model.sidebarSelection = .all
                model.searchText = bar.label
            }
        )
    }
}

/// A horizontal bar per category, all in one hue. The card title names what's plotted, values
/// sit at the bar tips, and hovering a row highlights it and shows the file count.
@MainActor
private struct StorageChartCard: View {
    let title: String
    let bars: [StorageBar]
    let isMeasured: Bool
    var labelWidth: CGFloat = 130
    let onSelect: (StorageBar) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            if !isMeasured {
                ProgressView("Calculating sizes…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                let maximum = max(bars.map(\.bytes).max() ?? 1, 1)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bars) { bar in
                        BarRow(bar: bar, labelWidth: labelWidth, fraction: Double(bar.bytes) / Double(maximum), isDimmed: hovered != nil && hovered != bar.id) {
                            onSelect(bar)
                        }
                        .onHover { inside in hovered = inside ? bar.id : (hovered == bar.id ? nil : hovered) }
                        .onTapGesture { onSelect(bar) }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor
private struct BarRow: View {
    let bar: StorageBar
    let labelWidth: CGFloat
    let fraction: Double
    let isDimmed: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(bar.label)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .leading)
            GeometryReader { geometry in
                HStack(spacing: 6) {
                    UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4, style: .continuous)
                        .fill(Color.accentColor.opacity(isDimmed ? 0.35 : 1))
                        .frame(width: max(2, (geometry.size.width - 70) * fraction), height: 16)
                    Text(Formatters.bytes(bar.bytes))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 22)
        }
        .contentShape(Rectangle())
        .help(String(localized: "\(bar.label): \(Formatters.bytes(bar.bytes)) in \(bar.count) files"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.label)
        .accessibilityValue(String(localized: "\(Formatters.bytes(bar.bytes)), \(bar.count) files"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }
}

// MARK: - DAWs

@MainActor
private struct DAWSummary: View {
    let model: AppModel

    var body: some View {
        let used = Set(model.daws.flatMap(\.formats))
        let installed = Set(model.items(in: .all).map(\.format))
        let unused = PluginFormat.pluginFormats.filter { installed.contains($0) && !used.contains($0) && $0 != .waves }
        VStack(alignment: .leading, spacing: 12) {
            Text("DAWs on this Mac")
                .font(.title3.weight(.semibold))
            if model.daws.isEmpty {
                Text("Plugboard didn't find a DAW in Applications.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.daws) { daw in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(daw.name).fontWeight(.medium)
                            if let version = daw.version {
                                Text(verbatim: version)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        Spacer(minLength: 8)
                        FormatBadges(formats: daw.formats.sorted().filter { $0 != .auv3 })
                    }
                }
                if !unused.isEmpty {
                    Divider()
                    Label {
                        Text("No DAW here loads \(ListFormatter.localizedString(byJoining: unused.map(\.shortName))).")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor
private struct LargestPlugins: View {
    let model: AppModel

    var body: some View {
        let largest = model.groups
            .filter { group in group.isFullyMeasured && !group.items.contains { $0.format.isDriver } }
            .sorted { $0.combinedBytes > $1.combinedBytes }
            .prefix(6)
        VStack(alignment: .leading, spacing: 12) {
            Text("Largest plug-ins")
                .font(.title3.weight(.semibold))
            if largest.isEmpty {
                ProgressView("Calculating sizes…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ForEach(Array(largest)) { group in
                    Button {
                        if let first = group.items.first { model.select(first) }
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.name).fontWeight(.medium).lineLimit(1)
                                Text(group.vendor ?? String(localized: "Unknown vendor"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(Formatters.bytes(group.combinedBytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
