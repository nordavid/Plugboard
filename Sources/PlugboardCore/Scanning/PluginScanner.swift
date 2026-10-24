import Darwin
import Foundation

/// A bundle found on disk, before its metadata is read.
public struct PluginCandidate: Sendable, Hashable {
    public var url: URL
    public var format: PluginFormat
    public var domain: InstallDomain
    public var isInUnusedFolder: Bool
}

/// Finds plug-in bundles and reads their metadata, reusing cached results for bundles
/// that haven't changed since the last scan.
public final class PluginScanner: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let cache: ScanCache

    public init(cache: ScanCache) {
        self.cache = cache
    }

    // MARK: Discovery

    /// Lists every bundle in the given locations. Fast: reads directory entries only.
    public func discover(in locations: [ScanLocation]) -> [PluginCandidate] {
        var seen = Set<String>()
        var result: [PluginCandidate] = []
        for location in locations {
            for candidate in discover(in: location) where seen.insert(candidate.url.standardizedFileURL.path).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    func discover(in location: ScanLocation) -> [PluginCandidate] {
        var result: [PluginCandidate] = []
        walk(location.url, depth: 1, location: location, into: &result)
        return result
    }

    private func walk(_ folder: URL, depth: Int, location: ScanLocation, into result: inout [PluginCandidate]) {
        guard depth <= location.maxDepth,
              let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }

        for name in names.sorted() where !Self.isIgnored(name) {
            let url = folder.appending(path: name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let isLink = info.st_mode & S_IFMT == S_IFLNK
            let isDirectory = info.st_mode & S_IFMT == S_IFDIR

            if let format = format(of: url, in: location), isDirectory || isLink {
                result.append(PluginCandidate(url: url, format: format, domain: location.domain, isInUnusedFolder: location.isUnusedFolder))
            } else if isDirectory, !Self.isOpaqueBundle(name) {
                // A vendor subfolder such as VST3/Eiosis. Symbolic links are never followed,
                // so a link back to a parent can't loop.
                walk(url, depth: depth + 1, location: location, into: &result)
            }
        }
    }

    private func format(of url: URL, in location: ScanLocation) -> PluginFormat? {
        let ext = url.pathExtension.lowercased()
        guard let format = location.format else {
            return PluginFormat(fileExtension: ext)
        }
        return format.bundleExtensions.contains(ext) ? format : nil
    }

    static func isIgnored(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "Icon\r" || name == "Icon"
    }

    /// Bundles that aren't plug-ins but shouldn't be descended into either.
    static func isOpaqueBundle(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["app", "framework", "bundle", "plugin", "kext", "pkg", "dmg"].contains(ext)
    }

    // MARK: Metadata

    /// Reads metadata for every candidate. Cached entries whose fingerprint still matches are
    /// reused, sizes included, so a second launch is near-instant.
    public func read(
        _ candidates: [PluginCandidate],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [PluginItem] {
        let cache = self.cache
        let total = candidates.count
        let counter = Counter()

        return await concurrentMap(candidates) { candidate in
            let fingerprint = Fingerprint(of: candidate.url)
            var item: PluginItem
            if let cached = cache.item(for: candidate.url.path, fingerprint: fingerprint),
               cached.format == candidate.format, cached.domain == candidate.domain {
                item = cached
            } else {
                item = BundleReader.read(
                    url: candidate.url,
                    format: candidate.format,
                    domain: candidate.domain,
                    isInUnusedFolder: candidate.isInUnusedFolder
                )
                cache.store(item, fingerprint: fingerprint)
            }
            item.isInUnusedFolder = candidate.isInUnusedFolder
            progress?(counter.increment(), total)
            return item
        }
    }

    /// AUv3 extensions registered with the system, outside Apple's own.
    public func discoverAppExtensions() -> [PluginItem] {
        var paths = Set<String>()
        for point in ["com.apple.AudioUnit-UI", "com.apple.AudioUnit"] {
            guard let result = ProcessRunner.run("/usr/bin/pluginkit", ["-m", "-A", "-v", "-p", point]), result.status == 0 else { continue }
            for line in result.output.split(separator: "\n") {
                guard let path = line.split(separator: "\t").last.map(String.init)?.trimmingCharacters(in: .whitespaces),
                      path.hasPrefix("/"), path.hasSuffix(".appex"),
                      !path.hasPrefix("/System/") else { continue }
                paths.insert(path)
            }
        }
        return paths.sorted().compactMap { path in
            let url = URL(fileURLWithPath: path)
            let item = BundleReader.readAppExtension(url: url)
            if item?.bundleIdentifier?.hasPrefix("com.apple.") == true { return nil }
            return item
        }
    }

    // MARK: Sizes

    /// Measures bundles that have no size yet, reporting each result as it lands.
    public func measure(
        _ items: [PluginItem],
        onResult: @escaping @Sendable (String, DiskUsage) -> Void
    ) async {
        let cache = self.cache
        let pending = items.filter { $0.usage == nil }
        // Disk-bound work: a few parallel walkers saturate an SSD without starving the UI.
        _ = await concurrentMap(pending, maxConcurrency: 4) { item in
            let usage = DiskUsageCalculator.usage(of: item.url)
            cache.storeUsage(usage, for: item.url.path)
            onResult(item.id, usage)
            return ()
        }
    }
}

/// Thread-safe progress counter.
final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
