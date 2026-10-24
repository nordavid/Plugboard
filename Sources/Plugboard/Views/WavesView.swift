import PlugboardCore
import SwiftUI

/// Waves installs each major version side by side. This lists them, newest first, with what
/// removing an older one frees.
@MainActor
struct WavesView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: CleanupCategory.olderWaves.symbol)
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(CleanupCategory.olderWaves.headline)
                            .font(.headline)
                        Text(CleanupCategory.olderWaves.explanation)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                }

                ForEach(model.cleanup.wavesVersions) { version in
                    WavesVersionCard(model: model, version: version)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private struct WavesVersionCard: View {
    let model: AppModel
    let version: WavesVersion

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: "Waves V\(version.major)")
                        .font(.title3.weight(.semibold))
                    if version.isNewest {
                        Text("Newest")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.primary)
                    }
                }
                Text(contents)
                    .foregroundStyle(.secondary)
                if !version.folders.isEmpty {
                    Text(version.folders.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            if let bytes = model.bytes(of: version) {
                Text(Formatters.bytes(bytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            if !version.isNewest {
                Button("Remove…") { model.requestRemoval(of: version) }
                    .disabled(model.isRemoving)
                    .accessibilityLabel(Text("Remove Waves V\(version.major)"))
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var contents: String {
        let shells = String(localized: "\(version.shells.count) shells")
        let plugins = String(localized: "\(version.plugins.count) plug-ins")
        return "\(shells) · \(plugins)"
    }
}
