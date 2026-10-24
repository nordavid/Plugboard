import Foundation

/// Runs shell commands as root through the standard macOS administrator prompt.
///
/// Plug-ins in /Library are often owned by root. Rather than install a privileged helper,
/// Plugboard asks for the administrator password once per batch, the same prompt
/// Installer and Finder show.
@MainActor
public enum PrivilegedShell {
    public enum Failure: Error, Sendable, Equatable {
        case cancelled
        case failed(String)
    }

    /// Runs the script and returns its standard output. NSAppleScript must run on the main thread.
    public static func run(_ script: String, prompt: String) -> Result<String, Failure> {
        let source = "do shell script \(appleScriptLiteral(script)) with prompt \(appleScriptLiteral(prompt)) with administrator privileges without altering line endings"
        guard let appleScript = NSAppleScript(source: source) else {
            return .failure(.failed("Couldn't prepare the administrator request."))
        }
        var errorInfo: NSDictionary?
        let output = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -128 { return .failure(.cancelled) }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Error \(number)"
            return .failure(.failed(message))
        }
        return .success(output.stringValue ?? "")
    }

    /// Wraps a value in single quotes for /bin/sh. Nothing inside single quotes is expanded.
    public nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wraps a value in an AppleScript string literal.
    public nonisolated static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
