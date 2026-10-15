import Foundation

public struct ProjectSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let updatedAt: Date
    public let areaM2: Float
    public let roomCount: Int
    public let hasWorldMap: Bool
}

public enum ProjectStoreError: LocalizedError {
    case unreadableFile

    public var errorDescription: String? {
        switch self {
        case .unreadableFile: return "This file is not a valid Mesh Planner project."
        }
    }
}

/// Saves projects off the main thread. Each project is one `.signalsim` file (JSON) in Documents/Projects,
/// visible in the Files app; up to five timestamped backups per project live in Application Support.
/// Older builds used Documents/Projetos; that folder is renamed on first launch.
public actor ProjectStore {
    public static let fileExtension = "signalsim"
    static let backupsToKeep = 5
    static let backupInterval: TimeInterval = 10 * 60
    static let projectsFolderName = "Projects"
    static let legacyProjectsFolderName = "Projetos"

    public let projectsDirectory: URL
    let backupsDirectory: URL
    let legacyDirectory: URL

    public init(rootDirectory: URL? = nil) {
        let fm = FileManager.default
        let documents = rootDirectory ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = rootDirectory?.appendingPathComponent("Support", isDirectory: true)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let projects = documents.appendingPathComponent(Self.projectsFolderName, isDirectory: true)
        let legacyProjects = documents.appendingPathComponent(Self.legacyProjectsFolderName, isDirectory: true)
        Self.migrateLegacyProjectsFolder(from: legacyProjects, to: projects)
        projectsDirectory = projects
        backupsDirectory = support.appendingPathComponent("Backups", isDirectory: true)
        legacyDirectory = documents
        try? fm.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
    }

    /// Renames Documents/Projetos → Documents/Projects, or merges leftover files if both exist.
    static func migrateLegacyProjectsFolder(from legacy: URL, to current: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        if !fm.fileExists(atPath: current.path) {
            try? fm.moveItem(at: legacy, to: current)
            return
        }
        let files = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let dest = current.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: file, to: dest)
            }
        }
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func fileURL(for id: String) -> URL {
        projectsDirectory.appendingPathComponent(id).appendingPathExtension(Self.fileExtension)
    }

    func worldMapURL(for id: String) -> URL {
        projectsDirectory.appendingPathComponent(".\(id).worldmap")
    }

    // MARK: Listing and loading

    public func list() -> [ProjectSummary] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url -> ProjectSummary? in
                guard let data = try? Data(contentsOf: url),
                      let decoded = try? Self.decoder().decode(FloorplanProject.self, from: data) else { return nil }
                let project = ProjectRepair.upgradeIfNeeded(decoded)
                return ProjectSummary(
                    id: project.id,
                    name: project.name,
                    updatedAt: project.updatedAt,
                    areaM2: project.areaM2,
                    roomCount: project.rooms.count,
                    hasWorldMap: fm.fileExists(atPath: worldMapURL(for: project.id).path)
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(id: String) throws -> FloorplanProject {
        let data = try Data(contentsOf: fileURL(for: id))
        if let project = try? Self.decoder().decode(FloorplanProject.self, from: data) {
            let upgraded = ProjectRepair.upgradeIfNeeded(project)
            if upgraded.schemaVersion != project.schemaVersion { try? save(upgraded) }
            return upgraded
        }
        // The main file is damaged: fall back to the newest readable backup.
        for backup in backups(for: id) {
            if let data = try? Data(contentsOf: backup), let project = try? Self.decoder().decode(FloorplanProject.self, from: data) {
                return project
            }
        }
        throw ProjectStoreError.unreadableFile
    }

    // MARK: Saving

    public func save(_ project: FloorplanProject) throws {
        guard !project.isDemo else { return }
        var copy = project
        copy.updatedAt = Date()
        let data = try Self.encoder().encode(copy)
        try data.write(to: fileURL(for: project.id), options: .atomic)
        rotateBackup(data: data, id: project.id)
    }

    func backups(for id: String) -> [URL] {
        let folder = backupsDirectory.appendingPathComponent(id, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == Self.fileExtension }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func rotateBackup(data: Data, id: String) {
        let fm = FileManager.default
        let folder = backupsDirectory.appendingPathComponent(id, isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = backups(for: id)
        if let newest = existing.first,
           let date = (try? fm.attributesOfItem(atPath: newest.path)[.modificationDate]) as? Date,
           Date().timeIntervalSince(date) < Self.backupInterval {
            return
        }
        let stamp = Int(Date().timeIntervalSince1970)
        try? data.write(to: folder.appendingPathComponent("\(stamp)").appendingPathExtension(Self.fileExtension), options: .atomic)
        for old in backups(for: id).dropFirst(Self.backupsToKeep) {
            try? fm.removeItem(at: old)
        }
    }

    // MARK: Deleting

    /// Removes the project, its backups and its AR world map.
    public func delete(id: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL(for: id))
        try? fm.removeItem(at: worldMapURL(for: id))
        try? fm.removeItem(at: backupsDirectory.appendingPathComponent(id, isDirectory: true))
    }

    // MARK: AR world map

    public func saveWorldMap(_ data: Data, for id: String) throws {
        try data.write(to: worldMapURL(for: id), options: .atomic)
    }

    public func worldMap(for id: String) -> Data? {
        try? Data(contentsOf: worldMapURL(for: id))
    }

    // MARK: Import / export

    /// Writes a shareable copy named after the project.
    public func exportFile(for project: FloorplanProject) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = project.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let url = folder.appendingPathComponent(safeName.isEmpty ? "Mesh Planner" : safeName).appendingPathExtension(Self.fileExtension)
        try Self.encoder().encode(project).write(to: url, options: .atomic)
        return url
    }

    /// Imports a `.signalsim` project, a legacy scan or a web floorplan document. Always creates a new project.
    public func importProject(from url: URL) throws -> FloorplanProject {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let fallbackName = url.deletingPathExtension().lastPathComponent
        var project = try Self.decodeAnyFormat(data, fallbackName: fallbackName)
        project = FloorplanProject(
            name: project.name,
            width: project.width,
            depth: project.depth,
            walls: project.walls,
            accessPoints: project.accessPoints,
            rooms: project.rooms,
            furniture: project.furniture,
            profile: project.profile,
            calibration: project.calibration,
            measurements: project.measurements,
            probe: project.probe,
            probeFloor: project.probeFloor,
            selectedBand: project.selectedBand,
            worldAlignment: project.worldAlignment,
            floorCount: project.floorCount
        )
        try save(project)
        return project
    }

    static func decodeAnyFormat(_ data: Data, fallbackName: String) throws -> FloorplanProject {
        let decoder = Self.decoder()
        if let project = try? decoder.decode(FloorplanProject.self, from: data), !project.walls.isEmpty {
            return project
        }
        if let legacy = try? decoder.decode(LegacyScanState.self, from: data) {
            return legacy.toProject()
        }
        if let document = try? JSONDecoder().decode(SignalFloorplanDocument.self, from: data) {
            return SignalDataExporter.project(from: document, fallbackName: fallbackName)
        }
        throw ProjectStoreError.unreadableFile
    }

    // MARK: Legacy migration

    /// Converts the single-slot scan saved by earlier versions into a project, once.
    public func migrateLegacyScanIfNeeded() -> FloorplanProject? {
        let fm = FileManager.default
        let legacy = legacyDirectory.appendingPathComponent("current_scan.json")
        guard fm.fileExists(atPath: legacy.path) else { return nil }
        defer { try? fm.moveItem(at: legacy, to: legacyDirectory.appendingPathComponent("current_scan.migrated.json")) }
        guard let data = try? Data(contentsOf: legacy),
              let state = try? Self.decoder().decode(LegacyScanState.self, from: data) else { return nil }
        let project = state.toProject()
        try? save(project)
        return project
    }
}
