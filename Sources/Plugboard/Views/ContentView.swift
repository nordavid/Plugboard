import PlugboardCore
import SwiftUI

@MainActor
struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
                .inspector(isPresented: inspectorBinding) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
                }
        }
        .navigationTitle(model.sidebarSelection?.title ?? "Plugboard")
        .navigationSubtitle(subtitle)
        .overlay(alignment: .bottom) {
            ToastView(model: model)
        }
        .sheet(isPresented: Binding(
            get: { model.removalPlan != nil },
            set: { if !$0 { model.removalPlan = nil } }
        )) {
            RemovalSheet(model: model)
        }
        .confirmationDialog(
            model.confirmation?.title ?? "",
            isPresented: Binding(
                get: { model.confirmation != nil },
                set: { if !$0 { model.confirmation = nil } }
            ),
            presenting: model.confirmation
        ) { confirmation in
            Button(confirmation.buttonTitle, role: confirmation.action == .delete ? .destructive : nil) {
                model.confirm(confirmation)
            }
            Button("Cancel", role: .cancel) { model.confirmation = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .confirmationDialog("Reset the Audio Unit cache?", isPresented: $model.confirmsCacheReset) {
            Button("Reset Cache") { model.resetAudioUnitCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quit Logic Pro and GarageBand first. Their next launch takes longer while they check every Audio Unit.")
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { _ in
            Button("OK") { model.alert = nil }
        } message: { alert in
            Text(alert.message)
        }
        .onAppear {
            model.undoManager = undoManager
            model.start()
        }
        .onChange(of: undoManager) { _, newValue in
            model.undoManager = newValue
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch model.sidebarSelection ?? .overview {
            case .overview:
                OverviewView(model: model)
            case .cleanup(.olderWaves):
                WavesView(model: model)
            case let scope:
                PluginTableView(model: model, scope: scope)
            }
        }
        .frame(minWidth: 480)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text("Search plug-ins"))
        .onSubmit(of: .search) {
            if model.sidebarSelection == .overview { model.sidebarSelection = .all }
        }
        .onChange(of: model.searchText) { _, newValue in
            // Searching from the overview jumps to the full list, where results appear.
            if !newValue.isEmpty, model.sidebarSelection == .overview || model.sidebarSelection == .cleanup(.olderWaves) {
                model.sidebarSelection = .all
            }
        }
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.showsGrouping {
                Picker("View", selection: $model.displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(String(localized: "Show one row per plug-in with its formats inside, or one row per file"))
            }

            if model.sidebarSelection?.isTable == true {
                Menu {
                    Picker("Location", selection: $model.locationFilter) {
                        ForEach(LocationFilter.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Type", selection: $model.kindFilter) {
                        ForEach(KindFilter.allCases) { Text($0.title).tag($0) }
                    }
                    if model.hasActiveFilters {
                        Divider()
                        Button("Clear Filters") {
                            model.locationFilter = .all
                            model.kindFilter = .all
                        }
                    }
                } label: {
                    Label("Filter", systemImage: model.hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
                .help(String(localized: "Filter by location and type"))
            }

            if model.phase.isBusy || model.isRemoving {
                ProgressView()
                    .controlSize(.small)
                    .help(statusText ?? "")
                    .accessibilityLabel(Text(statusText ?? ""))
            } else {
                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help(String(localized: "Scan all plug-in folders again"))
            }

            Button {
                model.export(exportItems)
            } label: {
                Label("Export List", systemImage: "square.and.arrow.up")
            }
            .help(String(localized: "Save the plug-ins shown as a CSV file"))
            .disabled(!model.hasScanned)
        }

        ToolbarItem(placement: .primaryAction) {
            if model.sidebarSelection?.isTable == true {
                Button {
                    model.isInspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help(model.isInspectorPresented ? String(localized: "Hide Inspector") : String(localized: "Show Inspector"))
            }
        }
    }

    /// The inspector only has something to say about list selections, so the overview and the
    /// Waves page use the full width. The user's choice to show it is kept for the lists.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { model.isInspectorPresented && model.sidebarSelection?.isTable == true },
            set: { newValue in
                if model.sidebarSelection?.isTable == true { model.isInspectorPresented = newValue }
            }
        )
    }

    private var exportItems: [PluginItem] {
        model.sidebarSelection?.isTable == true
            ? model.filteredItems(in: model.sidebarSelection)
            : model.items(in: .all)
    }

    private var statusText: String? {
        switch model.phase {
        case .idle: model.isRemoving ? String(localized: "Removing…") : nil
        case .discovering: String(localized: "Looking for plug-ins…")
        case .reading(let done, let total): String(localized: "Reading \(done) of \(total) plug-ins…")
        case .measuring(let done, let total): String(localized: "Calculating sizes, \(done) of \(total)…")
        }
    }

    private var subtitle: String {
        if let statusText, !model.hasScanned { return statusText }
        guard let scope = model.sidebarSelection else { return "" }
        if scope == .overview || scope == .cleanup(.olderWaves) { return statusText ?? "" }
        let items = model.filteredItems(in: scope)
        var parts = [String(localized: "\(items.count) files")]
        if scope == .all && model.displayMode == .products {
            parts.insert(String(localized: "\(Set(items.map(\.productKey)).count) plug-ins"), at: 0)
        }
        guard !items.isEmpty else { return parts.joined(separator: " · ") }
        guard items.allSatisfy({ $0.usage != nil }) else { return statusText ?? parts.joined(separator: " · ") }
        parts.append(Formatters.bytes(model.bytes(of: items)))
        return parts.joined(separator: " · ")
    }
}

/// A short confirmation at the bottom of the window. One with Undo stays until dismissed or
/// replaced; one without disappears after a few seconds.
@MainActor
struct ToastView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text(toast.text)
                        .lineLimit(2)
                    if let undoItems = toast.undoItems, !undoItems.isEmpty {
                        Button("Undo") {
                            Task { await model.restore(undoItems) }
                        }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                    }
                    Button {
                        model.dismissToast()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Dismiss"))
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(.bottom, 20)
                .padding(.horizontal, 20)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                .task(id: toast.id) {
                    guard toast.undoItems == nil else { return }
                    try? await Task.sleep(for: .seconds(5))
                    if model.toast?.id == toast.id { model.dismissToast() }
                }
            }
        }
    }
}
