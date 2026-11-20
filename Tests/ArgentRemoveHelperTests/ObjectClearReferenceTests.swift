import Foundation
import Testing
@testable import ArgentRemoveHelper

/// The pipeline around the graphs against what ObjectClear computed in PyTorch, with no model loaded: each relation of
/// `objectclear_reference.py check` given its own recorded inputs, then the whole loop fed the recorded networks' outputs. Exact
/// where the reference is exact; where it documents a tolerance (goldens/README.md), that tolerance.
@Suite(.enabled(if: Goldens.present, "needs the tensors H1 recorded, in $R/goldens or ARGENT_REMOVE_GOLDENS"))
struct ObjectClearReferenceTests {
    @Test(arguments: Goldens.runs) func theScheduleIsTheRecordedOne(_ run: String) throws {
        let golden = try Goldens(run), schedule = EulerSchedule(steps: golden.steps)
        #expect(schedule.timesteps == (try golden.tensor("timesteps")))
        // Within 3.8e-6 of torch's table, as the reference's own schedule (about 4e-7 of the value).
        #expect(difference(schedule.sigmas, try golden.tensor("sigmas")).worst <= 4e-6)
        #expect(abs(schedule.initialFactor - (try golden.tensor("init_noise_sigma"))[0]) <= 4e-6)
        for i in 0..<golden.steps {
            #expect(try golden.step(i, "unet_timestep") == [schedule.timesteps[i]])
        }
    }

    @Test(arguments: Goldens.runs) func picturesAndMasksBecomeTheRecordedTensors(_ run: String) throws {
        let golden = try Goldens(run), w = golden.width, h = golden.height
        let picture = ObjectClear.pictureTensor(try golden.picture("input", channels: 3), width: w, height: h)
        let mask = ObjectClear.maskTensor(try golden.picture("mask", channels: 1))
        #expect(picture == (try golden.tensor("picture")))
        #expect(mask == (try golden.tensor("mask")))
        let object = ObjectClear.objectAlone(picture, mask: mask)
        #expect(object == (try golden.tensor("image_encoder_input")))
        // Summation order in doubles: the reference is 1.4e-5 from the file, 80 % of values exact.
        let resized = ObjectClear.resizeAntialias(object, channels: 3, width: w, height: h)
        #expect(difference(resized, try golden.tensor("image_encoder_resized")).worst <= 2e-5)
        #expect(ObjectClear.maskLatents(mask, width: w, height: h) == (try golden.tensor("mask_latents")))
    }

    @Test(arguments: Goldens.runs) func theLatentsAreSampledAsThePipelineSamplesThem(_ run: String) throws {
        let golden = try Goldens(run)
        let moments = try golden.tensor("vae_encoder_moments_picture")
        // MPS's half-precision exp: the reference is within 8e-6 of the file, in under 0.01 % of values.
        for (noise, latents) in [("vae_sample_noise_picture", "picture_latents"), ("vae_sample_noise_masked", "masked_picture_latents")] {
            let sampled = ObjectClear.sampleLatents(moments: moments, noise: try golden.tensor(noise))
            let off = difference(sampled, try golden.tensor(latents))
            #expect(off.worst <= 8e-6 && off.differing <= sampled.count / 1000, "\(latents): \(off)")
        }
        let factor = try golden.tensor("init_noise_sigma")[0]
        #expect(ObjectClear.initialLatents(noise: try golden.tensor("initial_noise"), factor: factor) == (try golden.tensor("initial_latents")))
        let states = try golden.tensor("text_states"), fused = try golden.tensor("fused_prompt_states")
        let row = Array(fused[(5 * 2048)..<(6 * 2048)])
        #expect(ObjectClear.fusePrompt(states, row: row) == fused)
    }

    /// Each step from its own recorded inputs, with the recorded sigmas, so what shows is the step's own rounding: none.
    @Test(arguments: Goldens.runs) func everyStepIsTheRecordedStep(_ run: String) throws {
        let golden = try Goldens(run)
        let sigmas = try golden.tensor("sigmas"), maskLatents = try golden.tensor("mask_latents")
        let masked = try golden.tensor("masked_picture_latents"), plane = golden.latentWidth * golden.latentHeight
        for i in 0..<golden.steps {
            let latentsIn = try golden.step(i, "latents_in")
            let sample = ObjectClear.unetSample(latents: latentsIn, sigma: sigmas[i], maskLatents: maskLatents, maskedPictureLatents: masked)
            #expect(Array(repeating: sample, count: golden.batch).flatMap { $0 } == (try golden.step(i, "unet_sample")), "step \(i)")
            let out = try golden.step(i, "unet_out")
            let noise = golden.batch == 1 ? out
                : ObjectClear.guide(unconditional: Array(out[..<(4 * plane)]), conditional: Array(out[(4 * plane)...]), guidance: golden.guidance)
            #expect(noise == (try golden.step(i, "noise_pred")), "step \(i)")
            let stepped = ObjectClear.eulerStep(latents: latentsIn, noise: try golden.step(i, "noise_pred"), sigma: sigmas[i], next: sigmas[i + 1])
            #expect(stepped == (try golden.step(i, "scheduler_out")), "step \(i)")
            if i == 0 {
                let blended = ObjectClear.afterFirstStep(try golden.step(0, "scheduler_out"), pictureLatents: try golden.tensor("picture_latents"),
                                                         noise: try golden.tensor("initial_noise"), nextSigma: sigmas[1], maskLatents: maskLatents)
                #expect(blended == (try golden.step(0, "latents_out")))
            }
        }
    }

    @Test(arguments: Goldens.runs) func theAttentionMapIsThePipelines(_ run: String) throws {
        let golden = try Goldens(run)
        let reduced = try Self.reducedAttention(golden)
        let bytes = try #require(ObjectClear.attentionBytes(reduced, latentWidth: golden.latentWidth, latentHeight: golden.latentHeight))
        #expect(bytes == (try golden.picture("attention_latent", channels: 1, latent: true)))
        let full = AttentionGuidedFusion.resizeBicubic(bytes, width: golden.latentWidth, height: golden.latentHeight,
                                                       toWidth: golden.width, toHeight: golden.height)
        #expect(full == (try golden.picture("attention", channels: 1)))
    }

    @Test(arguments: Goldens.runs) func theDecodersPictureAndTheFusionAreThePipelines(_ run: String) throws {
        let golden = try Goldens(run), w = golden.width, h = golden.height
        let decoderInput = try golden.tensor("final_latents").map { ObjectClear.half($0 / ObjectClear.scaling) }
        #expect(decoderInput == (try golden.tensor("vae_decoder_input")))
        let generated = ObjectClear.pictureBytes(try golden.tensor("vae_decoder_output"), width: w, height: h)
        #expect(generated == (try golden.picture("generated", channels: 3)))
        let fused = AttentionGuidedFusion.fuse(original: try golden.picture("input", channels: 3), removed: generated,
                                               attention: try golden.picture("attention_latent", channels: 1, latent: true), width: w, height: h)
        let recorded = try golden.picture("fused", channels: 3)
        let off = zip(fused, recorded).filter { $0 != $1 }
        // OpenCV blurs in single floats: the reference differs from the file by 1 in 13 to 35 values of 1.2 to 2 million.
        #expect(off.allSatisfy { abs(Int($0) - Int($1)) <= 1 } && off.count <= 64, "\(off.count) values differ")
    }

    /// The whole loop, fed what the networks returned in PyTorch: the loop's arithmetic over every step at once, and its order of
    /// calls. With torch's own sigmas the final latents are the pipeline's to the bit; with this engine's schedule, 4e-6 from
    /// torch's, they move by a few half-float steps in under 1 % of values, which the decoder never sees as more than noise.
    @Test(arguments: Goldens.runs) func theLoopOverRecordedNetworksGivesThePipelinesPicture(_ run: String) async throws {
        let golden = try Goldens(run)
        let states = try golden.tensor("text_states"), pooled = try golden.tensor("pooled_text_states")
        let noises = [try golden.tensor("vae_sample_noise_picture"), try golden.tensor("initial_noise"), try golden.tensor("vae_sample_noise_masked")]
        let recorded = EulerSchedule(timesteps: try golden.tensor("timesteps"), sigmas: try golden.tensor("sigmas"),
                                     initialFactor: try golden.tensor("init_noise_sigma")[0])
        for schedule in [recorded, EulerSchedule(steps: golden.steps)] {
            let networks = try RecordedNetworks(golden)
            let told = StepLog()
            let result = try await ObjectClearRun.run(image: try golden.picture("input", channels: 3), mask: try golden.picture("mask", channels: 1),
                                                      width: golden.width, height: golden.height, steps: golden.steps, guidance: golden.guidance,
                                                      noises: noises, states: states, pooled: pooled, networks: networks,
                                                      schedule: schedule) { told.add($0) }
            #expect(told.all == Array(1...golden.steps))
            #expect(networks.calls == golden.steps * golden.batch, "one UNet call a step at guidance 1, two above it")
            let off = difference(networks.lastLatents, try golden.tensor("vae_decoder_input"))
            if schedule == recorded {
                #expect(off.differing == 0, "final latents with torch's sigmas: \(off)")
            } else {
                #expect(off.worst <= 0.25 && off.differing <= networks.lastLatents.count / 100, "final latents: \(off)")
            }
            #expect(result.attentionLatent == (try golden.picture("attention_latent", channels: 1, latent: true)))
            #expect(result.attention == (try golden.picture("attention", channels: 1)))
            #expect(result.generated == (try golden.picture("generated", channels: 3)))
            #expect(psnr(result.fused, try golden.picture("fused", channels: 3)) > 60)
        }
    }

    /// Column 5 of the raw attention, the conditional branch's mean over its ten heads, in half precision: what the converted UNet
    /// returns as its second output.
    static func reducedAttention(_ golden: Goldens) throws -> [Float] {
        let raw = try golden.tensor("attention_raw"), tokens = (golden.latentWidth / 2) * (golden.latentHeight / 2)
        let first = (golden.batch - 1) * 10
        return (0..<tokens).map { t in
            var sum: Float = 0
            for head in first..<(first + 10) { sum += raw[(head * tokens + t) * 77 + ObjectClear.fuseIndex] }
            return ObjectClear.half(sum / 10)
        }
    }
}

/// The networks as PyTorch ran them on one recorded job: each call answered from the files.
final class RecordedNetworks: ObjectClearNetworks, @unchecked Sendable {
    private let golden: Goldens
    private let row: [Float], moments: [Float], attention: [Float], decoded: [Float]
    private let outs: [[Float]]
    private let lock = NSLock()
    private var made = 0
    private var latents: [Float] = []

    init(_ golden: Goldens) throws {
        self.golden = golden
        let fused = try golden.tensor("fused_prompt_states")
        row = Array(fused[(5 * 2048)..<(6 * 2048)])
        moments = try golden.tensor("vae_encoder_moments_picture")
        attention = try ObjectClearReferenceTests.reducedAttention(golden)
        decoded = try golden.tensor("vae_decoder_output")
        outs = try (0..<golden.steps).map { try golden.step($0, "unet_out") }
    }

    var calls: Int { lock.withLock { made } }
    var lastLatents: [Float] { lock.withLock { latents } }

    func encodeObject(_ object: [Float]) async throws -> [Float] { row }
    func encodePicture(_ picture: [Float], width: Int, height: Int) async throws -> [Float] { moments }

    func unet(sample: [Float], timestep: Float, states: [Float], pooled: [Float], timeIDs: [Float], width: Int, height: Int)
        async throws -> (noise: [Float], attention: [Float]) {
        let call = lock.withLock { () -> Int in made += 1; return made - 1 }
        let step = call / golden.batch, plane = 4 * golden.latentWidth * golden.latentHeight
        let out = outs[step]
        let unconditional = !states.contains { $0 != 0 }
        let noise = golden.batch == 1 ? out : unconditional ? Array(out[..<plane]) : Array(out[plane...])
        return (noise, attention)
    }

    func decode(_ latents: [Float], width: Int, height: Int) async throws -> [Float] {
        lock.withLock { self.latents = latents }
        return decoded
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [Int] = []
    func add(_ step: Int) { lock.withLock { steps.append(step) } }
    var all: [Int] { lock.withLock { steps } }
}
