import Foundation
import Testing
@testable import SignalCore

@Suite("Review regressions")
struct ReviewRegressionTests {
    func project() -> FloorplanProject {
        let polygon: [SIMD2<Float>] = [[0, 0], [4, 0], [4, 4], [0, 4]]
        return FloorplanProject(name: "Synthetic", width: 4, depth: 4,
            walls: [RFWallSegment(p1: [0, 0], p2: [4, 0], material: .drywall)],
            accessPoints: [RFAccessPoint(name: "Router", position: [1, 1])],
            rooms: [RoomInfo(name: "Room", kind: .bedroom, polygon: polygon)], probe: [2, 2])
    }

    func store() throws -> (ProjectStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ProjectStore(rootDirectory: root), root)
    }

    @Test(arguments: ["dimension", "floor", "rooms", "schema", "id", "reflection"])
    func malformedNativeProjectsAreRejected(kind: String) throws {
        var p = project()
        switch kind {
        case "dimension": p.width = .greatestFiniteMagnitude
        case "floor": p.walls[0].floor = Int.max
        case "rooms": p.rooms.append(p.rooms[0])
        case "schema": p.schemaVersion = 999
        case "reflection":
            p.walls[0].material = RFMaterial(id: "invalid", name: "Negative reflection", crossingLoss: [4, 4, 4],
                reflectionLoss: -1000, colorHex: "#000000", defaultThickness: 0.1)
        default:
            var json = try #require(JSONSerialization.jsonObject(with: ProjectStore.encoder().encode(p)) as? [String: Any])
            json["id"] = "../outside"
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try ProjectStore.decodeAnyFormat(data, fallbackName: "bad") }
            return
        }
        let data = try ProjectStore.encoder().encode(p)
        #expect(throws: (any Error).self) { try ProjectStore.decodeAnyFormat(data, fallbackName: "bad") }
    }

    @Test(arguments: [false, true])
    func listingRecoversMissingOrCorruptPrimary(corrupt: Bool) async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = project()
        try await store.save(p)
        let primary = await store.fileURL(for: p.id)
        if corrupt { try Data("broken".utf8).write(to: primary) }
        else { try FileManager.default.removeItem(at: primary) }
        #expect(await store.list().map(\.id) == [p.id])
        let recovered = try await store.load(id: p.id)
        #expect(recovered.walls == p.walls)
        #expect(FileManager.default.fileExists(atPath: primary.path))
    }

    @Test func nativeImportMigratesBeforeRestamping() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        var p = project()
        p.schemaVersion = 1
        p.walls[0].material = .legacyGlass
        p.walls[0].kind = .window
        let expected = ProjectRepair.upgradeIfNeeded(p)
        let url = root.appendingPathComponent("old.signalsim")
        try ProjectStore.encoder().encode(p).write(to: url)
        let imported = try await store.importProject(from: url)
        #expect(imported.id != p.id)
        #expect(imported.schemaVersion == FloorplanProject.currentSchemaVersion)
        #expect(imported.walls == expected.walls)
        #expect(imported.rooms == expected.rooms)
    }

    @Test @MainActor func switchingFlushesEditsAndClosingClearsWork() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = project()
        try await store.save(p)
        let model = FloorplanViewModel(store: store)
        await model.open(id: p.id)
        model.rename(to: "Saved before switch")
        await model.openDemo()
        #expect(try await store.load(id: p.id).name == "Saved before switch")
        await model.close()
        #expect(model.project == nil)
        #expect(model.field == nil)
        #expect(!model.isComputing)
    }

    @Test @MainActor func optimizerIsInvalidatedByFloorAndEdits() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        var p = project()
        p.floorCount = 2
        try await store.save(p)
        let model = FloorplanViewModel(store: store)
        await model.open(id: p.id)
        model.runOptimizer(satellites: .exactly(1), lockRouter: false)
        model.setFloor(1)
        #expect(model.optimizer == .idle)
        model.runOptimizer(satellites: .exactly(1), lockRouter: false)
        model.rename(to: "New revision")
        #expect(model.optimizer == .idle)
        model.applyOptimizerResult()
        #expect(model.project?.accessPoints == p.accessPoints)
        await model.close()
    }

    @Test func upstairsOptimizationKeepsTheRouterDownstairs() throws {
        var p = project()
        p.rooms[0].floor = 1
        let router = try #require(p.router)
        let result = try #require(PlacementOptimizer.optimize(PlacementRequest(walls: p.walls, rooms: p.rooms,
            accessPoints: p.accessPoints, profile: p.profile, width: 4, depth: 4, floor: 1, satellites: .exactly(1))))
        #expect(result.routerPosition == router.position)
        #expect(result.satellitePositions.count == 1)
    }

    @Test(arguments: [1, 2])
    func smallCalibrationPreservesDistanceModel(count: Int) throws {
        let p = project()
        let current = Calibration(pathLossExponent: 2.8, wallLossScale: 1.2)
        let model = PropagationModel(walls: p.walls, band: .five, calibration: current)
        let measurements = (0..<count).map { i in
            let point = SIMD2<Float>(Float(i + 2), 2)
            return SignalMeasurement(position: point, band: .five, rssi: model.best(from: p.accessPoints, to: point, floor: 0).rssi + 3)
        }
        let result = try #require(Calibrator.fit(measurements: measurements, walls: p.walls, accessPoints: p.accessPoints, profile: p.profile, current: current))
        #expect(result.calibration.pathLossExponent == current.pathLossExponent)
        #expect(result.calibration.wallLossScale == current.wallLossScale)
        #expect(abs(result.calibration.offsetDb - 3) < 0.01)
    }

    @Test func crossFloorPathsAreReciprocal() {
        let wall = RFWallSegment(p1: [2, 0], p2: [2, 4], material: .brick, floor: 0)
        let model = PropagationModel(walls: [wall], band: .five)
        let forward = model.pathLoss(from: [1, 2], floorA: 0, to: [3, 2], floorB: 1)
        let reverse = model.pathLoss(from: [3, 2], floorA: 1, to: [1, 2], floorB: 0)
        #expect(abs(forward - reverse) < 0.001)
    }

    @Test func disconnectedSatellitesHaveNoUpstream() {
        var p = project()
        p.accessPoints[0].isSatellite = true
        let model = PropagationModel(walls: p.walls, band: .five)
        let reading = FloorplanViewModel.reading(project: p, model: model, backhaul: [:], point: [2, 2], floor: 0)
        #expect(reading.effectiveThroughputMbps == 0)
    }

    @Test func widthsAndGridAreHardBounded() {
        var profile = NetworkProfile(standard: .wifi6E, channelWidth6: 320)
        #expect(profile.channelWidth(for: .six) == 160)
        profile.standard = .wifi7
        #expect(profile.channelWidth(for: .six) == 320)
        profile.standard = .wifi6E
        profile.normalizeChannelWidths()
        #expect(profile.channelWidth6 == 160)
        for dimensions: SIMD2<Float> in [[1000, 0.01], [1000, 1000], [.greatestFiniteMagnitude, 1]] {
            #expect(FieldGrid.covering(width: dimensions.x, depth: dimensions.y, targetCell: 0.1, maxCells: 1400).count <= 1400)
        }
    }

    @Test @MainActor func failedSaveKeepsProjectOpenForRetry() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = project()
        try await store.save(p)
        let model = FloorplanViewModel(store: store)
        await model.open(id: p.id)
        let directory = await store.projectsDirectory
        try FileManager.default.removeItem(at: directory)
        try Data([0]).write(to: directory)
        model.rename(to: "Unsaved edit")
        await model.close()
        #expect(model.project?.name == "Unsaved edit")
        #expect(model.errorMessage != nil)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(await model.flushSave())
        #expect(try await store.load(id: p.id).name == "Unsaved edit")
        await model.close()
    }

    @Test @MainActor func editingAnObstacleUpdatesAllItsFaces() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        var p = project()
        p.walls = [
            RFWallSegment(p1: [1, 1], p2: [2, 1], material: .concrete, objId: 7, kind: .obstacle),
            RFWallSegment(p1: [1, 2], p2: [2, 2], material: .concrete, objId: 7, kind: .obstacle)
        ]
        try await store.save(p)
        let model = FloorplanViewModel(store: store)
        await model.open(id: p.id)
        model.setMaterial(.drywall, forWalls: [p.walls[0].id])
        #expect(model.project?.walls.allSatisfy { $0.material == .drywall && !$0.isMaterialAuto } == true)
        await model.close()
    }

    @Test func backhaulPrefersFasterDirectRouteOverStrongerRelay() throws {
        let router = RFAccessPoint(name: "Router", position: [0, 0])
        let relay = RFAccessPoint(name: "Relay", position: [8, 0], txPower: 30, isSatellite: true)
        let client = RFAccessPoint(name: "Client", position: [9, 0], isSatellite: true)
        let profile = NetworkProfile()
        let model = PropagationModel(walls: [], band: profile.effectiveBackhaulBand)
        #expect(model.rssi(from: relay, to: client.position, floor: 0) > model.rssi(from: router, to: client.position, floor: 0))
        let links = BackhaulPlanner.plan(accessPoints: [router, relay, client], walls: [], profile: profile)
        #expect(try #require(links[client.id]).parentId == router.id)
    }

    @Test func captureKeepsActualFloorElevations() throws {
        let polygon: [SIMD2<Float>] = [[0, 0], [4, 0], [4, 4], [0, 4]]
        let capture = RoomPlanCapture(surfaces: [], floors: [
            RoomPlanRawFloor(polygon: polygon, story: -1, y: -0.4),
            RoomPlanRawFloor(polygon: polygon, story: 1, y: 3.1)
        ], floorY: -0.4)
        let converted = RoomPlanConverter.convert(capture)
        #expect(converted.alignment.elevation(for: 1, floorHeight: 2.8) == 3.1)
        let data = try JSONEncoder().encode(converted.alignment)
        let decoded = try JSONDecoder().decode(WorldAlignment.self, from: data)
        #expect(decoded.floorElevations == [-0.4, 3.1])
    }
}


extension ReviewRegressionTests {
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Background operation did not reach the expected state")
    }

    @Test @MainActor func failedReplacementPreservesWorldMapAvailability() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = project()
        try await store.save(p)
        try await store.saveWorldMap(Data([0]), for: p.id)
        let model = FloorplanViewModel(store: store)
        await model.open(id: p.id)
        #expect(model.hasWorldMap)
        let directory = await store.projectsDirectory
        try FileManager.default.removeItem(at: directory)
        try Data([0]).write(to: directory)
        model.rename(to: "Unsaved")
        await model.openDemo()
        #expect(model.project?.id == p.id)
        #expect(model.hasWorldMap)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.close()
    }

    @Test @MainActor func optimizerAllowsProbeMovementAndAppliesOnlyItsFloor() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        var p = project()
        p.floorCount = 2
        p.rooms[0].floor = 1
        let downstairs = RFAccessPoint(name: "Downstairs", position: [3, 3], isSatellite: true, backhaul: .wired)
        p.accessPoints.append(downstairs)
        try await store.save(p)
        let model = FloorplanViewModel(store: store)
        await model.open(id: p.id)
        model.setFloor(1)
        model.runOptimizer(satellites: .exactly(1), lockRouter: false)
        model.placeProbe(at: [2.5, 2.5])
        try await waitUntil { if case .running = model.optimizer { return false }; return true }
        guard case .ready = model.optimizer else {
            Issue.record("Probe movement should preserve the optimizer request")
            await model.close()
            return
        }
        model.placeProbe(at: [3, 2])
        model.applyOptimizerResult()
        #expect(model.project?.router == p.router)
        #expect(model.accessPoint(id: downstairs.id) == downstairs)
        #expect(model.project?.satellites.filter { $0.floor == 1 }.count == 1)
        #expect(model.project?.probe == [3, 2])
        await model.close()
    }

    @Test @MainActor func changingNetworkClearsOldBackhaulImmediately() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        var p = project()
        let satellite = RFAccessPoint(name: "Satellite", position: [3, 3], isSatellite: true)
        p.accessPoints.append(satellite)
        try await store.save(p)
        let model = FloorplanViewModel(store: store)
        await model.open(id: p.id)
        try await waitUntil { model.backhaul[satellite.id] != nil }
        model.updateAccessPoint(id: p.accessPoints[0].id) { $0.isActive = false }
        #expect(model.backhaul.isEmpty)
        #expect(model.probe?.effectiveThroughputMbps == 0)
        await model.close()
    }

    @Test func sparseRoomsRetainOptimizerCandidates() throws {
        let rooms = [RoomInfo(name: "First", kind: .bedroom, polygon: [[0, 0], [2, 0], [2, 2], [0, 2]]),
                     RoomInfo(name: "Far", kind: .bedroom, polygon: [[998, 998], [1000, 998], [1000, 1000], [998, 1000]])]
        let proposal = PlacementOptimizer.optimize(PlacementRequest(walls: [], rooms: rooms,
            accessPoints: [RFAccessPoint(name: "Router", position: [1, 1])], profile: NetworkProfile(),
            width: 1000, depth: 1000, satellites: .exactly(0)))
        #expect(proposal != nil)
        if let proposal { #expect(rooms.contains { $0.contains(proposal.routerPosition) }) }
    }

    @Test func fixedFloorAnchorMustReachRouterInProposedTopology() throws {
        let router = RFAccessPoint(name: "Router", position: [1, 2])
        let fixed = RFAccessPoint(name: "Far downstairs", position: [202, 2], txPower: 30, isSatellite: true)
        let room = RoomInfo(name: "Upstairs", kind: .bedroom, polygon: [[200, 0], [204, 0], [204, 4], [200, 4]], floor: 1)
        let proposal = try #require(PlacementOptimizer.optimize(PlacementRequest(walls: [], rooms: [room],
            accessPoints: [router, fixed,
                RFAccessPoint(name: "Replaced wireless", position: [2, 2], txPower: 30, isSatellite: true, floor: 1),
                RFAccessPoint(name: "Removed wired", position: [50, 2], txPower: 100, isSatellite: true, floor: 1, backhaul: .wired)],
            profile: NetworkProfile(), width: 204, depth: 4,
            floor: 1, satellites: .exactly(1))))
        #expect(proposal.satellitePositions.isEmpty)
    }

    @Test func crossFloorBudgetCrossingsMatchTotalWallLoss() {
        let wall = RFWallSegment(p1: [2, 0], p2: [2, 4], material: .brick)
        let model = PropagationModel(walls: [wall], band: .five)
        let budget = model.linkBudget(from: RFAccessPoint(name: "Router", position: [1, 2]), to: [3, 2], floor: 1, reflections: false)
        #expect(abs(budget.crossings.reduce(0) { $0 + $1.loss } - budget.wallLossDb) < 0.001)
    }
}


extension ReviewRegressionTests {
    @Test @MainActor func backgroundFlushSavesAnInProgressDrag() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = project()
        try await store.save(p)
        let model = FloorplanViewModel(store: store)
        await model.open(id: p.id)
        let id = p.accessPoints[0].id
        model.beginDrag(accessPointId: id)
        model.moveAccessPoint(id: id, to: [3, 3])
        #expect(await model.flushSave())
        #expect(try await store.load(id: p.id).accessPoints[0].position == [3, 3])
        model.endDrag()
        await model.close()
    }

    @Test func recoverySkipsBackupThatFailsAfterMigration() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let good = project()
        try await store.save(good)
        var legacy = good
        legacy.schemaVersion = 1
        legacy.walls = [
            RFWallSegment(id: "split", p1: [0, 0], p2: [4, 0], material: .drywall),
            RFWallSegment(id: "opening", p1: [1, 0], p2: [2, 0], material: .openDoor, kind: .opening),
            RFWallSegment(id: "split#2", p1: [0, 4], p2: [4, 4], material: .drywall)
        ]
        // Unique before repair; generated split segment collides with an existing ID after repair.
        try legacy.validate()
        #expect(throws: (any Error).self) { try ProjectRepair.upgradeIfNeeded(legacy).validate() }
        let backups = await store.backupsDirectory.appendingPathComponent(good.id)
        try ProjectStore.encoder().encode(legacy).write(to: backups.appendingPathComponent("z.signalsim"))
        try Data("broken".utf8).write(to: await store.fileURL(for: good.id))
        let recovered = try await store.load(id: good.id)
        #expect(recovered.walls == good.walls)
    }

    @Test @MainActor func failedLegacyMigrationIsVisibleAndRetryable() async throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("current_scan.json")
        try Data(#"{"title":"Synthetic legacy","floorplanWidth":4,"floorplanDepth":4,"walls":[],"accessPoints":[]}"#.utf8).write(to: legacy)
        let directory = await store.projectsDirectory
        try FileManager.default.removeItem(at: directory)
        try Data([0]).write(to: directory)
        let model = FloorplanViewModel(store: store)
        await model.start()
        #expect(model.errorMessage?.contains("migrate") == true)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(try await store.migrateLegacyScanIfNeeded()?.name == "Synthetic legacy")
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func migrationRasterHandlesLargeAndThinBounds() {
        let wall = RFWallSegment(p1: [0, 0], p2: [4, 0], material: .drywall)
        for size: SIMD2<Float> in [[1000, 1000], [1000, 0.01]] {
            #expect(RoomRegionDetector.regions(walls: [wall], floor: 0, width: size.x, depth: size.y).isEmpty)
        }
    }
}


extension ReviewRegressionTests {
    @Test(arguments: ["rooms", "accessPoints", "schemaVersion", "floorCount", "profile"])
    func malformedPresentNativeFieldsAreRejected(field: String) throws {
        var json = try #require(JSONSerialization.jsonObject(with: ProjectStore.encoder().encode(project())) as? [String: Any])
        json[field] = "damaged"
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try ProjectStore.decodeAnyFormat(data, fallbackName: "Invalid") }
    }
}
