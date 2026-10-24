import PlugboardCore
import SwiftUI

@MainActor
struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.overview)
                row(.all, systemImage: "square.stack.3d.up", tint: .accentColor)
            }

            if !model.visibleFormats.isEmpty {
                Section("Formats") {
                    ForEach(model.visibleFormats, id: \.self) { format in
                        row(.format(format), systemImage: format.symbol, tint: format.tint)
                    }
                }
            }

            if model.hasScanned {
                Section("Cleanup") {
                    ForEach(model.applicableCleanupCategories) { category in
                        row(.cleanup(category), systemImage: category.symbol, tint: .orange)
                    }
                }
            }

            if !model.visibleDriverFormats.isEmpty {
                Section("Drivers") {
                    ForEach(model.visibleDriverFormats, id: \.self) { format in
                        row(.format(format), systemImage: format.symbol, tint: format.tint)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ item: SidebarItem, systemImage: String, tint: Color) -> some View {
        Label {
            Text(item.title)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .badge(model.hasScanned ? model.count(for: item) : 0)
        .tag(item)
    }
}
