import SwiftUI
import AppKit

private extension Notification.Name {
    static let pdfpoOpenEvent = Notification.Name("PDFPOOpenEvent")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [PDFWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        openNewWindow(with: nil)
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
    
    private func openNewWindow(with url: URL?) {
        logOpen("openNewWindow: \(url?.path ?? "empty")")
        if let url, let existing = windowControllers.first(where: { $0.fileURL == nil }) {
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
        }
        windowControllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func logOpen(_ message: String) {
        NSLog("PDFPO: \(message)")
        NotificationCenter.default.post(name: .pdfpoOpenEvent, object: message)
    }
}

final class PDFWindowController: NSWindowController, NSWindowDelegate {
    @Published var fileURL: URL? {
        didSet {
            updateWindowMetadata()
        }
    }

    var onClose: (() -> Void)?

    init(fileURL: URL?) {
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
        ))
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        updateWindowMetadata()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func updateWindowMetadata() {
        let title = fileURL?.lastPathComponent ?? "PDFPO"
        window?.title = title
        window?.representedURL = fileURL
    }
}

@main
struct PDFPOApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
