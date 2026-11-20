import ArgentCore
import CoreGraphics
import Foundation
import os
import Testing
@testable import ArgentApp

/// Pure-Swift tests for `FrameSurroundSample`, `FrameSurroundMotion`, and `FrameSurroundController`:
/// orientation-preserving downsampling, cubic ease-out timing, Reduce Motion snapping, single-slot
/// coalescing on rapid scrubs, deduplication, occlusion detection, and token-scoped detach.
@MainActor @Suite struct FrameSurroundControllerTests {
    private static func solidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: OutputSpace.sRGB.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ))
    }

    @Test func sampleExtractionPreservesAspectRatioAndAvoidsUpscaling() throws {
        let landscape = try Self.solidImage(width: 300, height: 200, r: 200, g: 120, b: 60)
        let lSample = try #require(FrameSurroundSample.extract(from: landscape, targetSpace: .displayP3))
        #expect(lSample.width == 48 && lSample.height == 32)
        #expect(lSample.space == .displayP3)
        #expect(lSample.bytes.count == 48 * 32 * 4)

        let portrait = try Self.solidImage(width: 200, height: 300, r: 40, g: 140, b: 220)
        let pSample = try #require(FrameSurroundSample.extract(from: portrait, targetSpace: .sRGB))
        #expect(pSample.width == 32 && pSample.height == 48)

        let tiny = try Self.solidImage(width: 12, height: 8, r: 100, g: 100, b: 100)
        let tSample = try #require(FrameSurroundSample.extract(from: tiny, targetSpace: .sRGB))
        #expect(tSample.width == 12 && tSample.height == 8)
    }

    @Test func motionEasesSmoothlyAndStopsAtSettlement() {
        var motion = FrameSurroundMotion()
        #expect(!motion.isAnimating && motion.blend == 1)

        motion.begin(.step, reduceMotion: false)
        #expect(motion.isAnimating && motion.blend == 0)

        // Halfway through 0.28 s -> cubic ease-out is past 0.5 (0.875).
        motion.step(dt: 0.07, reduceMotion: false)
        motion.step(dt: 0.07, reduceMotion: false)
        #expect(motion.isAnimating)
        #expect(motion.blend > 0.8 && motion.blend < 0.95)

        // Large hitch is clamped to maximumStep (0.1 s), so a single huge dt cannot jump backward or overshoot.
        motion.step(dt: 5.0, reduceMotion: false)
        #expect(motion.blend > 0.95)
        motion.step(dt: 0.1, reduceMotion: false)
        #expect(!motion.isAnimating && motion.blend == 1)

        // Reduce Motion snaps immediately on begin and on mid-flight step.
        motion.begin(.step, reduceMotion: true)
        #expect(!motion.isAnimating && motion.blend == 1)
        motion.begin(.live, reduceMotion: false)
        #expect(motion.isAnimating)
        motion.step(dt: 0.01, reduceMotion: true)
        #expect(!motion.isAnimating && motion.blend == 1)
    }

    @Test func synchronousSeedInstallsImmediatelyAndDeduplicatesRepeatedSubmissions() throws {
        let controller = FrameSurroundController()
        let extractions = OSAllocatedUnfairLock(initialState: 0)
        controller.extractor = { image, space in
            extractions.withLock { $0 += 1 }
            return FrameSurroundSample.extract(from: image, targetSpace: space)
        }
        var reasons: [FrameSurroundController.ChangeReason] = []
        controller.attach { reasons.append($0) }

        let url = URL(fileURLWithPath: "/tmp/frame-1.ARW")
        let image = try Self.solidImage(width: 60, height: 40, r: 180, g: 90, b: 40)
        controller.submit(image: image, for: url, space: .sRGB, pacing: .step, seedSynchronously: true)

        #expect(controller.currentSample != nil)
        #expect(controller.previousSample == nil)
        #expect(controller.lastPacing == .instant)
        #expect(controller.sampleGeneration == 1)
        #expect(reasons == [.sample])

        // Re-submitting the exact same CGImage + space + frame URL does nothing.
        controller.submit(image: image, for: url, space: .sRGB, pacing: .step, seedSynchronously: false)
        #expect(extractions.withLock { $0 } == 1)
        #expect(controller.sampleGeneration == 1)
    }

    @Test func rapidScrubbingCoalescesAndPromotesPreviousSampleForCrossfade() async throws {
        let controller = FrameSurroundController()
        let firstURL = URL(fileURLWithPath: "/tmp/frame-1.ARW")
        let secondURL = URL(fileURLWithPath: "/tmp/frame-2.ARW")
        let thirdURL = URL(fileURLWithPath: "/tmp/frame-3.ARW")
        let img1 = try Self.solidImage(width: 60, height: 40, r: 20, g: 80, b: 220)
        let img2 = try Self.solidImage(width: 60, height: 40, r: 40, g: 200, b: 80)
        let img3 = try Self.solidImage(width: 60, height: 40, r: 220, g: 120, b: 30)

        controller.submit(image: img1, for: firstURL, space: .sRGB, pacing: .instant, seedSynchronously: true)
        let firstSample = controller.currentSample

        // Queue two frames synchronously before the detached worker runs: only the latest frame needs to land.
        controller.submit(image: img2, for: secondURL, space: .sRGB, pacing: .step)
        controller.submit(image: img3, for: thirdURL, space: .sRGB, pacing: .live)
        await controller.waitUntilIdle()

        #expect(controller.frameURL == thirdURL)
        #expect(controller.previousSample == firstSample)
        #expect(controller.lastPacing == .live)
        #expect(controller.currentSample?.bytes.first ?? 0 > 180)
    }

    @Test func occlusionDetectionAndTokenScopedDetach() throws {
        let controller = FrameSurroundController()
        let url = URL(fileURLWithPath: "/tmp/a.ARW")
        controller.updateGeometry(photoRect: CGRect(x: 0, y: 100, width: 1000, height: 500), for: url)
        #expect(!controller.isSurroundOccluded(workspaceSize: CGSize(width: 1000, height: 780)))

        // Zoomed past every edge of the workspace -> surround is fully occluded.
        controller.updateGeometry(photoRect: CGRect(x: -50, y: -40, width: 1200, height: 900), for: url)
        #expect(controller.isSurroundOccluded(workspaceSize: CGSize(width: 1000, height: 780)))

        // A stale view's detach must never clear a newer host's listener or samples.
        let image = try Self.solidImage(width: 60, height: 40, r: 200, g: 150, b: 90)
        let oldToken = controller.attach { _ in }
        let newToken = controller.attach { _ in }
        controller.submit(image: image, for: url, space: .sRGB, pacing: .instant, seedSynchronously: true)
        controller.detach(oldToken, clearSamples: true)
        #expect(controller.currentSample != nil)

        // Detaching the active view clears samples but keeps photoRect for same-frame toggles
        // (e.g. Gray Surround off -> on -> off while FramePicture remains mounted).
        controller.detach(newToken, clearSamples: true)
        #expect(controller.currentSample == nil)
        #expect(controller.photoRect != nil)

        // A full reset (e.g. switching rolls) clears the stale zoomed photoRect too.
        controller.reset()
        #expect(controller.photoRect == nil)
        #expect(!controller.isSurroundOccluded(workspaceSize: CGSize(width: 1000, height: 780)))
    }

    @Test func aspectChangeStepPreservesPreviousPhotoRectForCrossfade() async throws {
        let controller = FrameSurroundController()
        let landscapeURL = URL(fileURLWithPath: "/tmp/landscape.ARW")
        let portraitURL = URL(fileURLWithPath: "/tmp/portrait.ARW")
        let landscapeRect = CGRect(x: 0, y: 100, width: 900, height: 600)
        let portraitRect = CGRect(x: 200, y: 0, width: 500, height: 750)
        let landscapeImage = try Self.solidImage(width: 60, height: 40, r: 30, g: 120, b: 230)
        let portraitImage = try Self.solidImage(width: 40, height: 60, r: 230, g: 110, b: 30)

        controller.updateGeometry(photoRect: landscapeRect, for: landscapeURL)
        controller.submit(image: landscapeImage, for: landscapeURL, space: .sRGB, pacing: .instant, seedSynchronously: true)
        #expect(controller.currentPhotoRect == landscapeRect)

        // Stepping to a portrait frame publishes its geometry on the main thread before its sample
        // finishes extracting off-thread: the outgoing sample's rect must stay landscape.
        controller.updateGeometry(photoRect: portraitRect, for: portraitURL)
        #expect(controller.currentPhotoRect == landscapeRect)

        controller.submit(image: portraitImage, for: portraitURL, space: .sRGB, pacing: .step)
        await controller.waitUntilIdle()

        #expect(controller.frameURL == portraitURL)
        #expect(controller.previousPhotoRect == landscapeRect)
        #expect(controller.currentPhotoRect == portraitRect)
    }

    @Test func cancelledWorkerDoesNotClobberNewerWorker() async throws {
        let controller = FrameSurroundController()
        let (enteredFirstStream, enteredFirst) = AsyncStream<Void>.makeStream()
        let releaseFirst = DispatchSemaphore(value: 0)
        let (enteredSecondStream, enteredSecond) = AsyncStream<Void>.makeStream()
        let releaseSecond = DispatchSemaphore(value: 0)
        let thirdRanWhileSecondActive = OSAllocatedUnfairLock(initialState: false)
        let secondActive = OSAllocatedUnfairLock(initialState: false)

        controller.extractor = { image, space in
            if image.width == 60 {
                enteredFirst.yield()
                releaseFirst.wait()
            } else if image.width == 64 {
                secondActive.withLock { $0 = true }
                enteredSecond.yield()
                releaseSecond.wait()
                secondActive.withLock { $0 = false }
            } else if image.width == 68 {
                if secondActive.withLock({ $0 }) {
                    thirdRanWhileSecondActive.withLock { $0 = true }
                }
            }
            return FrameSurroundSample.extract(from: image, targetSpace: space)
        }

        let url1 = URL(fileURLWithPath: "/tmp/worker-1.ARW")
        let url2 = URL(fileURLWithPath: "/tmp/worker-2.ARW")
        let url3 = URL(fileURLWithPath: "/tmp/worker-3.ARW")
        let img1 = try Self.solidImage(width: 60, height: 40, r: 20, g: 40, b: 220)
        let img2 = try Self.solidImage(width: 64, height: 40, r: 40, g: 200, b: 60)
        let img3 = try Self.solidImage(width: 68, height: 40, r: 220, g: 90, b: 20)

        var firstIterator = enteredFirstStream.makeAsyncIterator()
        var secondIterator = enteredSecondStream.makeAsyncIterator()

        controller.submit(image: img1, for: url1, space: .sRGB, pacing: .step)
        _ = await firstIterator.next()

        // Cancel worker 1 and immediately start worker 2 before worker 1 resumes on MainActor.
        controller.reset()
        controller.submit(image: img2, for: url2, space: .sRGB, pacing: .step)
        _ = await secondIterator.next()

        // Let cancelled worker 1 finish and resume on MainActor: it must NOT nil out worker 2.
        releaseFirst.signal()
        try await Task.sleep(for: .milliseconds(25))

        // Queue a third job while worker 2 is still blocked: it must coalesce behind worker 2
        // instead of launching a concurrent worker 3 that races with worker 2.
        controller.submit(image: img3, for: url3, space: .sRGB, pacing: .live)
        try await Task.sleep(for: .milliseconds(25))
        #expect(!thirdRanWhileSecondActive.withLock { $0 })

        releaseSecond.signal()
        await controller.waitUntilIdle()

        #expect(!thirdRanWhileSecondActive.withLock { $0 })
        #expect(controller.frameURL == url3)
        #expect(controller.currentSample?.bytes.first ?? 0 > 180)
    }

    @Test func clampedShadowRectBoundsHighZoomAndOmitsFullyOccludedFrames() {
        let workspace = CGRect(x: 0, y: 0, width: 1000, height: 780)
        // Normal fitted photo passes through untouched.
        let fitted = CGRect(x: 50, y: 40, width: 900, height: 600)
        #expect(FrameSurroundController.clampedShadowRect(for: fitted, visibleWorkspace: workspace) == fitted)

        // Zoomed 4x centered covers well past the margin on all sides -> shadow omitted.
        let occluded = CGRect(x: -6500, y: -4300, width: 14000, height: 9300)
        #expect(FrameSurroundController.clampedShadowRect(for: occluded, visibleWorkspace: workspace) == nil)

        // Zoomed 4x panned to the top-left corner keeps visible edges exact and clamps off-screen edges.
        let corner = CGRect(x: 0, y: 0, width: 14000, height: 9300)
        let clamped = FrameSurroundController.clampedShadowRect(for: corner, visibleWorkspace: workspace, margin: 72)
        #expect(clamped == CGRect(x: 0, y: 0, width: 1072, height: 852))
    }
}
