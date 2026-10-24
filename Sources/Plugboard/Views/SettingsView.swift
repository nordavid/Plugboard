import PlugboardCore
import SwiftUI

@MainActor
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            LocationSettings(model: model)
                .tabItem { Label("Locations", systemImage: "folder") }
        }
        .frame(width: 560)
    }
}

@MainActor
private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var confirmsCacheReset = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.asksBeforeTrash) {
                    Text("Ask before moving plug-ins to the Trash")
                    Text("Large batches and drivers always ask first.")
                }
                Toggle(isOn: $model.watchesFolders) {
                    Text("Update the list when plug-ins change")
                    Text("Rescans automatically after an installer adds or removes plug-ins.")
                }
            }
            Section {
                LabeledContent {
                    Button("Reset…") { confirmsCacheReset = true }
                } label: {
                    Text("Audio Unit cache")
                    Text("Makes Logic Pro and GarageBand check every Audio Unit again on their next launch.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 300)
        .confirmationDialog("Reset the Audio Unit cache?", isPresented: $confirmsCacheReset) {
            Button("Reset Cache") { model.resetAudioUnitCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quit Logic Pro and GarageBand first. Their next launch takes longer while they check every Audio Unit.")
        }
    }
}

@MainActor
private struct LocationSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                if model.customFolders.isEmpty {
                    Text("No additional folders")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.customFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder.path)
                        Spacer()
                        Button {
                            model.removeCustomFolder(folder)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove \(folder.lastPathComponent) from the list"))
                        .help(String(localized: "Stop scanning this folder"))
                    }
                }
                Button("Add Folder…") { model.addCustomFolders() }
            } header: {
                Text("Additional folders")
            } footer: {
                Text("For plug-ins you keep outside the standard folders, such as a custom VST folder set in FL Studio or Ableton Live.")
                    .foregroundStyle(.secondary)
            }

            Section("Standard folders") {
                ForEach(model.standardLocations) { location in
                    let exists = FileManager.default.fileExists(atPath: location.url.path)
                    HStack(spacing: 8) {
                        Text((location.url.path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(exists ? .primary : .tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(location.url.path)
                        Spacer(minLength: 8)
                        if let format = location.format {
                            FormatBadge(format: format)
                        }
                        if exists {
                            Button {
                                model.reveal([location.url])
                            } label: {
                                Image(systemName: "arrow.right.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Show \(location.url.lastPathComponent) in Finder"))
                            .help(String(localized: "Show in Finder"))
                        } else {
                            Text("Not present")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
    }
}
