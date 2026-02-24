import SwiftUI

struct ContentView: View {
    @StateObject private var controller: PDFDocumentController
    @Binding var fileURL: URL?
    @State private var isTargeted: Bool = false
    @State private var isHoveringDropArea: Bool = false
    @State private var isPressingDropArea: Bool = false

    init(fileURL: Binding<URL?>, controller: PDFDocumentController = PDFDocumentController()) {
        _fileURL = fileURL
        _controller = StateObject(wrappedValue: controller)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ControlGroup {
                        Button("Save") { controller.save() }
                            .keyboardShortcut("s")
                            .disabled(controller.document == nil || !controller.hasChanges)
                        Menu {
                            Button("Save As") { controller.saveAs() }
                                .keyboardShortcut("s", modifiers: [.command, .shift])
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .menuIndicator(.hidden)
                        .disabled(controller.document == nil || !controller.hasChanges)
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
                Button {
                    controller.openDocument()
                } label: {
                    VStack(spacing: 12) {
                        Text("Drop a PDF here to open")
                            .font(.title2)
                        Text("or click to browse")
                            .foregroundStyle(.secondary)
                    }
                    .padding(30)
                    .background(.thinMaterial)
                    .cornerRadius(12)
                    .scaleEffect(isPressingDropArea ? 0.98 : (isHoveringDropArea ? 1.05 : 1.0))
                    .opacity(isHoveringDropArea ? 0.92 : 1.0)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHoveringDropArea = hovering
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isPressingDropArea = true }
                        .onEnded { _ in isPressingDropArea = false }
                )
                .animation(.easeInOut(duration: 0.2), value: isHoveringDropArea)
                .animation(.easeInOut(duration: 0.12), value: isPressingDropArea)
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
