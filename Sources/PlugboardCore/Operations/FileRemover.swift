import Darwin
import Foundation

public enum RemovalMode: String, Sendable, Hashable {
    case moveToTrash
    case deleteImmediately
}

/// Something that was removed, with what's needed to put it back.
public struct RemovedItem: Sendable, Hashable {
    public var originalURL: URL
    /// Nil when the item was deleted immediately.
    public var trashedURL: URL?
    public var ownerID: UInt32
    public var groupID: UInt32
    public var usedAdministratorRights: Bool
}

public struct RemovalFailure: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var reason: Reason

    public enum Reason: Sendable, Hashable {
        case notAllowed
        case missing
        case inUse
        case appManagementBlocked
        case other(String)
    }
}

public struct RemovalResult: Sendable {
    public var removed: [RemovedItem] = []
    public var failures: [RemovalFailure] = []
    /// The administrator prompt was dismissed; nothing that needed it happened.
    public var wasCancelled = false
    public var forgottenReceipts: [String] = []

    public init() {}
}

/// A removal to perform, after the user confirmed it.
public struct RemovalRequest: Sendable {
    public var urls: [URL]
    public var mode: RemovalMode
    /// Installer receipt IDs to forget with `pkgutil --forget`.
    public var receiptsToForget: [String]
    /// Restart Core Audio so a removed audio driver unloads.
    public var restartsCoreAudio: Bool
    /// Shown in the administrator prompt, if one is needed.
    public var prompt: String

    public init(urls: [URL], mode: RemovalMode, receiptsToForget: [String] = [], restartsCoreAudio: Bool = false, prompt: String) {
        self.urls = urls
        self.mode = mode
        self.receiptsToForget = receiptsToForget
        self.restartsCoreAudio = restartsCoreAudio
        self.prompt = prompt
    }
}

/// Moves plug-ins to the Trash or deletes them, asking for an administrator password only
/// for the items that need one, and only once per batch.
@MainActor
public final class FileRemover {
    private let policy: RemovalPolicy
    private let home: URL
    /// Large batches are split so a single shell script stays well under the argument limit.
    private let batchSize = 200

    public init(policy: RemovalPolicy, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.policy = policy
        self.home = home
    }

    public func perform(_ request: RemovalRequest) async -> RemovalResult {
        var result = RemovalResult()
        var allowed: [URL] = []
        for url in request.urls {
            do {
                try policy.validate(url)
                allowed.append(url)
            } catch RemovalPolicy.Violation.missing {
                result.failures.append(RemovalFailure(url: url, reason: .missing))
            } catch {
                result.failures.append(RemovalFailure(url: url, reason: .notAllowed))
            }
        }

        // Items the user can remove on their own go first, off the main thread.
        let mode = request.mode
        let candidates = allowed
        let attempts = await Task.detached(priority: .userInitiated) {
            candidates.map { url in (url, Self.removeWithoutPrivileges(url, mode: mode)) }
        }.value

        var needsAdministrator: [URL] = []
        for (url, attempt) in attempts {
            switch attempt {
            case .removed(let item): result.removed.append(item)
            case .needsAdministrator: needsAdministrator.append(url)
            case .failed(let reason): result.failures.append(RemovalFailure(url: url, reason: reason))
            }
        }

        let needsPrivileges = !needsAdministrator.isEmpty || !request.receiptsToForget.isEmpty || request.restartsCoreAudio
        guard needsPrivileges else { return result }

        var batches = stride(from: 0, to: needsAdministrator.count, by: batchSize).map {
            Array(needsAdministrator[$0..<min($0 + batchSize, needsAdministrator.count)])
        }
        if batches.isEmpty { batches = [[]] }

        for (index, batch) in batches.enumerated() {
            let isLast = index == batches.count - 1
            let outcome = runPrivileged(
                batch,
                mode: request.mode,
                receipts: isLast ? request.receiptsToForget : [],
                restartCoreAudio: isLast && request.restartsCoreAudio,
                prompt: request.prompt
            )
            switch outcome {
            case .success(let partial):
                result.removed += partial.removed
                result.failures += partial.failures
                result.forgottenReceipts += partial.forgottenReceipts
            case .failure(.cancelled):
                result.wasCancelled = true
                return result
            case .failure(.failed(let message)):
                result.failures += batch.map { RemovalFailure(url: $0, reason: .other(message)) }
            }
        }
        return result
    }

    /// Puts trashed items back where they were. Deleted items can't be restored.
    public func restore(_ items: [RemovedItem], prompt: String) async -> RemovalResult {
        var result = RemovalResult()
        let restorable = items.filter { $0.trashedURL != nil }

        let attempts = await Task.detached(priority: .userInitiated) {
            restorable.map { item -> (RemovedItem, Bool) in
                guard let trashed = item.trashedURL else { return (item, false) }
                do {
                    try FileManager.default.createDirectory(at: item.originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: trashed, to: item.originalURL)
                    return (item, true)
                } catch {
                    return (item, false)
                }
            }
        }.value

        var privileged: [RemovedItem] = []
        for (item, restored) in attempts {
            if restored { result.removed.append(item) } else { privileged.append(item) }
        }
        guard !privileged.isEmpty else { return result }

        let script = restoreScript(for: privileged)
        switch PrivilegedShell.run(script, prompt: prompt) {
        case .success(let output):
            let status = Self.parseStatus(output)
            for (index, item) in privileged.enumerated() {
                if status.ok.contains(index) {
                    result.removed.append(item)
                } else {
                    result.failures.append(RemovalFailure(url: item.originalURL, reason: .other("")))
                }
            }
        case .failure(.cancelled):
            result.wasCancelled = true
        case .failure(.failed(let message)):
            result.failures += privileged.map { RemovalFailure(url: $0.originalURL, reason: .other(message)) }
        }
        return result
    }

    /// Builds the script that moves trashed items back and restores their original owner.
    nonisolated func restoreScript(for items: [RemovedItem]) -> String {
        var script = Self.scriptPreamble
        for (index, item) in items.enumerated() {
            guard let trashed = item.trashedURL else { continue }
            let original = PrivilegedShell.shellQuote(item.originalURL.path)
            let source = PrivilegedShell.shellQuote(trashed.path)
            let parent = PrivilegedShell.shellQuote(item.originalURL.deletingLastPathComponent().path)
            script += """
            if ! exists \(original) && /bin/mkdir -p \(parent) && /bin/mv -n -- \(source) \(original) && exists \(original); then \
            /usr/sbin/chown -R -h \(item.ownerID):\(item.groupID) \(original); echo "OK:\(index)"; else echo "FAIL:\(index)"; fi

            """
        }
        return script
    }

    // MARK: Without privileges

    enum Attempt {
        case removed(RemovedItem)
        case needsAdministrator
        case failed(RemovalFailure.Reason)
    }

    nonisolated static func removeWithoutPrivileges(_ url: URL, mode: RemovalMode) -> Attempt {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .failed(.missing) }
        let owner = info.st_uid
        let group = info.st_gid

        switch mode {
        case .moveToTrash:
            do {
                var trashed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                return .removed(RemovedItem(originalURL: url, trashedURL: trashed as URL?, ownerID: owner, groupID: group, usedAdministratorRights: false))
            } catch {
                return isPermissionError(error) ? .needsAdministrator : .failed(reason(for: error, at: url))
            }
        case .deleteImmediately:
            // Deleting a tree can fail halfway through. Only start when every folder in it is
            // writable, so a plug-in is never left half-deleted.
            guard isFullyWritable(url) else { return .needsAdministrator }
            do {
                try FileManager.default.removeItem(at: url)
                return .removed(RemovedItem(originalURL: url, trashedURL: nil, ownerID: owner, groupID: group, usedAdministratorRights: false))
            } catch {
                return isPermissionError(error) ? .needsAdministrator : .failed(reason(for: error, at: url))
            }
        }
    }

    nonisolated static func isFullyWritable(_ url: URL) -> Bool {
        guard access(url.deletingLastPathComponent().path, W_OK) == 0 else { return false }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        guard info.st_mode & S_IFMT == S_IFDIR else { return true }

        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return false }
        if access(url.path, W_OK) != 0 { return false }
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true, values?.isSymbolicLink != true, access(child.path, W_OK) != 0 {
                return false
            }
        }
        return true
    }

    nonisolated static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(nsError.code) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionError(underlying)
        }
        return false
    }

    nonisolated static func reason(for error: Error, at url: URL) -> RemovalFailure.Reason {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError { return .missing }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EBUSY) { return .inUse }
        return .other(nsError.localizedDescription)
    }

    // MARK: With privileges

    private struct PrivilegedOutcome {
        var removed: [RemovedItem] = []
        var failures: [RemovalFailure] = []
        var forgottenReceipts: [String] = []
    }

    nonisolated static let scriptPreamble = "exists() { [ -e \"$1\" ] || [ -L \"$1\" ]; }\n"

    /// One item in a privileged batch, with where it goes and who owned it.
    struct PlannedRemoval {
        var url: URL
        var destination: URL?
        var owner: UInt32
        var group: UInt32
    }

    /// Builds the shell script for a batch. Separate from running it, so checks can run the same
    /// script without root against files the user owns.
    func privilegedScript(
        for urls: [URL],
        mode: RemovalMode,
        receipts: [String],
        restartCoreAudio: Bool,
        userID: UInt32 = getuid(),
        groupID: UInt32 = getgid()
    ) -> (script: String, planned: [PlannedRemoval]) {
        var reservedNames = Set<String>()
        var planned: [PlannedRemoval] = []
        var script = Self.scriptPreamble

        for url in urls {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let index = planned.count
            let source = PrivilegedShell.shellQuote(url.path)

            switch mode {
            case .moveToTrash:
                let destination = uniqueTrashURL(for: url, reserved: &reservedNames)
                let target = PrivilegedShell.shellQuote(destination.path)
                // Hand the trashed copy to the user so emptying the Trash never asks for a password.
                script += """
                if /bin/mv -n -- \(source) \(target) && ! exists \(source) && exists \(target); then \
                /usr/sbin/chown -R -h \(userID):\(groupID) \(target); echo "OK:\(index)"; else echo "FAIL:\(index)"; fi

                """
                planned.append(PlannedRemoval(url: url, destination: destination, owner: info.st_uid, group: info.st_gid))
            case .deleteImmediately:
                script += """
                if /bin/rm -rf -- \(source) && ! exists \(source); then echo "OK:\(index)"; else echo "FAIL:\(index)"; fi

                """
                planned.append(PlannedRemoval(url: url, destination: nil, owner: info.st_uid, group: info.st_gid))
            }
        }

        for (index, receipt) in receipts.enumerated() {
            script += "/usr/sbin/pkgutil --forget \(PrivilegedShell.shellQuote(receipt)) >/dev/null 2>&1 && echo \"RECEIPT:\(index)\"\n"
        }
        if restartCoreAudio {
            // launchd starts Core Audio again right away, without the removed driver.
            script += "/usr/bin/killall coreaudiod >/dev/null 2>&1 || true\n"
        }
        return (script, planned)
    }

    private func runPrivileged(
        _ urls: [URL],
        mode: RemovalMode,
        receipts: [String],
        restartCoreAudio: Bool,
        prompt: String
    ) -> Result<PrivilegedOutcome, PrivilegedShell.Failure> {
        let (script, planned) = privilegedScript(for: urls, mode: mode, receipts: receipts, restartCoreAudio: restartCoreAudio)

        switch PrivilegedShell.run(script, prompt: prompt) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let output):
            let status = Self.parseStatus(output)
            var outcome = PrivilegedOutcome()
            for (index, plan) in planned.enumerated() {
                if status.ok.contains(index) {
                    outcome.removed.append(RemovedItem(
                        originalURL: plan.url,
                        trashedURL: plan.destination,
                        ownerID: plan.owner,
                        groupID: plan.group,
                        usedAdministratorRights: true
                    ))
                } else {
                    let blocked = plan.url.path.hasPrefix("/Applications/")
                    outcome.failures.append(RemovalFailure(url: plan.url, reason: blocked ? .appManagementBlocked : .other("")))
                }
            }
            outcome.forgottenReceipts = receipts.enumerated().filter { status.receipts.contains($0.offset) }.map(\.element)
            return .success(outcome)
        }
    }

    nonisolated static func parseStatus(_ output: String) -> (ok: Set<Int>, receipts: Set<Int>) {
        var ok = Set<Int>()
        var receipts = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("OK:"), let index = Int(line.dropFirst(3)) { ok.insert(index) }
            if line.hasPrefix("RECEIPT:"), let index = Int(line.dropFirst(8)) { receipts.insert(index) }
        }
        return (ok, receipts)
    }

    /// A free name in ~/.Trash, numbered the way Finder does when the name is taken.
    func uniqueTrashURL(for url: URL, reserved: inout Set<String>) -> URL {
        let trash = home.appending(path: ".Trash", directoryHint: .isDirectory)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var attempt = 1
        while true {
            let name = attempt == 1 ? url.lastPathComponent : (ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)")
            let candidate = trash.appending(path: name)
            var info = stat()
            if lstat(candidate.path, &info) != 0, reserved.insert(name).inserted {
                return candidate
            }
            attempt += 1
        }
    }
}
