import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ArgentApp

/// The Open roll backdrop's shader, drawn on the Mac's own Metal device into an offscreen texture
/// and read back: the pipeline and its uniforms, the intro, the clear column, the field's grain and
/// its colour, the pointer's pool, a drop and a read, and that a frame is drawn the same twice.
/// Without a Metal device the GPU tests fail on their first line.
@MainActor @Suite struct OpenRollBackdropShaderTests {
    private typealias Motion = OpenRollBackdropMotion
    private typealias Renderer = OpenRollBackdropRenderer

    /// A field as on the page: 1200 by 800 points, a 408-point column in the middle, and the drop
    /// zone at the column's top.
    private static let size = CGSize(width: 1200, height: 800)
    private static let column = CGRect(x: 396, y: 220, width: 408, height: 360)
    private static let heroZone = CGRect(x: 396, y: 220, width: 408, height: 160)
    /// The column grown as the shader keeps it clear.
    private static let grownColumn = column.insetBy(dx: -Renderer.columnMargin, dy: -Renderer.columnMargin)
    /// A place in the open field, well past the clear zone's falloff.
    private static let openPlace = CGPoint(x: 180, y: 400)

    private static let darkPalette = ThemeCatalog.theme(id: "github").darkVersion(id: "dark").palette
    private static let lightPalette = ThemeCatalog.theme(id: "github").light!.palette

    /// One frame read back: its texels in BGRA order, row by row.
    private struct Picture {
        let width: Int, height: Int
        let bytes: [UInt8]

        func texel(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }

        /// The centre in points of each cell, with its coordinates, that `include` keeps.
        func cells(where include: (CGPoint) -> Bool) -> [(x: Int, y: Int)] {
            var out: [(x: Int, y: Int)] = []
            for y in 0..<height {
                for x in 0..<width {
                    let p = CGPoint(x: (CGFloat(x) + 0.5) * Renderer.cell, y: (CGFloat(y) + 0.5) * Renderer.cell)
                    if include(p) { out.append((x, y)) }
                }
            }
            return out
        }

        func litFraction(_ cells: [(x: Int, y: Int)]) -> Double {
            Double(cells.count { texel($0.x, $0.y).a > 0 }) / Double(max(cells.count, 1))
        }
    }

    private static func device() throws -> MTLDevice {
        try #require(MTLCreateSystemDefaultDevice())
    }

    private static func motion(for seconds: Double, pointer: CGPoint? = nil,
                               hero: RollModel.OpenRollHero = .ready) -> Motion {
        var motion = Motion()
        let count = Int((seconds * 60).rounded())
        for _ in 0..<count {
            motion.step(dt: 1.0 / 60, input: Motion.Input(pointer: pointer, hero: hero, reduceMotion: false))
        }
        return motion
    }

    private static func frame(_ motion: Motion, palette: ThemePalette = darkPalette) -> OpenRollBackdropFrame {
        OpenRollBackdropFrame(size: size, column: column, heroZone: heroZone, palette: palette, motion: motion)
    }

    private static func render(_ frame: OpenRollBackdropFrame, with renderer: Renderer) throws -> Picture {
        let cells = Renderer.cells(for: frame.size)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Renderer.pixelFormat, width: cells.width, height: cells.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let buffer = try #require(renderer.draw(frame, to: texture))
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.status == .completed)
        var bytes = [UInt8](repeating: 0, count: cells.width * cells.height * 4)
        texture.getBytes(&bytes, bytesPerRow: cells.width * 4,
                         from: MTLRegionMake2D(0, 0, cells.width, cells.height), mipmapLevel: 0)
        return Picture(width: cells.width, height: cells.height, bytes: bytes)
    }

    private static func isOpenField(_ p: CGPoint) -> Bool {
        !grownColumn.insetBy(dx: -Renderer.widestFalloff, dy: -Renderer.widestFalloff).contains(p)
    }

    private static func near(_ center: CGPoint, _ radius: CGFloat) -> (CGPoint) -> Bool {
        { hypot($0.x - center.x, $0.y - center.y) <= radius }
    }

    @Test func theSourceCompilesAndTheUniformsAgree() throws {
        let renderer = try Renderer(device: Self.device())
        #expect(renderer.shaderUniformsSize > 0)
        #expect(renderer.shaderUniformsSize == MemoryLayout<Renderer.Uniforms>.size)
        #expect(MemoryLayout<Renderer.Uniforms>.size == MemoryLayout<Renderer.Uniforms>.stride)
        #expect(Motion.trailCapacity == 20)
    }

    /// Each uniform starts where the source's own does: two of one size swapped would keep the size.
    @Test func everyUniformStartsWhereTheSourcesDoes() throws {
        let renderer = try Renderer(device: Self.device())
        typealias Uniforms = Renderer.Uniforms
        let mirrored: [(String, Int?)] = [
            ("size", MemoryLayout<Uniforms>.offset(of: \.size)), ("cellPoints", MemoryLayout<Uniforms>.offset(of: \.cellPoints)),
            ("time", MemoryLayout<Uniforms>.offset(of: \.time)), ("column", MemoryLayout<Uniforms>.offset(of: \.column)),
            ("hero", MemoryLayout<Uniforms>.offset(of: \.hero)), ("pointer", MemoryLayout<Uniforms>.offset(of: \.pointer)),
            ("ink", MemoryLayout<Uniforms>.offset(of: \.ink)), ("accent", MemoryLayout<Uniforms>.offset(of: \.accent)),
            ("columnFalloff", MemoryLayout<Uniforms>.offset(of: \.columnFalloff)), ("drop", MemoryLayout<Uniforms>.offset(of: \.drop)),
            ("read", MemoryLayout<Uniforms>.offset(of: \.read)), ("intro", MemoryLayout<Uniforms>.offset(of: \.intro)),
            ("trail", MemoryLayout<Uniforms>.offset(of: \.trail)),
        ]
        #expect(renderer.shaderUniformOffsets.count == mirrored.count)
        for (name, offset) in mirrored {
            #expect(offset != nil, "\(name) has no offset in Swift")
            #expect(renderer.shaderUniformOffsets[name] == offset, "\(name)")
        }
    }

    @Test func theCellsRoundUpAndNeverGiveZero() {
        #expect(Renderer.cells(for: CGSize(width: 1200, height: 800)) == (600, 400))
        #expect(Renderer.cells(for: CGSize(width: 1201, height: 799.5)) == (601, 400))
        #expect(Renderer.cells(for: CGSize(width: 0.5, height: 3)) == (1, 2))
        #expect(Renderer.cells(for: .zero) == (1, 1))
        #expect(Renderer.cells(for: CGSize(width: -10, height: CGFloat.nan)) == (1, 1))
    }

    /// The clear zone's falloff is 110 points, narrower in a narrow field but never under 48.
    @Test func theFalloffNarrowsWithTheRoom() {
        #expect(Renderer.falloff(column: Self.grownColumn, width: 1200) == 110)
        #expect(abs(Renderer.falloff(column: CGRect(x: 100, y: 0, width: 428, height: 100), width: 628) - 60) < 1e-9)
        #expect(Renderer.falloff(column: CGRect(x: 10, y: 0, width: 428, height: 100), width: 448) == 48)
    }

    @Test func beforeTheIntroEveryTexelIsTransparent() throws {
        let renderer = try Renderer(device: Self.device())
        let picture = try Self.render(Self.frame(Motion()), with: renderer)
        #expect(picture.bytes.allSatisfy { $0 == 0 })
    }

    /// After the intro and with no pointer the grown column is clear, and about a tenth of the open
    /// field is lit.
    @Test func theColumnIsClearAndTheOpenFieldIsGrained() throws {
        let renderer = try Renderer(device: Self.device())
        let picture = try Self.render(Self.frame(Self.motion(for: 2)), with: renderer)
        let inColumn = picture.cells { Self.grownColumn.contains($0) }
        #expect(!inColumn.isEmpty)
        #expect(picture.litFraction(inColumn) == 0)
        let open = picture.litFraction(picture.cells(where: Self.isOpenField))
        #expect(open > 0.03 && open < 0.30, "open field lit fraction \(open)")
    }

    /// Far from any light a lit texel is the ink at the palette's strength, premultiplied.
    @Test(arguments: [true, false]) func aLitTexelIsTheInkAtTheStrength(isDark: Bool) throws {
        let renderer = try Renderer(device: Self.device())
        let palette = isDark ? Self.darkPalette : Self.lightPalette
        let picture = try Self.render(Self.frame(Self.motion(for: 2), palette: palette), with: renderer)
        let strength = Double(isDark ? Renderer.darkStrength : Renderer.lightStrength)
        func expected(_ shift: UInt32) -> Double { Double((palette.text >> shift) & 0xff) / 255 * strength * 255 }
        let lit = picture.cells(where: Self.isOpenField).filter { picture.texel($0.x, $0.y).a > 0 }
        #expect(!lit.isEmpty)
        for cell in lit {
            let texel = picture.texel(cell.x, cell.y)
            #expect(abs(Double(texel.a) - strength * 255) <= 1)
            #expect(abs(Double(texel.r) - expected(16)) <= 1)
            #expect(abs(Double(texel.g) - expected(8)) <= 1)
            #expect(abs(Double(texel.b) - expected(0)) <= 1)
        }
    }

    /// A pointer that rests in the open field brings the grain up round it and moves its colour
    /// toward the accent.
    @Test func aRestingPointerRaisesTheGrainInTheAccent() throws {
        let renderer = try Renderer(device: Self.device())
        let palette = Self.darkPalette
        let with = try Self.render(Self.frame(Self.motion(for: 3, pointer: Self.openPlace)), with: renderer)
        let without = try Self.render(Self.frame(Self.motion(for: 3)), with: renderer)
        let round = with.cells(where: Self.near(Self.openPlace, 40))
        let raised = with.litFraction(round), before = without.litFraction(round)
        #expect(raised > before + 0.2, "lit near the pointer \(raised), without it \(before)")

        func component(_ hex: UInt32, _ shift: UInt32) -> Double { Double((hex >> shift) & 0xff) / 255 }
        var distanceToAccent = 0.0, distanceToInk = 0.0
        for cell in round {
            let texel = with.texel(cell.x, cell.y)
            guard texel.a > 0 else { continue }
            let alpha = Double(texel.a)
            let rgb = [Double(texel.r) / alpha, Double(texel.g) / alpha, Double(texel.b) / alpha]
            for (value, shift) in zip(rgb, [UInt32(16), 8, 0]) {
                distanceToAccent += abs(value - component(palette.primaryBottom, shift))
                distanceToInk += abs(value - component(palette.text, shift))
            }
            #expect(alpha > Double(Renderer.darkStrength) * 255 + 1)
        }
        #expect(distanceToAccent < distanceToInk)
    }

    /// A drop and a read each change the field outside the column and leave the column clear.
    @Test(arguments: [RollModel.OpenRollHero.dropTargeted, .reading])
    func theHeroChangesTheFieldButNotTheColumn(hero: RollModel.OpenRollHero) throws {
        let renderer = try Renderer(device: Self.device())
        let rest = try Self.render(Self.frame(Self.motion(for: 2)), with: renderer)
        let active = try Self.render(Self.frame(Self.motion(for: 2, hero: hero)), with: renderer)
        let outside = active.cells { !Self.grownColumn.contains($0) }
        let changed = outside.count { rest.texel($0.x, $0.y) != active.texel($0.x, $0.y) }
        #expect(changed > outside.count / 100, "\(changed) of \(outside.count) texels changed")
        #expect(active.litFraction(active.cells { Self.grownColumn.contains($0) }) == 0)

        let unzoned = OpenRollBackdropFrame(size: Self.size, column: Self.column, heroZone: nil,
                                            palette: Self.darkPalette, motion: Self.motion(for: 2, hero: hero))
        #expect(try Self.render(unzoned, with: renderer).bytes == rest.bytes)
    }

    @Test func theSameFrameDrawsTheSameBytes() throws {
        let renderer = try Renderer(device: Self.device())
        let frame = Self.frame(Self.motion(for: 2.5, pointer: Self.openPlace, hero: .reading))
        #expect(try Self.render(frame, with: renderer).bytes == Self.render(frame, with: renderer).bytes)
    }
}
