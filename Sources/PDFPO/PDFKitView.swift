import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct PDFKitView: NSViewRepresentable {
    @ObservedObject var controller: PDFDocumentController
    @Binding var isTargeted: Bool

    func makeNSView(context: Context) -> PDFDropView {
        let view = PDFDropView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        view.delegate = context.coordinator
        view.controller = controller
        view.onTargetedChange = { targeted in
            isTargeted = targeted
        }
        view.registerForDraggedTypes([.fileURL, .pdf])
        controller.pdfView = view
        return view
    }

    func updateNSView(_ nsView: PDFDropView, context: Context) {
        if nsView.document !== controller.document {
            nsView.document = controller.document
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    final class Coordinator: NSObject, PDFViewDelegate {
        private let controller: PDFDocumentController

        init(controller: PDFDocumentController) {
            self.controller = controller
        }

        func pdfViewSelectionChanged(_ notification: Notification) {
            controller.updateSelection()
        }
    }
}

final class PDFDropView: PDFView, NSTextViewDelegate {
    weak var controller: PDFDocumentController?
    var onTargetedChange: ((Bool) -> Void)?
    private weak var draggingAnnotation: PDFAnnotation?
    private var dragPage: PDFPage?
    private var dragStartPoint: CGPoint = .zero
    private var dragStartBounds: CGRect = .zero
    private weak var editingAnnotation: PDFAnnotation?
    private var editorView: NSTextView?
    private var editorOutlineView: EditorOutlineView?
    private var resizeHandleView: ResizeHandleView?
    private var fontSizeHandleView: FontSizeHandleView?
    private weak var pendingAnnotation: PDFAnnotation?
    private var pendingPage: PDFPage?
    private var pendingStartPoint: CGPoint = .zero
    private var didDragAnnotation: Bool = false

    private let editorResizeHandleWidth: CGFloat = 12
    private let editorFontSizeHandleSize: CGFloat = 28
    private let editorMinWidth: CGFloat = 80
    private let editorMinHeight: CGFloat = 24

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let page = page(for: viewPoint, nearest: true) {
            let pagePoint = convert(viewPoint, to: page)
            if event.clickCount == 2, let controller {
                // Check if we clicked an existing annotation
                if let annotation = page.annotation(at: pagePoint),
                   annotation.type?.lowercased() == "freetext" {
                    commitEditing()
                    beginEditing(annotation: annotation, focus: true)
                    return
                }
                
                // If no annotation, check for text selection
                if let wordSelection = page.selectionForWord(at: pagePoint) {
                    // Verify the click is actually inside the word's bounds
                    let wordBounds = wordSelection.bounds(for: page)
                    if wordBounds.contains(pagePoint) {
                        commitEditing()
                        
                        // Add a white cover annotation over the word
                        let cover = PDFAnnotation(bounds: wordBounds, forType: .square, withProperties: nil)
                        cover.color = NSColor.white
                        cover.interiorColor = NSColor.white
                        cover.border = PDFBorder()
                        cover.border?.lineWidth = 0
                        controller.addAnnotation(cover, to: page)

                        let annotation = controller.createTextAnnotation(
                            at: pagePoint,
                            on: page,
                            scaleFactor: scaleFactor
                        )
                        
                        // Set annotation bounds to match word selection with extra width
                        var adjustedBounds = wordBounds
                        adjustedBounds.size.width += 20 // Add extra width to prevent clipping/wrapping
                        annotation.bounds = adjustedBounds
                        annotation.contents = wordSelection.string
                        
                        // Infer font from selection if possible
                        if let attributed = wordSelection.attributedString, attributed.length > 0 {
                            if let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                                annotation.font = font
                            }
                        }
                        
                        beginEditing(annotation: annotation, focus: true)
                        return
                    }
                }

                // Default: create new annotation
                if page.annotation(at: pagePoint) == nil {
                    commitEditing()
                    let annotation = controller.createTextAnnotation(
                        at: pagePoint,
                        on: page,
                        scaleFactor: scaleFactor
                    )
                    annotation.contents = "Text"
                    beginEditing(annotation: annotation, focus: true)
                    return
                }
            }
            if let annotation = page.annotation(at: pagePoint),
               annotation.type?.lowercased() == "freetext" {
                pendingAnnotation = annotation
                pendingPage = page
                pendingStartPoint = pagePoint
                didDragAnnotation = false
                return
            }
        }
        commitEditing()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let annotation = draggingAnnotation, let page = dragPage {
            let viewPoint = convert(event.locationInWindow, from: nil)
            let pagePoint = convert(viewPoint, to: page)
            let dx = pagePoint.x - dragStartPoint.x
            let dy = pagePoint.y - dragStartPoint.y
            var newBounds = dragStartBounds
            newBounds.origin.x += dx
            newBounds.origin.y += dy
            annotation.bounds = newBounds
            setNeedsDisplay(annotation.bounds)
            return
        }

        if let annotation = pendingAnnotation, let page = pendingPage {
            let viewPoint = convert(event.locationInWindow, from: nil)
            let pagePoint = convert(viewPoint, to: page)
            let dx = pagePoint.x - pendingStartPoint.x
            let dy = pagePoint.y - pendingStartPoint.y
            let distance = hypot(dx, dy)
            if distance > 2 {
                commitEditing()
                draggingAnnotation = annotation
                dragPage = page
                dragStartPoint = pendingStartPoint
                dragStartBounds = annotation.bounds
                didDragAnnotation = true
            }
            return
        }

        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if draggingAnnotation != nil {
            controller?.hasChanges = true
            draggingAnnotation = nil
            dragPage = nil
        }
        if let annotation = pendingAnnotation {
            if didDragAnnotation {
                pendingAnnotation = nil
                pendingPage = nil
                didDragAnnotation = false
            } else {
                pendingAnnotation = nil
                pendingPage = nil
                beginEditing(annotation: annotation, focus: true)
            }
        }
        super.mouseUp(with: event)
        controller?.updateSelection()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onTargetedChange?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChange?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetedChange?(false)
        commitEditing()
        let pasteboard = sender.draggingPasteboard

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first {
            controller?.open(url: url)
            return true
        }

        if let data = pasteboard.data(forType: .pdf) ??
            pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.pdf.identifier)) {
            controller?.open(data: data)
            return true
        }

        return false
    }

    func beginEditing(annotation: PDFAnnotation, focus: Bool) {
        commitEditing()
        guard let page = annotation.page else { return }
        let viewBounds = convert(annotation.bounds, from: page)
        let components = [viewBounds.origin.x, viewBounds.origin.y, viewBounds.size.width, viewBounds.size.height]
        let hasInvalid = components.contains { $0.isNaN || $0.isInfinite }
        guard !hasInvalid, !viewBounds.isEmpty, !viewBounds.isNull else {
            return
        }
        let editorBounds = viewBounds
        let textView = SingleLineTextView(frame: editorBounds)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineBreakMode = .byWordWrapping
        let annotationFont = annotation.font ?? NSFont.systemFont(ofSize: 12)
        let editorFont = NSFontManager.shared.convert(annotationFont, toSize: annotationFont.pointSize * scaleFactor)
        textView.font = editorFont
        textView.typingAttributes = [.font: editorFont]
        let textColor = annotation.fontColor ?? .labelColor
        textView.textColor = textColor
        textView.string = annotation.contents ?? ""
        if let textStorage = textView.textStorage {
            textStorage.setAttributes(
                [.font: editorFont, .foregroundColor: textColor],
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.focusRingType = .none
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0

        addSubview(textView)
        let outlineView = EditorOutlineView(frame: editorBounds)
        addSubview(outlineView, positioned: .above, relativeTo: textView)
        editorOutlineView = outlineView

        let handleFrame = CGRect(
            x: editorBounds.maxX,
            y: editorBounds.minY,
            width: editorResizeHandleWidth,
            height: editorBounds.height
        )
        let handle = ResizeHandleView(frame: handleFrame)
        handle.onDragDeltaX = { [weak self, weak textView] dx in
            guard let self, let textView else { return }
            var frame = textView.frame
            frame.size.width = max(self.editorMinWidth, frame.size.width + dx)
            textView.frame = frame
            self.updateEditorHeightToFitText()
            self.layoutEditorOverlay()
        }
        addSubview(handle, positioned: .above, relativeTo: outlineView)
        resizeHandleView = handle

        let fontSizeHandleFrame = CGRect(
            x: editorBounds.midX - editorFontSizeHandleSize / 2,
            y: editorBounds.maxY,
            width: editorFontSizeHandleSize,
            height: editorFontSizeHandleSize
        )
        let fontSizeHandle = FontSizeHandleView(frame: fontSizeHandleFrame)
        fontSizeHandle.onDragDeltaY = { [weak self, weak textView] dy in
            guard let self, let textView else { return }
            let font = textView.font ?? NSFont.systemFont(ofSize: 12)
            let currentPointSizePage = font.pointSize / self.scaleFactor
            let newPointSizePage = max(6, min(72, currentPointSizePage + dy * 0.5))
            let newPointSizeView = newPointSizePage * self.scaleFactor
            
            if abs(newPointSizeView - font.pointSize) < 0.1 { return }
            let newFont = NSFontManager.shared.convert(font, toSize: newPointSizeView)
            textView.font = newFont
            textView.typingAttributes = [.font: newFont]
            if let storage = textView.textStorage {
                storage.addAttribute(.font, value: newFont, range: NSRange(location: 0, length: storage.length))
            }
            self.updateEditorHeightToFitText()
            self.layoutEditorOverlay()
        }
        addSubview(fontSizeHandle, positioned: .above, relativeTo: handle)
        fontSizeHandleView = fontSizeHandle

        updateEditorHeightToFitText()
        layoutEditorOverlay()
        if focus {
            window?.makeFirstResponder(textView)
            textView.selectAll(nil)
        }
        editingAnnotation = annotation
        editorView = textView
        annotation.shouldDisplay = false
    }

    private func commitEditing() {
        guard let textView = editorView else { return }
        if let annotation = editingAnnotation {
            let previousContents = annotation.contents ?? ""
            let previousBounds = annotation.bounds
            annotation.contents = textView.string
            if previousContents != textView.string {
                controller?.hasChanges = true
            }
            if let page = annotation.page {
                textView.layoutManager?.ensureLayout(for: textView.textContainer!)
                var newBounds = convert(textView.frame, to: page)
                if newBounds.width > 0, newBounds.height > 0, !newBounds.isNull, !newBounds.isEmpty {
                    let extraBottom: CGFloat = 6
                    newBounds.size.height += extraBottom
                    newBounds.origin.y -= extraBottom
                    annotation.bounds = newBounds
                }
            }
            annotation.shouldDisplay = true
            if let controller, let undo = controller.undoManager() {
                undo.registerUndo(withTarget: annotation) { ann in
                    let redoContents = ann.contents ?? ""
                    let redoBounds = ann.bounds
                    ann.contents = previousContents
                    ann.bounds = previousBounds
                    undo.registerUndo(withTarget: ann) { _ in
                        ann.contents = redoContents
                        ann.bounds = redoBounds
                    }
                }
                undo.setActionName("Edit Text")
            }
        }
        if let font = textView.font {
            let pageFont = NSFontManager.shared.convert(font, toSize: font.pointSize / scaleFactor)
            editingAnnotation?.font = pageFont
        }
        textView.removeFromSuperview()
        editorOutlineView?.removeFromSuperview()
        editorOutlineView = nil
        resizeHandleView?.removeFromSuperview()
        resizeHandleView = nil
        fontSizeHandleView?.removeFromSuperview()
        fontSizeHandleView = nil
        editorView = nil
        editingAnnotation = nil
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView, textView === editorView else { return }
        updateEditorHeightToFitText()
        layoutEditorOverlay()
    }

    func textDidEndEditing(_ notification: Notification) {
        commitEditing()
    }

    private func updateEditorHeightToFitText() {
        guard let textView = editorView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let bottomPadding = max(8, abs(font.descender) + 4)
        let targetHeight = max(editorMinHeight, ceil(used.height) + bottomPadding)
        var frame = textView.frame
        if abs(frame.height - targetHeight) > 0.5 {
            let topY = frame.maxY
            frame.size.height = targetHeight
            frame.origin.y = topY - targetHeight
            textView.frame = frame
        }
    }

    private func layoutEditorOverlay() {
        guard let textView = editorView else { return }
        editorOutlineView?.frame = textView.frame
        editorOutlineView?.needsDisplay = true
        if let handle = resizeHandleView {
            handle.frame = CGRect(
                x: textView.frame.maxX,
                y: textView.frame.minY,
                width: editorResizeHandleWidth,
                height: textView.frame.height
            )
            handle.needsDisplay = true
        }
        if let fontSizeHandle = fontSizeHandleView {
            let s = editorFontSizeHandleSize
            fontSizeHandle.frame = CGRect(
                x: textView.frame.midX - s / 2,
                y: textView.frame.maxY,
                width: s,
                height: s
            )
            fontSizeHandle.needsDisplay = true
        }
    }
}

final class EditorOutlineView: NSView {
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1.5
        NSColor.systemBlue.setStroke()
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.stroke()
    }
}

final class SingleLineTextView: NSTextView {
    override func insertNewline(_ sender: Any?) {
        if let delegate = self.delegate as? PDFDropView {
            delegate.textDidEndEditing(Notification(name: NSText.didEndEditingNotification, object: self))
        }
    }
}

final class ResizeHandleView: NSView {
    var onDragDeltaX: ((CGFloat) -> Void)?
    private var lastWindowX: CGFloat?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastWindowX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastWindowX else { return }
        let newX = event.locationInWindow.x
        let dx = newX - lastWindowX
        self.lastWindowX = newX
        onDragDeltaX?(dx)
    }

    override func mouseUp(with event: NSEvent) {
        lastWindowX = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds
        NSColor.controlBackgroundColor.withAlphaComponent(0.7).setFill()
        NSBezierPath(rect: rect).fill()
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()

        let midX = rect.midX
        let midY = rect.midY
        let pad: CGFloat = 4
        let vertPad: CGFloat = 5
        let availableHeight = rect.height - vertPad * 2
        let availableWidth = rect.width - pad * 2
        let sqrt3: CGFloat = 1.73205080757
        let triHeight = min(availableHeight, availableWidth * 2 / sqrt3)
        let triWidth = triHeight * sqrt3 / 2

        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: midX + triWidth / 2, y: midY))
        tri.line(to: NSPoint(x: midX - triWidth / 2, y: midY - triHeight / 2))
        tri.line(to: NSPoint(x: midX - triWidth / 2, y: midY + triHeight / 2))
        tri.close()
        NSColor.labelColor.setFill()
        tri.fill()
    }
}

final class FontSizeHandleView: NSView {
    var onDragDeltaY: ((CGFloat) -> Void)?
    private var lastWindowY: CGFloat?

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        lastWindowY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastWindowY else { return }
        let newY = event.locationInWindow.y
        let dy = newY - lastWindowY
        self.lastWindowY = newY
        onDragDeltaY?(dy)
    }

    override func mouseUp(with event: NSEvent) {
        lastWindowY = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds
        NSColor.controlBackgroundColor.withAlphaComponent(0.7).setFill()
        NSBezierPath(rect: rect).fill()
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.stroke()

        let midX = rect.midX
        let midY = rect.midY
        let sqrt3: CGFloat = 1.73205080757
        let refWidth: CGFloat = 12
        let pad: CGFloat = 4
        let availableWidth = refWidth - pad * 2
        let triVertical = availableWidth * 2 / sqrt3
        let triBaseHalf = triVertical / sqrt3

        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: midX, y: midY + triVertical / 2))
        tri.line(to: NSPoint(x: midX - triBaseHalf, y: midY - triVertical / 2))
        tri.line(to: NSPoint(x: midX + triBaseHalf, y: midY - triVertical / 2))
        tri.close()
        NSColor.labelColor.setFill()
        tri.fill()
    }
}
