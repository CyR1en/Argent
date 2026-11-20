import ArgentCore
import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ArgentApp

/// GPU tests for `FrameSurroundRenderer`: Metal compilation, Swift/Metal uniform layout reflection,
/// top/bottom and left/right spatial edge matching, theme polarity bounds on extreme images,
/// boundary continuity (no ghost outline when a pinched photo shrinks inside `photoRect`),
/// crossfade blending, and drawable sizing.
@MainActor @Suite struct FrameSurroundShaderTests {
    private typealias Renderer = FrameSurroundRenderer
    private static let darkPalette = ThemeCatalog.theme(id: "graphite").darkVersion(id: "dark").palette
    private static let lightPalette = ThemeCatalog.theme(id: "graphite").light!.palette

    private struct RenderedImage {
        let width: Int
        let height: Int
        /// BGRA8 bytes row by row from top-left.
        let bytes: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let i = (y * width + x) * 4
            return (Double(bytes[i + 2]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i]) / 255)
        }

        func mean(in rect: CGRect) -> (r: Double, g: Double, b: Double) {
            let x0 = max(0, Int(rect.minX)), x1 = min(width, Int(rect.maxX))
            let y0 = max(0, Int(rect.minY)), y1 = min(height, Int(rect.maxY))
            var sr = 0.0, sg = 0.0, sb = 0.0, count = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let p = pixel(x, y)
                    sr += p.r; sg += p.g; sb += p.b
                    count += 1
                }
            }
            let n = Double(max(1, count))
            return (sr / n, sg / n, sb / n)
        }

        static func luminance(_ rgb: (r: Double, g: Double, b: Double)) -> Double {
            func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(rgb.r) + 0.7152 * lin(rgb.g) + 0.0722 * lin(rgb.b)
        }
    }

    private static func device() throws -> MTLDevice {
        try #require(MTLCreateSystemDefaultDevice())
    }

    /// Creates a solid or split RGBA8 `CGImage` in `space`.
    /// Row 0 in `CGImage` pixel data is visually at the top (`y < height / 2` is the upper half).
    private static func makeTestImage(
        width: Int,
        height: Int,
        space: OutputSpace = .sRGB,
        fill: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = fill(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ))
    }

    private static func render(
        _ state: FrameSurroundDrawState,
        textures: FrameSurroundTextureSet,
        with renderer: Renderer
    ) throws -> RenderedImage {
        let size = Renderer.drawableSize(for: state.viewSize)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Renderer.pixelFormat, width: size.width, height: size.height, mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let target = try #require(renderer.device.makeTexture(descriptor: desc))
        let buffer = try #require(renderer.draw(state, textures: textures, to: target))
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.status == .completed)
        var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
        target.getBytes(
            &bytes, bytesPerRow: size.width * 4,
            from: MTLRegionMake2D(0, 0, size.width, size.height), mipmapLevel: 0
        )
        return RenderedImage(width: size.width, height: size.height, bytes: bytes)
    }

    private static func upload(
        _ sample: FrameSurroundSample,
        into textures: FrameSurroundTextureSet,
        keepPrevious: Bool = false,
        with renderer: Renderer
    ) throws {
        let buffer = try #require(renderer.uploadAndBlur(sample, into: textures, keepPrevious: keepPrevious))
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.status == .completed)
    }

    @Test func theShaderCompilesAndUniformOffsetsMatchSwift() throws {
        let renderer = try Renderer(device: Self.device())
        #expect(renderer.shaderUniformsSize == MemoryLayout<Renderer.Uniforms>.size)
        #expect(renderer.shaderUniformOffsets["viewSize"] == MemoryLayout<Renderer.Uniforms>.offset(of: \.viewSize))
        #expect(renderer.shaderUniformOffsets["workspaceSize"] == MemoryLayout<Renderer.Uniforms>.offset(of: \.workspaceSize))
        #expect(renderer.shaderUniformOffsets["photoRect"] == MemoryLayout<Renderer.Uniforms>.offset(of: \.photoRect))
        #expect(renderer.shaderUniformOffsets["prevPhotoRect"] == MemoryLayout<Renderer.Uniforms>.offset(of: \.prevPhotoRect))
        #expect(renderer.shaderUniformOffsets["baseColor"] == MemoryLayout<Renderer.Uniforms>.offset(of: \.baseColor))
        #expect(renderer.shaderUniformOffsets["intensity"] == MemoryLayout<Renderer.Uniforms>.offset(of: \.intensity))
        #expect(renderer.shaderUniformOffsets["blend"] == MemoryLayout<Renderer.Uniforms>.offset(of: \.blend))
        #expect(renderer.shaderUniformOffsets["hasCurrent"] == MemoryLayout<Renderer.Uniforms>.offset(of: \.hasCurrent))
        #expect(renderer.shaderUniformOffsets["hasPrevious"] == MemoryLayout<Renderer.Uniforms>.offset(of: \.hasPrevious))
        #expect(renderer.shaderUniformOffsets["transferMode"] == MemoryLayout<Renderer.Uniforms>.offset(of: \.transferMode))
    }

    @Test func topAndBottomSurroundMatchThePhotosVerticalEdges() throws {
        let renderer = try Renderer(device: Self.device())
        let textures = FrameSurroundTextureSet()
        // Row 0 in CGImage data is visually TOP: vibrant sky blue top half, warm orange bottom half.
        let image = try Self.makeTestImage(width: 96, height: 64) { _, y in
            y < 32 ? (40, 125, 240) : (240, 130, 35)
        }
        let sample = try #require(FrameSurroundSample.extract(from: image, targetSpace: .sRGB))
        try Self.upload(sample, into: textures, with: renderer)

        let viewSize = CGSize(width: 400, height: 400)
        let photoRect = CGRect(x: 20, y: 110, width: 360, height: 180)
        let state = FrameSurroundDrawState(
            viewSize: viewSize, workspaceSize: viewSize, photoRect: photoRect, previousPhotoRect: nil,
            palette: Self.darkPalette, outputSpace: .sRGB, intensity: 0.75, blend: 1,
            hasCurrent: true, hasPrevious: false
        )
        let rendered = try Self.render(state, textures: textures, with: renderer)

        let above = rendered.mean(in: CGRect(x: 120, y: 40, width: 160, height: 50))
        let below = rendered.mean(in: CGRect(x: 120, y: 310, width: 160, height: 50))
        #expect(above.b > above.r + 0.04, "Expected cool blue above photo, got \(above)")
        #expect(below.r > below.b + 0.04, "Expected warm orange below photo, got \(below)")
    }

    @Test func portraitLeftAndRightSurroundMatchHorizontalEdges() throws {
        let renderer = try Renderer(device: Self.device())
        let textures = FrameSurroundTextureSet()
        // Warm tungsten lanterns on the left half, cool cyan reflections on the right half.
        let image = try Self.makeTestImage(width: 64, height: 96) { x, _ in
            x < 32 ? (235, 110, 40) : (35, 145, 230)
        }
        let sample = try #require(FrameSurroundSample.extract(from: image, targetSpace: .sRGB))
        try Self.upload(sample, into: textures, with: renderer)

        let viewSize = CGSize(width: 400, height: 320)
        let photoRect = CGRect(x: 120, y: 20, width: 160, height: 240)
        let state = FrameSurroundDrawState(
            viewSize: viewSize, workspaceSize: viewSize, photoRect: photoRect, previousPhotoRect: nil,
            palette: Self.darkPalette, outputSpace: .sRGB, intensity: 0.75, blend: 1,
            hasCurrent: true, hasPrevious: false
        )
        let rendered = try Self.render(state, textures: textures, with: renderer)

        let left = rendered.mean(in: CGRect(x: 20, y: 80, width: 80, height: 120))
        let right = rendered.mean(in: CGRect(x: 300, y: 80, width: 80, height: 120))
        #expect(left.r > left.b + 0.04, "Expected warm left surround, got \(left)")
        #expect(right.b > right.r + 0.04, "Expected cool right surround, got \(right)")
    }

    @Test func zeroIntensityAndMissingSampleMatchNeutralPhotoSurround() throws {
        let renderer = try Renderer(device: Self.device())
        let textures = FrameSurroundTextureSet()
        let image = try Self.makeTestImage(width: 64, height: 48) { _, _ in (250, 40, 40) }
        let sample = try #require(FrameSurroundSample.extract(from: image, targetSpace: .sRGB))
        try Self.upload(sample, into: textures, with: renderer)

        let viewSize = CGSize(width: 240, height: 240)
        let photoRect = CGRect(x: 20, y: 60, width: 200, height: 120)
        let expectedR = Double((Self.darkPalette.photoSurround >> 16) & 0xff) / 255
        let expectedG = Double((Self.darkPalette.photoSurround >> 8) & 0xff) / 255
        let expectedB = Double(Self.darkPalette.photoSurround & 0xff) / 255

        for (intensity, hasCurrent) in [(Float(0), true), (Float(0.8), false)] {
            let state = FrameSurroundDrawState(
                viewSize: viewSize, workspaceSize: viewSize, photoRect: photoRect, previousPhotoRect: nil,
                palette: Self.darkPalette, outputSpace: .sRGB, intensity: intensity, blend: 1,
                hasCurrent: hasCurrent, hasPrevious: false
            )
            let rendered = try Self.render(state, textures: textures, with: renderer)
            let mean = rendered.mean(in: CGRect(x: 40, y: 10, width: 160, height: 40))
            #expect(abs(mean.r - expectedR) < 0.01)
            #expect(abs(mean.g - expectedG) < 0.01)
            #expect(abs(mean.b - expectedB) < 0.01)
        }
    }

    @Test func themePolarityKeepsExtremeFramesBoundedInDarkAndLightMode() throws {
        let renderer = try Renderer(device: Self.device())
        let viewSize = CGSize(width: 240, height: 240)
        let photoRect = CGRect(x: 20, y: 60, width: 200, height: 120)

        let whiteImage = try Self.makeTestImage(width: 48, height: 32) { _, _ in (255, 255, 255) }
        let blackImage = try Self.makeTestImage(width: 48, height: 32) { _, _ in (0, 0, 0) }
        let whiteSample = try #require(FrameSurroundSample.extract(from: whiteImage, targetSpace: .sRGB))
        let blackSample = try #require(FrameSurroundSample.extract(from: blackImage, targetSpace: .sRGB))

        // White frame in Dark mode stays subdued (never blinds the dark workspace).
        let darkTextures = FrameSurroundTextureSet()
        try Self.upload(whiteSample, into: darkTextures, with: renderer)
        let darkWhite = try Self.render(
            FrameSurroundDrawState(
                viewSize: viewSize, workspaceSize: viewSize, photoRect: photoRect, previousPhotoRect: nil,
                palette: Self.darkPalette, outputSpace: .sRGB, intensity: 1.0, blend: 1,
                hasCurrent: true, hasPrevious: false
            ),
            textures: darkTextures, with: renderer
        )
        let darkWhiteLuma = RenderedImage.luminance(darkWhite.mean(in: CGRect(x: 40, y: 10, width: 160, height: 40)))
        #expect(darkWhiteLuma < 0.25, "White photo in dark mode should stay dark-gallery bounded: \(darkWhiteLuma)")

        // Black frame in Light mode stays light and airy (never turns the light workspace gloomy).
        let lightTextures = FrameSurroundTextureSet()
        try Self.upload(blackSample, into: lightTextures, with: renderer)
        let lightBlack = try Self.render(
            FrameSurroundDrawState(
                viewSize: viewSize, workspaceSize: viewSize, photoRect: photoRect, previousPhotoRect: nil,
                palette: Self.lightPalette, outputSpace: .sRGB, intensity: 1.0, blend: 1,
                hasCurrent: true, hasPrevious: false
            ),
            textures: lightTextures, with: renderer
        )
        let lightBlackLuma = RenderedImage.luminance(lightBlack.mean(in: CGRect(x: 40, y: 10, width: 160, height: 40)))
        #expect(lightBlackLuma > 0.38, "Black photo in light mode should stay airy: \(lightBlackLuma)")

        // White frame in Middle gray Dark (base 0x777777, baseY ≈ 0.184) must stay mid-gray bounded
        // rather than overshooting near-white like an uncapped dark-gallery multiplier would.
        let middleGrayDark = ThemeCatalog.theme(id: "middle-gray").darkVersion(id: "dark").palette
        let middleGrayWhite = try Self.render(
            FrameSurroundDrawState(
                viewSize: viewSize, workspaceSize: viewSize, photoRect: photoRect, previousPhotoRect: nil,
                palette: middleGrayDark, outputSpace: .sRGB, intensity: 1.0, blend: 1,
                hasCurrent: true, hasPrevious: false
            ),
            textures: darkTextures, with: renderer
        )
        let middleGrayWhiteLuma = RenderedImage.luminance(middleGrayWhite.mean(in: CGRect(x: 40, y: 10, width: 160, height: 40)))
        #expect(middleGrayWhiteLuma < 0.36, "White photo in Middle gray Dark should stay bounded: \(middleGrayWhiteLuma)")
    }

    @Test func surroundIsContinuousAcrossThePhotoBoundary() throws {
        let renderer = try Renderer(device: Self.device())
        let textures = FrameSurroundTextureSet()
        // High-contrast vertical & horizontal variation to stress boundary sampling.
        let image = try Self.makeTestImage(width: 64, height: 96) { x, y in
            y < 48 ? (x < 32 ? (185, 205, 230) : (210, 215, 225)) : (115, 88, 62)
        }
        let sample = try #require(FrameSurroundSample.extract(from: image, targetSpace: .sRGB))
        try Self.upload(sample, into: textures, with: renderer)

        let viewSize = CGSize(width: 400, height: 320)
        let photoRect = CGRect(x: 120, y: 40, width: 160, height: 240)
        for palette in [Self.darkPalette, Self.lightPalette] {
            let rendered = try Self.render(
                FrameSurroundDrawState(
                    viewSize: viewSize, workspaceSize: viewSize, photoRect: photoRect, previousPhotoRect: nil,
                    palette: palette, outputSpace: .sRGB, intensity: 0.85, blend: 1,
                    hasCurrent: true, hasPrevious: false
                ),
                textures: textures, with: renderer
            )

            // Sample strips immediately outside vs. immediately inside each photoRect edge: when a
            // pinched photograph shrinks transiently inside `photoRect`, there must be no sharp
            // luminance step or ghost outline along `photoRect`.
            let leftOutside = rendered.mean(in: CGRect(x: 114, y: 80, width: 5, height: 160))
            let leftInside = rendered.mean(in: CGRect(x: 121, y: 80, width: 5, height: 160))
            let rightInside = rendered.mean(in: CGRect(x: 274, y: 80, width: 5, height: 160))
            let rightOutside = rendered.mean(in: CGRect(x: 281, y: 80, width: 5, height: 160))
            let topOutside = rendered.mean(in: CGRect(x: 140, y: 34, width: 120, height: 5))
            let topInside = rendered.mean(in: CGRect(x: 140, y: 41, width: 120, height: 5))
            let bottomInside = rendered.mean(in: CGRect(x: 140, y: 274, width: 120, height: 5))
            let bottomOutside = rendered.mean(in: CGRect(x: 140, y: 281, width: 120, height: 5))

            for (a, b) in [
                (leftOutside, leftInside),
                (rightInside, rightOutside),
                (topOutside, topInside),
                (bottomInside, bottomOutside),
            ] {
                let maxChannelDelta = max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b)))
                #expect(maxChannelDelta < 0.015, "Unexpected step across photoRect boundary: \(a) vs \(b)")
            }
        }
    }

    @Test func crossfadeBlendsSmoothlyBetweenPreviousAndCurrentFields() throws {
        let renderer = try Renderer(device: Self.device())
        let textures = FrameSurroundTextureSet()
        let blue = try #require(FrameSurroundSample.extract(
            from: try Self.makeTestImage(width: 48, height: 32) { _, _ in (30, 100, 240) }, targetSpace: .sRGB
        ))
        let orange = try #require(FrameSurroundSample.extract(
            from: try Self.makeTestImage(width: 48, height: 32) { _, _ in (240, 120, 30) }, targetSpace: .sRGB
        ))
        try Self.upload(blue, into: textures, keepPrevious: false, with: renderer)
        try Self.upload(orange, into: textures, keepPrevious: true, with: renderer)

        let viewSize = CGSize(width: 240, height: 240)
        let photoRect = CGRect(x: 20, y: 60, width: 200, height: 120)
        func sampleAt(_ blend: Float) throws -> (r: Double, g: Double, b: Double) {
            let rendered = try Self.render(
                FrameSurroundDrawState(
                    viewSize: viewSize, workspaceSize: viewSize, photoRect: photoRect, previousPhotoRect: photoRect,
                    palette: Self.darkPalette, outputSpace: .sRGB, intensity: 0.8, blend: blend,
                    hasCurrent: true, hasPrevious: true
                ),
                textures: textures, with: renderer
            )
            return rendered.mean(in: CGRect(x: 40, y: 12, width: 160, height: 36))
        }

        let start = try sampleAt(0)
        let mid = try sampleAt(0.5)
        let end = try sampleAt(1)
        #expect(start.b > start.r + 0.03)
        #expect(end.r > end.b + 0.03)
        #expect(mid.r > start.r && mid.r < end.r)
        #expect(mid.b < start.b && mid.b > end.b)
    }

    @Test func backToBackAsyncUploadsDoNotCorruptInFlightCommandBuffers() throws {
        let renderer = try Renderer(device: Self.device())
        let textures = FrameSurroundTextureSet()
        let blue = try #require(FrameSurroundSample.extract(
            from: try Self.makeTestImage(width: 48, height: 32) { _, _ in (20, 90, 245) }, targetSpace: .sRGB
        ))
        let orange = try #require(FrameSurroundSample.extract(
            from: try Self.makeTestImage(width: 48, height: 32) { _, _ in (245, 115, 25) }, targetSpace: .sRGB
        ))

        let viewSize = CGSize(width: 240, height: 240)
        let photoRect = CGRect(x: 20, y: 60, width: 200, height: 120)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Renderer.pixelFormat, width: 240, height: 240, mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let target1 = try #require(renderer.device.makeTexture(descriptor: desc))
        let target2 = try #require(renderer.device.makeTexture(descriptor: desc))

        let state = FrameSurroundDrawState(
            viewSize: viewSize, workspaceSize: viewSize, photoRect: photoRect, previousPhotoRect: nil,
            palette: Self.darkPalette, outputSpace: .sRGB, intensity: 0.85, blend: 1,
            hasCurrent: true, hasPrevious: false
        )

        // Commit both upload+draw command buffers back-to-back without waiting in between.
        let buf1 = try #require(renderer.uploadAndBlur(blue, into: textures, keepPrevious: false))
        let draw1 = try #require(renderer.draw(state, textures: textures, to: target1, on: buf1))
        draw1.commit()

        let buf2 = try #require(renderer.uploadAndBlur(orange, into: textures, keepPrevious: true))
        let draw2 = try #require(renderer.draw(state, textures: textures, to: target2, on: buf2))
        draw2.commit()

        draw1.waitUntilCompleted()
        draw2.waitUntilCompleted()
        #expect(draw1.status == .completed && draw2.status == .completed)

        func read(_ texture: MTLTexture) -> RenderedImage {
            var bytes = [UInt8](repeating: 0, count: 240 * 240 * 4)
            texture.getBytes(&bytes, bytesPerRow: 240 * 4, from: MTLRegionMake2D(0, 0, 240, 240), mipmapLevel: 0)
            return RenderedImage(width: 240, height: 240, bytes: bytes)
        }
        let first = read(target1).mean(in: CGRect(x: 40, y: 12, width: 160, height: 36))
        let second = read(target2).mean(in: CGRect(x: 40, y: 12, width: 160, height: 36))
        #expect(first.b > first.r + 0.03, "First async upload should stay blue, got \(first)")
        #expect(second.r > second.b + 0.03, "Second async upload should be orange, got \(second)")
    }

    @Test func drawableSizeClampsLargeDisplaysAndInvalidInputs() {
        #expect(Renderer.drawableSize(for: CGSize(width: 1200, height: 800)) == (1200, 800))
        let capped = Renderer.drawableSize(for: CGSize(width: 3200, height: 1600))
        #expect(capped == (1600, 800))
        #expect(Renderer.drawableSize(for: .zero) == (1, 1))
        #expect(Renderer.drawableSize(for: CGSize(width: CGFloat.nan, height: 400)) == (1, 1))
    }
}
