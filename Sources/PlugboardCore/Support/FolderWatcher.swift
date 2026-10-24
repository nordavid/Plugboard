import CoreServices
import Foundation

/// Reports changes anywhere under a set of folders, coalesced, so an installer that writes
/// thousands of files triggers one rescan instead of thousands.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Plugboard.FolderWatcher")

    public init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    deinit { stop() }

    public func watch(_ folders: [URL], latency: TimeInterval = 1.5) {
        stop()
        let paths = folders.map(\.path) as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Logic Pro and GarageBand keep a cache of every Audio Unit they've validated. Clearing it
/// makes them rescan on next launch, which fixes plug-ins that vanished or show stale versions.
public enum AudioUnitCache {
    public static func cacheFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            home.appending(path: "Library/Caches/AudioUnitCache"),
            home.appending(path: "Library/Preferences/com.apple.audio.InfoHelper.plist"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Moves the cache to the Trash and restarts the registrar that rebuilds it.
    public static func reset(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        for url in cacheFiles(home: home) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        _ = ProcessRunner.run("/usr/bin/killall", ["-9", "AudioComponentRegistrar"], timeout: 5)
    }
}
