import Foundation
import Testing
import simd
@testable import SignalCore

@Suite("Project store")
struct ProjectStoreTests {
    func makeStore() -> (ProjectStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signal-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ProjectStore(rootDirectory: root), root)
    }

    func sampleProject(name: String = "Casa") -> FloorplanProject {
        var project = DefaultApartmentFixture.makeProject()
        project = FloorplanProject(name: name, width: project.width, depth: project.depth, walls: project.walls, accessPoints: project.accessPoints, rooms: project.rooms, probe: project.probe)
        return project
    }

    @Test func saveListLoadAndDelete() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = sampleProject()
        try await store.save(project)
        try await store.saveWorldMap(Data([1, 2, 3]), for: project.id)
        let list = await store.list()
        #expect(list.map(\.id) == [project.id])
        #expect(list.first?.hasWorldMap == true)
        let loaded = try await store.load(id: project.id)
        #expect(loaded.walls == project.walls)
        #expect(loaded.rooms == project.rooms)

        try await store.delete(id: project.id)
        #expect(await store.list().isEmpty)
        #expect(await store.worldMap(for: project.id) == nil)
        #expect(await store.backups(for: project.id).isEmpty)
        await #expect(throws: (any Error).self) { try await store.load(id: project.id) }
    }

    @Test func demoProjectsAreNeverSaved() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.save(DefaultApartmentFixture.makeProject())
        #expect(await store.list().isEmpty)
    }

    @Test func backupsAreBounded() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = sampleProject()
        for _ in 0..<20 { try await store.save(project) }
        #expect(await store.backups(for: project.id).count <= ProjectStore.backupsToKeep)
        #expect(await store.backups(for: project.id).count == 1, "saves within the backup interval reuse the last backup")
    }

    @Test func exportAndImportRoundTrip() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = sampleProject(name: "Apartamento / 2º andar")
        let url = try await store.exportFile(for: project)
        #expect(url.pathExtension == ProjectStore.fileExtension)
        let imported = try await store.importProject(from: url)
        #expect(imported.id != project.id)
        #expect(imported.walls == project.walls)
        #expect(await store.list().count == 1)
    }

    @Test func webDocumentsKeepOpenDoorways() throws {
        let project = sampleProject()
        let data = try SignalDataExporter.exportJSON(SignalDataExporter.document(from: project))
        let restored = try ProjectStore.decodeAnyFormat(data, fallbackName: "web")
        let doorway = try #require(restored.walls.first { $0.material.id == RFMaterial.openDoor.id })
        #expect(doorway.material.isTransparent)
        #expect(restored.width == project.width)
    }

    @Test func legacyScanIsMigratedOnce() async throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = """
        {"title":"Cômodo antigo","date":"2026-09-26T20:00:00Z","floorplanWidth":5,"floorplanDepth":4,"roomAreaM2":20,"isCustomScan":true,
         "walls":[{"id":"w1","name":"Parede","p1":[0,0],"p2":[5,0],"material":{"id":"glass","name":"Low-E glass","crossingLoss":[20,25,28],"reflectionLoss":5,"colorHex":"#7fb6d6","defaultThickness":0.03},"thickness":0.1,"height":2.7,"isActive":true,"objId":0}],
         "accessPoints":[{"id":"r","name":"Roteador","position":[2,2],"txPower":20,"isSatellite":false,"backhaulRSSI":-50,"isActive":true}],
         "probePosition":[1,1],"roomPolygon":[[0,0],[5,0],[5,4],[0,4]],"rawObjects":[],"selectedBand":"5","revealSlider":0.85,"reflectionsEnabled":true}
        """
        try Data(legacy.utf8).write(to: root.appendingPathComponent("current_scan.json"))
        let migrated = try #require(await store.migrateLegacyScanIfNeeded())
        #expect(migrated.name == "Cômodo antigo")
        #expect(migrated.rooms.count == 1)
        #expect(migrated.walls.first?.material == RFMaterial.glass, "old Low-E default on windows becomes clear glass")
        #expect(migrated.schemaVersion == FloorplanProject.currentSchemaVersion)
        #expect(await store.migrateLegacyScanIfNeeded() == nil)
        #expect(await store.list().count == 1)
    }

    @Test func malformedMaterialArraysDecodeSafely() throws {
        let json = ##"{"id":"x","name":"X","crossingLoss":[7],"reflectionLoss":5,"colorHex":"#fff","defaultThickness":0.1}"##
        let material = try JSONDecoder().decode(RFMaterial.self, from: Data(json.utf8))
        #expect(material.crossingLoss(for: .six) == 7)
    }

    @Test func legacyProjectsFolderIsRenamed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signal-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Projetos", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let project = sampleProject()
        try ProjectStore.encoder().encode(project).write(to: legacy.appendingPathComponent("\(project.id).signalsim"))
        let store = ProjectStore(rootDirectory: root)
        let folder = await store.projectsDirectory.lastPathComponent
        #expect(folder == "Projects")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(await store.list().map(\.id) == [project.id])
    }
}
