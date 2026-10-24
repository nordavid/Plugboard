import Foundation

/// A lock-protected value, for collecting results from concurrent callbacks.
final class Box<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
}

/// Checks defined in other files register here, since only main.swift runs top-level code.
var extraChecks: [() -> Void] = []
