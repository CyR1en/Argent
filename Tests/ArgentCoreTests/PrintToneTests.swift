import Foundation
import Metal
import simd
import Testing
@testable import ArgentCore

/// The tone step's contract: identity is the old render, its offset is print exposure's lightness, a local
/// base moves regions, a burn takes colour as it burns, a dodge respects what the negative holds, and recipes keep what
/// they recorded.
@Suite struct PrintToneTests {
    private static let side = 96

    private func frame(_ gpu: GPU, _ light: (Int, Int) -> Float) throws -> LinearFrame {
        let side = Self.side
        let texture = try gpu.makeTexture(width: side, height: side)
        var halves = [Float16](repeating: 1, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let value = Float16(light(x, y)), i = (y * side + x) * 4
                halves[i] = value; halves[i + 1] = value; halves[i + 2] = value
            }
        }
        halves.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: side * 8)
        }
        return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "test", scale: 1)
    }

    private func flat(_ gpu: GPU, stops: Float) throws -> LinearFrame {
        try frame(gpu) { _, _ in 0.18 * pow(2, stops) }
    }

    private func pixels(_ texture: MTLTexture) -> [Float16] {
        var values = [Float16](repeating: 0, count: Self.side * Self.side * 4)
        values.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: Self.side * 8, from: MTLRegionMake2D(0, 0, Self.side, Self.side), mipmapLevel: 0)
        }
        return values
    }

    private func render(_ gpu: GPU, _ renderer: FilmRenderer, _ frame: LinearFrame, _ settings: DevelopSettings) throws -> [Float16] {
        pixels(try renderer.render(frame, settings: settings).image.texture)
    }

    /// The same pixel in two renders, channel by channel, within half-float rounding through a LUT.
    private func expectClose(_ a: [Float16], _ b: [Float16], tolerance: Float, _ comment: Comment) {
        var worst: Float = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 { worst = max(worst, abs(Float(a[i + c]) - Float(b[i + c]))) }
        }
        #expect(worst <= tolerance, "\(comment): differs by \(worst)")
    }

    @Test func aToneWithNoStrengthIsTheOldRender() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        let source = try frame(gpu) { x, y in 0.01 + 2 * Float((x * 7 + y * 3) % 31) / 31 }
        let plain = try render(gpu, renderer, source, DevelopSettings())
        var settings = DevelopSettings()
        settings.tone = PrintTone(burn: 0, dodge: 0, referenceStops: 1.5)
        #expect(!settings.tone.isActive)
        #expect(try render(gpu, renderer, source, settings) == plain, "no strength takes the original path, bit for bit")
    }

    private func luminance(_ p: [Float16]) -> Float {
        0.2627 * Float(p[0]) + 0.6780 * Float(p[1]) + 0.0593 * Float(p[2])
    }

    /// In a flat field the base is the field's own level, so the print must land at the lightness the same stops of print
    /// exposure give, with the colour the frame prints without a tone step.
    @Test(arguments: [Float(-3), -2, -1, 0, 1, 2, 3, 4.5, 6])
    func aFlatFieldPrintsAtThatPrintExposuresLightnessInItsOwnColour(stops: Float) throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        let tone = PrintTone(burn: 0.8, dodge: 0.4)
        let source = try flat(gpu, stops: stops)
        let plain = try render(gpu, renderer, source, DevelopSettings())
        var toned = DevelopSettings()
        toned.tone = tone
        var global = DevelopSettings()
        global.printExposure = try tone.stops(baseLog2: log2(0.18) + stops, ratedStops: 0)
        let out = try render(gpu, renderer, source, toned), lit = try render(gpu, renderer, source, global)
        #expect(abs(luminance(out) - luminance(lit)) < 3e-3, "lightness at \(stops) stops")
        for c in 0..<3 {
            let held = Float(out[c]) / max(luminance(out), 1e-4), own = Float(plain[c]) / max(luminance(plain), 1e-4)
            #expect(abs(held - own) < 6e-3, "channel \(c)'s share at \(stops) stops: \(held) against \(own)")
        }
    }

    /// The defect this guards: a burn on Portra 400 turned a white sky lavender, and only an eye could see it.
    @Test func aBurnedWhiteKeepsItsColourOnEveryBakedStock() throws {
        let gpu = try GPU()
        for url in LightCompilerBaselineTests.bakedStocks {
            let stock = try Stock.load(from: url)
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            for stops in [Float(1.5), 2.5, 3.5, 4.5] {
                let source = try flat(gpu, stops: stops)
                let plain = try render(gpu, renderer, source, DevelopSettings())
                var settings = DevelopSettings()
                settings.tone = PrintTone(burn: 0.6, dodge: 0)
                let held = try render(gpu, renderer, source, settings)
                settings.tone.holdsColour = false
                let uneven = try render(gpu, renderer, source, settings)
                func tilt(_ p: [Float16]) -> Float {
                    let y = max(luminance(p), 1e-4)
                    return max(abs(Float(p[0]) / y - Float(plain[0]) / max(luminance(plain), 1e-4)),
                               abs(Float(p[2]) / y - Float(plain[2]) / max(luminance(plain), 1e-4)))
                }
                #expect(tilt(held) <= tilt(uneven) + 1e-3, "\(stock.id) at \(stops) stops: held \(tilt(held)), plain offset \(tilt(uneven))")
                #expect(tilt(held) < 0.02, "\(stock.id) at \(stops) stops: a gray stays its own colour, moved \(tilt(held))")
                #expect(luminance(held) < luminance(plain), "\(stock.id) at \(stops) stops still darkens")
            }
        }
    }

    @Test func thePrintsAlphaStaysOpaque() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        var settings = DevelopSettings()
        settings.tone = PrintTone(burn: 1, dodge: 0.5)
        for sharpen in [false, true] {
            settings.sharpen = sharpen
            let out = try render(gpu, renderer, try flat(gpu, stops: 2), settings)
            for i in stride(from: 3, to: out.count, by: 4) where out[i] != 1 {
                Issue.record("alpha \(out[i]) with sharpen \(sharpen)")
                return
            }
        }
    }

    @Test func burnDarkensBrightRegionsAndDodgeLightensDimOnes() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        // Sky over ground, with texture in each.
        let source = try frame(gpu) { x, y in
            let wave = 1 + 0.15 * sin(Float(x) * 0.9) * sin(Float(y) * 0.7)
            return (y < Self.side / 2 ? 0.18 * pow(2, -1.5) : 0.18 * pow(2, 2.5)) * wave
        }
        let plain = try render(gpu, renderer, source, DevelopSettings())
        var settings = DevelopSettings()
        settings.tone = PrintTone(burn: 0.8, dodge: 0.4)
        let out = try render(gpu, renderer, source, settings)
        func mean(_ p: [Float16], _ rows: Range<Int>) -> Float {
            var sum: Float = 0, n: Float = 0
            for y in rows { for x in 0..<Self.side { sum += Float(p[(y * Self.side + x) * 4 + 1]); n += 1 } }
            return sum / n
        }
        func spread(_ p: [Float16], _ rows: Range<Int>) -> Float {
            let m = mean(p, rows)
            var sum: Float = 0, n: Float = 0
            for y in rows { for x in 0..<Self.side { let d = Float(p[(y * Self.side + x) * 4 + 1]) - m; sum += d * d; n += 1 } }
            return (sum / n).squareRoot()
        }
        let dim = 8..<(Self.side / 2 - 8), bright = (Self.side / 2 + 8)..<(Self.side - 8)
        #expect(mean(out, dim) > mean(plain, dim) + 1e-3, "the dim half lightens")
        #expect(mean(out, bright) < mean(plain, bright) - 1e-3, "the bright half darkens")
        #expect(spread(out, dim) > 0.5 * spread(plain, dim), "texture stays in the dim half")
        #expect(spread(out, bright) > 0.5 * spread(plain, bright), "texture stays in the bright half")
    }

    /// Every entry of the table on every stock: finite, no step between neighbours beyond what the plain offset takes, and
    /// a gray at every level the frame's light reaches keeps its colour. A solve that gave up would show here, not just
    /// at the levels a test happens to name.
    @Test(arguments: [(burn: Float(0.3), dodge: Float(0.1)), (0.6, 0.3), (1, 0.5)])
    func theTableHoldsOnEveryBakedStockAtEveryLevel(strength: (burn: Float, dodge: Float)) throws {
        for url in LightCompilerBaselineTests.bakedStocks {
            let stock = try Stock.load(from: url)
            for rating: Float? in [nil, stock.boxSpeed * 4] {
                let settings = DevelopSettings(ratedAt: rating, labBalance: SIMD3(0.05, 0, -0.05))
                let tone = PrintTone(burn: strength.burn, dodge: strength.dodge)
                var plainTone = tone
                plainTone.holdsColour = false
                let table = try tone.table(stock: stock, settings: settings), plain = try plainTone.table(stock: stock, settings: settings)
                #expect(table.count == PrintToneTableInfo.entries)
                var worstStep: Float = 0, worstPlainStep: Float = 0, worstHeld: Float = 0
                let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
                let encoding = stock.negative.encoding
                let rated = settings.exposureStops(boxSpeed: stock.boxSpeed)
                func share(_ rgb: SIMD3<Float>) -> SIMD3<Float> { rgb / max(0.2627 * rgb.x + 0.6780 * rgb.y + 0.0593 * rgb.z, 1e-4) }
                for i in table.indices {
                    #expect(table[i].x.isFinite && table[i].y.isFinite && table[i].z.isFinite, "\(stock.id) entry \(i)")
                    if i > 0 {
                        for c in 0..<3 {
                            worstStep = max(worstStep, abs(table[i][c] - table[i - 1][c]))
                            worstPlainStep = max(worstPlainStep, abs(plain[i][c] - plain[i - 1][c]))
                        }
                    }
                    let scene = PrintToneTableInfo.firstStops + Float(i) * PrintToneTableInfo.stepStops
                    // Where the negative's encoding ends the print cannot move, so the check stops with it.
                    guard scene + rated > -encoding.stopsBelowMidGray, scene + rated < encoding.stopsAboveMidGray else { continue }
                    let film = stock.negative.sample(encoded: SIMD3(repeating: encoding.encode(encoding.midGray * exp2(scene + rated)))) + offset
                    func printed(_ a: SIMD3<Float>) -> SIMD3<Float> { stock.print.sample(encoded: a.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))) }
                    let unmoved = printed(film)
                    guard 0.2627 * unmoved.x + 0.6780 * unmoved.y + 0.0593 * unmoved.z > 0.01 else { continue }
                    let moved = printed(film + SIMD3(table[i].x, table[i].y, table[i].z))
                    let tilt = abs(share(moved) - share(unmoved))
                    worstHeld = max(worstHeld, max(tilt.x, max(tilt.y, tilt.z)))
                }
                #expect(worstStep <= 3 * worstPlainStep + 0.004, "\(stock.id) rated \(String(describing: rating)): step \(worstStep), plain \(worstPlainStep)")
                #expect(worstHeld < 0.06, "\(stock.id) rated \(String(describing: rating)) at \(strength): a gray's colour moves \(worstHeld)")
                print("TONETABLE \(stock.id) rated \(rating.map { Int($0) } ?? 0) burn \(strength.burn): step \(worstStep), plain step \(worstPlainStep), colour \(worstHeld)")
            }
        }
    }

    /// The sharpened kernel and the halation kernel are the ones every app render takes.
    @Test(arguments: [Float(-2), 0.5, 3])
    func theKernelsAppRendersTakeAgreeWithThePlainOnes(stops: Float) throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        let tone = PrintTone(burn: 0.7, dodge: 0.35)
        let source = try flat(gpu, stops: stops)
        var plain = DevelopSettings()
        plain.tone = tone
        var sharpened = plain
        sharpened.sharpen = true
        // A flat field has no detail to sharpen, so the two kernels must print it alike.
        expectClose(try render(gpu, renderer, source, plain), try render(gpu, renderer, source, sharpened), tolerance: 2e-3, "sharpened at \(stops)")
        // Grain stays keyed to the film's own amounts: its noise is the same with the tone as without, around each print.
        var grained = sharpened
        grained.grain = 1; grained.grainSeed = 7
        let out = try render(gpu, renderer, source, grained)
        var moved = false
        let flatPrint = try render(gpu, renderer, source, sharpened)
        for i in stride(from: 1, to: out.count, by: 4) where out[i] != flatPrint[i] { moved = true }
        if ToyStock.make().grain != nil { #expect(moved, "grain still shows") }
        for url in LightCompilerBaselineTests.bakedStocks where url.lastPathComponent == "kodak-portra-400" {
            let stock = try Stock.load(from: url)
            let baked = try FilmRenderer(gpu: gpu, stock: stock)
            var settings = DevelopSettings(halation: stock.halation != nil, sharpen: true)
            let before = try render(gpu, baked, source, settings)
            settings.tone = tone
            let after = try render(gpu, baked, source, settings)
            let shift = try tone.stops(baseLog2: log2(0.18) + stops, ratedStops: 0)
            if shift != 0 { #expect((luminance(after) > luminance(before)) == (shift > 0), "\(stock.id) moves the right way") }
            for i in stride(from: 3, to: after.count, by: 4) where after[i] != 1 { Issue.record("alpha \(after[i]) through halation"); break }
        }
    }

    /// A preview and its develop read the same base, so a frame prints alike at either size.
    @Test func aPreviewAndItsDevelopAgree() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        let side = Self.side
        func light(_ x: Int, _ y: Int, _ scale: Int) -> Float {
            0.18 * pow(2, (Float(y * scale) / Float(side)) * 6 - 3)
        }
        func makeFrame(_ size: Int, _ scale: Int) throws -> LinearFrame {
            let texture = try gpu.makeTexture(width: size, height: size)
            var halves = [Float16](repeating: 1, count: size * size * 4)
            for y in 0..<size { for x in 0..<size {
                let v = Float16(light(x, y, scale)), i = (y * size + x) * 4
                halves[i] = v; halves[i + 1] = v; halves[i + 2] = v
            } }
            halves.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size * 8) }
            return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "test", scale: 1)
        }
        var settings = DevelopSettings()
        settings.tone = PrintTone(burn: 0.8, dodge: 0.4)
        let large = try renderer.render(try makeFrame(side, 1), settings: settings).image.texture
        let small = try renderer.render(try makeFrame(side / 2, 2), settings: settings).image.texture
        var a = [Float16](repeating: 0, count: side * side * 4), b = [Float16](repeating: 0, count: side * side)
        a.withUnsafeMutableBytes { large.getBytes($0.baseAddress!, bytesPerRow: side * 8, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0) }
        b.withUnsafeMutableBytes { small.getBytes($0.baseAddress!, bytesPerRow: side / 2 * 8, from: MTLRegionMake2D(0, 0, side / 2, side / 2), mipmapLevel: 0) }
        var worst: Float = 0
        for y in 2..<(side / 2 - 2) {
            let big = (Float(a[(y * 2 * side + 40) * 4 + 1]) + Float(a[((y * 2 + 1) * side + 40) * 4 + 1])) / 2
            worst = max(worst, abs(big - Float(b[(y * (side / 2) + 20) * 4 + 1])))
        }
        #expect(worst < 0.02, "worst difference \(worst)")
    }

    @Test func aFrameRenderedInPlaceKeepsItsTone() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        var settings = DevelopSettings()
        settings.tone = PrintTone(burn: 0.8, dodge: 0.4)
        let aside = try render(gpu, renderer, try flat(gpu, stops: 2.5), settings)
        let inPlace = pixels(try renderer.render(try flat(gpu, stops: 2.5), settings: settings, inPlace: true).image.texture)
        expectClose(aside, inPlace, tolerance: 0, "in place")
    }

    @Test func aDodgeFadesWhereTheNegativeHoldsLittle() throws {
        let tone = PrintTone(burn: 0, dodge: 0.5)
        let base = log2(Float(0.18)) - 2
        let box = try tone.stops(baseLog2: base, ratedStops: 0)
        let twoUnder = try tone.stops(baseLog2: base, ratedStops: -2)
        #expect(box > 0.4, "two stops under at box speed: the negative holds it, so nearly the full dodge")
        #expect(twoUnder < 0.15, "the same scene rated two under sits deep in the toe, so little is lifted")
        #expect(try tone.stops(baseLog2: log2(Float(0.18)) - 6, ratedStops: 0) == 0, "nothing to lift deep in the toe")
    }

    @Test func aBurnSparesThePapersWhite() throws {
        let tone = PrintTone(burn: 1, dodge: 0)
        func stops(_ scene: Float) throws -> Float { try tone.stops(baseLog2: log2(Float(0.18)) + scene, ratedStops: 0) }
        #expect(abs(try stops(4.5) + 1) < 1e-5, "full strength at the top of the sky")
        #expect(abs(try stops(7) + 0.4) < 1e-5, "some of it left past the white")
        #expect(try stops(-0.25) == 0, "nothing below the print's mid-gray")
        #expect(abs(try stops(0)) < 0.02, "mid-gray stays about where the aim put it")
    }

    /// The defect this guards: a burn that rose over a stop and three quarters flattened the tones it crossed, and doubled
    /// it printed a dark ring round the sun on a river, since a paper stop is about two scene stops through the negative.
    @Test func theStrongestBurnNeverReversesTheTonesItCrosses() throws {
        let tone = PrintTone(burn: 1.25, dodge: 0)
        var previous = try tone.stops(baseLog2: log2(Float(0.18)) - 1, ratedStops: 0)
        for step in 1...160 {
            let scene = -1 + Float(step) * 0.05
            let here = try tone.stops(baseLog2: log2(Float(0.18)) + scene, ratedStops: 0)
            #expect((previous - here) / 0.05 <= 0.41, "falls \((previous - here) / 0.05) paper stops per scene stop at \(scene)")
            previous = here
        }
    }

    /// The defects this guards: a burn brought a pale sky down off the paper's shoulder into a deep blue the scene never had,
    /// and taking colour from all it burned bleached a patch of orange lamplight on a night street to pink.
    @Test func aBurnTakesColourAsItBurnsAndADodgeTakesNone() throws {
        let gpu = try GPU()
        let renderer = try FilmRenderer(gpu: gpu, stock: ToyStock.make())
        func tinted(stops: Float, _ tint: SIMD3<Float> = SIMD3(0.9, 1, 1.25)) throws -> LinearFrame {
            let side = Self.side, texture = try gpu.makeTexture(width: side, height: side)
            let y = 0.18 * pow(2, stops)
            let light = tint * (y / (0.2627 * tint.x + 0.6780 * tint.y + 0.0593 * tint.z))
            var halves = [Float16](repeating: 1, count: side * side * 4)
            for i in stride(from: 0, to: halves.count, by: 4) {
                halves[i] = Float16(light.x); halves[i + 1] = Float16(light.y); halves[i + 2] = Float16(light.z)
            }
            halves.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: side * 8)
            }
            return LinearFrame(image: PooledTexture(unpooled: texture), decoderVersion: "test", scale: 1)
        }
        func colour(_ p: [Float16]) -> Float { abs(Float(p[2]) - Float(p[0])) / max(luminance(p), 1e-4) }
        func withColour(_ share: Float, burn: Float, dodge: Float) -> DevelopSettings {
            var settings = DevelopSettings()
            settings.tone = PrintTone(burn: burn, dodge: dodge)
            var shape = PrintTone.Shape.v2026_11_05_2
            shape.burnColour = share
            settings.tone.shapeOverride = shape
            return settings
        }
        let sky = try tinted(stops: 2.5)
        let kept = try render(gpu, renderer, sky, withColour(0, burn: 0.8, dodge: 0))
        let taken = try render(gpu, renderer, sky, withColour(0.5, burn: 0.8, dodge: 0))
        #expect(colour(taken) < 0.9 * colour(kept), "the burned sky loses colour: \(colour(taken)) against \(colour(kept))")
        let lamp = try tinted(stops: 2.5, SIMD3(2.13, 0.63, 0.21))
        expectClose(try render(gpu, renderer, lamp, withColour(0, burn: 0.8, dodge: 0)), try render(gpu, renderer, lamp, withColour(0.5, burn: 0.8, dodge: 0)),
                    tolerance: 0, "a lamp's saturated orange keeps its colour under the same burn")
        let dim = try tinted(stops: -1.5)
        expectClose(try render(gpu, renderer, dim, withColour(0, burn: 0, dodge: 0.4)), try render(gpu, renderer, dim, withColour(0.5, burn: 0, dodge: 0.4)),
                    tolerance: 0, "a dodge takes no colour")
        let tone = withColour(0.5, burn: 0.8, dodge: 0.4)
        for (i, entry) in try tone.tone.table(stock: ToyStock.make(), settings: tone).enumerated() {
            let scene = PrintToneTableInfo.firstStops + Float(i) * PrintToneTableInfo.stepStops
            let stops = try tone.tone.stops(baseLog2: log2(Float(0.18)) + scene, ratedStops: 0)
            #expect(abs(entry.w - max(-stops, 0) * 0.5) < 1e-5, "entry \(i)")
        }
    }

    @Test func theCurveFollowsTheAim() throws {
        let aimed = PrintTone(burn: 1, dodge: 0.5, referenceStops: 0.75)
        let plain = PrintTone(burn: 1, dodge: 0.5)
        let difference = abs(try aimed.stops(baseLog2: log2(Float(0.18)) + 1.75, ratedStops: 0) - plain.stops(baseLog2: log2(Float(0.18)) + 1, ratedStops: 0))
        #expect(difference < 1e-5, "the highlights are counted from the print's mid-gray")
    }

    @Test func theRenderVersionNamesAToneOnlyWhenThereIsOne() {
        var settings = DevelopSettings()
        #expect(RenderGraph.version(for: settings) == RenderGraph.version, "an older develop keeps its version")
        settings.tone = PrintTone(burn: 0.5, dodge: 0)
        #expect(RenderGraph.version(for: settings) == RenderGraph.version + "+tone-" + PrintTone.currentVersion)
        settings.tone.version = "2026-11-05-2"
        #expect(RenderGraph.version(for: settings) == RenderGraph.version + "+tone-2026-11-05-2", "a develop on the first table keeps its name")
    }

    @Test func recipesRoundTripAndRefuseWhatTheyCannotHonour() throws {
        let tone = PrintTone(burn: 0.5, dodge: 0.25, referenceStops: -0.3)
        let data = try JSONEncoder().encode(tone)
        #expect(try JSONDecoder().decode(PrintTone.self, from: data) == tone)
        let negative = Data(#"{"burn":-1,"dodge":0,"referenceStops":0,"version":"2026-11-05-2"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PrintTone.self, from: negative) }
        #expect(PrintTone.currentVersion == "2026-11-23-1" && PrintTone.versions == ["2026-11-05-2", "2026-11-23-1"])
        let first = Data(#"{"burn":0.5,"dodge":0.25,"referenceStops":-0.3,"version":"2026-11-05-2"}"#.utf8)
        let recorded = try JSONDecoder().decode(PrintTone.self, from: first)
        #expect(recorded.version == "2026-11-05-2" && PrintTone.supports(version: recorded.version), "a recipe on the first version keeps it")
        #expect(try JSONDecoder().decode(PrintTone.self, from: JSONEncoder().encode(recorded)) == recorded)
        #expect(try recorded.shape() == PrintTone(version: PrintTone.currentVersion).shape(), "the two versions share their curve")
        let future = PrintTone(burn: 0.5, dodge: 0, referenceStops: 0, version: "future")
        #expect(throws: PrintToneError.unsupportedVersion("future")) { try future.stops(baseLog2: 0, ratedStops: 0) }
        #expect(throws: PrintToneError.unsupportedVersion("future")) { try future.table(stock: ToyStock.make(), settings: DevelopSettings()) }
    }

    /// The first version's table as it was solved until 2026-11-23, kept here so `2026-11-05-2` is held to it.
    private static func firstVersionTable(_ tone: PrintTone, stock: Stock, settings: DevelopSettings) throws -> [SIMD4<Float>] {
        let rated = settings.exposureStops(boxSpeed: stock.boxSpeed)
        let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        let units = DevelopSettings.printUnits(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
        let encoding = stock.negative.encoding
        let luma = SIMD3<Float>(0.2627, 0.6780, 0.0593)
        let burnColour = try tone.shape().burnColour
        func printed(_ amounts: SIMD3<Float>) -> SIMD3<Float> {
            stock.print.sample(encoded: amounts.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)))
        }
        var values: [SIMD4<Float>] = []
        for index in 0..<PrintToneTableInfo.entries {
            let scene = PrintToneTableInfo.firstStops + Float(index) * PrintToneTableInfo.stepStops
            let stopsHere = try tone.stops(baseLog2: log2(Float(0.18)) + scene, ratedStops: rated)
            guard stopsHere != 0 else { values.append(.zero); continue }
            let colourShare = min(max(-stopsHere, 0) * burnColour, 1)
            let film = stock.negative.sample(encoded: SIMD3(repeating: encoding.encode(encoding.midGray * exp2(scene + rated)))) + offset
            let plain = stopsHere * units
            let unmoved = printed(film)
            let wanted = dot(printed(film + plain), luma)
            let base = dot(unmoved, luma)
            guard base > 1e-5, wanted > 1e-6 else { values.append(SIMD4(plain, colourShare)); continue }
            let target = unmoved * (wanted / base)
            var delta = plain
            let limit = abs(plain) + SIMD3(repeating: 0.002)
            func error(_ d: SIMD3<Float>) -> SIMD3<Float> { printed(film + d) - target }
            var best = delta, bestError = simd_length(error(delta))
            for _ in 0..<8 {
                let e = error(delta)
                let h: Float = 0.004
                func column(_ c: Int) -> SIMD3<Float> {
                    var up = delta, down = delta
                    up[c] += h; down[c] -= h
                    return (error(up) - error(down)) / (2 * h)
                }
                let jacobian = simd_float3x3(column(0), column(1), column(2))
                guard abs(jacobian.determinant) > 1e-9 else { break }
                let step = jacobian.inverse * e
                guard step.x.isFinite, step.y.isFinite, step.z.isFinite else { break }
                delta = (delta - step).clamped(lowerBound: plain - limit, upperBound: plain + limit)
                let size = simd_length(error(delta))
                if size < bestError { best = delta; bestError = size }
            }
            values.append(SIMD4(best, colourShare))
        }
        return values
    }

    /// Settings as Auto makes them and past them: ratings over and under, the lab balance of aims a stop and a half either way
    /// (its print offset in paper stops), and a print exposure.
    private static func settingsAcrossAims(_ stock: Stock) -> [DevelopSettings] {
        var all: [DevelopSettings] = []
        for rating: Float? in [nil, stock.boxSpeed * 4] {
            for lab in [SIMD3<Float>(0.05, 0, -0.05), SIMD3(-0.8, -0.75, -0.7), SIMD3(1.1, 1, 0.95)] {
                for exposure in [Float(0), 0.3] { all.append(DevelopSettings(ratedAt: rating, labBalance: lab, printExposure: exposure)) }
            }
        }
        return all
    }

    private static let tonesAcrossStrengths: [(burn: Float, dodge: Float, reference: Float)] = [(0.3, 0.1, 0), (0.6, 0.4, -0.3), (1.25, 0.5, 1.5), (1, 0, -1.5)]

    private static var everyStock: [Stock] {
        get throws { [LightCompilerBaselineTests.toyStock()] + (try LightCompilerBaselineTests.bakedStocks.map { try Stock.load(from: $0) }) }
    }

    /// A frame saved on the first version renders as it did: its table is the first solve's, to the bit, on every stock.
    @Test func theFirstVersionKeepsItsTableToTheBit() throws {
        for stock in try Self.everyStock {
            for settings in Self.settingsAcrossAims(stock) {
                for strength in Self.tonesAcrossStrengths {
                    let tone = PrintTone(burn: strength.burn, dodge: strength.dodge, referenceStops: strength.reference, version: "2026-11-05-2")
                    let table = try tone.table(stock: stock, settings: settings)
                    let first = try Self.firstVersionTable(tone, stock: stock, settings: settings)
                    #expect(table == first, "\(stock.id) \(settings.labBalance) \(settings.printExposure) \(strength)")
                    #expect(try tone.solved(stock: stock, settings: settings).heldAtWhite.allSatisfy { !$0 }, "the first version holds nothing")
                }
            }
        }
    }

    /// The second version moves only the entries where a channel of the print is at the paper's white, and there it stays
    /// within the solve's own box; every entry the solve answers is the first version's, to the bit.
    @Test func theSecondVersionMovesOnlyWhereThePrintIsAtWhite() throws {
        var held = 0, moved = 0
        for stock in try Self.everyStock {
            let white = stock.print.sample(encoded: SIMD3(repeating: 1))
            let units = DevelopSettings.printUnits(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
            for settings in Self.settingsAcrossAims(stock) {
                let rated = settings.exposureStops(boxSpeed: stock.boxSpeed), encoding = stock.negative.encoding
                let offset = settings.printOffset(densityRange: stock.densityRange, exposurePerUnit: stock.exposurePerUnit)
                for strength in Self.tonesAcrossStrengths {
                    let tone = PrintTone(burn: strength.burn, dodge: strength.dodge, referenceStops: strength.reference)
                    var firstTone = tone
                    firstTone.version = "2026-11-05-2"
                    let first = try firstTone.table(stock: stock, settings: settings)
                    let second = try tone.solved(stock: stock, settings: settings)
                    for i in first.indices {
                        guard second.heldAtWhite[i] else {
                            #expect(second.values[i] == first[i], "\(stock.id) entry \(i) is answered, so it is the first version's")
                            continue
                        }
                        held += 1
                        if second.values[i] != first[i] { moved += 1 }
                        let scene = PrintToneTableInfo.firstStops + Float(i) * PrintToneTableInfo.stepStops
                        let plain = try tone.stops(baseLog2: log2(Float(0.18)) + scene, ratedStops: rated) * units
                        let film = stock.negative.sample(encoded: SIMD3(repeating: encoding.encode(encoding.midGray * exp2(scene + rated)))) + offset
                        let print = stock.print.sample(encoded: (film + plain).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1)))
                        #expect(simd_reduce_min(white - print) <= 0.05, "\(stock.id) entry \(i) is held with no channel near the paper's white")
                        #expect(0.2627 * print.x + 0.6780 * print.y + 0.0593 * print.z > 0.9, "\(stock.id) entry \(i) is held off the paper's white")
                        let value = SIMD3(second.values[i].x, second.values[i].y, second.values[i].z)
                        #expect(simd_reduce_max(abs(value - plain) - (abs(plain) + 0.002)) <= 1e-6, "\(stock.id) entry \(i) leaves the solve's box")
                        #expect(second.values[i].w == first[i].w, "the burn's share of colour is the curve's")
                    }
                }
            }
        }
        if !LightCompilerBaselineTests.bakedStocks.isEmpty { #expect(held > 0 && moved > 0, "the baked stocks reach white: \(held) held, \(moved) moved") }
    }

    /// Where a stock's table does not move between the versions, a frame renders the same bytes on either.
    @Test func aTableThatDoesNotMoveRendersTheSameBytesOnEitherVersion() throws {
        let gpu = try GPU()
        var unmoved: [String] = []
        for stock in try Self.everyStock {
            let renderer = try FilmRenderer(gpu: gpu, stock: stock)
            let settings = DevelopSettings(ratedAt: stock.boxSpeed, labBalance: SIMD3(0.05, 0, -0.05), grain: 1, grainSeed: 37,
                                           halation: stock.halation != nil, sharpen: true)
            let second = PrintTone(burn: 0.6, dodge: 0.3), first = PrintTone(burn: 0.6, dodge: 0.3, version: "2026-11-05-2")
            guard try first.table(stock: stock, settings: settings) == second.table(stock: stock, settings: settings) else { continue }
            unmoved.append(stock.id)
            var a = settings, b = settings
            a.tone = first
            b.tone = second
            let frame = try LightCompilerBaselineTests.frame(gpu)
            #expect(try render(gpu, renderer, frame, a, LightCompilerBaselineTests.width, LightCompilerBaselineTests.height)
                    == render(gpu, renderer, frame, b, LightCompilerBaselineTests.width, LightCompilerBaselineTests.height), "\(stock.id)")
        }
        #expect(unmoved.contains(LightCompilerBaselineTests.toyStock().id), "the toy stock never reaches white")
        if !LightCompilerBaselineTests.bakedStocks.isEmpty { #expect(unmoved.count > 1, "some baked stock's table does not move: \(unmoved)") }
    }

    private func render(_ gpu: GPU, _ renderer: FilmRenderer, _ frame: LinearFrame, _ settings: DevelopSettings, _ width: Int, _ height: Int) throws -> [UInt8] {
        let texture = try renderer.render(frame, settings: settings).image.texture
        var bytes = [UInt8](repeating: 0, count: width * height * 8)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return bytes
    }
}
