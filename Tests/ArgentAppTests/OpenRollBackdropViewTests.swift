import CoreGraphics
import QuartzCore
import Testing
@testable import ArgentApp

/// The Open roll backdrop's view, without a window: the Metal layer covers the view in whole cells
/// from its top left with one texel a cell, and the display link's range follows each rate the
/// motion asks for.
@Suite struct OpenRollBackdropViewTests {
    @Test func theLayerIsWholeCellsFromTheTopLeft() {
        let even = OpenRollBackdropView.layerGeometry(for: CGSize(width: 1200, height: 800))
        #expect(even.frame == CGRect(x: 0, y: 0, width: 1200, height: 800))
        #expect(even.drawableSize == CGSize(width: 600, height: 400))

        let odd = OpenRollBackdropView.layerGeometry(for: CGSize(width: 801, height: 560.5))
        #expect(odd.frame == CGRect(x: 0, y: 0, width: 802, height: 562))
        #expect(odd.drawableSize == CGSize(width: 401, height: 281))
    }

    @Test func anEmptyViewStillHasOneCell() {
        let empty = OpenRollBackdropView.layerGeometry(for: .zero)
        #expect(empty.frame == CGRect(x: 0, y: 0, width: 2, height: 2))
        #expect(empty.drawableSize == CGSize(width: 1, height: 1))
    }

    @Test func theLinkPausesAtNoRateAndOtherwisePrefersIt() {
        #expect(OpenRollBackdropView.frameRateRange(framesPerSecond: 0) == nil)
        for rate in [OpenRollBackdropMotion.backgroundRate, OpenRollBackdropMotion.restingRate, OpenRollBackdropMotion.livelyRate] {
            let range = OpenRollBackdropView.frameRateRange(framesPerSecond: rate)
            #expect(range?.preferred == Float(rate))
            #expect(range?.maximum == Float(rate))
            #expect(range?.minimum == Float(rate) / 2)
        }
    }

    @Test func aDropIsPacedAsInTheActiveApp() {
        #expect(OpenRollBackdropView.pacesAsActive(appIsActive: true, hero: .ready))
        #expect(!OpenRollBackdropView.pacesAsActive(appIsActive: false, hero: .ready))
        #expect(!OpenRollBackdropView.pacesAsActive(appIsActive: false, hero: .reading))
        // A drag from Finder leaves Finder the active app.
        #expect(OpenRollBackdropView.pacesAsActive(appIsActive: false, hero: .dropTargeted))
    }

    @Test func aFieldInAScreensCornerIsNotOnIt() {
        let screen = CGRect(x: 0, y: 0, width: 1650, height: 1072)
        // A window parked in the corner as AeroSpace hides another workspace's: a point of it on the screen.
        #expect(!OpenRollBackdropView.isOnScreen(CGRect(x: 1649 + 66, y: -808, width: 1214, height: 802), screens: [screen]))
        #expect(!OpenRollBackdropView.isOnScreen(CGRect(x: 1649, y: -808, width: 1214, height: 802), screens: [screen]))
        #expect(OpenRollBackdropView.isOnScreen(CGRect(x: 893, y: 171, width: 1214, height: 802), screens: [screen]))
        #expect(OpenRollBackdropView.isOnScreen(CGRect(x: 1700, y: 100, width: 400, height: 300),
                                                screens: [screen, CGRect(x: 1650, y: 0, width: 1920, height: 1080)]))
    }

    #if DEBUG
    @Test func aHeldPointerMovesAlongItsLineAndRestsAtItsEnd() {
        let hold = OpenRollBackdropPointerHold(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 200, y: 300), start: 10, duration: 4)
        #expect(hold.position(at: 9) == CGPoint(x: 0, y: 100))
        #expect(hold.position(at: 11) == CGPoint(x: 50, y: 150))
        #expect(hold.position(at: 20) == CGPoint(x: 200, y: 300))
        #expect(OpenRollBackdropPointerHold(at: CGPoint(x: 5, y: 6)).position(at: 0) == CGPoint(x: 5, y: 6))
        #expect(OpenRollBackdropPointerHold.away.position(at: 0) == nil)
    }

    @Test func theCountersKeepTheLastSecond() {
        let counters = OpenRollBackdropCounters()
        #expect(counters.lastSecond().frames == 0)
        #expect(counters.lastSecond().mean == nil)
        counters.noteFrame()
        counters.noteFrame()
        counters.noteGPU(milliseconds: 0.2)
        counters.noteGPU(milliseconds: 0.6)
        let counted = counters.lastSecond()
        #expect(counted.frames == 2)
        #expect(counted.total == 2)
        #expect(abs((counted.mean ?? 0) - 0.4) < 1e-9)
        #expect(counted.worst == 0.6)
    }
    #endif
}
