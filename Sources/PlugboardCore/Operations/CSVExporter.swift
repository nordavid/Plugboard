import Foundation

/// Writes a plug-in list as CSV that Numbers and Excel open correctly in any region.
public struct CSVExporter: Sendable {
    public struct Column: Sendable {
        public var title: String
        public var value: @Sendable (PluginItem) -> String

        public init(title: String, value: @escaping @Sendable (PluginItem) -> String) {
            self.title = title
            self.value = value
        }
    }

    public var columns: [Column]
    /// Excel splits on the region's list separator: a comma, or a semicolon where the
    /// decimal separator is a comma, as in Germany.
    public var separator: Character

    public init(columns: [Column], locale: Locale = .current) {
        self.columns = columns
        separator = locale.decimalSeparator == "," ? ";" : ","
    }

    public init(columns: [Column], separator: Character) {
        self.columns = columns
        self.separator = separator
    }

    public func csv(for items: [PluginItem]) -> String {
        var lines = [columns.map { escape($0.title) }.joined(separator: String(separator))]
        for item in items {
            lines.append(columns.map { escape($0.value(item)) }.joined(separator: String(separator)))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// UTF-8 with a byte-order mark, which Excel needs to read umlauts correctly.
    public func data(for items: [PluginItem]) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(csv(for: items).utf8)
    }

    func escape(_ field: String) -> String {
        let needsQuotes = field.contains(separator) || field.contains("\"") || field.contains("\n") || field.contains("\r")
        // A leading =, +, - or @ would run as a formula in a spreadsheet.
        var safe = field
        if let first = safe.first, "=+-@".contains(first) {
            safe = "'" + safe
        }
        guard needsQuotes else { return safe }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
