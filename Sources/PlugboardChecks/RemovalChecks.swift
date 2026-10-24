import Foundation
@testable import PlugboardCore

/// Runs real removals against a throwaway folder: the administrator script as the current user
/// (so no password is needed), immediate deletion, and a round trip through the real Trash.
@MainActor
func removalChecks() async {
    let fileManager = FileManager.default
    let sandbox = fileManager.temporaryDirectory.appending(path: "PlugboardRemoval-\(UUID().uuidString)")
    let home = sandbox.appending(path: "home")
    let vst3 = home.appending(path: "Library/Audio/Plug-Ins/VST3")
    try? fileManager.createDirectory(at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: sandbox) }

    func makePlugin(_ name: String) -> URL {
        let url = vst3.appending(path: name)
        let binary = url.appending(path: "Contents/MacOS/Plugin")
        try? fileManager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: binary.path, contents: Data("plug-in".utf8))
        return url
    }

    func runShell(_ script: String) -> String {
        ProcessRunner.run("/bin/sh", ["-c", script])?.output ?? ""
    }

    let policy = RemovalPolicy(locations: ScanLocation.standard(home: home), home: home)
    let remover = FileRemover(policy: policy, home: home)

    // 1. The administrator script, run without root on files the user owns.
    let tricky = makePlugin("It's a \"Test\" $HOME `x`.vst3")
    let plain = makePlugin("Plain.vst3")
    let missing = vst3.appending(path: "Missing.vst3")
    let (script, planned) = remover.privilegedScript(for: [missing, tricky, plain], mode: .moveToTrash, receipts: [], restartCoreAudio: false)
    checkEqual(planned.count, 2, "Missing items are left out of the script")
    let output = runShell(script)
    checkEqual(FileRemover.parseStatus(output).ok, [0, 1], "Both existing plug-ins reported moved")
    check(!fileManager.fileExists(atPath: tricky.path), "Tricky name left its folder")
    check(fileManager.fileExists(atPath: home.appending(path: ".Trash/It's a \"Test\" $HOME `x`.vst3").path), "Tricky name arrived in the Trash unchanged")

    // 2. Restoring puts both back.
    let removed = planned.map { RemovedItem(originalURL: $0.url, trashedURL: $0.destination, ownerID: $0.owner, groupID: $0.group, usedAdministratorRights: true) }
    let restoreOutput = runShell(remover.restoreScript(for: removed))
    checkEqual(FileRemover.parseStatus(restoreOutput).ok, [0, 1], "Both plug-ins reported restored")
    check(fileManager.fileExists(atPath: tricky.appending(path: "Contents/MacOS/Plugin").path), "Restored bundle is intact")

    // 3. A second trash of the same name gets a numbered name, not an overwrite.
    let occupied = home.appending(path: ".Trash/Plain.vst3")
    try? fileManager.createDirectory(at: occupied, withIntermediateDirectories: true)
    let (_, renamed) = remover.privilegedScript(for: [plain], mode: .moveToTrash, receipts: [], restartCoreAudio: false)
    checkEqual(renamed.first?.destination?.lastPathComponent, "Plain 2.vst3", "Occupied trash name is numbered")

    // 4. The delete script removes the whole tree.
    let (deleteScript, _) = remover.privilegedScript(for: [plain], mode: .deleteImmediately, receipts: [], restartCoreAudio: false)
    checkEqual(FileRemover.parseStatus(runShell(deleteScript)).ok, [0], "Delete script reports success")
    check(!fileManager.fileExists(atPath: plain.path), "Deleted plug-in is gone")

    // 5. The full removal path, without privileges: refused paths stay, allowed ones go.
    let doomed = makePlugin("Doomed.vst3")
    let result = await remover.perform(RemovalRequest(
        urls: [doomed, home.appending(path: "Documents"), vst3],
        mode: .deleteImmediately,
        prompt: ""
    ))
    checkEqual(result.removed.map(\.originalURL.lastPathComponent), ["Doomed.vst3"], "Only the plug-in was deleted")
    checkEqual(result.failures.count, 2, "Outside path and format folder were refused")
    check(fileManager.fileExists(atPath: vst3.path), "The VST3 folder survived")
    check(!result.wasCancelled, "No administrator prompt was needed")

    // 6. A round trip through the real Trash and back with Undo.
    let roundTrip = makePlugin("Plugboard Check \(UUID().uuidString.prefix(8)).vst3")
    let trashed = await remover.perform(RemovalRequest(urls: [roundTrip], mode: .moveToTrash, prompt: ""))
    checkEqual(trashed.removed.count, 1, "Moved to the Trash without a password")
    check(!fileManager.fileExists(atPath: roundTrip.path), "Gone from the plug-in folder")
    let restored = await remover.restore(trashed.removed, prompt: "")
    checkEqual(restored.removed.count, 1, "Put back from the Trash")
    check(fileManager.fileExists(atPath: roundTrip.path), "Back in the plug-in folder")
    if let trashURL = trashed.removed.first?.trashedURL {
        check(!fileManager.fileExists(atPath: trashURL.path), "Nothing left behind in the Trash")
    }
}
