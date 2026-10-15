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
        case .unreadableFile: return "This project is damaged, uses an unsupported version, or exceeds supported geometry limits. Try another copy or backup."
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
        let backupIDs = (try? fm.contentsOfDirectory(atPath: backupsDirectory.path)) ?? []
        let ids = Set(files.filter { $0.pathExtension == Self.fileExtension }.map { $0.deletingPathExtension().lastPathComponent } + backupIDs)
        return ids.compactMap { id -> ProjectSummary? in
                guard let project = try? load(id: id) else { return nil }
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
        guard Self.safeID(id) else { throw ProjectStoreError.unreadableFile }
        if let (project, upgraded) = try? Self.readAndUpgrade(at: fileURL(for: id), id: id) {
            if upgraded.schemaVersion != project.schemaVersion { try? save(upgraded, preserveTimestamp: true) }
            return upgraded
        }
        // The main file is damaged: fall back to the newest readable backup.
        for backup in backups(for: id) {
            if let (_, upgraded) = try? Self.readAndUpgrade(at: backup, id: id) {
                try? save(upgraded, preserveTimestamp: true)
                return upgraded
            }
        }
        throw ProjectStoreError.unreadableFile
    }

    // MARK: Saving

    public func save(_ project: FloorplanProject, preserveTimestamp: Bool = false) throws {
        try project.validate()
        guard !project.isDemo else { return }
        var copy = project
        if !preserveTimestamp { copy.updatedAt = Date() }
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
    public func delete(id: String) throws {
        guard Self.safeID(id) else { throw ProjectStoreError.unreadableFile }
        let fm = FileManager.default
        for url in [fileURL(for: id), worldMapURL(for: id), backupsDirectory.appendingPathComponent(id, isDirectory: true)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    // MARK: AR world map

    public func saveWorldMap(_ data: Data, for id: String) throws {
        guard Self.safeID(id) else { throw ProjectStoreError.unreadableFile }
        try data.write(to: worldMapURL(for: id), options: .atomic)
    }

    public func worldMap(for id: String) -> Data? {
        guard Self.safeID(id) else { return nil }
        return try? Data(contentsOf: worldMapURL(for: id))
    }

    // MARK: Import / export

    /// Writes a shareable copy named after the project.
    public func exportFile(for project: FloorplanProject) throws -> URL {
        let folder = try ExportFilename.directory()
        let safeName = ExportFilename.sanitized(project.name)
        let url = folder.appendingPathComponent(safeName.isEmpty ? "Mesh Planner" : safeName).appendingPathExtension(Self.fileExtension)
        try Self.encoder().encode(project).write(to: url, options: .atomic)
        return url
    }

    public func isExistingProjectFile(_ url: URL) -> String? {
        let dir = url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let projectsDir = projectsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard dir == projectsDir, url.pathExtension.lowercased() == Self.fileExtension else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        guard Self.safeID(id), (try? load(id: id)) != nil else { return nil }
        return id
    }

    /// Imports a `.signalsim` project, a legacy scan or a web floorplan document. Opens in place when already in `Projects`.
    public func importProject(from url: URL) throws -> FloorplanProject {
        if let existingID = isExistingProjectFile(url) {
            return try load(id: existingID)
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Self.readData(at: url)
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
        guard data.count <= 20_000_000 else { throw ProjectStoreError.unreadableFile }
        let decoder = Self.decoder()
        if let project = try? decoder.decode(FloorplanProject.self, from: data), !project.walls.isEmpty {
            let upgraded = ProjectRepair.upgradeIfNeeded(project)
            try upgraded.validate()
            return upgraded
        }
        if let legacy = try? decoder.decode(LegacyScanState.self, from: data) {
            let project = try legacy.toProject()
            try project.validate()
            return project
        }
        if let document = try? JSONDecoder().decode(SignalFloorplanDocument.self, from: data) {
            guard ["1.0", "2.0"].contains(document.version), document.materials.count <= 1_000,
                  document.walls.count <= 10_000, document.accessPoints.count <= 64 else { throw ProjectStoreError.unreadableFile }
            let project = SignalDataExporter.project(from: document, fallbackName: fallbackName)
            try project.validate()
            return project
        }
        throw ProjectStoreError.unreadableFile
    }

    // MARK: Legacy migration

    /// Converts the single-slot scan saved by earlier versions into a project, once.
    public func migrateLegacyScanIfNeeded() throws -> FloorplanProject? {
        let fm = FileManager.default
        let legacy = legacyDirectory.appendingPathComponent("current_scan.json")
        guard fm.fileExists(atPath: legacy.path) else { return nil }
        let data = try Self.readData(at: legacy)
        let state = try Self.decoder().decode(LegacyScanState.self, from: data)
        let project = try state.toProject()
        try save(project)
        try fm.moveItem(at: legacy, to: legacyDirectory.appendingPathComponent("current_scan.migrated.json"))
        return project
    }

    private static func safeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && id != "." && id != ".." && !id.contains("/") && !id.contains("\\")
    }

    private static func readData(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20_000_000 else { throw ProjectStoreError.unreadableFile }
        return try Data(contentsOf: url)
    }

    private static func readProject(at url: URL) throws -> FloorplanProject {
        try decoder().decode(FloorplanProject.self, from: readData(at: url))
    }

    private static func readAndUpgrade(at url: URL, id: String) throws -> (FloorplanProject, FloorplanProject) {
        let project = try readProject(at: url)
        guard project.id == id else { throw ProjectStoreError.unreadableFile }
        let upgraded = ProjectRepair.upgradeIfNeeded(project)
        try upgraded.validate()
        return (project, upgraded)
    }
}
