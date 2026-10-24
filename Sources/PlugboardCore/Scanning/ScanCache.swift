import Darwin
import Foundation

/// Identifies one version of a bundle on disk. When an installer replaces or updates a
/// plug-in, at least one of these values changes.
public struct Fingerprint: Codable, Sendable, Hashable {
    var inode: UInt64
    var modified: Int
    var infoPlistModified: Int
    var executableFolderModified: Int

    public init(of url: URL) {
        inode = 0
        modified = 0
        var info = stat()
        if lstat(url.path, &info) == 0 {
            inode = info.st_ino
            modified = info.st_mtimespec.tv_sec
        }
        // stat, not lstat: follow a symlinked bundle to the real files.
        infoPlistModified = Self.mtime(url.appending(path: "Contents/Info.plist").path)
        executableFolderModified = Self.mtime(url.appending(path: "Contents/MacOS").path)
    }

    private static func mtime(_ path: String) -> Int {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_mtimespec.tv_sec : 0
    }
}

/// Remembers what was read about each bundle, keyed by path, across launches.
public final class ScanCache: @unchecked Sendable {
    private struct Entry: Codable {
        var fingerprint: Fingerprint
        var item: PluginItem
    }

    private struct Archive: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    /// Bump when PluginItem or the reading rules change, so stale entries are dropped.
    private static let formatVersion = 3

    private let fileURL: URL?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var isDirty = false

    /// Pass nil for an in-memory cache.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == Self.formatVersion else { return }
        entries = archive.entries
    }

    public static func defaultURL(bundleIdentifier: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: bundleIdentifier).appending(path: "scan-cache.json")
    }

    func item(for path: String, fingerprint: Fingerprint) -> PluginItem? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.fingerprint == fingerprint else { return nil }
        return entry.item
    }

    func store(_ item: PluginItem, fingerprint: Fingerprint) {
        lock.lock()
        defer { lock.unlock() }
        var item = item
        // Keep a previously measured size only if the bundle is unchanged.
        if let existing = entries[item.id], existing.fingerprint == fingerprint {
            item.usage = existing.item.usage
        }
        entries[item.id] = Entry(fingerprint: fingerprint, item: item)
        isDirty = true
    }

    func storeUsage(_ usage: DiskUsage, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[path]?.item.usage = usage
        isDirty = true
    }

    /// Drops entries for bundles that no longer exist and writes the cache to disk.
    public func save(keeping paths: Set<String>) {
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
        let snapshot = Archive(version: Self.formatVersion, entries: entries)
        let shouldWrite = isDirty
        isDirty = false
        lock.unlock()

        guard shouldWrite, let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A cache that can't be written only costs speed on the next launch.
        }
    }

    public func removeAll() {
        lock.lock()
        entries = [:]
        isDirty = true
        lock.unlock()
    }
}
