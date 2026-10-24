import Foundation

/// Runs a command-line tool and collects its output. Arguments are passed as an array,
/// never through a shell, so paths with spaces or quotes need no escaping.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var errorOutput: String
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting, so a full pipe buffer can't block the child.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            errorOutput: String(decoding: errData, as: UTF8.self)
        )
    }
}

/// Maps work over a collection on a bounded number of concurrent tasks, keeping order.
public func concurrentMap<T: Sendable, R: Sendable>(
    _ items: [T],
    maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
    _ transform: @escaping @Sendable (T) -> R
) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        let limit = max(1, maxConcurrency)

        while next < min(limit, items.count) {
            let index = next
            group.addTask { (index, transform(items[index])) }
            next += 1
        }
        while let (index, value) = await group.next() {
            results[index] = value
            if next < items.count {
                let index = next
                group.addTask { (index, transform(items[index])) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}
