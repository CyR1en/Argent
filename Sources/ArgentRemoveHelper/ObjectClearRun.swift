import Foundation

/// One job through the four networks: the reference's `run`, with the graphs' reduced attention in place of the raw one, as
/// `objectclear_parity.py`'s `run_mode` calls them. What the PyTorch pipeline returns, to the byte where the graphs agree.
enum ObjectClearRun {
    struct Result: Sendable {
        /// The engine's picture, `H x W x 3`: the decoder's, fused with the input outside the attention map (`out.png`).
        let fused: [UInt8]
        /// The attention map at the working size, `H x W` (`attn.png`).
        let attention: [UInt8]
        /// The map at the latents' size, as the fusion reads it.
        let attentionLatent: [UInt8]
        /// The decoder's picture before the fusion.
        let generated: [UInt8]
    }

    /// The job's three normal draws, in the generator's order: the picture's sample, the start, the masked picture's sample.
    static func draws(seed: UInt64, width: Int, height: Int) -> [[Float]] {
        var draws = NoiseDraws(seed: seed)
        let count = 4 * (width / ObjectClear.latentScale) * (height / ObjectClear.latentScale)
        return (0..<3).map { _ in draws.normal(count) }
    }

    /// - Parameters:
    ///   - image: `H x W x 3` bytes at the working size; `mask` `H x W`, the object at 128 and up.
    ///   - noises: the three draws (`draws(seed:width:height:)`, or a recording's).
    ///   - states, pooled: the fixed text states (`ObjectClearFolder.textStates`).
    ///   - schedule: the steps' sigmas, `EulerSchedule(steps:)` unless a test gives torch's own table.
    ///   - step: told each finished step, from 1; throwing from it stops the run between two steps.
    static func run(image: [UInt8], mask: [UInt8], width: Int, height: Int, steps: Int, guidance: Float, noises: [[Float]],
                    states: [Float], pooled: [Float], networks: some ObjectClearNetworks, schedule given: EulerSchedule? = nil,
                    step: (Int) async throws -> Void = { _ in }) async throws -> Result {
        let h = height / ObjectClear.latentScale, w = width / ObjectClear.latentScale
        let picture = ObjectClear.pictureTensor(image, width: width, height: height)
        let objectMask = ObjectClear.maskTensor(mask)
        let object = ObjectClear.resizeAntialias(ObjectClear.objectAlone(picture, mask: objectMask), channels: 3, width: width, height: height)
        let row = ObjectClear.half(try await networks.encodeObject(object))
        let fusedStates = ObjectClear.fusePrompt(states, row: row)
        let moments = ObjectClear.half(try await networks.encodePicture(picture, width: width, height: height))
        let pictureLatents = ObjectClear.sampleLatents(moments: moments, noise: noises[0])
        let maskedLatents = ObjectClear.sampleLatents(moments: moments, noise: noises[2])
        let maskLatents = ObjectClear.maskLatents(objectMask, width: width, height: height)

        let schedule = given ?? EulerSchedule(steps: steps)
        var latents = ObjectClear.initialLatents(noise: noises[1], factor: schedule.initialFactor)
        let timeIDs = [Float(height), Float(width), 0, 0, Float(height), Float(width)]
        // The unconditional branch is zeros for both text inputs; at guidance 1 it is not run.
        let noStates = guidance > 1 ? [Float](repeating: 0, count: states.count) : []
        let noPooled = guidance > 1 ? [Float](repeating: 0, count: pooled.count) : []
        var seen: [Float] = []
        for i in 0..<steps {
            let sample = ObjectClear.unetSample(latents: latents, sigma: schedule.sigmas[i], maskLatents: maskLatents,
                                                maskedPictureLatents: maskedLatents)
            let conditional = try await networks.unet(sample: sample, timestep: schedule.timesteps[i], states: fusedStates, pooled: pooled,
                                                      timeIDs: timeIDs, width: width, height: height)
            var noise = ObjectClear.half(conditional.noise)
            seen = conditional.attention
            if guidance > 1 {
                let unconditional = try await networks.unet(sample: sample, timestep: schedule.timesteps[i], states: noStates, pooled: noPooled,
                                                            timeIDs: timeIDs, width: width, height: height)
                noise = ObjectClear.guide(unconditional: ObjectClear.half(unconditional.noise), conditional: noise, guidance: guidance)
            }
            latents = ObjectClear.eulerStep(latents: latents, noise: noise, sigma: schedule.sigmas[i], next: schedule.sigmas[i + 1])
            if i == 0 {
                latents = ObjectClear.afterFirstStep(latents, pictureLatents: pictureLatents, noise: noises[1],
                                                     nextSigma: schedule.sigmas[1], maskLatents: maskLatents)
            }
            try await step(i + 1)
        }
        guard let attentionLatent = ObjectClear.attentionBytes(seen, latentWidth: w, latentHeight: h) else {
            throw ObjectClearError.failed("the UNet's attention map is flat: the call failed")
        }
        let decoded = try await networks.decode(latents.map { ObjectClear.half($0 / ObjectClear.scaling) }, width: width, height: height)
        let generated = ObjectClear.pictureBytes(decoded, width: width, height: height)
        let fused = AttentionGuidedFusion.fuse(original: image, removed: generated, attention: attentionLatent, width: width, height: height)
        let attention = AttentionGuidedFusion.resizeBicubic(attentionLatent, width: w, height: h, toWidth: width, toHeight: height)
        return Result(fused: fused, attention: attention, attentionLatent: attentionLatent, generated: generated)
    }
}
