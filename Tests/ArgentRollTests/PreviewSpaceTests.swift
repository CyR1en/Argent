import ArgentCore
import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ArgentRoll

/// Previews are in the colour space a develop is to write, so they show the colours the file will hold.
@Suite struct PreviewSpaceTests {
    /// Linear Rec. 2020: grays, colours every space holds, then colours past sRGB and past Display P3.
    private static let gray = 0..<4
    private static let saturated = 6..<12
    private static let patches: [SIMD3<Float>] = [
        SIMD3(repeating: 0.002), SIMD3(repeating: 0.18), SIMD3(repeating: 0.5), SIMD3(repeating: 1),
        SIMD3(0.4, 0.3, 0.2), SIMD3(0.2, 0.3, 0.5),
        SIMD3(0.9, 0.05, 0.02), SIMD3(0.02, 0.85, 0.05), SIMD3(0.02, 0.05, 0.9),
        SIMD3(0.02, 0.6, 0.6), SIMD3(0.9, 0.7, 0), SIMD3(0.6, 0.05, 0.5),
    ]

    private func texture(_ gpu: GPU) throws -> MTLTexture {
        let texture = try gpu.makeTexture(width: Self.patches.count, height: 1)
        var values = [Float16]()
        for patch in Self.patches { values += [Float16(patch.x), Float16(patch.y), Float16(patch.z), 1] }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, Self.patches.count, 1), mipmapLevel: 0, withBytes: $0.baseAddress!,
                            bytesPerRow: Self.patches.count * 8)
        }
        return texture
    }

    /// `image`'s 8-bit codes in its own colour space, so nothing converts them.
    private func codes(_ image: CGImage) throws -> [SIMD3<Int>] {
        let space = try #require(image.colorSpace)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.width).map { SIMD3(Int(data[$0 * 4]), Int(data[$0 * 4 + 1]), Int(data[$0 * 4 + 2])) }
    }

    private func worstDifference(_ a: [SIMD3<Int>], _ b: [SIMD3<Int>]) -> Int {
        zip(a, b).map { max(abs($0.x - $1.x), abs($0.y - $1.y), abs($0.z - $1.z)) }.max() ?? 0
    }

    private func previews() throws -> (FilmPreviews, URL) {
        let directory = try temporaryFolder()
        try writeToyStock(id: "toy", in: directory)
        return (try FilmPreviews(stocks: StockLibrary.load(from: directory).stocks), directory)
    }

    /// The claim the feature rests on: a preview holds the codes of the file a develop writes, colours
    /// the space cannot hold included. The two reach those codes by different Core Image paths.
    @Test(arguments: OutputSpace.allCases)
    func aPreviewHoldsTheCodesOfTheFileADevelopWrites(space: OutputSpace) throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gpu = try GPU(maxIdlePoolBytes: 64 << 20), encoder = try ImageEncoder(gpu: gpu)
        let linear = try texture(gpu)

        let preview = try films.displayImage(linear, space: space, maxPixelSize: Self.patches.count)
        #expect(preview.colorSpace?.name == space.colorSpace.name)
        let shown = try codes(preview)
        for format in [OutputFormat.jpeg(quality: 1), .heic(quality: 1), .tiff16] {
            let developed = try encoder.picture(linear, colorSpace: gpu.workingColorSpace, format: format, space: space)
            #expect(developed.colorSpace?.name == space.colorSpace.name)
            let written = try codes(developed)
            #expect(worstDifference(shown, written) <= 1, "\(format) \(space): preview \(shown), file \(written)")
        }
    }

    /// sRGB and Display P3 share a transfer curve, so grays keep their codes and only colour moves;
    /// Adobe RGB's curve is its own, so its dark gray's code does.
    @Test func theSpaceDecidesTheCodes() throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        let linear = try texture(GPU(maxIdlePoolBytes: 64 << 20)), count = Self.patches.count
        let sRGB = try codes(films.displayImage(linear, space: .sRGB, maxPixelSize: count))
        let p3 = try codes(films.displayImage(linear, space: .displayP3, maxPixelSize: count))
        let adobe = try codes(films.displayImage(linear, space: .adobeRGB, maxPixelSize: count))
        #expect(worstDifference(Array(sRGB[Self.gray]), Array(p3[Self.gray])) <= 1, "\(sRGB) \(p3)")
        for patch in Self.saturated { #expect(sRGB[patch] != p3[patch], "patch \(patch): \(sRGB[patch])") }
        #expect(adobe[0] != p3[0], "\(adobe[0]) \(p3[0])")
    }

    @Test func printLimitsAreOfTheSpaceAskedAndKeptApart() async throws {
        let (films, directory) = try previews()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Blacks lifts the print's black off zero, where a transfer curve can tell one space from another.
        let settings = try DevelopSettings(manual: ManualRenderSettings(adjustments: ManualAdjustments(blacks: 100),
                                                                       referenceStops: 0, version: "2026-10-09-1"))
        let p3 = try #require(await films.printLimits(stock: 0, settings: settings, space: .displayP3))
        let adobe = try #require(await films.printLimits(stock: 0, settings: settings, space: .adobeRGB))
        #expect(adobe != p3, "\(adobe)")
        #expect(await films.printLimits(stock: 0, settings: settings, space: .displayP3) == p3)
        #expect(await films.printLimits(stock: 0, settings: settings, space: .adobeRGB) == adobe)
    }

    /// One slot, as settings share one: a new space cancels the last one's render and takes its place, so
    /// the budget holds one picture however often the choice changes, and never serves the wrong space.
    @Test func aNewSpaceTakesThePlaceOfTheLast() throws {
        let cache = RenderedImageCache(byteLimit: 1 << 20)
        let picture = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: OutputSpace.displayP3.colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        let film = { (space: OutputSpace) in
            RenderedImageKey.film("frame|source|apple", stock: 0, stockID: "toy", settings: DevelopSettings(), space: space,
                                  pixels: 100, frameSized: true)
        }
        let neutral = { (space: OutputSpace) in RenderedImageKey.neutral("frame|source|apple", space: space, pixels: 100) }
        for key in [film, neutral] {
            let (p3, sRGB) = (key(.displayP3), key(.sRGB))
            #expect(p3 != sRGB && p3.slot == sRGB.slot)
            let last = cache.beginRequest(for: p3), running = BlockOperation()
            cache.attach(running, to: last)
            #expect(cache.store(picture, for: p3, ticket: last))

            let next = cache.beginRequest(for: sRGB)
            #expect(running.isCancelled && !cache.isCurrent(last))
            #expect(cache.image(for: sRGB, ticket: next) == nil)
            let count = cache.count
            #expect(cache.store(picture, for: sRGB, ticket: next))
            #expect(cache.image(for: p3) == nil && cache.image(for: sRGB) != nil && cache.count == count)
        }
    }
}
