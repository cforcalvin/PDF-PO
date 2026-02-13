import Foundation
import PDFKit
import AppKit
import UniformTypeIdentifiers

final class PDFDocumentController: ObservableObject {
    @Published var document: PDFDocument?
    @Published var currentFileURL: URL?
    @Published var statusMessage: String = "Open a PDF to begin."
    @Published var selectedText: String = ""

    weak var pdfView: PDFView? {
        didSet {
            if pdfView != nil, let url = pendingURL {
                pendingURL = nil
                open(url: url)
            }
        }
    }
    
    private var pendingURL: URL?
    private var securityScopedURL: URL?
    private var isApplyingAutoReplace: Bool = false

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func open(url: URL) {
        if pdfView == nil {
            pendingURL = url
            statusMessage = "Loading \(url.lastPathComponent)..."
            NSLog("PDFPO: pdfView not ready, queued \(url.path)")
            return
        }

        stopAccessingSecurityScopedResourceIfNeeded()
        let accessGranted = url.startAccessingSecurityScopedResource()
        if accessGranted {
            securityScopedURL = url
        }
        NSLog("PDFPO: open url=\(url.path) accessGranted=\(accessGranted)")

        guard let loaded = PDFDocument(url: url) else {
            stopAccessingSecurityScopedResourceIfNeeded()
            statusMessage = "Failed to open PDF."
            NSLog("PDFPO: failed to load PDFDocument from \(url.path)")
            return
        }
        document = loaded
        pdfView?.document = loaded
        currentFileURL = url
        statusMessage = url.lastPathComponent
        NSLog("PDFPO: opened PDF with \(loaded.pageCount) pages")
    }

    func open(data: Data, suggestedFilename: String = "Dropped.pdf") {
        stopAccessingSecurityScopedResourceIfNeeded()
        guard let loaded = PDFDocument(data: data) else {
            statusMessage = "Failed to open PDF."
            NSLog("PDFPO: failed to open PDFDocument from data")
            return
        }
        document = loaded
        if let pdfView {
            pdfView.document = loaded
        }
        currentFileURL = nil
        statusMessage = suggestedFilename
        NSLog("PDFPO: opened PDF from data with \(loaded.pageCount) pages")
    }

    deinit {
        stopAccessingSecurityScopedResourceIfNeeded()
    }

    private func stopAccessingSecurityScopedResourceIfNeeded() {
        if let securityScopedURL {
            securityScopedURL.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
        }
    }

    func undoManager() -> UndoManager? {
        pdfView?.window?.undoManager
    }

    func addAnnotation(_ annotation: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        undoManager()?.registerUndo(withTarget: self) { target in
            target.removeAnnotation(annotation, from: page)
        }
    }

    func removeAnnotation(_ annotation: PDFAnnotation, from page: PDFPage) {
        page.removeAnnotation(annotation)
        undoManager()?.registerUndo(withTarget: self) { target in
            target.addAnnotation(annotation, to: page)
        }
    }

    func createTextAnnotation(at point: CGPoint, on page: PDFPage, scaleFactor: CGFloat) -> PDFAnnotation {
        let width = 160 / max(1, scaleFactor)
        let height = 30 / max(1, scaleFactor)
        var bounds = CGRect(x: point.x, y: point.y - height / 2, width: width, height: height)
        let pageBounds = page.bounds(for: .mediaBox)
        if bounds.maxX > pageBounds.maxX {
            bounds.origin.x = max(pageBounds.minX, pageBounds.maxX - bounds.width)
        }
        if bounds.minY < pageBounds.minY {
            bounds.origin.y = pageBounds.minY
        }
        if bounds.maxY > pageBounds.maxY {
            bounds.origin.y = max(pageBounds.minY, pageBounds.maxY - bounds.height)
        }

        let text = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        text.color = NSColor.clear
        text.fontColor = NSColor.black
        text.font = NSFont.systemFont(ofSize: 12)
        text.alignment = .left
        text.contents = ""
        text.isReadOnly = false
        text.shouldDisplay = true
        text.shouldPrint = true
        addAnnotation(text, to: page)
        return text
    }

    func saveAs() {
        guard let document else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "Edited.pdf"

        if panel.runModal() == .OK, let url = panel.url {
            if document.write(to: url) {
                statusMessage = "Saved: \(url.lastPathComponent)"
            } else {
                statusMessage = "Save failed."
            }
        }
    }

    func save() {
        guard let document else { return }
        guard let url = currentFileURL else {
            saveAs()
            return
        }

        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
        }

        if document.write(to: url) {
            statusMessage = "Saved: \(url.lastPathComponent)"
        } else {
            statusMessage = "Save failed."
        }
    }

    func updateSelection() {
        guard let selection = pdfView?.currentSelection else {
            selectedText = ""
            return
        }
        let selectionText = selection.string ?? ""
        selectedText = selectionText

        guard !selectionText.isEmpty, !isApplyingAutoReplace else { return }
        isApplyingAutoReplace = true
        replaceSelection(with: selectionText)
        isApplyingAutoReplace = false
    }

    func replaceSelection(with replacement: String) {
        guard let pdfView, let document, !replacement.isEmpty else { return }
        guard let selection = pdfView.currentSelection else { return }

        let lineSelections = selection.selectionsByLine()
        var didFocus = false

        for page in selection.pages {
            let pageLineSelections = lineSelections.filter { $0.pages.contains(page) }
            guard !pageLineSelections.isEmpty else { continue }

            let pageText = pageLineSelections.compactMap { $0.string?.trimmingCharacters(in: .newlines) }
                .joined(separator: "\n")
            if pageText.isEmpty { continue }

            // Mask each selected line so we don't hide text before the selection start.
            for lineSelection in pageLineSelections {
                let bounds = lineSelection.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let cover = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
                cover.color = NSColor.white
                cover.interiorColor = NSColor.white
                cover.border = PDFBorder()
                cover.border?.lineWidth = 0
                addAnnotation(cover, to: page)
            }

            // Use the first line's start X for first-line indent.
            let firstLineBounds = pageLineSelections.first!.bounds(for: page)
            let unionBounds = pageLineSelections.reduce(firstLineBounds) { result, selection in
                result.union(selection.bounds(for: page))
            }
            let startX = firstLineBounds.minX
            let minX = unionBounds.minX
            let firstLineIndent = max(0, startX - minX)

            let attributed = selection.attributedString
            var dominantFont: NSFont?
            var inferredFontSize: CGFloat?
            if let attributed, attributed.length > 0 {
                var bestFont: NSFont?
                var bestRunLength = 0
                attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                    if let font = value as? NSFont, range.length > bestRunLength {
                        bestRunLength = range.length
                        bestFont = font
                    }
                }
                if let bestFont {
                    dominantFont = bestFont
                    inferredFontSize = bestFont.pointSize
                }
            }

            let defaultSize = max(10, unionBounds.height * 0.6)
            let fontSize = inferredFontSize ?? defaultSize
            let font = dominantFont ?? NSFont.systemFont(ofSize: fontSize)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]

            var textBounds = unionBounds
            let measuredWidth = (pageText as NSString).size(withAttributes: attributes).width
            textBounds.size.width = max(unionBounds.width, measuredWidth + 20)

            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = firstLineIndent
            paragraph.headIndent = 0
            paragraph.lineBreakMode = .byWordWrapping

            let attributedText = NSAttributedString(
                string: pageText,
                attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.black]
            )

            let maxSize = CGSize(width: textBounds.width - 8, height: .greatestFiniteMagnitude)
            let rect = attributedText.boundingRect(
                with: maxSize,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            textBounds.size.height = max(unionBounds.height, ceil(rect.height) + 8)

            let text = PDFAnnotation(bounds: textBounds, forType: .freeText, withProperties: nil)
            text.color = NSColor.clear
            text.fontColor = NSColor.black
            text.font = font
            text.alignment = .left
            text.contents = pageText
            text.isReadOnly = false
            text.shouldDisplay = true
            text.shouldPrint = true
            addAnnotation(text, to: page)

            if let dropView = pdfView as? PDFDropView, !didFocus {
                dropView.beginEditing(annotation: text, focus: true)
                didFocus = true
            }
        }

        pdfView.setCurrentSelection(nil, animate: false)
        document.delegate = nil
        statusMessage = "Applied replacement."
    }
}
