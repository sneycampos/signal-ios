import SwiftUI
import RoomPlan
import SignalCore

/// Full-screen RoomPlan scan: room by room, with a button to mark where the router is.
struct RoomScanView: View {
    @Environment(FloorplanViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = ScanController()
    @State private var confirmCancel = false
    @State private var creating = false
    @State private var creationTask: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            let isBusy = controller.phase == .processingRoom || controller.phase == .finishing || creating
            ZStack {
                CaptureViewRepresentable(captureView: controller.captureView)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    topBar
                    Spacer()
                    ScrollView { bottomPanel }
                        .frame(maxHeight: min(380, geometry.size.height * 0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal)
                .disabled(isBusy)
                .accessibilityHidden(isBusy)

                if controller.phase == .processingRoom || controller.phase == .finishing || creating {
                    processingOverlay
                        .accessibilityAddTraits(.isModal)
                }
            }
        }
        .statusBarHidden(false)
        .onDisappear {
            creationTask?.cancel()
            controller.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, !creating {
                controller.interrupted()
            }
        }
        .onChange(of: controller.phase) { _, phase in
            if phase != .scanning { confirmCancel = false }
        }
        .onAppear {
            controller.onComplete = { capture, worldMap in
                creating = true
                creationTask = Task {
                    await model.createProject(from: capture, worldMap: worldMap)
                    guard !Task.isCancelled else { return }
                    creating = false
                    dismiss()
                }
            }
            controller.start()
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                controller.cancel()
                dismiss()
            }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("Rooms already captured will be lost.")
        }
        .alert("Room couldn't be processed", isPresented: Binding(get: { controller.roomWarning != nil }, set: { if !$0 { controller.dismissWarning() } })) {
            if controller.canCompleteFromWarning, controller.roomsCaptured > 0 {
                Button("Save \(controller.roomsCaptured == 1 ? "1 room" : "\(controller.roomsCaptured) rooms")") {
                    controller.completeWithCapturedRooms()
                }
                Button("Rescan room", role: .cancel) {
                    controller.dismissWarning()
                }
            } else {
                Button("OK", role: .cancel) {
                    controller.dismissWarning()
                }
            }
        } message: {
            Text(controller.roomWarning ?? "")
        }
        .alert("Couldn't finish", isPresented: Binding(get: {
            guard !confirmCancel, controller.roomWarning == nil else { return false }
            if case .failed = controller.phase { return true } else { return false }
        }, set: { _ in })) {
            if controller.roomsCaptured > 0 {
                Button("Save \(controller.roomsCaptured == 1 ? "1 room" : "\(controller.roomsCaptured) rooms")") {
                    controller.completeWithCapturedRooms()
                }
                Button("Discard", role: .destructive) {
                    controller.cancel()
                    dismiss()
                }
            } else {
                Button("OK") {
                    controller.cancel()
                    dismiss()
                }
            }
        } message: {
            if case .failed(let message) = controller.phase { Text(message) }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                if controller.hasCapturedAnything { confirmCancel = true } else { controller.cancel(); dismiss() }
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .accessibilityLabel("Cancel scan")

            Spacer()

            Text("Room \(controller.roomNumber)")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 12) {
                CountLabel(value: controller.counts.walls, title: "Walls", icon: "square.split.2x1")
                CountLabel(value: controller.counts.doors, title: "Doors", icon: "door.left.hand.open")
                CountLabel(value: controller.counts.windows, title: "Windows", icon: "window.vertical.closed")
                CountLabel(value: controller.counts.objects, title: "Objects", icon: "refrigerator")
            }
            .frame(maxWidth: .infinity)

            Text("Walk the room pointing at walls, doors, and windows. Open doors that usually stay open.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                controller.markRouter()
            } label: {
                Label(controller.routerMarked ? "Router marked here" : "I'm next to the router",
                      systemImage: controller.routerMarked ? "checkmark.circle.fill" : "wifi.router")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(controller.routerMarked ? .green : .accentColor)
            .sensoryFeedback(.success, trigger: controller.routerMarked)

            (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                Button {
                    controller.nextRoom()
                } label: {
                    Label("Next room", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(controller.counts.walls == 0)

                Button {
                    controller.finish()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.counts.walls == 0 && controller.roomsCaptured == 0)
            }
            .controlSize(.large)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(.bottom, 8)
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(controller.phase == .processingRoom ? "Processing the room…" : "Building the home plan…")
                    .font(.headline)
                Text("This may take a few seconds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

private struct CountLabel: View {
    let value: Int
    let title: LocalizedStringKey
    let icon: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.subheadline)
            Text(value.formatted()).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct CaptureViewRepresentable: UIViewRepresentable {
    let captureView: RoomCaptureView

    func makeUIView(context: Context) -> RoomCaptureView { captureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
