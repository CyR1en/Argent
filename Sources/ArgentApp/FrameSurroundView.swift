import AppKit
import ArgentCore
import Metal
import QuartzCore
import SwiftUI

/// The single-frame view's context-aware ambient surround, rendered on a `CAMetalLayer` behind
/// `FrameView`. Takes no clicks (`hitTest` returns `nil`) and drives crossfades via an on-demand
/// `CADisplayLink` that pauses immediately once settled (0% idle CPU/GPU).
struct FrameSurroundView: NSViewRepresentable {
    var controller: FrameSurroundController
    var workspaceSize: CGSize
    var palette: ThemePalette
    var outputSpace: OutputSpace
    var intensity: Double
    var reduceMotion: Bool
    /// Currently displayed frame image on `RollModel`, used to seed synchronously if the surround
    /// mounts after a frame is already open (e.g. turning off Gray Surround or toggling Settings).
    var fallbackImage: (frame: URL, image: CGImage)?

    func makeNSView(context: Context) -> FrameSurroundHostView {
        FrameSurroundHostView(controller: controller)
    }

    func updateNSView(_ view: FrameSurroundHostView, context: Context) {
        view.update(
            controller: controller,
            workspaceSize: workspaceSize,
            palette: palette,
            outputSpace: outputSpace,
            intensity: intensity,
            reduceMotion: reduceMotion,
            fallbackImage: fallbackImage
        )
    }

    static func dismantleNSView(_ view: FrameSurroundHostView, coordinator: ()) {
        view.teardown()
    }
}

/// AppKit + Metal host for the ambient surround.
final class FrameSurroundHostView: NSView {
    /// Compiled once per process; nil where no Metal device is available.
    private static let sharedRenderer: FrameSurroundRenderer? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try? FrameSurroundRenderer(device: device)
    }()

    private let renderer: FrameSurroundRenderer?
    private let metalLayer: CAMetalLayer?
    private let textures = FrameSurroundTextureSet()

    private var controller: FrameSurroundController
    private var controllerToken: UUID?
    private var motion = FrameSurroundMotion()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var drawnSize: CGSize = .zero
    private var uploadedGeneration: UInt64 = 0

    private var workspaceSize: CGSize = .zero
    private var palette: ThemePalette = Graphite.palette
    private var outputSpace: OutputSpace = .sRGB
    private var intensity: Double = AppearanceSettings.defaultAmbientSurroundIntensity
    private var reduceMotion: Bool = false

    init(controller: FrameSurroundController) {
        self.controller = controller
        renderer = Self.sharedRenderer
        metalLayer = renderer.map { renderer in
            let layer = CAMetalLayer()
            layer.device = renderer.device
            layer.pixelFormat = FrameSurroundRenderer.pixelFormat
            layer.colorspace = OutputSpace.sRGB.colorSpace
            layer.isOpaque = true
            layer.framebufferOnly = true
            layer.magnificationFilter = .linear
            layer.minificationFilter = .linear
            layer.contentsGravity = .resize
            layer.actions = [
                "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
                "contents": NSNull(), "anchorPoint": NSNull(), "contentsScale": NSNull(),
            ]
            return layer
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        if let metalLayer { layer?.addSublayer(metalLayer) }
        setAccessibilityElement(false)
        attach(to: controller)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Every click, drag and double-click belongs to `FrameView` over the surround.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(
        controller: FrameSurroundController,
        workspaceSize: CGSize,
        palette: ThemePalette,
        outputSpace: OutputSpace,
        intensity: Double,
        reduceMotion: Bool,
        fallbackImage: (frame: URL, image: CGImage)?
    ) {
        if controller !== self.controller {
            if let token = controllerToken { self.controller.detach(token, clearSamples: false) }
            self.controller = controller
            textures.clear()
            uploadedGeneration = 0
            attach(to: controller)
        }

        let spaceChanged = outputSpace != self.outputSpace
        let visualChanged = workspaceSize != self.workspaceSize
            || palette != self.palette
            || spaceChanged
            || intensity != self.intensity
            || reduceMotion != self.reduceMotion

        self.workspaceSize = workspaceSize
        self.palette = palette
        self.outputSpace = outputSpace
        self.intensity = intensity
        self.reduceMotion = reduceMotion

        if spaceChanged {
            metalLayer?.colorspace = outputSpace.colorSpace
        }
        updateFallbackBackgroundColor()

        if reduceMotion, motion.isAnimating {
            motion.finish()
        }

        let needsInitialSeed = controller.currentSample == nil
        let needsSpaceReseed = spaceChanged && controller.currentSample?.space != outputSpace
        if (needsInitialSeed || needsSpaceReseed), let fallback = fallbackImage {
            controller.submit(
                image: fallback.image,
                for: fallback.frame,
                space: outputSpace,
                pacing: .instant,
                seedSynchronously: needsInitialSeed
            )
        }

        let needsUpload = controller.currentSample != nil && uploadedGeneration != controller.sampleGeneration
        if needsUpload {
            handleControllerChange(.sample, inTransaction: true)
        } else if visualChanged {
            updateLinkState()
            render(inTransaction: true)
        }
    }

    func teardown() {
        stopDisplayLinkAndObservers()
        if let token = controllerToken {
            controller.detach(token, clearSamples: true)
            controllerToken = nil
        }
        textures.clear()
        uploadedGeneration = 0
    }

    private func attach(to controller: FrameSurroundController) {
        controllerToken = controller.attach { [weak self] reason in
            self?.handleControllerChange(reason, inTransaction: false)
        }
    }

    private func updateFallbackBackgroundColor() {
        let hex = palette.photoSurround
        let r = CGFloat((hex >> 16) & 0xff) / 255
        let g = CGFloat((hex >> 8) & 0xff) / 255
        let b = CGFloat(hex & 0xff) / 255
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            layer?.backgroundColor = CGColor(colorSpace: srgb, components: [r, g, b, 1])
        }
    }

    // MARK: Window lifecycle

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        stopDisplayLinkAndObservers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, renderer != nil else { return }
        let center = NotificationCenter.default
        let windowNames: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeScreenNotification,
        ]
        for name in windowNames {
            center.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: window)
        }
        let appNames: [Notification.Name] = [
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSApplication.didChangeScreenParametersNotification,
        ]
        for name in appNames {
            center.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: NSApp)
        }
        center.addObserver(self, selector: #selector(powerStateChanged(_:)), name: .NSProcessInfoPowerStateDidChange, object: nil)

        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
        metalLayer?.contentsScale = window.backingScaleFactor
        updateLinkState()
        if isReady {
            render(inTransaction: true)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window { metalLayer?.contentsScale = window.backingScaleFactor }
    }

    private func stopDisplayLinkAndObservers() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func visibilityChanged(_ notification: Notification) {
        updateLinkState()
        if isShown, isReady, !motion.isAnimating, !isOccludedByPhoto {
            render(inTransaction: false)
        }
    }

    @objc nonisolated private func powerStateChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.updateLinkState() }
    }

    private var isShown: Bool {
        guard let window, window.occlusionState.contains(.visible), !window.isMiniaturized, !NSApp.isHidden else {
            return false
        }
        return true
    }

    private var isReady: Bool {
        renderer != nil && metalLayer != nil && bounds.width > 0 && bounds.height > 0
    }

    private var effectiveWorkspaceSize: CGSize {
        workspaceSize.width > 0 && workspaceSize.height > 0 ? workspaceSize : bounds.size
    }

    private var isOccludedByPhoto: Bool {
        controller.isSurroundOccluded(workspaceSize: effectiveWorkspaceSize)
    }

    /// Runs the display link strictly while a crossfade is in progress and visible; pauses
    /// immediately at rest for zero idle GPU/CPU cost.
    private func updateLinkState() {
        guard let link else { return }
        let shouldRun = motion.isAnimating && !reduceMotion && isShown && isReady && !isOccludedByPhoto
        if shouldRun {
            let maxRate: Float = ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 120
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxRate, preferred: maxRate)
            if link.isPaused {
                lastTimestamp = nil
                link.isPaused = false
            }
        } else if !link.isPaused {
            link.isPaused = true
            lastTimestamp = nil
        }
    }

    // MARK: Drawing

    override func layout() {
        super.layout()
        guard let metalLayer, bounds.size != drawnSize else { return }
        drawnSize = bounds.size
        let drawable = FrameSurroundRenderer.drawableSize(for: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = convertToLayer(bounds)
        metalLayer.drawableSize = CGSize(width: drawable.width, height: drawable.height)
        CATransaction.commit()
        updateLinkState()
        render(inTransaction: true)
    }

    private func handleControllerChange(_ reason: FrameSurroundController.ChangeReason, inTransaction: Bool) {
        switch reason {
        case .reset:
            textures.clear()
            uploadedGeneration = 0
            motion.finish()
            updateLinkState()
            render(inTransaction: inTransaction)
        case .geometry:
            updateLinkState()
            if !isOccludedByPhoto {
                render(inTransaction: false)
            }
        case .sample:
            let hadTexture = textures.current != nil
            if hadTexture, controller.previousSample != nil, !isOccludedByPhoto {
                motion.begin(controller.lastPacing, reduceMotion: reduceMotion)
            } else {
                motion.finish()
            }
            updateLinkState()
            if !isOccludedByPhoto {
                render(inTransaction: inTransaction)
            }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard isReady else { return }
        let dt = lastTimestamp.map { link.timestamp - $0 } ?? 0
        lastTimestamp = link.timestamp
        motion.step(dt: dt, reduceMotion: reduceMotion)
        render(inTransaction: false)
        if !motion.isAnimating {
            updateLinkState()
        }
    }

    private func render(inTransaction: Bool) {
        guard isReady, let renderer, let metalLayer else { return }
        let needsUpload = controller.currentSample != nil && uploadedGeneration != controller.sampleGeneration
        let sampleToUpload = needsUpload ? controller.currentSample : nil
        let keepPrevious = textures.current != nil && controller.previousSample != nil && motion.isAnimating

        metalLayer.presentsWithTransaction = inTransaction
        guard let drawable = metalLayer.nextDrawable() else { return }

        var buffer: MTLCommandBuffer?
        if let sampleToUpload {
            buffer = renderer.uploadAndBlur(sampleToUpload, into: textures, keepPrevious: keepPrevious)
            if buffer != nil {
                uploadedGeneration = controller.sampleGeneration
            }
        }

        let state = FrameSurroundDrawState(
            viewSize: bounds.size,
            workspaceSize: effectiveWorkspaceSize,
            photoRect: controller.currentPhotoRect ?? controller.photoRect,
            previousPhotoRect: controller.previousPhotoRect,
            palette: palette,
            outputSpace: outputSpace,
            intensity: Float(intensity),
            blend: motion.blend,
            hasCurrent: textures.current != nil,
            hasPrevious: textures.previous != nil && motion.isAnimating
        )

        guard let finalBuffer = renderer.draw(state, textures: textures, to: drawable.texture, on: buffer) else {
            buffer?.commit()
            return
        }

        if inTransaction {
            finalBuffer.commit()
            finalBuffer.waitUntilScheduled()
            drawable.present()
        } else {
            finalBuffer.present(drawable)
            finalBuffer.commit()
        }
    }
}
