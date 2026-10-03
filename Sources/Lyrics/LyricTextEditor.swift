import AppKit
import SwiftUI

/// The native text view handles file drops before its standard path insertion.
struct LyricTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var onFileDrop: ([URL]) -> Void
    var onFileTargetChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let editor = LyricDropTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 5, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.registerForDraggedTypes([.fileURL])
        editor.setAccessibilityLabel("歌詞全文")
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? LyricDropTextView else { return }
        editor.isEditable = isEditable
        editor.onFileDrop = onFileDrop
        editor.onFileTargetChanged = onFileTargetChanged
        if editor.string != text {
            editor.string = text
            editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LyricTextEditor
        init(_ parent: LyricTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            // Keep Japanese composition intact until the input is committed.
            guard !editor.hasMarkedText() else {
                parent.text = editor.string
                return
            }
            let cleaned = LyricInput.clean(editor.string, selection: editor.selectedRange())
            if editor.string != cleaned.text {
                editor.string = cleaned.text
                editor.setSelectedRange(cleaned.selection)
            }
            parent.text = cleaned.text
        }
    }
}

final class LyricDropTextView: NSTextView {
    var onFileDrop: (([URL]) -> Void)?
    var onFileTargetChanged: ((Bool) -> Void)?

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL]? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return nil }
        return urls
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileURLs(sender) != nil else { return super.draggingEntered(sender) }
        onFileTargetChanged?(isEditable)
        return isEditable ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileURLs(sender) != nil else { return super.draggingUpdated(sender) }
        return isEditable ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileTargetChanged?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard fileURLs(sender) != nil else { return super.prepareForDragOperation(sender) }
        return isEditable
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(sender) else { return super.performDragOperation(sender) }
        onFileTargetChanged?(false)
        guard isEditable else { return false }
        onFileDrop?(urls)
        // Failed imports are handled here too, without inserting paths or passing to the audio queue.
        return true
    }
}
