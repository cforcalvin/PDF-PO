import SwiftUI

struct ContentView: View {
    @StateObject private var controller = PDFDocumentController()
    @Binding var fileURL: URL?
    @State private var replacementText: String = ""
    @State private var isTargeted: Bool = false

    init(fileURL: Binding<URL?>) {
        _fileURL = fileURL
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button("Open") { controller.openDocument() }
                    ControlGroup {
                        Button("Save") { controller.save() }
                            .keyboardShortcut("s")
                        Menu {
                            Button("Save As") { controller.saveAs() }
                                .keyboardShortcut("s", modifiers: [.command, .shift])
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .menuIndicator(.hidden)
                    }
                    .controlGroupStyle(.automatic)
                    Divider().frame(height: 20)
                    Text("Selected:")
                    Text(controller.selectedText.isEmpty ? "None" : controller.selectedText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)

                Divider()

                PDFKitView(controller: controller, isTargeted: $isTargeted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                HStack(spacing: 12) {
                    Spacer()
                    Text(controller.statusMessage)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            }
            .blur(radius: isTargeted && controller.document == nil ? 2 : 0)

            if controller.document == nil {
                VStack(spacing: 12) {
                    Text("Drop a PDF here to open")
                        .font(.title2)
                    Text("or use the Open button")
                        .foregroundStyle(.secondary)
                }
                .padding(30)
                .background(.thinMaterial)
                .cornerRadius(12)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            if let fileURL {
                NSLog("PDFPO: ContentView task opening \(fileURL.path)")
                controller.open(url: fileURL)
            }
        }
        .onChange(of: fileURL) { newURL in
            if let newURL {
                NSLog("PDFPO: ContentView onChange opening \(newURL.path)")
                controller.open(url: newURL)
            }
        }
    }
}
