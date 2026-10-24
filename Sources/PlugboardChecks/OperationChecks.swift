import Foundation
@testable import PlugboardCore

let operationChecks: Void = {
    extraChecks.append {
        // Shell and AppleScript quoting: a path with quotes, spaces and $ must survive intact.
        checkEqual(PrivilegedShell.shellQuote("/Library/It's a $HOME `test`"), "'/Library/It'\\''s a $HOME `test`'", "Shell quoting")
        checkEqual(PrivilegedShell.appleScriptLiteral("say \"hi\" \\ bye"), "\"say \\\"hi\\\" \\\\ bye\"", "AppleScript literal")

        let status = FileRemover.parseStatus("OK:0\nFAIL:1\nOK:2\r\nRECEIPT:0\n")
        checkEqual(status.ok, [0, 2], "Privileged script status lines")
        checkEqual(status.receipts, [0], "Receipt status lines")

        // CSV escaping and formula protection.
        let exporter = CSVExporter(columns: [], separator: ";")
        checkEqual(exporter.escape("Pro-Q 4"), "Pro-Q 4", "Plain field")
        checkEqual(exporter.escape("A;B"), "\"A;B\"", "Field with separator")
        checkEqual(exporter.escape("Say \"hi\""), "\"Say \"\"hi\"\"\"", "Quotes doubled")
        checkEqual(exporter.escape("=cmd"), "'=cmd", "Formula neutralized")

        // Identifier normalization for preference files.
        checkEqual(LeftoverFinder.normalizedIdentifier("com.fabfilter.Pro-Q.Clap.4"), "com.fabfilter.pro-q.4", "Format word dropped")
        checkEqual(LeftoverFinder.normalizedIdentifier("com.fabfilter.Pro-Q.4"), "com.fabfilter.pro-q.4", "Preference name")

        // Receipt paths reduce to the item an uninstall removes.
        checkEqual(
            PackageReceipts.topLevelItem(URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3/Foo.vst3/Contents/MacOS/Foo"))?.path,
            "/Library/Audio/Plug-Ins/VST3/Foo.vst3",
            "Receipt file inside a bundle"
        )
        checkEqual(
            PackageReceipts.topLevelItem(URL(fileURLWithPath: "/Library/Application Support/FabFilter/Pro-Q 4/Presets/x.ffp"))?.path,
            "/Library/Application Support/FabFilter/Pro-Q 4",
            "Receipt file under a vendor folder"
        )
        checkEqual(PackageReceipts.topLevelItem(URL(fileURLWithPath: "/Library/Application Support/FabFilter")), nil, "Vendor folder alone is never proposed")

        policyChecks()
    }
}()

func policyChecks() {
    let fileManager = FileManager.default
    let sandbox = fileManager.temporaryDirectory.appending(path: "PlugboardChecks-\(UUID().uuidString)")
    let home = sandbox.appending(path: "home")
    let vst3 = home.appending(path: "Library/Audio/Plug-Ins/VST3")
    let plugin = vst3.appending(path: "Test.vst3")
    let support = home.appending(path: "Library/Application Support/Vendor/Test")
    try? fileManager.createDirectory(at: plugin.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
    try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: sandbox) }

    let policy = RemovalPolicy(locations: ScanLocation.standard(home: home), home: home)
    check(policy.isAllowed(plugin), "A plug-in bundle may be removed")
    check(policy.isAllowed(support), "A product's support folder may be removed")
    check(!policy.isAllowed(vst3), "The VST3 folder itself is protected")
    check(!policy.isAllowed(home.appending(path: "Library/Audio/Plug-Ins")), "An ancestor of a format folder is protected")
    check(!policy.isAllowed(home), "The home folder is protected")
    check(!policy.isAllowed(URL(fileURLWithPath: "/System/Library/Components")), "Paths outside managed folders are refused")
    check(!policy.isAllowed(URL(fileURLWithPath: vst3.path + "/../../../../Documents")), "Parent references are refused")
    check(!policy.isAllowed(vst3.appending(path: "Missing.vst3")), "Missing items are refused")
    check(!policy.isAllowed(URL(fileURLWithPath: "relative/path")), "Relative paths are refused")
    check(!policy.isAllowed(URL(fileURLWithPath: "/Library/Application Support/Avid")), "A folder containing a scan location is protected")

    // A real move to a temporary trash, without privileges.
    var reserved = Set<String>()
    let remover = MainActor.assumeIsolated { FileRemover(policy: policy, home: home) }
    let trashURL = MainActor.assumeIsolated { remover.uniqueTrashURL(for: plugin, reserved: &reserved) }
    checkEqual(trashURL.lastPathComponent, "Test.vst3", "First trash name is the original")
    let second = MainActor.assumeIsolated { remover.uniqueTrashURL(for: plugin, reserved: &reserved) }
    checkEqual(second.lastPathComponent, "Test 2.vst3", "Taken trash names get a number")
    check(FileRemover.isFullyWritable(plugin), "A bundle the user owns is fully writable")

    // Leftovers for a product whose vendor folder holds its own subfolder.
    var item = PluginItem(url: plugin, format: .vst3, domain: .user, name: "Test", vendor: "Vendor")
    item.declaredVendor = "Vendor"
    item.productKey = "test"
    let group = ProductGroup(key: "test", name: "Test", vendor: "Vendor", items: [item])
    let leftovers = LeftoverFinder(home: home).leftovers(for: group)
    check(leftovers.contains { $0.url.standardizedFileURL.path == support.standardizedFileURL.path }, "Support folder found under its vendor folder")
    check(!leftovers.contains { $0.url.lastPathComponent == "Vendor" }, "Shared vendor folder is never proposed")
}

let catalogChecks: Void = {
    extraChecks.append {
        checkEqual(Catalog.wavesBaseKey("CLA-76 (m)"), Catalog.nameKey("CLA-76"), "Waves mono suffix")
        checkEqual(Catalog.wavesBaseKey("C4 Stereo"), Catalog.nameKey("C4"), "Waves stereo word")
    }
}()
