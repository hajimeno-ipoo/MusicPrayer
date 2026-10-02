import AppKit
import MetalKit
import SwiftUI

struct MetalVisualizerView: NSViewRepresentable {
    let source: VisualFrameSource

    func makeNSView(context: Context) -> VisualizerHostView {
        VisualizerHostView(source: source)
    }

    func updateNSView(_ nsView: VisualizerHostView, context: Context) {
    }
}

final class VisualizerHostView: NSView {
    private let metalView: MTKView
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var renderer: MetalRenderer?

    init(source: VisualFrameSource) {
        let device = MTLCreateSystemDefaultDevice()
        metalView = WaterInteractiveMetalView(device: device, source: source)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.005, green: 0.012, blue: 0.04, alpha: 1).cgColor
        metalView.colorPixelFormat = .bgra8Unorm_srgb
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)
        errorLabel.textColor = .white
        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -70),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8)
        ])
        do {
            guard let device else { throw RenderFailure.message("このMacでMetalを使用できません。") }
            renderer = try MetalRenderer(device: device, source: source)
            renderer?.onError = { [weak self] message in
                DispatchQueue.main.async { self?.showError(message) }
            }
            metalView.delegate = renderer
            source.observeFrames { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    (self.metalView as? WaterInteractiveMetalView)?.updateInteractionStyle()
                    self.renderer?.resumeIfNeeded(in: self.metalView)
                }
            }
        } catch { showError(error.localizedDescription) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func showError(_ message: String) {
        NSLog("Visualizer: %@", message)
        errorLabel.stringValue = "ビジュアライザーを描画できません\n" + message
        errorLabel.isHidden = false
        metalView.isPaused = true
    }
}

/// Native pointer handling only receives the uncovered background, below SwiftUI controls.
private final class WaterInteractiveMetalView: MTKView {
    private let source: VisualFrameSource
    private let interactions: WaterInteractions
    private var draggingWater = false
    private var lastDragPoint: SIMD2<Float>?
    private var lastDragTime: TimeInterval = 0

    init(device: MTLDevice?, source: VisualFrameSource) {
        self.source = source
        self.interactions = source.waterInteractions
        super.init(frame: .zero, device: device)
        updateInteractionStyle()
    }

    func updateInteractionStyle() {
        let isWater = source.snapshot().style == .ribbons
        let hint = isWater ? "水面をクリック・ドラッグすると波紋が広がります" : nil
        if toolTip != hint { toolTip = hint }
        if !isWater { draggingWater = false; lastDragPoint = nil }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard source.snapshot().style == .ribbons else { super.mouseDown(with: event); return }
        guard let point = screenUV(for: event) else { return }
        draggingWater = interactions.enqueue(screenUV: point)
        if draggingWater {
            isPaused = false
            lastDragPoint = point
            lastDragTime = event.timestamp
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard source.snapshot().style == .ribbons else { draggingWater = false; super.mouseDragged(with: event); return }
        guard draggingWater else { super.mouseDragged(with: event); return }
        guard let point = screenUV(for: event) else { return }
        let previous = lastDragPoint ?? point
        let dx = point.x - previous.x, dy = point.y - previous.y
        guard dx * dx + dy * dy >= 0.000144, event.timestamp - lastDragTime >= 0.025 else { return }
        if interactions.enqueue(screenUV: point, strength: 0.35, radius: 0.018) {
            isPaused = false
            lastDragPoint = point
            lastDragTime = event.timestamp
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !draggingWater { super.mouseUp(with: event) }
        draggingWater = false
        lastDragPoint = nil
    }

    private func screenUV(for event: NSEvent) -> SIMD2<Float>? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return SIMD2<Float>(Float((point.x - bounds.minX) / bounds.width),
                            Float(isFlipped ? (point.y - bounds.minY) / bounds.height : (bounds.maxY - point.y) / bounds.height))
    }
}
