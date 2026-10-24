import PlugboardCore
import SwiftUI

/// A format abbreviation such as "VST3", set in a quiet capsule.
@MainActor
struct FormatBadge: View {
    let format: PluginFormat

    var body: some View {
        Text(verbatim: format.shortName)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help(format.title)
    }
}

@MainActor
struct FormatBadges: View {
    let formats: [PluginFormat]

    var body: some View {
        // Falls back to the first formats plus a count when the column is too narrow for all.
        ViewThatFits(in: .horizontal) {
            row(formats, hidden: 0)
            if formats.count > 2 { row(Array(formats.prefix(2)), hidden: formats.count - 2) }
            if formats.count > 1 { row(Array(formats.prefix(1)), hidden: formats.count - 1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(formats.map(\.title).joined(separator: ", "))
        .help(formats.map(\.title).joined(separator: ", "))
    }

    private func row(_ shown: [PluginFormat], hidden: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(shown, id: \.self) { FormatBadge(format: $0) }
            if hidden > 0 {
                Text(verbatim: "+\(hidden)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

/// The plug-in kind as a small symbol, used beside names.
@MainActor
struct KindIcon: View {
    let kind: PluginKind
    var isShell = false
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: isShell ? "shippingbox" : kind.symbol)
            .font(.system(size: size * 0.75, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Large icon for the inspector header: the kind symbol on the format's tint.
@MainActor
struct ProductIcon: View {
    let kind: PluginKind
    let format: PluginFormat
    var isShell = false

    var body: some View {
        Image(systemName: isShell ? "shippingbox" : kind.symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(format.tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Architecture with a warning symbol where it limits the plug-in. The text always says it,
/// so the color is never the only cue.
@MainActor
struct ArchitectureLabel: View {
    let support: ArchitectureSupport
    private let isAppleSiliconMac = MachOReader.hostArchitecture.contains(.arm64)

    var body: some View {
        switch support {
        case .intel where isAppleSiliconMac:
            Label {
                Text(support.title)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            .help(support.detail)
        case .legacy:
            Label {
                Text(support.title)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            .help(support.detail)
        case .unknown:
            Text(verbatim: "—").foregroundStyle(.tertiary)
                .accessibilityLabel(support.title)
        default:
            Text(support.title).foregroundStyle(.secondary)
                .help(support.detail)
        }
    }
}

/// A size, or a quiet dash while it is still being measured.
@MainActor
struct SizeText: View {
    let bytes: Int64?

    var body: some View {
        if let bytes {
            Text(Formatters.bytes(bytes))
                .monospacedDigit()
        } else {
            Text(verbatim: "—")
                .foregroundStyle(.tertiary)
                .accessibilityLabel(Text("Calculating size"))
        }
    }
}

@MainActor
struct DateText: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(Formatters.date(date))
                .monospacedDigit()
                .help(Formatters.dateTime(date))
        } else {
            Text(verbatim: "—").foregroundStyle(.tertiary)
        }
    }
}
