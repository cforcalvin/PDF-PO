import SwiftUI
import AppKit
import PDFKit
import Combine

private extension Notification.Name {
    static let pdfpoOpenEvent = Notification.Name("PDFPOOpenEvent")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [PDFWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        openNewWindow(with: nil)
    }
    
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            openNewWindow(with: url, reuseEmpty: false)
        }
    }
    
    @objc func closeCurrentWindow(_ sender: Any?) {
        NSApp.keyWindow?.performClose(nil)
    }
    
    @objc func undo(_ sender: Any?) {
        // Try first responder's undo manager (for text views), then window's undo manager
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           let undoManager = textView.undoManager,
           undoManager.canUndo {
            undoManager.undo()
        } else if let window = NSApp.keyWindow,
                  let undoManager = window.undoManager,
                  undoManager.canUndo {
            undoManager.undo()
        }
    }
    
    @objc func redo(_ sender: Any?) {
        // Try first responder's undo manager (for text views), then window's undo manager
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           let undoManager = textView.undoManager,
           undoManager.canRedo {
            undoManager.redo()
        } else if let window = NSApp.keyWindow,
                  let undoManager = window.undoManager,
                  undoManager.canRedo {
            undoManager.redo()
        }
    }
    
    @objc func cut(_ sender: Any?) {
        // If a text view is first responder, let it handle cut
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           let textViewWindow = textView.window,
           textViewWindow === NSApp.keyWindow {
            textView.cut(nil)
            return
        }
        
        // For PDF text selection, we can only copy (can't cut PDF content)
        // So cut behaves like copy when not editing text
        copy(sender)
    }
    
    @objc func copy(_ sender: Any?) {
        // If a text view is first responder, let it handle copy
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           let textViewWindow = textView.window,
           textViewWindow === NSApp.keyWindow {
            textView.copy(nil)
            return
        }
        
        // Otherwise, copy selected PDF text
        if let window = NSApp.keyWindow,
           let contentView = window.contentView,
           let pdfView = findPDFView(in: contentView),
           let selection = pdfView.currentSelection,
           let text = selection.string, !text.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
    
    @objc func paste(_ sender: Any?) {
        // If a text view is first responder, let it handle paste
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           let textViewWindow = textView.window,
           textViewWindow === NSApp.keyWindow {
            textView.paste(nil)
            return
        }
        
        // Otherwise, paste text from clipboard as new annotation
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        
        if let window = NSApp.keyWindow,
           let contentView = window.contentView,
           let pdfView = findPDFView(in: contentView) as? PDFDropView,
           let controller = pdfView.controller {
            // Try to use mouse location, fallback to center of visible area
            let mouseLocation = NSEvent.mouseLocation
            let windowLocation = window.convertPoint(fromScreen: mouseLocation)
            let viewPoint = pdfView.convert(windowLocation, from: window.contentView)
            
            let targetPoint: CGPoint
            if pdfView.bounds.contains(viewPoint) {
                targetPoint = viewPoint
            } else {
                // Fallback to center of visible area
                let visibleRect = pdfView.visibleRect
                targetPoint = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
            }
            
            if let page = pdfView.page(for: targetPoint, nearest: true) {
                let pagePoint = pdfView.convert(targetPoint, to: page)
                let annotation = controller.createTextAnnotation(
                    at: pagePoint,
                    on: page,
                    scaleFactor: pdfView.scaleFactor
                )
                annotation.contents = text
                pdfView.beginEditing(annotation: annotation, focus: true)
            }
        }
    }
    
    private func findPDFView(in view: NSView) -> PDFView? {
        if let pdfView = view as? PDFView {
            return pdfView
        }
        for subview in view.subviews {
            if let pdfView = findPDFView(in: subview) {
                return pdfView
            }
        }
        return nil
    }

    func application(_ application: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        logOpen("openFile: \(url.path)")
        openNewWindow(with: url)
        return true
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        logOpen("openFiles: \(filenames.count) item(s)")
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            logOpen("openFiles item: \(url.path)")
            openNewWindow(with: url)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        logOpen("openURLs: \(urls.count) item(s)")
        for url in urls {
            logOpen("openURLs item: \(url.path)")
            openNewWindow(with: url)
        }
    }
    
    private func openNewWindow(with url: URL?, reuseEmpty: Bool = true) {
        logOpen("openNewWindow: \(url?.path ?? "empty")")
        if reuseEmpty, let url, let existing = windowControllers.first(where: { $0.isEmpty }) {
            logOpen("reusing empty window for \(url.path)")
            existing.fileURL = url
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = PDFWindowController(fileURL: url)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
            self.ensureEmptyWindowIfNoDocuments()
        }
        windowControllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureEmptyWindowIfNoDocuments() {
        let hasAnyDocumentWindow = windowControllers.contains { !$0.isEmpty }
        if !hasAnyDocumentWindow {
            let hasEmptyWindow = windowControllers.contains { $0.isEmpty }
            if !hasEmptyWindow {
                openNewWindow(with: nil)
            }
        }
    }

    private func logOpen(_ message: String) {
        NSLog("PDFPO: \(message)")
        NotificationCenter.default.post(name: .pdfpoOpenEvent, object: message)
    }
}

final class PDFWindowController: NSWindowController, NSWindowDelegate {
    let pdfController: PDFDocumentController
    private var cancellables: Set<AnyCancellable> = []

    @Published var fileURL: URL? {
        didSet {
            updateWindowMetadata()
        }
    }

    var onClose: (() -> Void)?
    var isEmpty: Bool { pdfController.document == nil }

    init(fileURL: URL?) {
        self.pdfController = PDFDocumentController()
        self.fileURL = fileURL
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        super.init(window: window)
        let contentView = ContentView(fileURL: Binding(
            get: { [weak self] in self?.fileURL },
            set: { [weak self] newValue in self?.fileURL = newValue }
        ), controller: pdfController)
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        updateWindowMetadata()
        bindControllerToWindow()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Prevent closing the empty window.
        guard pdfController.document != nil else { return false }
        // No unsaved changes: allow close.
        if !pdfController.hasChanges { return true }

        let name = pdfController.currentFileURL?.lastPathComponent ?? "Untitled"
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(name)\" before closing?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: // Save
            return pdfController.save()
        case .alertSecondButtonReturn: // Don't Save
            return true
        default: // Cancel (or third button)
            return false
        }
    }

    private func updateWindowMetadata() {
        let title: String
        if pdfController.document != nil {
            title = pdfController.statusMessage
        } else {
            title = fileURL?.lastPathComponent ?? "PDFPO"
        }
        window?.title = title
        window?.representedURL = pdfController.currentFileURL ?? fileURL
        window?.standardWindowButton(.closeButton)?.isEnabled = (pdfController.document != nil)
    }

    private func bindControllerToWindow() {
        pdfController.$document
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowMetadata()
            }
            .store(in: &cancellables)

        pdfController.$currentFileURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowMetadata()
            }
            .store(in: &cancellables)

        pdfController.$statusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateWindowMetadata()
            }
            .store(in: &cancellables)
    }
}

@main
struct PDFPOApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open...") {
                    NSApp.sendAction(#selector(AppDelegate.openDocument(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("o")
                
                Button("Close") {
                    NSApp.sendAction(#selector(AppDelegate.closeCurrentWindow(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("w")
            }
            
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    NSApp.sendAction(#selector(PDFDocumentController.save), to: nil, from: nil)
                }
                .keyboardShortcut("s")
                
                Button("Save As...") {
                    NSApp.sendAction(#selector(PDFDocumentController.saveAs), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    NSApp.sendAction(#selector(AppDelegate.undo(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("z")
                
                Button("Redo") {
                    NSApp.sendAction(#selector(AppDelegate.redo(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    NSApp.sendAction(#selector(AppDelegate.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x")
                
                Button("Copy") {
                    NSApp.sendAction(#selector(AppDelegate.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c")
                
                Button("Paste") {
                    NSApp.sendAction(#selector(AppDelegate.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v")
            }
        }
    }
}
