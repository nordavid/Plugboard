import AppKit
import PlugboardCore
import SwiftUI

/// Renders the main window in a series of states to PNG files, then quits. Used to check the
/// interface without clicking through it:
///
///     Plugboard.app/Contents/MacOS/Plugboard --snapshot /tmp/shots [--dark]
///
/// It never removes anything; it only changes what the window shows.
@MainActor
enum SnapshotRunner {
    static func runIfRequested(model: AppModel) {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        if arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }

        if arguments.contains("--removal-demo") {
            Task { await runRemovalDemo(model: model, folder: folder) }
            return
        }

        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            while !model.hasScanned || model.phase.isBusy {
                try? await Task.sleep(for: .milliseconds(250))
            }

            let firstGroup = model.groups.first { $0.items.count >= 3 && $0.items.contains { $0.format == .audioUnit } }
            let firstWaves = model.olderWavesVersions.first
            let steps: [(String, () -> Void)] = [
                ("01-overview", { model.sidebarSelection = .overview }),
                ("02-all-products", {
                    model.sidebarSelection = .all
                    model.displayMode = .products
                    if let firstGroup { model.selection = [firstGroup.id] }
                }),
                ("03-all-files", {
                    model.displayMode = .files
                    if let item = firstGroup?.items.first { model.selection = [item.id] }
                }),
                ("04-cleanup-aax", { model.sidebarSelection = .cleanup(.unusedAAX) }),
                ("05-cleanup-intel", {
                    model.sidebarSelection = .cleanup(.intelOnly)
                    if let id = model.cleanup.intelOnly.sorted().first { model.selection = [id] }
                }),
                ("06-waves", { model.sidebarSelection = .cleanup(.olderWaves) }),
                ("07-search-empty", {
                    model.sidebarSelection = .all
                    model.searchText = "zzzz-no-match"
                }),
                ("08-uninstall-sheet", {
                    model.searchText = ""
                    if let firstGroup { model.requestUninstall(firstGroup.items) }
                }),
                ("09-waves-sheet", {
                    model.removalPlan = nil
                    if let firstWaves { model.requestRemoval(of: firstWaves) }
                }),
                ("10-multi-select", {
                    model.removalPlan = nil
                    model.sidebarSelection = .format(.vst3)
                    model.selection = Set(model.items(in: .format(.vst3)).prefix(5).map(\.id))
                }),
                ("11-drivers", { model.sidebarSelection = .format(.audioDriver) }),
            ]

            for (name, step) in steps {
                NSLog("Snapshot step %@", name)
                step()
                try? await Task.sleep(for: .milliseconds(1200))
                capture(to: folder.appending(path: "\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// Moves a throwaway plug-in to the real Trash through the app's own code path, captures the
    /// confirmation, puts it back with Undo and reports whether it returned intact.
    private static func runRemovalDemo(model: AppModel, folder: URL) async {
        let fileManager = FileManager.default
        let fixtures = folder.appending(path: "fixtures")
        let plugin = fixtures.appending(path: "Plugboard Demo.vst3")
        let binary = plugin.appending(path: "Contents/MacOS/Plugboard Demo")
        try? fileManager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: binary.path, contents: Data(repeating: 1, count: 4096))

        model.temporaryFolders = [fixtures]
        while !model.hasScanned || model.phase.isBusy { try? await Task.sleep(for: .milliseconds(250)) }
        model.rescan()
        try? await Task.sleep(for: .milliseconds(300))
        while model.phase.isBusy { try? await Task.sleep(for: .milliseconds(250)) }

        guard let item = model.items.first(where: { $0.url.standardizedFileURL == plugin.standardizedFileURL }) else {
            NSLog("Removal demo: FAIL, fixture not found by the scan")
            NSApp.terminate(nil)
            return
        }
        model.sidebarSelection = .format(.vst3)
        model.searchText = "Plugboard Demo"
        model.selection = [item.id]
        try? await Task.sleep(for: .milliseconds(1000))
        capture(to: folder.appending(path: "12-before-removal.png"))

        model.requestMoveToTrash([item])
        while model.isRemoving || model.toast == nil { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(1200))
        capture(to: folder.appending(path: "13-after-removal.png"))
        let trashedAway = !fileManager.fileExists(atPath: plugin.path)

        if let undo = model.toast?.undoItems { await model.restore(undo) }
        try? await Task.sleep(for: .milliseconds(1500))
        capture(to: folder.appending(path: "14-after-undo.png"))
        let restored = fileManager.fileExists(atPath: binary.path)

        NSLog("Removal demo: trashed=%@ restored=%@", trashedAway ? "yes" : "no", restored ? "yes" : "no")
        try? fileManager.removeItem(at: fixtures)
        NSApp.terminate(nil)
    }

    private static func capture(to url: URL) {
        // Sheets are separate windows; capture the frontmost of those too.
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 300 }
        guard let window = windows.first(where: { $0.isSheet }) ?? windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) ?? windows.first,
              let windowNumber = Optional(window.windowNumber) else { return }

        if let image = (LegacyWindowCapture() as WindowCapturing).image(of: CGWindowID(windowNumber)) {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            return
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private protocol WindowCapturing {
    func image(of window: CGWindowID) -> CGImage?
}

/// CGWindowListCreateImage is deprecated, but it is the one call that captures this app's own
/// windows, sheets included, without asking for Screen Recording access. Debug tooling only.
private struct LegacyWindowCapture: WindowCapturing {
    @available(macOS, deprecated: 14.0)
    func image(of window: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, window, [.boundsIgnoreFraming, .bestResolution])
    }
}
