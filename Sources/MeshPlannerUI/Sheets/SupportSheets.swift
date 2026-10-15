import SwiftUI
import UIKit

struct DiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy") { UIPasteboard.general.string = text }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: text)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }
}

struct ReportShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Report ready")
                    .font(.title2.bold())
                Text(url.lastPathComponent)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ShareLink(item: url) {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
