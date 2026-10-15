import SwiftUI
import ARKit
import RealityKit
import SignalCore

/// Walks the real home: relocalizes against the scan's world map, lays the heatmap on the floor
/// and shows the estimated signal where the phone is.
struct ARWalkthroughView: View {
    @Environment(FloorplanViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var session = ARWalkSession()

    var body: some View {
        ZStack {
            ARViewContainer(arView: session.arView)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    Button {
                        session.stop()
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Circle())
                    Spacer()
                    statusPill
                }
                Spacer()
                if let reading = session.reading {
                    LiveReadingCard(reading: reading, scale: model.scale)
                }
            }
            .padding()
        }
        .task {
            guard let project = model.project, let alignment = project.worldAlignment else {
                session.status = .failed("This project has no augmented reality data. Scan again to use AR.")
                return
            }
            let map = await model.worldMapData()
            await session.start(project: project, alignment: alignment, floor: model.floor, heatmap: model.heatmapImage, worldMap: map)
        }
        .onDisappear { session.stop() }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch session.status {
        case .loading:
            Label("Starting…", systemImage: "hourglass").pill()
        case .relocalizing:
            Label("Point at the walls you scanned", systemImage: "viewfinder").pill()
        case .ready:
            Label("Map on the floor", systemImage: "checkmark.circle.fill").pill()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").pill()
        }
    }
}

private extension View {
    func pill() -> some View {
        font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
    }
}

private struct LiveReadingCard: View {
    let reading: ProbeReading
    let scale: SignalScale

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: reading.grade.symbol)
                .font(.title)
                .foregroundStyle(scale.uiColor(for: reading.grade))
            VStack(alignment: .leading, spacing: 2) {
                Text(reading.roomName ?? String(localized: "Here"))
                    .font(.headline)
                Text("\(Format.dbm(reading.rssi)) · \(Format.mbps(reading.effectiveThroughputMbps))")
                    .font(.subheadline.monospacedDigit())
                Text(reading.grade.usage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

private struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

@MainActor
@Observable
final class ARWalkSession {
    enum Status: Equatable {
        case loading
        case relocalizing
        case ready
        case failed(String)
    }

    var status: Status = .loading
    private(set) var reading: ProbeReading?

    @ObservationIgnored let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    @ObservationIgnored private var delegate: ARWalkDelegate?
    @ObservationIgnored private var project: FloorplanProject?
    @ObservationIgnored private var alignment: WorldAlignment?
    @ObservationIgnored private var floor = 0
    @ObservationIgnored private var heatmap: CGImage?
    @ObservationIgnored private var propagation: PropagationModel?
    @ObservationIgnored private var backhaul: [String: BackhaulLink] = [:]
    @ObservationIgnored private var placed = false
    @ObservationIgnored private var lastUpdate: TimeInterval = 0
    @ObservationIgnored private var stopped = false

    func start(project: FloorplanProject, alignment: WorldAlignment, floor: Int, heatmap: CGImage?, worldMap: Data?) async {
        guard !Task.isCancelled, !stopped else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            status = .failed("This device does not support augmented reality.")
            return
        }
        self.project = project
        self.alignment = alignment
        self.floor = floor
        self.heatmap = heatmap
        propagation = PropagationModel(walls: project.walls, band: project.selectedBand, calibration: project.calibration, floorHeight: project.profile.floorHeight)
        backhaul = BackhaulPlanner.plan(accessPoints: project.accessPoints, walls: project.walls, profile: project.profile, calibration: project.calibration)

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        if let worldMap, let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: worldMap) {
            configuration.initialWorldMap = map
            status = .relocalizing
        } else {
            status = .failed("No environment map for this project. Scan again to use AR.")
            return
        }
        let delegate = ARWalkDelegate(session: self)
        self.delegate = delegate
        arView.session.delegate = delegate
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        stopped = true
        reading = nil
        arView.session.delegate = nil
        arView.session.pause()
        arView.scene.anchors.removeAll()
    }

    fileprivate func trackingChanged(isNormal: Bool) {
        guard !stopped else { return }
        if case .failed = status { return }
        if isNormal {
            placeHeatmap()
            status = .ready
        } else if case .failed = status {
            return
        } else {
            reading = nil
            status = .relocalizing
        }
    }

    fileprivate func cameraMoved(to transform: simd_float4x4, time: TimeInterval) {
        guard !stopped, status == .ready, time - lastUpdate > 0.2, let project, let alignment, let propagation else { return }
        lastUpdate = time
        let point = alignment.planPoint(worldX: transform.columns.3.x, worldZ: transform.columns.3.z)
        reading = FloorplanViewModel.reading(project: project, model: propagation, backhaul: backhaul, point: point, floor: floor)
    }

    private func placeHeatmap() {
        guard !placed, let project, let alignment, let heatmap else { return }
        placed = true
        let w = project.width
        let d = project.depth
        var descriptor = MeshDescriptor(name: "heatmap")
        descriptor.positions = MeshBuffers.Positions([SIMD3(0, 0, 0), SIMD3(w, 0, 0), SIMD3(w, 0, d), SIMD3(0, 0, d)])
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates([SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)])
        descriptor.primitives = .triangles([0, 3, 2, 0, 2, 1, 0, 2, 3, 0, 1, 2])
        Task {
            do {
                let mesh = try MeshResource.generate(from: [descriptor])
                let texture: TextureResource
                if #available(iOS 18.0, *) {
                    texture = try await TextureResource(image: heatmap, options: .init(semantic: .color))
                } else {
                    texture = try TextureResource.generate(from: heatmap, options: .init(semantic: .color))
                }
                var material = UnlitMaterial()
                material.color = .init(tint: .white, texture: .init(texture))
                material.blending = .transparent(opacity: .init(floatLiteral: 0.7))
                let entity = ModelEntity(mesh: mesh, materials: [material])
                let origin = alignment.worldPoint(fromPlan: .zero)
                guard !stopped, !Task.isCancelled else { return }
                entity.position = SIMD3(origin.x, alignment.elevation(for: floor, floorHeight: project.profile.floorHeight) + 0.02, origin.y)
                entity.orientation = simd_quatf(angle: alignment.rotation, axis: SIMD3(0, 1, 0))
                let anchor = AnchorEntity(world: .zero)
                anchor.addChild(entity)
                arView.scene.addAnchor(anchor)
            } catch {
                failed("Couldn't draw the map on the floor.")
            }
        }
    }

    fileprivate func failed(_ message: String) {
        guard !stopped else { return }
        reading = nil
        status = .failed("\(message) Close AR and reopen it to retry, or scan again.")
        arView.session.pause()
    }
}

/// ARSession delivers callbacks on the main queue by default; only Sendable values cross into the session object.
private final class ARWalkDelegate: NSObject, ARSessionDelegate, @unchecked Sendable {
    weak var session: ARWalkSession?

    @MainActor
    init(session: ARWalkSession) {
        self.session = session
    }

    private var lastForwarded: TimeInterval = 0

    func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.session?.trackingChanged(isNormal: false) }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.session?.trackingChanged(isNormal: false) }
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.session?.failed(message) }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let time = frame.timestamp
        guard time - lastForwarded > 0.2 else { return }
        lastForwarded = time
        let transform = frame.camera.transform
        Task { @MainActor [weak self] in self?.session?.cameraMoved(to: transform, time: time) }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        var normal = false
        if case .normal = camera.trackingState { normal = true }
        Task { @MainActor [weak self] in self?.session?.trackingChanged(isNormal: normal) }
    }
}
