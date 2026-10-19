import AppKit

/// The player is the glass's content, so AppKit owns its backdrop and contrast.
final class PlayerGlassEffectView: NSGlassEffectView {
    var onFileDrop: (([URL]) -> Void)?
    var onFileTargetChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = .clear
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL]? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return nil }
        return urls
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let acceptsFiles = onFileDrop != nil && fileURLs(sender) != nil
        onFileTargetChanged?(acceptsFiles)
        return acceptsFiles ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFileDrop != nil && fileURLs(sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onFileDrop != nil && fileURLs(sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onFileTargetChanged?(false)
        guard let urls = fileURLs(sender), let onFileDrop else { return false }
        onFileDrop(urls)
        return true
    }
}
