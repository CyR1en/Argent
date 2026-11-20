import CoreGraphics
import Foundation
import Testing
@testable import ArgentApp

/// The Open roll backdrop's moving state: values that ease the same at any frame rate, the pointer's
/// arrival, its trail and its dwell, the step's clamp, the intro, the still field of Reduce Motion,
/// when the field needs the display's full rate, and the rate it is drawn at.
@Suite struct OpenRollBackdropMotionTests {
    private typealias Motion = OpenRollBackdropMotion

    private static func input(_ pointer: CGPoint?, _ hero: RollModel.OpenRollHero = .ready,
                              reduceMotion: Bool = false) -> Motion.Input {
        Motion.Input(pointer: pointer, hero: hero, reduceMotion: reduceMotion)
    }

    /// Steps `motion` through `seconds` at `rate` frames a second, in equal steps that add up to it.
    private static func run(_ motion: inout Motion, for seconds: Double, rate: Double = 120, _ input: Motion.Input) {
        let count = max(1, Int((seconds * rate).rounded()))
        for _ in 0..<count { motion.step(dt: seconds / Double(count), input: input) }
    }

    private static func ran(for seconds: Double, rate: Double, _ input: Motion.Input) -> Motion {
        var motion = Motion()
        run(&motion, for: seconds, rate: rate, input)
        return motion
    }

    /// One time constant takes each value about 63% of the way, and stepping at 30 frames a second
    /// comes to the same place as stepping at 120.
    @Test func valuesEaseByTheirTimeConstantAtAnyRate() {
        let oneTau = 1 - exp(-1.0)
        let here = Self.input(CGPoint(x: 200, y: 150))
        for rate in [120.0, 30.0] {
            #expect(abs(Self.ran(for: Motion.presenceTau, rate: rate, here).presence - oneTau) < 0.005)
            #expect(abs(Self.ran(for: Motion.dropTau, rate: rate, Self.input(nil, .dropTargeted)).drop - oneTau) < 0.005)
            #expect(abs(Self.ran(for: Motion.readTau, rate: rate, Self.input(nil, .reading)).read - oneTau) < 0.005)
        }
        let fast = Self.ran(for: 0.5, rate: 120, here), slow = Self.ran(for: 0.5, rate: 30, here)
        #expect(abs(fast.presence - slow.presence) < 0.01 * fast.presence)
        #expect(abs(fast.dwell - slow.dwell) < 0.01 * fast.dwell)
        let dropFast = Self.ran(for: 0.3, rate: 120, Self.input(nil, .dropTargeted))
        let dropSlow = Self.ran(for: 0.3, rate: 30, Self.input(nil, .dropTargeted))
        #expect(abs(dropFast.drop - dropSlow.drop) < 0.01 * dropFast.drop)
        let readFast = Self.ran(for: 0.3, rate: 120, Self.input(nil, .reading))
        let readSlow = Self.ran(for: 0.3, rate: 30, Self.input(nil, .reading))
        #expect(abs(readFast.read - readSlow.read) < 0.01 * readFast.read)
    }

    /// A pointer that comes back far from where it left has not moved: it rests at once, takes one
    /// sample, and its pool fades from where it was seen last while it is away.
    @Test func aPointerThatArrivesJumpsWithoutMoving() {
        var motion = Motion()
        motion.step(dt: 1.0 / 120, input: Self.input(CGPoint(x: 600, y: 400)))
        #expect(motion.dwell > 0)
        #expect(motion.trail.count == 1)

        Self.run(&motion, for: 0.5, Self.input(CGPoint(x: 10, y: 10)))
        Self.run(&motion, for: 0.5, Self.input(nil))
        #expect(motion.pointer == CGPoint(x: 10, y: 10))
        let away = motion.dwell, samples = motion.trail.count
        motion.step(dt: 1.0 / 120, input: Self.input(CGPoint(x: 700, y: 500)))
        #expect(motion.dwell > away)
        #expect(motion.trail.count == samples + 1)
        #expect(motion.trail.first?.position == CGPoint(x: 700, y: 500))
        #expect(motion.pointer == CGPoint(x: 700, y: 500))
    }

    /// The trail takes a sample only after more than 9 points of travel, keeps the newest 20 newest
    /// first, ages them by each step and lets them go after 6 seconds.
    @Test func theTrailIsSpacedCappedAgedAndExpires() {
        var motion = Motion()
        let dt = 1.0 / 120
        motion.step(dt: dt, input: Self.input(CGPoint(x: 100, y: 100)))
        for x in stride(from: 101.0, through: 109, by: 1) {
            motion.step(dt: dt, input: Self.input(CGPoint(x: x, y: 100)))
        }
        #expect(motion.trail.count == 1)
        #expect(abs(motion.trail[0].age - 9 * dt) < 1e-9)
        motion.step(dt: dt, input: Self.input(CGPoint(x: 109.5, y: 100)))
        #expect(motion.trail.count == 2)
        #expect(motion.trail[0].position.x == 109.5)
        #expect(motion.trail[0].age == 0)

        for index in 1...30 {
            motion.step(dt: dt, input: Self.input(CGPoint(x: 109.5 + 10 * Double(index), y: 100)))
        }
        #expect(motion.trail.count == Motion.trailCapacity)
        #expect(motion.trail.first?.position.x == 409.5)
        #expect(zip(motion.trail, motion.trail.dropFirst()).allSatisfy { $0.position.x > $1.position.x && $0.age < $1.age })

        Self.run(&motion, for: 5.8, Self.input(nil))
        #expect(!motion.trail.isEmpty)
        Self.run(&motion, for: 0.4, Self.input(nil))
        #expect(motion.trail.isEmpty)
    }

    /// Dwell comes up only while the pointer creeps under 14 points a second, and lets go within a
    /// quarter of a second once it moves.
    @Test func dwellRisesWhileSlowAndFallsWhenMoving() {
        var motion = Motion()
        var x = 100.0
        func move(by step: Double, for seconds: Double) {
            for _ in 0..<Int(seconds * 120) {
                x += step
                motion.step(dt: 1.0 / 120, input: Self.input(CGPoint(x: x, y: 100)))
            }
        }
        move(by: 2, for: 1)
        #expect(motion.dwell < 0.01)
        move(by: 0.05, for: 1)
        #expect(abs(motion.dwell - (1 - exp(-1 / Motion.dwellRiseTau))) < 0.01)
        let rested = motion.dwell
        move(by: 2, for: Motion.dwellFallTau)
        #expect(abs(motion.dwell - rested * exp(-1.0)) < 0.01)
    }

    /// A step below 0 is no step, and one above a tenth of a second is a tenth.
    @Test func theStepIsClampedAtBothEnds() {
        var motion = Motion()
        let here = Self.input(CGPoint(x: 50, y: 50))
        motion.step(dt: -1, input: here)
        #expect(motion.time == 0)
        #expect(motion.presence == 0)
        #expect(motion.intro == 0)
        motion.step(dt: 5, input: here)
        #expect(motion.time == Motion.maximumStep)
        #expect(abs(motion.presence - (1 - exp(-Motion.maximumStep / Motion.presenceTau))) < 1e-12)
        motion.step(dt: .nan, input: here)
        #expect(motion.time == Motion.maximumStep)
    }

    /// The intro is 0 before the first step and 1 after a second and a half, eased between.
    @Test func theIntroRunsOverASecondAndAHalfEased() {
        var motion = Motion()
        #expect(motion.intro == 0)
        Self.run(&motion, for: 0.375, Self.input(nil))
        #expect(abs(motion.intro - 0.15625) < 1e-9)
        Self.run(&motion, for: 0.375, Self.input(nil))
        #expect(abs(motion.intro - 0.5) < 1e-9)
        Self.run(&motion, for: 0.75, Self.input(nil))
        #expect(motion.intro == 1)
        Self.run(&motion, for: 1, Self.input(nil))
        #expect(motion.intro == 1)
    }

    /// Reduce Motion holds a still field with nothing following the pointer, and turned off again
    /// the field moves on from there without a second intro.
    @Test func reduceMotionHoldsAStillFieldAndResumes() {
        var motion = Motion()
        Self.run(&motion, for: 0.5, Self.input(CGPoint(x: 80, y: 80), .dropTargeted))
        #expect(motion.isLively)
        motion.step(dt: 1.0 / 60, input: Self.input(CGPoint(x: 300, y: 80), .reading, reduceMotion: true))
        #expect(motion.time == Motion.stillTime)
        #expect(motion.intro == 1)
        #expect(motion.presence == 0 && motion.dwell == 0 && motion.drop == 0 && motion.read == 0)
        #expect(motion.trail.isEmpty)
        #expect(!motion.isLively)
        Self.run(&motion, for: 2, Self.input(CGPoint(x: 400, y: 80), .reading, reduceMotion: true))
        #expect(motion.time == Motion.stillTime)
        #expect(!motion.isLively)

        motion.step(dt: 1.0 / 60, input: Self.input(nil))
        #expect(abs(motion.time - (Motion.stillTime + 1.0 / 60)) < 1e-9)
        #expect(motion.intro == 1)
        #expect(!motion.isLively)
    }

    /// The field is lively while the pointer moves, settles within about 7 seconds with the pointer
    /// resting over it and once the trail has run out with it away, and stays lively for as long
    /// as a drop or a read holds.
    @Test func livelinessFollowsWhatMoves() {
        var motion = Motion()
        Self.run(&motion, for: 2, Self.input(nil))
        #expect(!motion.isLively)
        for index in 1...240 {
            motion.step(dt: 1.0 / 120, input: Self.input(CGPoint(x: 100 + Double(index), y: 100)))
            #expect(motion.isLively)
        }
        Self.run(&motion, for: 7, Self.input(CGPoint(x: 340, y: 100)))
        // The trail has run out under the resting pointer, and does not start again there.
        #expect(motion.trail.isEmpty)
        #expect(!motion.isLively)

        Self.run(&motion, for: 0.2, Self.input(CGPoint(x: 600, y: 300)))
        Self.run(&motion, for: 5, Self.input(nil))
        #expect(motion.isLively)
        Self.run(&motion, for: 1.5, Self.input(nil))
        #expect(motion.trail.isEmpty)
        #expect(!motion.isLively)

        for hero in [RollModel.OpenRollHero.dropTargeted, .reading] {
            Self.run(&motion, for: 30, Self.input(nil, hero))
            #expect(motion.isLively)
            Self.run(&motion, for: 0.5, Self.input(nil))
            #expect(motion.isLively)
            Self.run(&motion, for: 2, Self.input(nil))
            #expect(!motion.isLively)
        }
    }

    @Test func framesPerSecondTable() {
        func rate(shown: Bool = true, active: Bool = true, lowPower: Bool = false, reduced: Bool = false, lively: Bool = false) -> Int {
            Motion.framesPerSecond(isShown: shown, isActive: active, isLowPower: lowPower, reduceMotion: reduced, isLively: lively)
        }
        #expect(rate(shown: false, lively: true) == 0)
        #expect(rate(reduced: true, lively: true) == 0)
        #expect(rate(active: false, lively: true) == Motion.backgroundRate)
        #expect(rate(lowPower: true, lively: true) == Motion.backgroundRate)
        #expect(rate(lively: true) == Motion.livelyRate)
        #expect(rate() == Motion.restingRate)
        #expect(Motion.backgroundRate == 15 && Motion.restingRate == 30 && Motion.livelyRate == 120)
    }
}
