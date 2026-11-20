import Foundation

/// From a selection to a patch, in pure functions around one run of the engine (docs/remove-plan.md, section 4.4):
///
///     plan     the selection, carried to the decode's pixels, and the box the model works in
///     prepare  the crop of that box, encoded for the model as a job
///     healed   the patch with no model, where what is round the selection is smooth and nothing has to be imagined
///     finish   the engine's output as a patch: matched to the original at the edge, with its two alphas and its notes
///
/// The model sits between `prepare` and `finish`, and is the queue's to run (`RemovalQueue`); `healed` is asked first, of a
/// new selection (`RemovalSteps.patch`). Constants marked P are the research
/// prototype's (`ObjectClear.swift` and its helpers), which is what was measured; the others are inferences, each with its reason.
/// The steps themselves are in the files beside this one, each a port of the prototype's function it names.
public enum RemovalPipeline {
    /// The crop is the object's box with context on every side: `contextShare` of the object's longer side, kept within
    /// `contextRange`, so a shadow half as long as the object is in the model's view and a small object is not lost in a wide one.
    ///
    /// The crop decides how sharp the fill is. The model's pixels are the working size's, and the prototype's rule (P: `cropRect`,
    /// 384 pixels a side at 512 on the short side) had the model draw a road sign 240 pixels across at half the picture's scale:
    /// enlarged twice to go back in, the leaves it drew were plainly softer than those round them. So the model works at the
    /// picture's own scale wherever the crop fits its largest side (`RemovalPatch.longSideLimit`), which a crop of an object up
    /// to 672 pixels does, and at the largest scale that fits it otherwise. Measured in the helper on the same sign, a
    /// letter box and a part of a tree 520 by 660: at the picture's scale the fill is as sharp as its surround, and at twenty
    /// steps a crop of 512 by 624 takes 2.9 s, one of 1024 by 1344 13 s and 5.4 GB.
    public static let contextShare: Float = 0.5
    public static let contextRange = 128...512
    /// A crop's working sides are made multiples of this, with more context, and `RemovalPatch.shortSide` at least where the
    /// frame allows it. The model compiles for each working size at its first use, seven to ten seconds, and holds one size at
    /// a time; on a coarse grid two removals in a row are likely to share a size.
    public static let sizeStep = 128
    /// The model is given the crop with its median luminance at this, through an sRGB-like curve, 8 bits (P).
    public static let medianTarget: Float = 0.25
    /// The object's mask as the model gets it is grown this many working pixels (inference). P gave the model its mask as it
    /// was, but had grown it 16 decode pixels before the crop, 2 to 5 working pixels on its two runs, because a segmenter's
    /// mask stops short of hair and soft edges; a painted or snapped selection does too. Four, now that a working pixel is often
    /// a pixel of the picture: grown by 0, 2, 6 and 12 the sign came out alike, and a rim left in is what a ghost is made of.
    /// A patch notes what its mask was grown by (`RemovalPatch.Notes.growth`), since making it again undoes exactly that.
    public static let maskGrowth = 4
    /// What a patch with no such note was grown by: every patch made before the note was.
    static let unnotedMaskGrowth = 2
    /// The attention map counts as changed at this and above (P, and the model's own fusion).
    public static let attentionThreshold: UInt8 = 128
    /// The changed area is grown this many working pixels (P, of the short side it was set to work at, 512; here of the
    /// raster's own, 512 to 1344).
    public static func changedGrowth(shortSide: Int) -> Int { max(2, shortSide / 128) }
    /// The blur of the log ratio that matches the fill to the original along the changed area's edge (P: `boundaryMatch`).
    public static func matchBlur(shortSide: Int) -> Int { max(3, shortSide / 96) }
    /// Each alpha's feather, in working pixels: the width of the ramp across its mask's edge (inference). Three is the
    /// narrowest ramp that has a step on each side of the edge, which is what lets a mask be read back from its alpha
    /// (`feathered`). At the prototype's scale that was 9 to 24 decode pixels, about what P cross-faded over; at the picture's
    /// own it is three, across an edge the mask's growth has already put outside the object, and no seam showed there on the
    /// sign at 100 %. A wider ramp at that scale was not tried.
    public static let feather = 3

    /// What the Remove tab selected: coverage over the whole corrected picture, 0 outside and 255 inside, at the brush picture's
    /// size, which need not be the frame's.
    public struct Selection: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let coverage: [UInt8]
        public init(width: Int, height: Int, coverage: [UInt8]) throws {
            guard width > 0, height > 0, coverage.count == width * height else {
                throw RemovalError.invalid("a selection's coverage is its width by its height")
            }
            // Eight bytes at a time: a byte at a time costs a debug build a quarter of a second on a picture selected near its foot.
            let selected = coverage.withUnsafeBytes { bytes -> Bool in
                let words = bytes.count / 8
                for word in 0..<words where bytes.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self) & 0x8080_8080_8080_8080 != 0 {
                    return true
                }
                for byte in (words * 8)..<bytes.count where bytes[byte] >= 128 { return true }
                return false
            }
            guard selected else { throw RemovalError.invalid("nothing is selected") }
            self.width = width; self.height = height; self.coverage = coverage
        }
    }

    /// Where the model will work and what it will be told to remove: the box in the full-size decode, and the object's mask over
    /// that box, one byte a decode pixel, 0 outside and 255 inside.
    public struct Plan: Sendable, Equatable {
        public let box: RemovalPatch.Box
        public let object: [UInt8]
        public let frameWidth: Int
        public let frameHeight: Int
        public init(box: RemovalPatch.Box, object: [UInt8], frameWidth: Int, frameHeight: Int) throws {
            guard object.count == box.width * box.height, box.x + box.width <= frameWidth, box.y + box.height <= frameHeight else {
                throw RemovalError.invalid("a plan's mask is its box's size, inside the frame")
            }
            self.box = box; self.object = object; self.frameWidth = frameWidth; self.frameHeight = frameHeight
        }
    }

    /// The decode's pixels over a plan's box, earlier removals composited, before the lens warp (`FilmPreviews.removalInput`):
    /// scene-linear red, green and blue, `box.width * box.height * 3` values.
    public struct Crop: Sendable, Equatable {
        public let box: RemovalPatch.Box
        public let rgb: [Float16]
        public let decoder: String
        public init(box: RemovalPatch.Box, rgb: [Float16], decoder: String) throws {
            guard rgb.count == box.width * box.height * 3 else { throw RemovalError.invalid("a crop's pixels are its box's size") }
            self.box = box; self.rgb = rgb; self.decoder = decoder
        }
    }

    /// A job ready for the engine, with what `finish` needs to turn its output back into scene light.
    public struct Prepared: Sendable, Equatable {
        public let job: RemovalJob
        public let plan: Plan
        public let crop: Crop
        /// The gain the crop was given before its curve; the output is divided by it.
        public let gain: Float
        /// The crop at the job's size, scene-linear red, green and blue: what the fill is matched to, and the patch's pixels
        /// wherever the model changed nothing.
        public let original: [Float]
    }

    /// The model's working size for a crop of `width` by `height`: the crop's own size where its long side is within
    /// `RemovalPatch.longSideLimit`, and reduced so that it is otherwise, each side the nearest multiple of
    /// `RemovalPatch.sideMultiple`. `cropBox` makes crops whose sides this leaves as they are or brings to the limit and the
    /// grid. A crop's working size follows from its box alone, so a patch made by this rule is made again at the size it has; one
    /// made by the prototype's, at 512 on the short side, is made again at this rule's size for its box, which is larger. A crop
    /// the frame leaves smaller than the model's training size is enlarged to it, as the prototype enlarged every crop.
    public static func workingSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let multiple = RemovalPatch.sideMultiple, limit = RemovalPatch.longSideLimit, least = Double(RemovalPatch.shortSide)
        let long = Double(max(width, height)), short = Double(min(width, height))
        var scale = min(1, Double(limit) / long)
        if short * scale < least { scale = min(Double(limit) / long, least / short) }
        func side(_ pixels: Int) -> Int {
            min(limit, max(RemovalPatch.leastWorkingSide, Int((Double(pixels) * scale / Double(multiple)).rounded()) * multiple))
        }
        return (side(width), side(height))
    }

    /// Step 1 and 2: the selection carried from the corrected picture to the decode's pixels, and the crop's box. `geometry` is the
    /// corrected picture's (`ResolvedLensCorrection.geometry`), `nil` where the lens stage does not warp.
    public static func plan(_ selection: Selection, geometry: LensGeometry?, frameWidth: Int, frameHeight: Int) throws -> Plan {
        let sides = 1...RemovalPatch.Box.limit
        guard sides.contains(frameWidth), sides.contains(frameHeight) else {
            throw RemovalError.invalid("a frame's sides are 1 to \(RemovalPatch.Box.limit) pixels")
        }
        let carried = carried(selection, geometry: geometry, frameWidth: frameWidth, frameHeight: frameHeight)
        // A selection finer than the frame can hold a speck that no decode pixel's middle reaches.
        guard let bounds = carried.bounds else { throw RemovalError.invalid("nothing is selected at the frame's size") }
        let box = try cropBox(around: bounds, frameWidth: frameWidth, frameHeight: frameHeight)
        return try Plan(box: box, object: carried.cut(to: box), frameWidth: frameWidth, frameHeight: frameHeight)
    }

    /// The plan for another run of a removal already made, Try Again and Better: the box is the patch's, and the mask is the one
    /// the first run was planned on, read back from the patch's object alpha.
    ///
    /// That alpha is the mask the model was given, feathered across its edge (`finish`), so at 128 and above it is that mask
    /// again: the object grown by what the patch notes, at the patch's own scale. Shrunk by the same it is the object, and
    /// `prepare` then gives the model the mask it had the first time, however often a removal is tried again. Without the
    /// shrink each run would grow it `maskGrowth` more. A mask too thin to shrink is used as it is.
    public static func plan(retrying patch: RemovalPatch, frameWidth: Int, frameHeight: Int) throws -> Plan {
        let given = patch.objectAlpha.map { $0 >= 128 ? UInt8(255) : 0 }
        let object = shrunk(given, width: patch.width, height: patch.height, by: patch.notes.growth ?? unnotedMaskGrowth)
        let mask = resampled(object.contains(255) ? object : given, width: patch.width, height: patch.height,
                             to: (patch.box.width, patch.box.height))
        guard mask.contains(255) else { throw RemovalError.invalid("the patch's object alpha selects nothing") }
        return try Plan(box: patch.box, object: mask, frameWidth: frameWidth, frameHeight: frameHeight)
    }

    /// Steps 3 to 5: the crop area-resized to the working size, given `medianTarget` and the curve, 8 bits, and the object's mask
    /// at that size grown `maskGrowth`.
    public static func prepare(_ crop: Crop, plan: Plan, steps: Int = RemovalJob.defaultSteps,
                               guidance: Float = RemovalJob.defaultGuidance, seed: UInt64) throws -> Prepared {
        try prepare(crop, plan: plan, steps: steps, guidance: guidance, seed: seed,
                    size: workingSize(width: plan.box.width, height: plan.box.height), wholePixels: false)
    }

    /// `prepare` at a working size that is given, reduced with the prototype's whole pixels if asked (`resized`). Only for the
    /// suite that holds this port against the prototype's files, whose runs were made at 512 on the short side: the app's jobs
    /// are all at `workingSize`.
    static func prepare(_ crop: Crop, plan: Plan, steps: Int, guidance: Float, seed: UInt64, size: (width: Int, height: Int),
                        wholePixels: Bool) throws -> Prepared {
        guard crop.box == plan.box else { throw RemovalError.invalid("a crop is cut to its plan's box") }
        let box = plan.box
        let object = resampled(plan.object, width: box.width, height: box.height, to: size)
        guard object.contains(255) else { throw RemovalError.invalid("nothing is selected") }
        let gain = gain(for: crop)
        let original = resized(crop.rgb, width: box.width, height: box.height, to: size, wholePixels: wholePixels)
        let job = try RemovalJob(width: size.width, height: size.height, image: encoded(original, gain: gain),
                                 mask: grown(object, width: size.width, height: size.height, by: maskGrowth),
                                 steps: steps, guidance: guidance, seed: seed)
        return Prepared(job: job, plan: plan, crop: crop, gain: gain, original: original)
    }

    /// Steps 7 to 11: the output decoded with the job's gain, the changed area from the mask and the attention map, the fill
    /// matched to the original along that area's edge, the two alphas, and the notes: the engine and its settings, the decode, and
    /// the box of a face in `faces` that was not the object and that the changed area reaches into (`redrawnFace`).
    ///
    /// The object throughout is the mask the model was given, the job's, since the model may have redrawn all of it. Outside the
    /// changed area the patch holds the crop's own pixels at the working size, so an alpha that reaches past it mixes like with
    /// like.
    public static func finish(_ output: RemovalOutput, prepared: Prepared, faces: [FaceMeasure], made: Date = Date()) throws -> RemovalPatch {
        let job = prepared.job, plan = prepared.plan, width = job.width, height = job.height
        guard output.width == width, output.height == height else { throw RemovalError.invalid("an output is its job's size") }
        let short = min(width, height)
        let changed = changedArea(object: job.mask, attention: output.attention, width: width, height: height,
                                  growth: changedGrowth(shortSide: short))
        var fill = decoded(output.image, gain: prepared.gain)
        match(&fill, to: prepared.original, hole: changed, width: width, height: height, blur: matchBlur(shortSide: short))

        let objectAlpha = feathered(job.mask, width: width, height: height, by: feather)
        var effectsAlpha = feathered(changed, width: width, height: height, by: feather)
        for i in effectsAlpha.indices where effectsAlpha[i] < objectAlpha[i] { effectsAlpha[i] = objectAlpha[i] }

        let notes = RemovalPatch.Notes(engine: output.engine, weights: output.weights, steps: job.steps, guidance: job.guidance,
                                       seed: job.seed, decoder: prepared.crop.decoder, frameWidth: plan.frameWidth,
                                       frameHeight: plan.frameHeight,
                                       face: redrawnFace(faces, changed: changed, object: job.mask, width: width, height: height, plan: plan),
                                       made: made, growth: maskGrowth)
        // A half float ends at 65504, and a patch refuses a pixel that is not finite.
        let limit = Float(Float16.greatestFiniteMagnitude)
        return try RemovalPatch(box: plan.box, width: width, height: height, rgb: fill.map { Float16(min(max($0, -limit), limit)) },
                                objectAlpha: objectAlpha, effectsAlpha: effectsAlpha, notes: notes)
    }
}
