import SwiftUI
import UniformTypeIdentifiers
import SignalCore

extension UTType {
    /// Signal project file (JSON), declared in the app's Info.plist.
    static let signalProject = UTType(exportedAs: "com.silviogodinho.signal.project", conformingTo: .json)
}

/// Shares the current project as a `.signalsim` file.
struct ProjectDocument: Transferable {
    let project: FloorplanProject

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .signalProject) { document in
            let url = try await ProjectStore().exportFile(for: document.project)
            return SentTransferredFile(url)
        }
    }
}

/// Floorplan in the web simulator format.
struct WebFloorplanDocument: Transferable {
    let data: Data
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { document in
            let url = try ExportFilename.directory().appendingPathComponent("\(ExportFilename.sanitized(document.name))-web").appendingPathExtension("json")
            try document.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
