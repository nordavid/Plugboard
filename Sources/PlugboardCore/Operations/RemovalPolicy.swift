import Darwin
import Foundation

/// The last line of defense before anything is moved or deleted. Every path must sit strictly
/// inside a folder Plugboard manages, and may never be one of those folders or an ancestor of one.
public struct RemovalPolicy: Sendable {
    public enum Violation: Error, Equatable, Sendable {
        case notAbsolute(String)
        case missing(String)
        case outsideManagedFolders(String)
        case protectedFolder(String)
    }

    /// Folders whose contents may be removed.
    public let allowedRoots: [String]
    /// Folders that must survive, such as /Library/Audio/Plug-Ins/VST3 itself.
    public let protectedPaths: Set<String>

    public init(locations: [ScanLocation], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let homePath = home.standardizedFileURL.path
        let leftoverZones = [
            homePath + "/Library/Preferences",
            homePath + "/Library/Caches",
            homePath + "/Library/Application Support",
            homePath + "/Library/Audio/Presets",
            homePath + "/Music/Audio Music Apps/Plug-In Settings",
            "/Library/Preferences",
            "/Library/Application Support",
            "/Library/Audio/Presets",
            "/Users/Shared",
            ScanLocation.wavesRoot.path,
        ]
        let locationPaths = locations.map { $0.url.standardizedFileURL.path }
        allowedRoots = Array(Set(locationPaths + leftoverZones)).sorted()

        // Every managed folder and each of its ancestors is protected, so neither a format
        // folder nor something like "/Library/Application Support/Avid" can be removed whole.
        var protected = Set<String>()
        for path in allowedRoots {
            var url = URL(fileURLWithPath: path)
            while url.pathComponents.count > 1 {
                protected.insert(url.path)
                url.deleteLastPathComponent()
            }
        }
        protected.insert("/")
        protected.insert(homePath)
        // Waves version folders are scan locations, but removing an old version is the point.
        for location in locations where location.format == .waves {
            protected.remove(location.url.standardizedFileURL.path)
        }
        protectedPaths = protected
    }

    public init(allowedRoots: [String], protectedPaths: Set<String>) {
        self.allowedRoots = allowedRoots
        self.protectedPaths = protectedPaths
    }

    public func validate(_ url: URL) throws {
        let raw = url.path
        guard raw.hasPrefix("/") else { throw Violation.notAbsolute(raw) }
        // Resolve ".." without following the final symlink, so a link is judged by where it is.
        let path = url.standardizedFileURL.path
        guard !path.split(separator: "/").contains("..") else { throw Violation.outsideManagedFolders(path) }

        var info = stat()
        guard lstat(path, &info) == 0 else { throw Violation.missing(path) }
        guard !protectedPaths.contains(path) else { throw Violation.protectedFolder(path) }
        guard allowedRoots.contains(where: { path.hasPrefix($0 + "/") }) else {
            throw Violation.outsideManagedFolders(path)
        }
    }

    public func isAllowed(_ url: URL) -> Bool {
        (try? validate(url)) != nil
    }
}
