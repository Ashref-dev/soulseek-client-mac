import SwiftUI
import QuickLookUI
import ArpeggioServices

struct DocumentPreviewView: View {
    let model: AppModel
    let identity: UUID
    private var preview: DocumentPreview? { model.documentPreview?.id == identity ? model.documentPreview : nil }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(preview?.title ?? "Preview").font(.headline).lineLimit(1)
                Spacer()
                if preview?.transferID != nil {
                    Button("Download") { Task { await model.keepDocumentPreview() } }
                }
                Button("Close") { Task { await model.closeDocumentPreview() } }.keyboardShortcut(.cancelAction)
            }
            if let url = preview?.url { NativeFilePreview(url: url) }
            else {
                Spacer()
                if let failure = preview?.failure {
                    ContentUnavailableView("Preview Unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else {
                    ProgressView()
                    Text(preview?.status ?? "Loading…").foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 480, idealWidth: 720, minHeight: 360, idealHeight: 520)
    }
}

private struct NativeFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true; view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.previewItem = nil; view.close() }
}
