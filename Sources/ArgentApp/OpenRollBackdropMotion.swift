import CoreGraphics
import Foundation

/// The moving state of the Open roll page's backdrop, the Latent image: unexposed emulsion with
/// light drifting over it. The pointer is the enlarger's light: where it rests the grain comes up,
/// and the trail it leaves fades behind it. A drop over the window gathers bands toward the
/// page's centre; reading a roll sends a front out from it.
///
/// It keeps no clock of its own: whoever draws the backdrop hands each step its time, so the
/// state can be advanced and read the same way by the display link and by tests. Every value eases
/// toward its target exponentially, so the result does not depend on the rate it is stepped at.
struct OpenRollBackdropMotion: Equatable, Sendable {
    /// What the backdrop answers on each step.
    struct Input: Equatable, Sendable {
        /// The pointer in the backdrop's points from its top left; nil while it is away.
        var pointer: CGPoint?
        /// What the page's centre says: a drop gathers the bands, a read sends a front out.
        var hero: RollModel.OpenRollHero
        /// The still field: nothing moves and nothing follows the pointer.
        var reduceMotion: Bool
    }

    /// A place the pointer passed, and how long ago in seconds.
    struct TrailSample: Equatable, Sendable {
        var position: CGPoint
        var age: Double
    }

    /// The longest step taken, in seconds: a pause or a hitch in the display link is a slow frame,
    /// never a jump.
    static let maximumStep = 0.1
    /// The presence's time constant, in seconds: the pool comes up and fades in about a fifth of a second.
    static let presenceTau = 0.22
    /// The dwell's time constant while the pointer rests, in seconds: grain comes up slowly under it.
    static let dwellRiseTau = 1.3
    /// The dwell's time constant once the pointer moves, in seconds: the pool lets go quickly.
    static let dwellFallTau = 0.25
    /// The drop's time constant, in seconds.
    static let dropTau = 0.12
    /// The read's time constant, in seconds.
    static let readTau = 0.2
    /// How long the intro takes, in seconds, from the first step.
    static let introDuration = 1.5
    /// The pointer counts as resting under this speed, in points a second.
    static let stillSpeed = 14.0
    /// The travel, in points, before the trail takes another sample.
    static let trailSpacing = 9.0
    /// The most samples the trail keeps; the renderer passes this many to the shader.
    static let trailCapacity = 20
    /// The age, in seconds, past which a sample is dropped: by then it no longer shows.
    static let trailLifetime = 6.0
    /// The field's clock under Reduce Motion, as in the approved mock.
    static let stillTime = 100.0
    /// How far, as a fraction, a value may sit from its target and still count as settled.
    static let settledTolerance = 0.01

    /// The draw rate while something moves under or near the pointer, frames a second.
    static let livelyRate = 120
    /// The draw rate while only the field's own slow drift moves.
    static let restingRate = 30
    /// The draw rate while the app is in the background or the Mac saves power.
    static let backgroundRate = 15

    /// The field's clock in seconds.
    private(set) var time: Double = 0
    /// Where the pointer was last seen: when it leaves, its pool fades where it was.
    private(set) var pointer: CGPoint = .zero
    /// How much the pointer's pool shows, from 0 to 1.
    private(set) var presence: Double = 0
    /// How long the pointer has rested, eased from 0 to 1.
    private(set) var dwell: Double = 0
    /// How far the bands have gathered for a drop, from 0 to 1.
    private(set) var drop: Double = 0
    /// How far the front of a read has come up, from 0 to 1.
    private(set) var read: Double = 0
    /// Where the pointer has been, newest first, at most `trailCapacity` samples.
    private(set) var trail: [TrailSample] = []

    /// The intro's progress, linear from 0 to 1.
    private var introProgress: Double = 0
    /// Where the trail took its last sample, kept after the sample expires so that a pointer resting
    /// there does not start the trail again.
    private var lastSamplePosition: CGPoint?
    /// Whether the pointer was over the field on the last step; the next sample after it was not is a jump.
    private var isPointerPresent = false
    /// Whether the pointer rested on the last step, the target the dwell eases toward.
    private var isStill = false
    /// Whether the pointer moved on the last step.
    private var didMove = false
    /// Whether the page's centre held a drop or a read on the last step.
    private var isDropTargeted = false
    private var isReading = false
    /// Whether the last step was under Reduce Motion.
    private var isReduced = false

    init() {}

    /// How far the intro has come, eased in and out, from 0 to 1.
    var intro: Double {
        let q = introProgress
        return q * q * (3 - 2 * q)
    }

    /// Whether something needs the display's full rate: the intro, a pointer that moves or a pool
    /// that has not settled, a trail still fading, or bands and a front, which move for as long as a
    /// drop or a read holds.
    var isLively: Bool {
        guard !isReduced else { return false }
        let tolerance = Self.settledTolerance
        return introProgress < 1
            || didMove
            || abs((isPointerPresent ? 1 : 0) - presence) > tolerance
            || abs((isStill ? 1 : 0) - dwell) > tolerance
            || !trail.isEmpty
            || isDropTargeted || drop > tolerance
            || isReading || read > tolerance
    }

    /// Advances the state by `dt` seconds, clamped to `0...maximumStep`, toward what `input` says.
    mutating func step(dt: Double, input: Input) {
        let dt = dt.isNaN ? 0 : min(max(dt, 0), Self.maximumStep)
        isDropTargeted = input.hero == .dropTargeted
        isReading = input.hero == .reading
        isReduced = input.reduceMotion
        if input.reduceMotion {
            holdStill(pointer: input.pointer)
            return
        }

        time += dt
        introProgress = min(1, introProgress + dt / Self.introDuration)

        let wasPresent = isPointerPresent
        isPointerPresent = input.pointer != nil
        var moved = 0.0
        if let position = input.pointer {
            if wasPresent { moved = Self.distance(position, pointer) }
            pointer = position
        }
        didMove = moved > 0
        isStill = isPointerPresent && moved / max(dt, 0.001) < Self.stillSpeed

        presence = Self.ease(presence, toward: isPointerPresent ? 1 : 0, dt: dt, tau: Self.presenceTau)
        dwell = Self.ease(dwell, toward: isStill ? 1 : 0, dt: dt, tau: isStill ? Self.dwellRiseTau : Self.dwellFallTau)
        drop = Self.ease(drop, toward: isDropTargeted ? 1 : 0, dt: dt, tau: Self.dropTau)
        read = Self.ease(read, toward: isReading ? 1 : 0, dt: dt, tau: Self.readTau)

        for index in trail.indices { trail[index].age += dt }
        trail.removeAll { $0.age > Self.trailLifetime }
        if let position = input.pointer, lastSamplePosition.map({ Self.distance(position, $0) > Self.trailSpacing }) ?? true {
            lastSamplePosition = position
            trail.insert(TrailSample(position: position, age: 0), at: 0)
            if trail.count > Self.trailCapacity { trail.removeLast(trail.count - Self.trailCapacity) }
        }
    }

    /// The still field of Reduce Motion: a fixed clock, the intro done, no pool, no bands, no trail.
    /// The pointer is still followed, so that motion turned on again measures from where it is.
    private mutating func holdStill(pointer position: CGPoint?) {
        time = Self.stillTime
        introProgress = 1
        presence = 0
        dwell = 0
        drop = 0
        read = 0
        trail = []
        didMove = false
        isStill = false
        isPointerPresent = position != nil
        if let position { pointer = position }
    }

    /// `value` eased toward `target` over `dt` with time constant `tau`, the same whatever the step.
    private static func ease(_ value: Double, toward target: Double, dt: Double, tau: Double) -> Double {
        value + (target - value) * (1 - exp(-dt / tau))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y))
    }

    /// The rate the backdrop is drawn at: none while it is hidden or still under Reduce Motion,
    /// where it is drawn only when asked; a low rate in the background or in Low Power Mode; the
    /// display's full rate while it is lively; and otherwise enough for the field's slow drift.
    static func framesPerSecond(isShown: Bool, isActive: Bool, isLowPower: Bool, reduceMotion: Bool, isLively: Bool) -> Int {
        guard isShown, !reduceMotion else { return 0 }
        if !isActive || isLowPower { return backgroundRate }
        return isLively ? livelyRate : restingRate
    }
}
