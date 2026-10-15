import SwiftUI
import UIKit
import SignalCore

struct ProjectsHomeView: View {
    @Environment(FloorplanViewModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    var onScan: () -> Void
    var onImport: () -> Void

    @State private var pendingDeletion: ProjectSummary?
    @State private var availability = ScanAvailability.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero

                if !model.projects.isEmpty {
                    Text("Your projects")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 4)
                    VStack(spacing: 12) {
                        ForEach(model.projects) { summary in
                            ProjectCard(summary: summary, preview: model.previews[summary.id]) {
                                Task { await model.open(id: summary.id) }
                            } onDelete: {
                                pendingDeletion = summary
                            }
                        }
                    }
                }

                Button {
                    Task { await model.openDemo() }
                } label: {
                    Label("Open demo apartment", systemImage: "building.2")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .cardSurface(cornerRadius: 18)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("openDemo")

                Text("Everything is calculated on this device. Plans are stored in the Mesh Planner folder in the Files app.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                SupportLinks()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("Mesh Planner")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onImport) {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Import project")
            }
        }
        .onAppear { availability = ScanAvailability.current }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { availability = ScanAvailability.current }
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "")?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete project", role: .destructive) {
                if let id = pendingDeletion?.id { Task { await model.delete(id: id) } }
                pendingDeletion = nil
            }
        } message: {
            Text("The project and its backups will be removed from this device.")
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RadialGradient(colors: [Color.cyan.opacity(0.18), .clear], center: .center, startRadius: 10, endRadius: 220)
                if let preview = model.demoPreview {
                    PlanThumbnail(project: preview.project, heatmap: preview.heatmap)
                        .padding(8)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)

            Text("Find the best place for Wi-Fi")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Scan your home with LiDAR and see the signal in every room. The app suggests the best position for the router and mesh satellites.")
                .foregroundStyle(.white.opacity(0.65))

            switch availability {
            case .available:
                Button(action: onScan) {
                    Label(model.projects.isEmpty ? "Scan my home" : "New scan", systemImage: "camera.viewfinder")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("scan")
            case .cameraDenied:
                Label("Camera access is turned off.", systemImage: "camera.badge.ellipsis")
                    .foregroundStyle(.orange)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
            case .unsupportedDevice:
                Label("This device has no LiDAR sensor. Scanning requires an iPhone or iPad Pro with LiDAR; you can still open the demo or import a project.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        }
        .padding(18)
        .cardSurface(cornerRadius: 28)
    }
}

/// Mini plan with its heatmap.
struct PlanThumbnail: View {
    let project: FloorplanProject
    let heatmap: CGImage?
    var drawNodes = true

    var body: some View {
        GeometryReader { geo in
            PlanLayers(
                snapshot: PlanSnapshot(project: project, heatmap: heatmap, drawNodes: drawNodes),
                transform: PlanTransform.fitting(width: project.width, depth: project.depth, in: geo.size, zoom: 1, pan: .zero, inset: 2)
            )
        }
    }
}

private struct ProjectCard: View {
    let summary: ProjectSummary
    let preview: ProjectPreview?
    var onOpen: () -> Void
    var onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35))
                    if let preview {
                        PlanThumbnail(project: preview.project, heatmap: preview.heatmap, drawNodes: false).padding(4)
                    }
                }
                .frame(width: 76, height: 64)

                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("\(Format.area(summary.areaM2)) · \(summary.roomCount) rooms · \(summary.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let preview {
                    CoverageRing(percent: preview.coverage, color: ringColor(preview.coverage))
                        .frame(width: 52, height: 52)
                }
            }
            .padding(12)
            .cardSurface(cornerRadius: 20)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityHint("Touch and hold to delete")
    }

    private func ringColor(_ value: Float) -> Color {
        switch value {
        case 90...: return .green
        case 75..<90: return .mint
        case 50..<75: return .yellow
        default: return .orange
        }
    }
}
