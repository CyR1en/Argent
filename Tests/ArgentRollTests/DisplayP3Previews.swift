import ArgentCore
import CoreGraphics
import Foundation
@testable import ArgentRoll

/// The preview calls in Display P3, for the tests about what a picture is made from and when, whose
/// answers do not depend on its colour space. The app has to name a space at every call, so none can
/// show a colour space other than the one a develop is to write; `PreviewSpaceTests` tests that one.
extension FilmPreviews {
    func cachedFilm(_ frame: Frame, stock: Int, settings: DevelopSettings, maxPixelSize: Int) -> CGImage? {
        cachedFilm(frame, stock: stock, settings: settings, space: .displayP3, maxPixelSize: maxPixelSize)
    }

    func film(_ frame: Frame, stock: Int, settings: DevelopSettings, maxPixelSize: Int,
              priority: Operation.QueuePriority = .normal, frameViewSide: Int? = nil) async -> CGImage? {
        await film(frame, stock: stock, settings: settings, space: .displayP3, maxPixelSize: maxPixelSize,
                   priority: priority, frameViewSide: frameViewSide)
    }

    func cachedFrameFilm(_ frame: Frame, stock: Int, settings: DevelopSettings, pixels: Int) -> CGImage? {
        cachedFrameFilm(frame, stock: stock, settings: settings, space: .displayP3, pixels: pixels)
    }

    func cachedFrameNeutral(_ frame: Frame, lens: LensSettings, pixels: Int) -> CGImage? {
        cachedFrameNeutral(frame, lens: lens, space: .displayP3, pixels: pixels)
    }

    func isRefinedFrameFilm(_ image: CGImage, frame: Frame, stock: Int, settings: DevelopSettings, pixels: Int) -> Bool {
        isRefinedFrameFilm(image, frame: frame, stock: stock, settings: settings, space: .displayP3, pixels: pixels)
    }

    func frameFilm(_ frame: Frame, stock: Int, settings: DevelopSettings, pixels: Int,
                   priority: Operation.QueuePriority = .veryHigh) async -> CGImage? {
        await frameFilm(frame, stock: stock, settings: settings, space: .displayP3, pixels: pixels, priority: priority)
    }

    func frameNeutral(_ frame: Frame, lens: LensSettings, pixels: Int, priority: Operation.QueuePriority = .veryHigh) async -> CGImage? {
        await frameNeutral(frame, lens: lens, space: .displayP3, pixels: pixels, priority: priority)
    }

    func printLimits(stock: Int, settings: DevelopSettings) async -> PrintLimits? {
        await printLimits(stock: stock, settings: settings, space: .displayP3)
    }
}

extension RenderedImageKey {
    static func film(_ decode: String, stock: Int, stockID: String, settings: DevelopSettings,
                     pixels: Int, frameSized: Bool = false, refined: Bool = false) -> Self {
        film(decode, stock: stock, stockID: stockID, settings: settings, space: .displayP3, pixels: pixels,
             frameSized: frameSized, refined: refined)
    }

    static func neutral(_ decode: String, pixels: Int, refined: Bool = false) -> Self {
        neutral(decode, space: .displayP3, pixels: pixels, refined: refined)
    }
}
