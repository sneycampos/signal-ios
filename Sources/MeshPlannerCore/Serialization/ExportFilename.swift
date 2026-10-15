import Foundation

public enum ExportFilename {
    public static func sanitized(_ name: String) -> String {
        let value = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "." || value == ".." ? "Mesh Planner" : String(value.prefix(120))
    }

    public static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
