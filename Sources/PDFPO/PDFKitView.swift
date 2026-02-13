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
    private weak var pendingAnnotation: PDFAnnotation?
    private var pendingPage: PDFPage?
    private var pendingStartPoint: CGPoint = .zero
    private var didDragAnnotation: Bool = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let page = page(for: viewPoint, nearest: true) {
            let pagePoint = convert(viewPoint, to: page)
            if event.clickCount == 2, let controller {
                if page.annotation(at: pagePoint) == nil {
                    commitEditing()
                    let annotation = controller.createTextAnnotation(
                        at: pagePoint,
                        on: page,
                        scaleFactor: scaleFactor
                    )
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
        let expandedBounds = viewBounds.insetBy(dx: -4, dy: -4)
        let textView = SingleLineTextView(frame: expandedBounds)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        let annotationFont = annotation.font ?? NSFont.systemFont(ofSize: 12)
        let scaledFont = NSFontManager.shared.convert(annotationFont, toSize: annotationFont.pointSize + 4)
        textView.font = scaledFont
        textView.typingAttributes = [.font: scaledFont]
        let textColor = annotation.fontColor ?? .labelColor
        textView.textColor = textColor
        textView.string = annotation.contents ?? ""
        if let textStorage = textView.textStorage {
            textStorage.setAttributes(
                [.font: scaledFont, .foregroundColor: textColor],
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
            if let font = annotation.font {
                let attributes: [NSAttributedString.Key: Any] = [.font: font]
                let measuredWidth = (textView.string as NSString).size(withAttributes: attributes).width
                var newBounds = annotation.bounds
                newBounds.size.width = max(newBounds.width, measuredWidth + 20)
                annotation.bounds = newBounds
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
        textView.removeFromSuperview()
        editorView = nil
        editingAnnotation = nil
    }

    func textDidEndEditing(_ notification: Notification) {
        commitEditing()
    }
}

final class SingleLineTextView: NSTextView {
    override func insertNewline(_ sender: Any?) {
        if let delegate = self.delegate as? PDFDropView {
            delegate.textDidEndEditing(Notification(name: NSText.didEndEditingNotification, object: self))
        }
    }
}
