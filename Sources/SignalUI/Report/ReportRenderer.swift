import SwiftUI
import SignalCore

/// One-page A4 Wi-Fi coverage report rendered to PDF.
enum ReportRenderer {
    static let pageSize = CGSize(width: 595, height: 842)

    @MainActor
    static func render(model: FloorplanViewModel, project: FloorplanProject) -> URL? {
        guard !model.isComputing, model.field != nil, model.project == project else { return nil }
        var snapshot = PlanSnapshot(model: model, project: project, drawNodes: true, drawGrid: false)
        snapshot.printPalette = true
        snapshot.probe = nil
        snapshot.showRays = false
        snapshot.proposal = nil
        let view = ReportPage(snapshot: snapshot, model: model, project: project)
            .frame(width: pageSize.width, height: pageSize.height)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(pageSize)
        let safeName = ExportFilename.sanitized(project.name)
        guard let directory = try? ExportFilename.directory() else { return nil }
        let url = directory.appendingPathComponent("Wi-Fi report - \(safeName)").appendingPathExtension("pdf")
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            ok = true
        }
        return ok ? url : nil
    }
}

private struct ReportPage: View {
    let snapshot: PlanSnapshot
    let model: FloorplanViewModel
    let project: FloorplanProject

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Wi-Fi coverage report").font(.title2.bold())
                Text("\(project.name) · \(Date().formatted(date: .long, time: .omitted))").font(.subheadline).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                summaryBlock
                equipmentBlock
            }

            GeometryReader { geo in
                PlanLayers(snapshot: snapshot, transform: PlanTransform.fitting(width: project.width, depth: project.depth, in: geo.size, zoom: 1, pan: .zero, inset: 4))
            }
            .frame(height: 330)
            .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 8))

            SignalLegend(scale: model.scale, printPalette: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("By room (\(model.band.displayName))").font(.headline)
                ForEach(model.roomCoverage.prefix(12)) { room in
                    HStack {
                        Circle().fill(model.scale.uiColor(for: room.grade)).frame(width: 8, height: 8)
                        Text(room.name)
                        Spacer()
                        Text(Format.percent(room.summary.coveredPercent)).monospacedDigit()
                        Text(Format.dbm(room.summary.medianRSSI)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    }
                    .font(.caption)
                }
                if model.roomCoverage.count > 12 {
                    Text("Showing 12 of \(model.roomCoverage.count) rooms. See the app for all room results.").font(.caption)
                }
            }

            recommendations
            Spacer(minLength: 0)
            Text("Estimate from a multi-wall propagation model with reflections. Real values vary with interference, devices, and furniture.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .background(.white)
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summary").font(.headline)
            Text("Selected floor: \(model.floor == 0 ? "Ground floor" : "Floor \(model.floor)") · \(model.band.displayName)").font(.caption.bold())
            Text("\(Format.percent(model.coverage.coveredPercent)) of this floor has good signal").font(.subheadline.bold())
            Text("Area: \(Format.area(project.rooms(onFloor: model.floor).reduce(0) { $0 + $1.area })) · \(project.rooms(onFloor: model.floor).count) rooms").font(.caption)
            Text("Typical signal: \(Format.dbm(model.coverage.medianRSSI))").font(.caption)
            if project.calibration.isCalibrated {
                Text("Calibrated with \(project.calibration.sampleCount) measurement(s)").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var equipmentBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Equipment").font(.headline)
            Text(project.profile.standard.displayName).font(.caption)
            Text("\(project.satellites.count) mesh satellite(s)").font(.caption)
            if project.profile.internetPlanMbps > 0 {
                Text("Internet: \(Format.mbps(Float(project.profile.internetPlanMbps)))").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var recommendations: some View {
        let weak = model.roomCoverage.filter { $0.summary.cellCount > 0 && $0.summary.coveredPercent < 80 }
        VStack(alignment: .leading, spacing: 4) {
            Text("Recommendations").font(.headline)
            if weak.isEmpty {
                Text("Every room has good signal. Keep the router elevated and away from metal and aquariums.").font(.caption)
            } else {
                Text("Weak signal in: \(weak.prefix(3).map(\.name).formatted(.list(type: .and)))\(weak.count > 3 ? " and \(weak.count - 3) more rooms" : ""). Use “Optimize” in the app to try another router position or a mesh satellite.").font(.caption)
            }
            let weakBackhaul = model.backhaul.values.filter { $0.quality == .weak }
            if !weakBackhaul.isEmpty {
                Text("Some satellites have a weak link to the router; move them closer or use Ethernet.").font(.caption)
            }
        }
    }
}
