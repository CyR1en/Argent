import Metal

/// The film passes' compute pipelines, which no stock changes: a `GPU` makes them once (`GPU.filmPipelines()`) and every
/// `LUTPass`, `PrintPass`, `HalationField` and `ToneBaseField` on it shares them, so preparing each stock's renderer builds
/// only its LUTs and grain.
struct FilmPipelines {
    let negative: MTLComputePipelineState
    let negativeHalation: MTLComputePipelineState
    let negativeToned: MTLComputePipelineState
    let negativeTonedHalation: MTLComputePipelineState
    let print: MTLComputePipelineState
    let printSharpened: MTLComputePipelineState
    let printToned: MTLComputePipelineState
    let printTonedSharpened: MTLComputePipelineState
    let halationSource: MTLComputePipelineState
    let halationMix: MTLComputePipelineState
    let toneBase: ToneBaseField.Kernels
    let toneBaseMap: MTLComputePipelineState

    init(library: MTLLibrary, device: MTLDevice) throws {
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
            return try device.makeComputePipelineState(function: function)
        }
        negative = try pipeline("apply_lut3d")
        negativeHalation = try pipeline("apply_lut3d_halation")
        negativeToned = try pipeline("apply_lut3d_toned")
        negativeTonedHalation = try pipeline("apply_lut3d_halation_toned")
        print = try pipeline("apply_print_lut")
        printSharpened = try pipeline("apply_print_lut_sharpened")
        printToned = try pipeline("apply_print_lut_toned")
        printTonedSharpened = try pipeline("apply_print_lut_sharpened_toned")
        halationSource = try pipeline("halation_source")
        halationMix = try pipeline("halation_mix")
        toneBase = try ToneBaseField.Kernels(library: library, device: device)
        toneBaseMap = try pipeline("tone_base_map")
    }
}
