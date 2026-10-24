import PlugboardCore
import SwiftUI

@main
struct PlugboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Plugboard", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .task { SnapshotRunner.runIfRequested(model: model) }
        }
        .defaultSize(width: 1240, height: 760)
        .commands { PlugboardCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PlugboardCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // A single window, so there's nothing to create.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .newItem) { FileMenuItems(model: model) }
        CommandGroup(after: .pasteboard) { EditMenuItems(model: model) }
        CommandGroup(after: .sidebar) { ViewMenuItems(model: model) }
        CommandMenu("Plug-in") { PluginMenuItems(model: model) }
    }
}

// Menu contents are views, so they run on the main actor where the model lives.

@MainActor
private struct FileMenuItems: View {
    let model: AppModel

    var body: some View {
        Button("Rescan") { model.rescan() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.phase.isBusy)
        Button("Export List…") {
            model.export(model.sidebarSelection?.isTable == true ? model.filteredItems(in: model.sidebarSelection) : model.items(in: .all))
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!model.hasScanned)
    }
}

@MainActor
private struct EditMenuItems: View {
    let model: AppModel

    var body: some View {
        Divider()
        Button("Copy Path") { model.copyPaths(model.selectedItems) }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(model.selection.isEmpty)
    }
}

@MainActor
private struct ViewMenuItems: View {
    @Bindable var model: AppModel

    var body: some View {
        Button(model.isInspectorPresented ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")) {
            model.isInspectorPresented.toggle()
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        Picker("Show As", selection: $model.displayMode) {
            ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
        }
        .disabled(!model.showsGrouping)
        Divider()
    }
}

@MainActor
private struct PluginMenuItems: View {
    let model: AppModel

    var body: some View {
        let selected = model.selectedItems
        let removable = model.removable(selected)
        Button("Show in Finder") { model.revealInFinder(selected) }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(selected.isEmpty)
        Divider()
        Button("Uninstall…") { model.requestUninstall(removable) }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(removable.isEmpty || model.isRemoving)
        Button("Move to Trash") { model.requestMoveToTrash(removable) }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(removable.isEmpty || model.isRemoving)
        Button("Delete Immediately…") { model.requestDeleteImmediately(removable) }
            .keyboardShortcut(.delete, modifiers: [.command, .option])
            .disabled(removable.isEmpty || model.isRemoving)
        Divider()
        Button("Reset Audio Unit Cache…") { model.confirmsCacheReset = true }
    }
}
