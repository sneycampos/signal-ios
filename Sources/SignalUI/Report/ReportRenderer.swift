import SwiftUI
import SignalCore

/// One-page A4 Wi-Fi coverage report rendered to PDF.
enum ReportRenderer {
    static let pageSize = CGSize(width: 595, height: 842)

    @MainActor
    static func render(model: FloorplanViewModel, project: FloorplanProject) -> URL? {
        let view = ReportPage(snapshot: PlanSnapshot(model: model, project: project, drawNodes: true), model: model, project: project)
            .frame(width: pageSize.width, height: pageSize.height)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(pageSize)
        let safeName = project.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Wi-Fi report - \(safeName)").appendingPathExtension("pdf")
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

            SignalLegend(scale: model.scale)

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
            Text("\(Format.percent(model.coverage.coveredPercent)) of your home has good signal").font(.subheadline.bold())
            Text("Area: \(Format.area(project.areaM2)) · \(project.rooms.count) rooms").font(.caption)
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
                Text("Weak signal in: \(weak.map(\.name).formatted(.list(type: .and))). Use “Optimize” in the app to try another router position or a mesh satellite.").font(.caption)
            }
            let weakBackhaul = model.backhaul.values.filter { $0.quality == .weak }
            if !weakBackhaul.isEmpty {
                Text("Some satellites have a weak link to the router; move them closer or use Ethernet.").font(.caption)
            }
        }
    }
}
