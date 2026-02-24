import Foundation
import PDFKit
import AppKit
import UniformTypeIdentifiers

final class PDFDocumentController: ObservableObject {
    @Published var document: PDFDocument?
    @Published var currentFileURL: URL?
    @Published var statusMessage: String = "Open a PDF to begin."
    @Published var selectedText: String = ""
    @Published var hasChanges: Bool = false

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
        hasChanges = false
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
        hasChanges = false
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
        hasChanges = true
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

    @discardableResult
    func saveAs() -> Bool {
        guard let document else { return false }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "Edited.pdf"

        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard document.write(to: url) else {
            statusMessage = "Save failed."
            return false
        }
        hasChanges = false
        statusMessage = "Saved: \(url.lastPathComponent)"
        return true
    }

    @discardableResult
    func save() -> Bool {
        guard let document else { return false }
        guard let url = currentFileURL else { return saveAs() }

        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
        }

        guard document.write(to: url) else {
            statusMessage = "Save failed."
            return false
        }
        hasChanges = false
        statusMessage = "Saved: \(url.lastPathComponent)"
        return true
    }

    func updateSelection() {
        guard let selection = pdfView?.currentSelection else {
            selectedText = ""
            return
        }
        let selectionText = selection.string ?? ""
        selectedText = selectionText

        guard !isApplyingAutoReplace else { return }
        // Replace when we have text, or when selection has valid bounds (e.g. table cells where string can be empty).
        let hasText = !selectionText.isEmpty
        let hasValidBounds = selection.pages.contains { selection.bounds(for: $0).width > 0 && selection.bounds(for: $0).height > 0 }
        guard hasText || hasValidBounds else { return }

        isApplyingAutoReplace = true
        replaceSelection(with: hasText ? selectionText : "")
        isApplyingAutoReplace = false
    }

    func replaceSelection(with replacement: String) {
        guard let pdfView, let document else { return }
        guard let selection = pdfView.currentSelection else { return }

        let lineSelections = selection.selectionsByLine()
        var didFocus = false

        for page in selection.pages {
            let pageLineSelections = lineSelections.filter { $0.pages.contains(page) }
            let unionBounds: CGRect
            let pageText: String
            let firstLineIndent: CGFloat

            let useLineBased = !pageLineSelections.isEmpty
                && pageLineSelections.contains { $0.bounds(for: page).width > 0 && $0.bounds(for: page).height > 0 }

            if useLineBased {
                pageText = pageLineSelections.compactMap { $0.string?.trimmingCharacters(in: .newlines) }
                    .joined(separator: "\n")
                if pageText.isEmpty { continue }

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

                let firstLineBounds = pageLineSelections.first!.bounds(for: page)
                unionBounds = pageLineSelections.reduce(firstLineBounds) { result, sel in
                    result.union(sel.bounds(for: page))
                }
                firstLineIndent = max(0, firstLineBounds.minX - unionBounds.minX)
            } else {
                // Fallback for table cells and other content where selectionsByLine() is empty or has zero bounds.
                unionBounds = selection.bounds(for: page)
                guard unionBounds.width > 0, unionBounds.height > 0 else { continue }
                pageText = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                // Allow empty pageText so user can type when PDFKit gives no string (e.g. some table cells).

                let cover = PDFAnnotation(bounds: unionBounds, forType: .square, withProperties: nil)
                cover.color = NSColor.white
                cover.interiorColor = NSColor.white
                cover.border = PDFBorder()
                cover.border?.lineWidth = 0
                addAnnotation(cover, to: page)
                firstLineIndent = 0
            }

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
