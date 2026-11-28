import Foundation

public enum CustomStockCompiler {
    public static let previewSize = 17
    public static let saveSize = 65

    public static func compile(_ spec: CustomStockSpec, id: String, name: String, base: Stock? = nil,
                               size: Int = saveSize) throws -> Stock {
        guard (2...128).contains(size) else { throw LUTError.badSize(size) }
        let foundation: Stock?
        let mixer: SIMD3<Float>?
        switch spec.base {
        case .neutral: foundation = nil; mixer = nil
        case .monochrome:
            foundation = MonochromeFilm.stocks.first
            mixer = spec.monochromeMixer ?? luma
        case .derived(let stockID):
            guard let base, base.id == stockID else { throw StockError.badValue("Missing base stock: \(stockID)") }
            foundation = base
            mixer = base.monochrome.map { spec.monochromeMixer ?? $0.weights(for: spec.frameLook?.monochromeFilter ?? .none) }
        }
        try validate(spec, foundation: foundation)
        let analytical = if case .derived = spec.base { false } else { true }
        let encoding = foundation?.negative.encoding ?? LogEncoding()
        let densityRange = foundation?.densityRange ?? encoding.range * log10(Float(2))
        let look = spec.frameLook
        let manual = look?.manual ?? .identity
        let curves = try spec.toneCurve?.compiled()
        let weights = mixer.map { $0 / $0.sum() }
        let layer = foundation?.negative ?? .identity(size: 2, encoding: encoding)
        let settings = DevelopSettings(ratedAt: look?.ratedAt, labBalance: look?.labBalance ?? .zero,
                                      printExposure: look?.printExposure ?? 0, manual: manual,
                                      paperGrade: look?.paperGrade ?? .normal)
        let exposures = foundation?.exposurePerUnit ?? SIMD3(repeating: 1)
        let offset = settings.printOffset(densityRange: densityRange, exposurePerUnit: exposures)
        let rating = settings.exposureStops(boxSpeed: foundation?.boxSpeed ?? spec.boxSpeed)
        let tables = try foundation.flatMap { try manual.toneTables(stock: $0, settings: settings) }
        let sceneParameters = try manual.parameters(tables: tables)
        let inputEncoding = negativeInputEncoding(encoding, scene: sceneParameters, tables: tables, rating: rating)
        let printParameters = try manual.parameters
        let presence = manual.adjustments.presence
        let printPresence = presence.acts(in: .print)
            ? try PresencePrint.parameters(presence, constants: PresenceConstants.required(presence.version), stockID: foundation?.id ?? id)
            : .bypass
        let negativeSample: (SIMD3<Float>) -> SIMD3<Float> = { input in
            let scene = SIMD3(inputEncoding.decode(input.x), inputEncoding.decode(input.y), inputEncoding.decode(input.z))
            let adjusted = manual.applyingScene(to: scene, baseLog2: ManualRenderSettings.guideLog2(scene),
                                               tables: tables, parameters: sceneParameters)
            let exposed = adjusted * exp2(rating)
            if let weights {
                let gray = (exposed * weights).sum()
                return layer.sample(encoded: SIMD3(repeating: encoding.encode(gray)))
            }
            return layer.sample(encoded: SIMD3(encoding.encode(exposed.x), encoding.encode(exposed.y), encoding.encode(exposed.z)))
        }
        let negative = weights != nil || sceneParameters.sceneActive != 0 || rating != 0
            ? try makeLUT(size: size, encoding: inputEncoding, sample: negativeSample) : layer
        let finish = Finish(spec)
        let printSample: (SIMD3<Float>) -> SIMD3<Float> = { input in
            var dye = input + offset
            if let foundation, foundation.monochrome != nil {
                dye = foundation.paperAmounts(dye, grade: settings.paperGrade)
            }
            let rgb: SIMD3<Float>
            if let foundation {
                rgb = foundation.print.sample(encoded: dye.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)))
            } else {
                let scene = SIMD3(encoding.decode(dye.x), encoding.decode(dye.y), encoding.decode(dye.z))
                rgb = CubeImporter.neutralDisplay(scene)
            }
            let withPresence = PresencePrint.applying(to: rgb, parameters: printPresence)
            let baked = manual.applyingPrint(to: withPresence, parameters: printParameters, curves: curves)
            return finish.applying(to: baked)
        }
        let print = try makeLUT(size: size, sample: printSample)
        let daylight = Float(0.18)
        let mid = SIMD3<Float>(repeating: negative.encoding.encode(daylight))
        let dye = negative.sample(encoded: mid)
        let calibrated = analytical ? exposureCalibration(print: print, at: dye, densityRange: densityRange, sample: printSample) : exposures
        let scenePresence = try Presence(
            [.texture: presence.texture, .clarity: presence.clarity, .dehaze: presence.dehaze], version: presence.version)
        let combinedPresence = foundation?.scenePresence?.combined(with: scenePresence) ?? scenePresence
        let color = spec.canisterColor
        let h = spec.halation
        return Stock(id: id, displayName: name, status: "custom", boxSpeed: spec.boxSpeed,
                     densityRange: densityRange, exposurePerUnit: calibrated, negative: negative, print: print,
                     grain: grain(spec.grain, inherited: foundation?.grain, silver: weights != nil),
                     halation: h.enabled && h.strength > 0 ? .init(strength: h.strength, greenShare: h.greenShare,
                                                                 radiusMicrometres: h.radiusMicrometres) : nil,
                     origin: .userBuilt, canisterColor: .init(red: color[0], green: color[1], blue: color[2]),
                     characterLine: spec.characterLine, hasSpec: true,
                     monochromeGrain: spec.grain.preset == .monochrome || weights != nil
                        || (spec.grain.preset == .inherited && foundation?.monochromeGrain == true),
                     scenePresence: combinedPresence.isIdentity ? nil : combinedPresence,
                     scenePresenceReference: combinedPresence.isIdentity ? nil
                        : scenePresence.isIdentity ? foundation?.scenePresenceReference : manual.referenceStops)
    }

    private static let luma = SIMD3<Float>(0.2627, 0.6780, 0.0593)

    private static func negativeInputEncoding(_ source: LogEncoding, scene: ManualCurveParameters,
                                              tables: ManualToneTables?, rating: Float) -> LogEncoding {
        let shift = log2(scene.exposureGain) + rating
        let low: Float
        let high: Float
        if let tables {
            low = min(0, tables.local.min() ?? 0) + min(0, tables.global.min() ?? 0)
            high = tables.maximumGain
        } else {
            low = min(0, scene.shadows) + min(0, scene.highlights)
            high = max(0, scene.shadows) + max(0, scene.highlights)
        }
        // Invert the baked gain before setting the input limits: the renderer clips
        // to this domain before looking up the now-re-exposed foundation negative.
        return LogEncoding(stopsBelowMidGray: source.stopsBelowMidGray + shift + high,
                           stopsAboveMidGray: source.stopsAboveMidGray - shift - low,
                           midGray: source.midGray)
    }

    private static func makeLUT(size: Int, encoding: LogEncoding = .init(),
                                sample: (SIMD3<Float>) -> SIMD3<Float>) throws -> LUT3D {
        let step = 1 / Float(size - 1)
        var values: [Float] = []
        values.reserveCapacity(size * size * size * 3)
        for b in 0..<size {
            try Task.checkCancellation()
            for g in 0..<size {
                for r in 0..<size {
                    let value = sample(SIMD3(Float(r), Float(g), Float(b)) * step)
                    values.append(value.x)
                    values.append(value.y)
                    values.append(value.z)
                }
            }
        }
        return try LUT3D(size: size, encoding: encoding, values: values)
    }

    private static func exposureCalibration(print: LUT3D, at gray: SIMD3<Float>, densityRange: Float,
                                            sample: (SIMD3<Float>) -> SIMD3<Float>) -> SIMD3<Float> {
        // Measure the LUT's local slope against the continuous paper response to a
        // log-exposure change. A fully clipped or reversed channel has no usable slope.
        let delta: Float = 0.005
        var result = SIMD3<Float>(repeating: 1)
        for channel in 0..<3 {
            var axis = SIMD3<Float>.zero
            axis[channel] = delta / densityRange
            let slope = (print.sample(encoded: gray + axis) - print.sample(encoded: gray - axis))[channel]
            let target = (sample(gray + axis) - sample(gray - axis))[channel]
            if slope > 1e-6, target > 1e-6 {
                let ratio = slope / target
                if (0.25...4).contains(ratio) { result[channel] = ratio }
            }
        }
        return result
    }

    private static func grain(_ grain: CustomStockSpec.Grain, inherited: GrainTable?, silver: Bool) -> GrainTable? {
        guard grain.strength > 0, grain.preset != .none else { return nil }
        let base: GrainTable?
        switch grain.preset {
        case .none: return nil
        case .inherited: base = inherited
        case .fine: base = CubeImporter.Grain.fine.table
        case .medium, .monochrome: base = CubeImporter.Grain.medium.table
        case .coarse: base = CubeImporter.Grain.coarse.table
        }
        guard let base else { return nil }
        let rows = zip(base.amounts, base.sigma48).map { amounts, sigmas in
            zip(amounts, sigmas).enumerated().map { index, pair in
                let sigma = silver || grain.preset == .monochrome ? sigmas[0] : sigmas[index]
                return sigma * grain.strength * (1 + grain.shadowBias * (1 - min(max(pair.0, 0), 1)))
            }
        }
        return GrainTable(amounts: base.amounts, sigma48: rows)
    }

    private static func validate(_ spec: CustomStockSpec, foundation: Stock?) throws {
        func check(_ value: Float, _ range: ClosedRange<Float>, _ label: String) throws {
            guard value.isFinite, range.contains(value) else { throw StockError.badValue("Invalid \(label)") }
        }
        try check(spec.boxSpeed, 50...3200, "box speed")
        guard spec.canisterColor.count == 3 else { throw StockError.badValue("Canister color needs three components") }
        for value in spec.canisterColor { try check(value, 0...1, "canister color") }
        try check(spec.contrast, 0.25...4, "contrast")
        try check(spec.shadowToe, 0...1, "shadow toe")
        try check(spec.highlightShoulder, 0...1, "highlight shoulder")
        try check(spec.warmth, -1...1, "warmth")
        try check(spec.tint, -1...1, "tint")
        try check(spec.saturation, 0...2, "saturation")
        try check(spec.vibrance, -1...1, "vibrance")
        for tint in [spec.splitTone.shadows, spec.splitTone.midtones, spec.splitTone.highlights] {
            try check(tint.hue, 0...360, "split-tone hue")
            try check(tint.strength, 0...1, "split-tone strength")
        }
        for shift in spec.colorShift.values {
            try check(shift.hue, -60...60, "hue shift")
            try check(shift.saturation, -1...1, "hue saturation")
        }
        if let mixer = spec.monochromeMixer {
            for index in 0..<3 { try check(mixer[index], 0...1, "monochrome mixer") }
            guard mixer.sum() > 0 else { throw StockError.badValue("Monochrome mixer needs a nonzero channel") }
        }
        if let paper = spec.paperTone {
            for index in 0..<3 { try check(paper[index], 0...2, "paper tone") }
        }
        try check(spec.grain.strength, 0...2, "grain strength")
        try check(spec.grain.shadowBias, -1...1, "grain shadow bias")
        try check(spec.halation.strength, CustomStockSpec.Halation.strengthRange(inheriting: foundation), "halation strength")
        try check(spec.halation.greenShare, 0...1, "halation green share")
        try check(spec.halation.radiusMicrometres, 60...350, "halation radius")
        if let look = spec.frameLook {
            guard look.printExposure.isFinite, look.labBalance.x.isFinite, look.labBalance.y.isFinite, look.labBalance.z.isFinite,
                  look.ratedAt.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw StockError.badValue("Invalid baked frame exposure")
            }
        }
    }

    private struct Finish {
        let spec: CustomStockSpec
        let hues: [(angle: Float, shift: Float, saturation: Float)]
        let tones: [SIMD2<Float>]
        let hasColor: Bool

        init(_ spec: CustomStockSpec) {
            self.spec = spec
            hues = CustomStockSpec.Hue.allCases.compactMap { hue in
                guard let shift = spec.colorShift[hue], shift.hue != 0 || shift.saturation != 0 else { return nil }
                return (hue.center * .pi / 180, shift.hue * .pi / 180, shift.saturation)
            }
            let split = [spec.splitTone.shadows, spec.splitTone.midtones, spec.splitTone.highlights]
            tones = split.map { tint in
                let a = tint.hue * .pi / 180
                return SIMD2(cos(a), sin(a)) * (0.075 * tint.strength)
            }
            hasColor = spec.warmth != 0 || spec.tint != 0 || spec.saturation != 1 || spec.vibrance != 0
                || !hues.isEmpty || split.contains { $0.strength != 0 }
        }

        func applying(to source: SIMD3<Float>) -> SIMD3<Float> {
            var rgb = source
            let y = (rgb * luma).sum()
            if y >= 0 && y <= 1, spec.contrast != 1 || spec.shadowToe != 0 || spec.highlightShoulder != 0 {
                let anchor: Float = 0.18
                let span = y < anchor ? anchor : 1 - anchor
                let t = abs(y - anchor) / span
                let warped = t * spec.contrast / (1 + t * (spec.contrast - 1))
                let endpoint = y < anchor ? anchor * (1 - 0.7 * spec.shadowToe) : span * (1 - 0.35 * spec.highlightShoulder)
                let mapped = anchor + (y < anchor ? -1 : 1) * endpoint * warped
                let neutral = SIMD3<Float>(repeating: mapped)
                rgb = neutral + (rgb - y) * (mapped / max(y, 1e-6))
            }
            if hasColor {
                let lab = toOklab(rgb)
                var ab = SIMD2(lab.y, lab.z)
                let chroma = sqrt(ab.x * ab.x + ab.y * ab.y)
                if !hues.isEmpty && chroma > 0.002 {
                    let angle = atan2(ab.y, ab.x)
                    var rotation: Float = 0, saturation: Float = 0, weight: Float = 0
                    for hue in hues {
                        let raw = abs(angle - hue.angle)
                        let distance = min(raw, abs(2 * .pi - raw))
                        let w = max(0, 1 - distance / (.pi / 3))
                        rotation += w * hue.shift
                        saturation += w * hue.saturation
                        weight += w
                    }
                    let mask = min(chroma / 0.06, 1) / max(weight, 1)
                    let shift = rotation * mask
                    ab = SIMD2(cos(shift) * ab.x - sin(shift) * ab.y,
                               sin(shift) * ab.x + cos(shift) * ab.y) * (1 + saturation * mask)
                }
                ab *= spec.saturation * (1 + 0.7 * spec.vibrance * max(0, 1 - chroma / 0.25))
                let v = min(max(lab.x, 0), 1)
                let shadow = max(1 - v / 0.56, 0)
                let highlight = max((v - 0.56) / 0.44, 0)
                let midtone = 1 - shadow - highlight
                let cast = SIMD2(spec.tint, spec.warmth) * 0.045
                let bias = cast + tones[0] * shadow + tones[1] * midtone + tones[2] * highlight
                ab += bias * min(v * 5, (1 - v) * 5, 1)
                rgb = fromOklab(SIMD3(lab.x, ab.x, ab.y))
            }
            if let paper = spec.paperTone { rgb *= paper }
            return rgb
        }

        private func toOklab(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let l = cbrt((c * SIMD3(0.6167558, 0.3601984, 0.0230458)).sum())
            let m = cbrt((c * SIMD3(0.2651331, 0.6358394, 0.0990275)).sum())
            let s = cbrt((c * SIMD3(0.1001026, 0.2039065, 0.6959909)).sum())
            let v = SIMD3(l, m, s)
            return SIMD3((v * SIMD3(0.21045426, 0.79361779, -0.00407205)).sum(),
                         (v * SIMD3(1.9779985, -2.4285922, 0.4505937)).sum(),
                         (v * SIMD3(0.02590404, 0.78277177, -0.80867581)).sum())
        }

        private func fromOklab(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let lms = SIMD3(c.x + 0.39633778 * c.y + 0.21580376 * c.z,
                            c.x - 0.10556135 * c.y - 0.06385417 * c.z,
                            c.x - 0.08948418 * c.y - 1.29148555 * c.z)
            let v = lms * lms * lms
            return SIMD3((v * SIMD3(2.1399067, -1.2463895, 0.1064828)).sum(),
                         (v * SIMD3(-0.8847358, 2.1632309, -0.2784951)).sum(),
                         (v * SIMD3(-0.0485737, -0.4545032, 1.5030769)).sum())
        }
    }
}
