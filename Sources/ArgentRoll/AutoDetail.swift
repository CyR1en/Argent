import ArgentCore
import Foundation

/// Refines a settled aim only when measured detail is weak in its predicted print.
enum AutoDetail {
    private struct Patch {
        let rgb: SIMD3<Float>
        let y: Float
        let stops: Float
    }

    private struct Pair {
        let low: Patch
        let high: Patch
        var base: Float { (low.stops + high.stops) / 2 }
        var separation: Float { high.stops - low.stops }
    }

    private struct Tail {
        var deficit: Float = 0
        var clamped: Int = 0
        var reversed: Int = 0
        var separations: [Float] = []
        var isAtRisk: Bool { deficit >= 0.4 }

        func protects(_ prior: Self) -> Bool {
            clamped <= prior.clamped && reversed <= prior.reversed && deficit <= prior.deficit + 0.15
                && zip(separations, prior.separations).allSatisfy { now, before in now >= min(before, 2.8) - 0.75 }
        }
    }

    static func protect(_ prior: PrintAim, descriptor: SequenceDescriptor, analysis: ExposureAnalysis,
                        stock: Stock, controls: RollControls, iso: Int?) -> PrintAim {
        let w = descriptor.width, h = descriptor.height
        guard (1...SequenceDescriptor.longSide).contains(w), (1...SequenceDescriptor.longSide).contains(h),
              descriptor.rgb.count == 3 * w * h, descriptor.detail.count == w * h,
              descriptor.unclipped.count == w * h else { return prior }
        func patch(_ rgb: SIMD3<Float>) -> Patch? {
            let y = (rgb * Rec2020.luma).sum()
            guard y > 0, y.isFinite, rgb.min().isFinite, rgb.max().isFinite else { return nil }
            return Patch(rgb: rgb, y: y, stops: log2(y / 0.18))
        }
        let patches = (0..<(w * h)).map { i in
            patch(SIMD3(descriptor.rgb[3 * i], descriptor.rgb[3 * i + 1], descriptor.rgb[3 * i + 2]))
        }
        var highlights: [Pair] = [], shadows: [Pair] = []
        for i in patches.indices {
            guard let a = patches[i], descriptor.unclipped[i] >= 0.9 else { continue }
            for j in [i % w + 1 < w ? i + 1 : i, i + w < w * h ? i + w : i] where j != i {
                guard let b = patches[j], descriptor.unclipped[j] >= 0.9,
                      max(descriptor.detail[i], descriptor.detail[j]) >= 0.045 else { continue }
                let pair = a.stops < b.stops ? Pair(low: a, high: b) : Pair(low: b, high: a)
                let chroma = pair.low.rgb / pair.low.y - pair.high.rgb / pair.high.y
                guard (0.18...1.15).contains(pair.separation),
                      (chroma * chroma).sum() <= 0.09 else { continue }
                if pair.low.stops - prior.level >= 1.75 {
                    highlights.append(pair)
                } else if pair.high.stops - prior.level <= -1.75, reliableShadow(pair, noise: descriptor.noise, iso: iso) {
                    shadows.append(pair)
                }
            }
        }
        let minimum = max(4, w * h / 60)
        highlights = highlights.count >= minimum ? distributed(highlights, limit: 128) : []
        shadows = shadows.count >= minimum ? distributed(shadows, limit: 128) : []
        guard !highlights.isEmpty || !shadows.isEmpty else { return prior }

        let mids = distributed(patches.compactMap { $0 }.filter { abs($0.stops - prior.level) < 1 }, limit: 32)
        let faces = analysis.faces.compactMap { face -> Patch? in
            guard (face.confidence ?? 0) >= 0.7, (face.skinArea ?? 0) >= 0.01, (face.clipped ?? 1) < 0.1,
                  let skin = face.skin, skin.count == 3 else { return nil }
            return patch(SIMD3(skin[0], skin[1], skin[2]))
        }
        func predict(_ aim: PrintAim) -> PrintPatchResponse? {
            try? PrintPatchResponse(stock: stock, settings: controls.settings(for: stock, aim: aim))
        }
        guard let original = predict(prior) else { return prior }
        let bright = measure(highlights, with: original)
        let dark = measure(shadows, with: original)
        guard bright.isAtRisk || dark.isAtRisk else { return prior }

        let subject = (mids + faces).map { ($0, lightness(original.sample($0.rgb, baseStops: $0.stops).rgb)) }
        func improves(_ aim: PrintAim, bright currentBright: Tail, dark currentDark: Tail) -> (Tail, Tail)? {
            guard let response = predict(aim), subject.allSatisfy({ p, baseline in
                abs(lightness(response.sample(p.rgb, baseStops: p.stops).rgb) - baseline) <= 1.5
            }) else { return nil }
            let newBright = measure(highlights, with: response), newDark = measure(shadows, with: response)
            guard newBright.protects(bright), newDark.protects(dark),
                  newBright.protects(currentBright), newDark.protects(currentDark),
                  (currentBright.isAtRisk && newBright.deficit <= currentBright.deficit - 0.25)
                    || (currentDark.isAtRisk && newDark.deficit <= currentDark.deficit - 0.25) else { return nil }
            return (newBright, newDark)
        }

        var aim = prior
        var brightNow = bright, darkNow = dark
        if bright.isAtRisk {
            for move: Float in [0.125, 0.25, 0.5] {
                var candidate = aim
                candidate.burn = min(prior.burn + move, FittedTone.burnLimit)
                if candidate != aim, let result = improves(candidate, bright: brightNow, dark: darkNow),
                   result.0.deficit <= brightNow.deficit - 0.25 {
                    aim = candidate
                    (brightNow, darkNow) = result
                    break
                }
            }
        }
        if darkNow.isAtRisk {
            for move: Float in [0.0625, 0.125, 0.25] {
                var candidate = aim
                candidate.dodge = min(prior.dodge + move, FittedTone.dodgeLimit)
                if candidate != aim, let result = improves(candidate, bright: brightNow, dark: darkNow),
                   result.1.deficit <= darkNow.deficit - 0.25 {
                    aim = candidate
                    (brightNow, darkNow) = result
                    break
                }
            }
        }
        if aim == prior, bright.isAtRisk != dark.isAtRisk {
            var candidate = prior
            candidate.level = min(max(prior.level + (bright.isAtRisk ? 0.125 : -0.125), -AutoPrint.bound), AutoPrint.bound)
            if candidate != prior, improves(candidate, bright: bright, dark: dark) != nil { return candidate }
        }
        return aim
    }

    private static func reliableShadow(_ pair: Pair, noise: DecodedNoise?, iso: Int?) -> Bool {
        if let noise {
            let sigma = (0..<3).reduce(Float.zero) { sum, c in
                sum + Rec2020.luma[c] * max(noise.sigma(pair.low.rgb[c], channel: c), noise.sigma(pair.high.rgb[c], channel: c))
            }
            return pair.high.y - pair.low.y >= 4 * sigma
        }
        return pair.low.stops >= ((iso ?? 6400) >= 6400 ? -3.3 : -4) && pair.separation >= 0.3
    }

    private static func distributed<T>(_ all: [T], limit: Int) -> [T] {
        all.count <= limit ? all : (0..<limit).map { all[($0 * all.count + all.count / 2) / limit] }
    }

    private static func lightness(_ rgb: SIMD3<Float>) -> Float {
        SequenceAims.lightness((rgb * Rec2020.luma).sum())
    }

    private static func measure(_ pairs: [Pair], with response: PrintPatchResponse) -> Tail {
        var tail = Tail()
        for pair in pairs {
            let low = response.sample(pair.low.rgb, baseStops: pair.base)
            let high = response.sample(pair.high.rgb, baseStops: pair.base)
            let separation = (lightness(high.rgb) - lightness(low.rgb)) / pair.separation
            if low.clamped || high.clamped { tail.clamped += 1 }
            if separation < 0 { tail.reversed += 1 }
            tail.separations.append(separation)
            tail.deficit += max(0, 2.8 - separation)
        }
        if !pairs.isEmpty { tail.deficit /= Float(pairs.count) }
        return tail
    }
}
