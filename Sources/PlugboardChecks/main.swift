import Foundation
@testable import PlugboardCore

// Checks for PlugboardCore. Run `Scripts/build.sh debug && .build-swiftc/debug/PlugboardChecks`.
// Pass --scan to also scan this Mac and print a summary.

var failures = 0
var passes = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        print("✗ \(message)  (\(file):\(line))")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: StaticString = #file, line: UInt = #line) {
    check(actual == expected, "\(message): expected \(expected), got \(actual)", file: file, line: line)
}

// MARK: Mach-O headers

func bytes(_ words: [UInt32], bigEndian: Bool) -> Data {
    var data = Data()
    for word in words {
        var value = bigEndian ? word.bigEndian : word.littleEndian
        data.append(Data(bytes: &value, count: 4))
    }
    return data
}

let fatUniversal = bytes([0xCAFE_BABE, 2, 0x0100_0007, 3, 0, 0, 0, 0x0100_000C, 0, 0, 0, 0], bigEndian: true)
checkEqual(MachOReader.architectures(in: fatUniversal), [.x86_64, .arm64], "Fat header with x86_64 and arm64")
checkEqual(ArchitectureSupport(MachOReader.architectures(in: fatUniversal)), .universal, "Universal support")

let thinIntel = bytes([0xFEED_FACF, 0x0100_0007, 3], bigEndian: false)
checkEqual(MachOReader.architectures(in: thinIntel), [.x86_64], "Thin little-endian x86_64")

let thinARM = bytes([0xFEED_FACF, 0x0100_000C, 0], bigEndian: false)
checkEqual(ArchitectureSupport(MachOReader.architectures(in: thinARM)), .appleSilicon, "Thin arm64")

let thin32 = bytes([0xFEED_FACE, 7, 3], bigEndian: false)
checkEqual(ArchitectureSupport(MachOReader.architectures(in: thin32)), .legacy, "Thin i386 is legacy")

let powerPC = bytes([0xFEED_FACE, 18, 0], bigEndian: true)
checkEqual(MachOReader.architectures(in: powerPC), [.ppc], "Big-endian PowerPC")

let javaClass = bytes([0xCAFE_BABE, 52, 0, 0], bigEndian: true)
checkEqual(MachOReader.architectures(in: javaClass), [], "Java class file isn't a fat binary")
checkEqual(MachOReader.architectures(in: Data([1, 2])), [], "Truncated data")

// MARK: Names and vendors

checkEqual(Catalog.nameKey("FabFilter Pro-Q 4"), "fabfilter pro q 4", "Name key")
checkEqual(Catalog.nameKey("FabFilter Pro-Q 4 (VST3)"), "fabfilter pro q 4", "Format token dropped")
checkEqual(Catalog.nameKey("WaveShell1-AU 16.0"), Catalog.nameKey("WaveShell1-VST3 16.0"), "WaveShells group across formats")
checkEqual(Catalog.nameKey("WaveShell1-WPAPI_2 16.0"), Catalog.nameKey("WaveShell1-AAX 16.0"), "WPAPI shell groups with AAX shell")
check(Catalog.nameKey("Pro-Q 3") != Catalog.nameKey("Pro-Q 4"), "Versions stay apart")

checkEqual(Catalog.cleanVendorName("Native Instruments GmbH"), "Native Instruments", "GmbH removed")
checkEqual(Catalog.cleanVendorName("Plugin Alliance LLC"), "Plugin Alliance", "LLC removed")
checkEqual(Catalog.cleanVendorName("FabFilter B.V."), "FabFilter", "B.V. removed")
checkEqual(Catalog.cleanVendorName("iZotope, Inc."), "iZotope", "Comma and Inc. removed")
checkEqual(Catalog.cleanVendorName("AB"), "AB", "A lone word is kept")

checkEqual(
    CodeSignatureReader.organizationName(fromCertificateSummary: "Developer ID Application: FabFilter B.V. (ABCDE12345)"),
    "FabFilter B.V.",
    "Organization from certificate summary"
)

let component = AudioUnitComponent(type: "aufx", subtype: "FQ4p", manufacturer: "FabF", name: "FabFilter: Pro-Q 4")
checkEqual(component.vendorName, "FabFilter", "AU vendor from name")
checkEqual(component.pluginName, "Pro-Q 4", "AU plug-in name")
checkEqual(PluginKind(audioUnitType: "aumu"), .instrument, "aumu is an instrument")
checkEqual(PluginKind(audioUnitType: "aumf"), .effect, "aumf is an effect")
checkEqual(PluginKind(vst3SubCategories: ["Instrument|Synth"]), .instrument, "VST3 instrument")
checkEqual(PluginKind(vst3SubCategories: ["Fx"]), .effect, "VST3 effect")

// MARK: Waves naming

checkEqual(WavesNaming.majorVersion(ofShell: "WaveShell1-AU 14.12"), 14, "Shell major version")
checkEqual(WavesNaming.majorVersion(ofShell: "Heatwave"), nil, "Not a shell")
checkEqual(WavesNaming.majorVersion(ofPluginFolder: "Plug-Ins V16"), 16, "Plug-in folder version")
checkEqual(WavesNaming.majorVersion(ofShellFolder: "WaveShells V13"), 13, "Shell folder version")

// MARK: Grouping

func item(_ name: String, _ format: PluginFormat, vendor: String?, team: String? = nil, kind: PluginKind = .unknown) -> PluginItem {
    var item = PluginItem(
        url: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/\(format.shortName)/\(name).x"),
        format: format,
        domain: .system,
        name: name,
        vendor: vendor,
        kind: kind,
        signature: SignatureInfo(status: .developerID, organization: nil, teamID: team)
    )
    item.declaredVendor = vendor
    return item
}

let processed = Catalog.process([
    item("FabFilter Pro-Q 4", .audioUnit, vendor: "FabFilter", team: "T1", kind: .effect),
    item("FabFilter Pro-Q 4", .clap, vendor: nil, team: "T1"),
    item("FabFilter Pro-Q 4", .vst3, vendor: "FabFilter", team: "T1"),
    item("Compressor", .vst3, vendor: "Vendor A", team: "A"),
    item("Compressor", .vst3, vendor: "Vendor B", team: "B"),
])
let groups = Catalog.groups(processed)
checkEqual(groups.count, 3, "Pro-Q 4 is one product, the two compressors stay apart")
let proQ = groups.first { $0.name == "FabFilter Pro-Q 4" }
checkEqual(proQ?.items.count, 3, "Three formats of Pro-Q 4")
checkEqual(processed[1].vendor, "FabFilter", "CLAP vendor inferred from its signing team")
checkEqual(processed[1].kind, .effect, "CLAP kind inferred from its AU")

// MARK: Disk usage of hard links

let linkA = HardLink(device: 1, inode: 42, bytes: 1000, linkCount: 2)
let usageA = DiskUsage(allocated: 1500, fileCount: 2, hardLinks: [linkA])
let usageB = DiskUsage(allocated: 1200, fileCount: 2, hardLinks: [linkA])
checkEqual(DiskUsageCalculator.combinedBytes(of: [usageA, usageB]), 1700, "Hard-linked bytes counted once")
checkEqual(DiskUsageCalculator.reclaimableBytes(of: [usageA]), 500, "Removing one link frees only exclusive bytes")
checkEqual(DiskUsageCalculator.reclaimableBytes(of: [usageA, usageB]), 1700, "Removing both links frees the shared bytes")

// MARK: VST3 module info

let moduleJSON = """
{
  "Name": "TAIP",
  "Version": "1.6",
  "Factory Info": { "Vendor": "BABY Audio", },
  "Classes": [
    { "Category": "Audio Module Class", "Name": "TAIP", "Sub Categories": [ "Fx", ], },
    { "Category": "Component Controller Class", "Name": "TAIP", },
  ],
}
"""
let module = VST3ModuleInfo.parse(Data(moduleJSON.utf8))
checkEqual(module?.vendor, "BABY Audio", "JSON5 module info vendor")
checkEqual(module?.kind, .effect, "JSON5 module info kind")
checkEqual(module?.audioClassCount, 1, "Only audio module classes counted")

// MARK: Versions

checkEqual(CleanupAnalyzer.isNewer("15.0", than: OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1)), true, "15.0 is newer than 14.6.1")
checkEqual(CleanupAnalyzer.isNewer("10.11", than: OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1)), false, "10.11 is older")

_ = operationChecks
_ = catalogChecks
for check in extraChecks { check() }
await removalChecks()

// MARK: Live scan

if CommandLine.arguments.contains("--scan") {
    let start = Date()
    let scanner = PluginScanner(cache: ScanCache(fileURL: nil))
    let candidates = scanner.discover(in: ScanLocation.standard())
    let discovered = Date()
    var items = await scanner.read(candidates)
    items += scanner.discoverAppExtensions()
    items = Catalog.process(items)
    let read = Date()
    let measured = Box<[String: DiskUsage]>([:])
    await scanner.measure(items) { id, usage in measured.mutate { $0[id] = usage } }
    let done = Date()
    for index in items.indices { items[index].usage = measured.value[items[index].id] }

    print(String(format: "Discovered %d bundles in %.2fs, read metadata in %.2fs, measured in %.2fs",
                 candidates.count, discovered.timeIntervalSince(start), read.timeIntervalSince(discovered), done.timeIntervalSince(read)))
    for (format, members) in Dictionary(grouping: items, by: \.format).sorted(by: { $0.key < $1.key }) {
        let bytes = DiskUsageCalculator.combinedBytes(of: members.compactMap(\.usage))
        print("  \(format.shortName.padding(toLength: 6, withPad: " ", startingAt: 0)) \(String(members.count).padding(toLength: 5, withPad: " ", startingAt: 0)) \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
    }
    let groups = Catalog.groups(items)
    print("Products: \(groups.count), vendors: \(Set(items.compactMap(\.vendor)).count), unknown vendor: \(items.filter { $0.vendor == nil }.count)")
    print("Architectures:", Dictionary(grouping: items, by: \.architectureSupport).mapValues(\.count))
    print("Kinds:", Dictionary(grouping: items, by: \.kind).mapValues(\.count))
    let daws = DAWDetector.detect()
    print("DAWs:", daws.map { "\($0.name) \($0.version ?? "")" })
    let report = CleanupAnalyzer.analyze(items, daws: daws)
    for category in CleanupCategory.allCases {
        print("Cleanup \(category.rawValue): \(report.ids(for: category).count)")
    }
    for version in report.wavesVersions {
        print("  Waves V\(version.major): \(version.shells.count) shells, \(version.plugins.count) plug-ins, folders \(version.folders.map(\.lastPathComponent)), newest \(version.isNewest)")
    }
    print("Sample:")
    for item in items.prefix(400).filter({ $0.format != .audioUnit || $0.name.hasPrefix("Fab") }).prefix(12) {
        print("  \(item.name) | \(item.format.shortName) | \(item.vendor ?? "?") | \(item.kind) | \(item.version ?? "-") | \(item.architectureSupport) | \(item.signature.status)")
    }
    if CommandLine.arguments.contains("--unknown") {
        for item in items where item.vendor == nil { print("  no vendor: \(item.url.path)") }
    }
}

print(failures == 0 ? "✓ \(passes) checks passed" : "✗ \(failures) of \(passes + failures) checks failed")
exit(failures == 0 ? 0 : 1)
