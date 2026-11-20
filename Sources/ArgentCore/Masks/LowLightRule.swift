import Foundation

/// X1's low-light rule, written before it was applied to any frame (`lowlight/evidence/X1/RULE.md`), on the click's own decode: Subject's design changes only inside it.
/// A frame is in it if `EV_scene ≤ 7.0` or `ISO ≥ 6400`, where `EV100 = log2(N² / t) − log2(ISO / 100)` from the raw's FNumber, ExposureTime and ISO, and
/// `EV_scene = EV100 + log2(max(p50, 1e-4) / 0.18)`, `p50` the median Rec. 2020 luminance of the click's untouched linear decode. A frame missing FNumber, ExposureTime or ISO
/// has no `EV_scene` and passes only by the ISO clause.
///
/// It reads only the raw's metadata and the untouched decode, never a label, an edited pixel or a mask. Which edge a click produced is decided once, at the click, and stored.
public enum LowLightRule {
    public static let evSceneMaximum = 7.0
    public static let isoMinimum = 6400.0
    /// What a seed's provenance records; a change of meaning is a new version.
    public static let version = "x1-ev7-iso6400-1"

    /// What the raw says of its exposure, each `nil` when the file does not.
    public struct Metadata: Sendable, Equatable {
        public var iso: Double?
        public var exposureTime: Double?
        public var fNumber: Double?
        public init(iso: Double? = nil, exposureTime: Double? = nil, fNumber: Double? = nil) { self.iso = iso; self.exposureTime = exposureTime; self.fNumber = fNumber }
    }

    public struct Decision: Sendable, Equatable {
        /// Whether the frame is low light.
        public var inRule: Bool
        /// `EV_scene`, `nil` for a frame with no brightness to read (missing metadata or median).
        public var evScene: Double?
        /// The raw's ISO, `nil` if it says none.
        public var iso: Double?
        public var exposureTime: Double?
        public var fNumber: Double?
        /// The decode's median luminance.
        public var p50: Float?
        /// Clause 1 held.
        public var isDim: Bool { evScene.map { $0 <= LowLightRule.evSceneMaximum } ?? false }
        /// Clause 2 held.
        public var isHighISO: Bool { iso.map { $0 >= LowLightRule.isoMinimum } ?? false }

        public init(inRule: Bool, evScene: Double?, iso: Double?, exposureTime: Double?, fNumber: Double?, p50: Float?) {
            self.inRule = inRule; self.evScene = evScene; self.iso = iso; self.exposureTime = exposureTime; self.fNumber = fNumber; self.p50 = p50
        }

        /// What a seed's provenance records of the decision.
        public var parameters: [String: String] {
            var out = ["rule.version": LowLightRule.version, "rule.in": String(inRule), "rule.clause": inRule ? (isDim ? (isHighISO ? "dim,iso" : "dim") : "iso") : "none"]
            if let evScene { out["rule.evScene"] = String(evScene) }
            if let iso { out["rule.iso"] = String(iso) }
            if let exposureTime { out["rule.exposureTime"] = String(exposureTime) }
            if let fNumber { out["rule.fNumber"] = String(fNumber) }
            if let p50 { out["rule.p50"] = String(p50) }
            return out
        }
    }

    /// The rule on one frame.
    public static func decide(_ metadata: Metadata, medianLuminance p50: Float?) -> Decision {
        var evScene: Double?
        let iso = metadata.iso
        if let iso, let t = metadata.exposureTime, let n = metadata.fNumber, iso > 0, t > 0, n > 0, let p50 {
            let ev100 = log2(n * n / t) - log2(iso / 100)
            evScene = ev100 + log2(max(Double(p50), 1e-4) / 0.18)
        }
        let dim = evScene.map { $0 <= evSceneMaximum } ?? false
        let highISO = iso.map { $0 >= isoMinimum } ?? false
        return Decision(inRule: dim || highISO, evScene: evScene, iso: iso, exposureTime: metadata.exposureTime, fNumber: metadata.fNumber, p50: p50)
    }

    /// The median of `values`, destroying their order, in 32-bit floats as `np.median` computes it on a float32 array: the middle value, or for an even count the mean of the
    /// two middle values. `nil` when it is not a finite number.
    public static func median(_ values: inout [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let n = values.count, upper = n / 2
        let middle: Float = values.withUnsafeMutableBufferPointer { selectValue($0, k: upper) }
        let result: Float
        if n % 2 == 1 {
            result = middle
        } else {
            // The largest of everything left of `upper` is the other middle value; selection left the left part below it.
            let other: Float = values.withUnsafeBufferPointer { b in
                var best = b[0]
                for i in 0..<upper where b[i] > best { best = b[i] }
                return best
            }
            result = (other + middle) / 2
        }
        return result.isFinite ? result : nil
    }

    /// The same median as `median(_:)`, of values too many to hold at once: a full-size decode's luminances are 131 MB, beside the
    /// 262 MB read back to make them, where this holds a strip of each. `each` hands every value to its argument, in chunks of any
    /// size, and is called twice, with the same values each time, in any order.
    ///
    /// It selects by counting, which no sort or copy of the values is needed for. A `Float`'s bits order as its value does once the
    /// sign is folded (`key`); the first pass counts the values by the upper half of that key and finds which of the 65,536 counts
    /// holds each middle value, and the second counts the lower half of the values in those, which places the middle values exactly.
    /// `nil` for no values, a NaN among them, or a median that is not finite.
    public static func median(counting each: ((UnsafeBufferPointer<Float>) -> Void) -> Void) -> Float? {
        var coarse = [UInt32](repeating: 0, count: 1 << 16)
        var total = 0, sawNaN = false
        coarse.withUnsafeMutableBufferPointer { coarse in
            each { values in
                total += values.count
                for value in values {
                    if value.isNaN { sawNaN = true }
                    coarse[Int(key(value) >> 16)] &+= 1
                }
            }
        }
        guard total > 0, !sawNaN else { return nil }
        // The middle value, or for an even count the two below and above the middle, each by its rank from the smallest, 0.
        let upper = total / 2
        let low = place(total % 2 == 1 ? upper : upper - 1, in: coarse), high = place(upper, in: coarse)
        let lowBucket = UInt32(low.index), highBucket = UInt32(high.index)
        var fineLow = [UInt32](repeating: 0, count: 1 << 16), fineHigh = [UInt32](repeating: 0, count: 1 << 16)
        fineLow.withUnsafeMutableBufferPointer { fineLow in
            fineHigh.withUnsafeMutableBufferPointer { fineHigh in
                each { values in
                    for value in values {
                        let folded = key(value), bucket = folded >> 16
                        if bucket == lowBucket { fineLow[Int(folded & 0xFFFF)] &+= 1 }
                        if bucket == highBucket { fineHigh[Int(folded & 0xFFFF)] &+= 1 }
                    }
                }
            }
        }
        let below = value(lowBucket << 16 | UInt32(place(low.within, in: fineLow).index))
        let above = value(highBucket << 16 | UInt32(place(high.within, in: fineHigh).index))
        let result = total % 2 == 1 ? above : (below + above) / 2
        return result.isFinite ? result : nil
    }

    /// A `Float` as an integer that orders as it does: a positive value's bits above every negative one's, a negative value's turned
    /// over, since its bits grow as it falls. −0 sits just under 0, which a median cannot tell apart.
    @inline(__always) static func key(_ value: Float) -> UInt32 {
        let bits = value.bitPattern
        return bits & 0x8000_0000 != 0 ? ~bits : bits | 0x8000_0000
    }

    /// The `Float` of a `key`.
    @inline(__always) static func value(_ key: UInt32) -> Float {
        Float(bitPattern: key & 0x8000_0000 != 0 ? key & 0x7FFF_FFFF : ~key)
    }

    /// Which count holds the value of `rank`, and its rank among that count's own.
    private static func place(_ rank: Int, in counts: [UInt32]) -> (index: Int, within: Int) {
        counts.withUnsafeBufferPointer { counts in
            var before = 0
            for index in 0..<counts.count {
                let count = Int(counts[index])
                if rank < before + count { return (index, rank - before) }
                before += count
            }
            preconditionFailure("a rank past the values counted: the two passes were not handed the same values")
        }
    }

    /// Hoare quickselect: `buffer[k]` ends as the k-th smallest and everything before it is at most it, everything after at least it. A median of `Float`s from a decode, so NaNs
    /// are not expected; a NaN compares unordered and the result is simply not finite, which `median` reports as no median.
    private static func selectValue(_ buffer: UnsafeMutableBufferPointer<Float>, k: Int) -> Float {
        var low = 0, high = buffer.count - 1
        while low < high {
            let pivot = buffer[low + (high - low) / 2]
            var i = low, j = high
            while i <= j {
                while buffer[i] < pivot { i += 1 }
                while buffer[j] > pivot { j -= 1 }
                if i <= j {
                    buffer.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j { high = j } else if k >= i { low = i } else { return buffer[k] }
        }
        return buffer[k]
    }
}
