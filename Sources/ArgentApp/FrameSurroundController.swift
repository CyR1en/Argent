import ArgentCore
import CoreGraphics
import Foundation

/// A tiny RGBA8 sample of a photograph, extracted off the main thread in the output colour space
/// for the single-frame view's context-aware ambient surround (`FrameSurroundRenderer`).
struct FrameSurroundSample: Equatable, Sendable {
    /// The longer side of the sampled colour field, in texels: 48×32 for a 3:2 frame (6 KiB).
    static let longSide = 48

    var width: Int
    var height: Int
    /// Tightly packed RGBA8 bytes (`width * height * 4`) encoded in `space`.
    var bytes: [UInt8]
    var space: OutputSpace

    /// Downsamples `image` into a tiny `longSide` RGB bitmap in `targetSpace`, matching the
    /// window's colour space so wide-gamut Display P3 and Adobe RGB colours stay true.
    static func extract(from image: CGImage, targetSpace: OutputSpace) -> Self? {
        let sourceWidth = image.width, sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let width: Int
        let height: Int
        if sourceWidth >= sourceHeight {
            width = min(Self.longSide, sourceWidth)
            height = max(1, Int((Double(sourceHeight) / Double(sourceWidth) * Double(width)).rounded()))
        } else {
            height = min(Self.longSide, sourceHeight)
            width = max(1, Int((Double(sourceWidth) / Double(sourceHeight) * Double(height)).rounded()))
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: targetSpace.colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Self(width: width, height: height, bytes: bytes, space: targetSpace)
    }
}

/// Pure, clockless crossfade timing for the ambient surround: advances monotonically from `0` to `1`
/// with cubic ease-out, pauses cleanly at `1` (`isAnimating == false`), and snaps under Reduce Motion.
struct FrameSurroundMotion: Equatable, Sendable {
    /// How long each kind of change takes to settle, in seconds.
    enum Pacing: Equatable, Sendable {
        /// Initial seed when opening from the contact sheet or under Reduce Motion.
        case instant
        /// Single frame step or film render arriving over a camera preview.
        case step
        /// Rapid arrow-key scrubbing or live Adjust slider drags.
        case live

        var duration: Double {
            switch self {
            case .instant: 0
            case .step: 0.28
            case .live: 0.09
            }
        }
    }

    /// Cap each display-link tick so a hitch or wake from sleep never leaps wildly.
    static let maximumStep = 0.1

    /// Linear progress from `0` (previous sample) to `1` (current sample settled).
    private(set) var progress: Double = 1
    private(set) var duration: Double = 0

    var isAnimating: Bool { progress < 1 }

    /// Cubic ease-out blend factor handed to the Metal composite shader.
    var blend: Float {
        let t = min(max(progress, 0), 1)
        let inv = 1 - t
        return Float(1 - inv * inv * inv)
    }

    /// Begins a new transition of `pacing`, or snaps immediately when `reduceMotion` is on.
    mutating func begin(_ pacing: Pacing, reduceMotion: Bool) {
        let length = reduceMotion ? 0 : pacing.duration
        if length <= 0 {
            progress = 1
            duration = 0
        } else {
            progress = 0
            duration = length
        }
    }

    /// Advances the transition by `dt` seconds.
    mutating func step(dt: Double, reduceMotion: Bool) {
        if reduceMotion || duration <= 0 {
            progress = 1
            duration = 0
            return
        }
        guard progress < 1 else { return }
        let clamped = min(max(dt, 0), Self.maximumStep)
        progress = min(1, progress + clamped / duration)
        if progress >= 1 { duration = 0 }
    }

    /// Forces the transition to rest immediately.
    mutating func finish() {
        progress = 1
        duration = 0
    }
}

/// Coordinates off-main-thread image sampling and live geometry updates for the frame view's ambient
/// surround. Held as `@ObservationIgnored` on `RollModel` so live slider drags and zoom gestures drive
/// the `CAMetalLayer` directly without invalidating SwiftUI's workspace hierarchy.
@MainActor final class FrameSurroundController {
    enum ChangeReason: Equatable {
        case sample
        case geometry
        case reset
    }

    private struct PendingJob {
        var image: CGImage
        var imageID: ObjectIdentifier
        var frameURL: URL
        var space: OutputSpace
        var pacing: FrameSurroundMotion.Pacing
        var epoch: UInt64
    }

    private(set) var frameURL: URL?
    private(set) var currentSample: FrameSurroundSample?
    private(set) var previousSample: FrameSurroundSample?
    private(set) var currentPhotoRect: CGRect?
    private(set) var previousPhotoRect: CGRect?
    /// Monotonically increases each time a new sample is installed into `currentSample`.
    private(set) var sampleGeneration: UInt64 = 0
    private(set) var lastPacing: FrameSurroundMotion.Pacing = .instant
    private(set) var photoRect: CGRect?
    private var photoRectFrame: URL?

    /// Custom extraction hook for tests; production uses `FrameSurroundSample.extract`.
    var extractor: @Sendable (CGImage, OutputSpace) -> FrameSurroundSample? = { image, space in
        FrameSurroundSample.extract(from: image, targetSpace: space)
    }

    private var lastSubmittedID: ObjectIdentifier?
    private var lastSubmittedSpace: OutputSpace?
    private var lastSubmittedFrame: URL?
    private var pending: PendingJob?
    private var worker: Task<Void, Never>?
    private var workerToken: UInt64 = 0
    private var epoch: UInt64 = 0

    private var listenerToken: UUID?
    private var listener: (@MainActor (ChangeReason) -> Void)?

    /// Registers the active `FrameSurroundHostView` callback. Returns a token used to detach only
    /// if a newer view has not already taken over.
    @discardableResult
    func attach(_ onChange: @escaping @MainActor (ChangeReason) -> Void) -> UUID {
        let token = UUID()
        listenerToken = token
        listener = onChange
        return token
    }

    /// Detaches a view that is being dismantled. If it was the active host, clears buffered samples
    /// so closing the frame view releases its memory cleanly without flashing during the fade-out,
    /// while keeping the last `photoRect` intact in case `FramePicture` remains mounted (e.g. while
    /// toggling Gray Surround or Increase Contrast).
    func detach(_ token: UUID, clearSamples: Bool = true) {
        guard listenerToken == token else { return }
        listenerToken = nil
        listener = nil
        if clearSamples { reset(notify: false, clearGeometry: false) }
    }

    /// Submits a frame image for ambient surround extraction.
    ///
    /// - `seedSynchronously`: when `true` and no sample is currently shown, extracts synchronously
    ///   (taking <0.5 ms on a tiny 48×32 target) so the hero transition begins with matched colours
    ///   on its first frame rather than flashing neutral gray.
    /// - Rapid repeated submissions coalesce in a single slot so live slider drags and held arrow
    ///   keys never build a backlog.
    func submit(
        image: CGImage,
        for frameURL: URL,
        space: OutputSpace,
        pacing: FrameSurroundMotion.Pacing,
        seedSynchronously: Bool = false
    ) {
        let imageID = ObjectIdentifier(image)
        if lastSubmittedID == imageID, lastSubmittedSpace == space, lastSubmittedFrame == frameURL,
           currentSample != nil || pending != nil || worker != nil {
            return
        }
        lastSubmittedID = imageID
        lastSubmittedSpace = space
        lastSubmittedFrame = frameURL

        if seedSynchronously, currentSample == nil {
            epoch &+= 1
            workerToken &+= 1
            pending = nil
            worker?.cancel()
            worker = nil
            if let sample = extractor(image, space) {
                install(sample, for: frameURL, pacing: .instant)
            }
            return
        }

        pending = PendingJob(image: image, imageID: imageID, frameURL: frameURL, space: space, pacing: pacing, epoch: epoch)
        if worker == nil {
            startWorker()
        }
    }

    /// Updates the open photograph's rectangle in top-left workspace points, directly from
    /// `FrameGeometry.picture`.
    ///
    /// When `frameURL` differs from the currently installed sample's frame (e.g. stepping between
    /// landscape and portrait frames before the new sample finishes extracting), `photoRect` is
    /// recorded for the incoming sample while `currentPhotoRect` remains anchored to the outgoing
    /// frame so the crossfade preserves each frame's own aspect ratio.
    func updateGeometry(photoRect: CGRect, for frameURL: URL? = nil) {
        guard photoRect != self.photoRect || frameURL != self.photoRectFrame else { return }
        if let frameURL, frameURL != lastSubmittedFrame {
            // Switching frames invalidates the previous frame's raw ObjectIdentifier dedup key
            // so returning to an earlier frame never collides with a recycled CGImage address.
            lastSubmittedID = nil
        }
        self.photoRect = photoRect
        self.photoRectFrame = frameURL
        if currentSample != nil, frameURL == nil || frameURL == self.frameURL {
            currentPhotoRect = photoRect
            listener?(.geometry)
        }
    }

    /// True when a zoomed photograph completely covers the visible workspace, leaving no surround
    /// pixels exposed.
    func isSurroundOccluded(workspaceSize: CGSize) -> Bool {
        guard let photoRect, workspaceSize.width > 0, workspaceSize.height > 0 else { return false }
        let margin: CGFloat = 4
        return photoRect.minX <= -margin
            && photoRect.minY <= -margin
            && photoRect.maxX >= workspaceSize.width + margin
            && photoRect.maxY >= workspaceSize.height + margin
    }

    /// Clamps a photograph's rectangle to `visibleWorkspace` expanded by `margin` so the edge
    /// shadow never allocates a giant offscreen backing store at high zoom. Returns `nil` when
    /// all four edges lie past the expanded bounds (shadow is completely off-screen) or the rect
    /// is too small to cast a clean rounded shadow.
    nonisolated static func clampedShadowRect(
        for photoRect: CGRect,
        visibleWorkspace: CGRect,
        margin: CGFloat = 72
    ) -> CGRect? {
        guard photoRect.width > 4, photoRect.height > 4,
              visibleWorkspace.width > 0, visibleWorkspace.height > 0 else { return nil }
        let limit = visibleWorkspace.insetBy(dx: -margin, dy: -margin)
        if photoRect.minX <= limit.minX
            && photoRect.minY <= limit.minY
            && photoRect.maxX >= limit.maxX
            && photoRect.maxY >= limit.maxY {
            return nil
        }
        let clamped = photoRect.intersection(limit)
        guard !clamped.isNull, clamped.width > 4, clamped.height > 4 else { return nil }
        return clamped
    }

    /// Clears sampled state and cancels any pending background extraction (e.g. when switching rolls).
    func reset(notify: Bool = true, clearGeometry: Bool = true) {
        epoch &+= 1
        workerToken &+= 1
        pending = nil
        worker?.cancel()
        worker = nil
        frameURL = nil
        currentSample = nil
        previousSample = nil
        currentPhotoRect = nil
        previousPhotoRect = nil
        if clearGeometry {
            photoRect = nil
            photoRectFrame = nil
        }
        lastSubmittedID = nil
        lastSubmittedSpace = nil
        lastSubmittedFrame = nil
        lastPacing = .instant
        if notify { listener?(.reset) }
    }

    /// Awaits any in-flight extraction, for deterministic unit testing.
    func waitUntilIdle() async {
        while let task = worker {
            await task.value
        }
    }

    private func startWorker() {
        let extract = extractor
        workerToken &+= 1
        let token = workerToken
        worker = Task { @MainActor [weak self] in
            while let self, self.workerToken == token, let job = self.pending {
                self.pending = nil
                let sample = await Task.detached(priority: .userInitiated) {
                    extract(job.image, job.space)
                }.value
                guard !Task.isCancelled, self.workerToken == token, self.epoch == job.epoch else { break }
                // If rapid scrubbing already queued a newer frame, skip installing this stale one.
                if let newer = self.pending, newer.frameURL != job.frameURL { continue }
                if let sample {
                    self.install(sample, for: job.frameURL, pacing: job.pacing)
                }
            }
            if let self, self.workerToken == token {
                self.worker = nil
            }
        }
    }

    private func install(_ sample: FrameSurroundSample, for url: URL, pacing: FrameSurroundMotion.Pacing) {
        if let existing = currentSample, pacing != .instant {
            previousSample = existing
            previousPhotoRect = currentPhotoRect ?? photoRect
            lastPacing = pacing
        } else {
            previousSample = nil
            previousPhotoRect = nil
            lastPacing = .instant
        }
        frameURL = url
        currentSample = sample
        currentPhotoRect = photoRect
        sampleGeneration &+= 1
        listener?(.sample)
    }
}
