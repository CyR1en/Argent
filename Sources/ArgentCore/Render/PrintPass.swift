import Metal
import os
import Foundation

/// Two aligned float4s followed by three uints; matches Metal's 48-byte struct stride.
struct ToneCurveParameters {
    var startSlope = SIMD4<Float>(repeating: 1)
    var endSlope = SIMD4<Float>(repeating: 1)
    var activeMask: UInt32 = 0
    var tableSize: UInt32 = UInt32(CompiledChannelCurve.sampleCount)
    var finiteOutput: UInt32 = 0
}

/// Mirrors `struct PrintParams` in the Metal source. Layout: four floats or uints for the
/// offset and the LUT, a float and five uints for grain, then two floats, a uint, three
/// floats, a float and a uint for capture sharpening, 72 bytes.
public struct PrintParams: Sendable {
    /// Added to the negative's densities before the lookup, in the LUT's normalized units.
    public var offsetR: Float
    public var offsetG: Float
    public var offsetB: Float
    public var lutSize: UInt32
    /// The scale on the stock's sigma48 per pixel; 0 for no grain.
    public var grainScale: Float = 0
    public var grainAX: UInt32 = 0
    public var grainAY: UInt32 = 0
    public var grainBX: UInt32 = 0
    public var grainBY: UInt32 = 0
    public var sigmaCount: UInt32 = 1
    /// Capture sharpening, read only by the sharpened pipeline: the sensor mask's share of the
    /// detail and its kernel's taps either side, the soft threshold, the luminance weights, and
    /// the same two for the mask that takes out the decoder's scaling.
    public var sharpenAmount: Float = 0
    public var sharpenThreshold: Float = 0
    public var sharpenRadius: UInt32 = 0
    public var lumaR: Float = 0
    public var lumaG: Float = 0
    public var lumaB: Float = 0
    public var scalingAmount: Float = 0
    public var scalingRadius: UInt32 = 0

    public init(offset: SIMD3<Float>, lutSize: Int) {
        offsetR = offset.x
        offsetG = offset.y
        offsetB = offset.z
        self.lutSize = UInt32(lutSize)
    }
}

/// What the print pass needs for grain: the two noise tiles and the stock's sigma table.
public struct GrainInputs {
    public let tileA: MTLTexture
    public let tileB: MTLTexture
    public let sigmas: MTLTexture
}

/// The Print LUT pass: shift the negative's densities by the lab-balance offset, then
/// look them up in the Print LUT. The input is already in the LUT's domain, so unlike
/// `LUTPass` there is no log encoding. With a sharpening kernel it sharpens the dye amounts
/// first (`CaptureSharpening`), before grain goes in.
public final class PrintPass {
    private let pipeline: MTLComputePipelineState
    private let sharpenedPipeline: MTLComputePipelineState
    /// The same two with the tone step (`PrintTone`), which read each pixel's offset from the input's alpha.
    private let tonedPipeline: MTLComputePipelineState
    private let tonedSharpenedPipeline: MTLComputePipelineState
    private let placeholder: MTLTexture
    private let device: MTLDevice
    private let curveLock = NSLock()
    private var curveCache: (curves: ToneCurves, texture: MTLTexture, parameters: ToneCurveParameters)?
    /// The sharpened pipeline's threadgroup side, `SHARPEN_TILE` in the Metal source.
    static let sharpenTile = 16
    /// Whether this device runs the sharpened kernel: it needs a full 16 by 16 threadgroup,
    /// and a pipeline allowed fewer threads would trap at dispatch (found in review; 1024 on
    /// this M4). Without it every render is unsharpened, the same on every render.
    public let canSharpen: Bool
    /// The same for the toned kernel, which is compiled apart and may be allowed fewer.
    private let canSharpenToned: Bool
    private static let log = Logger(subsystem: "camera.argent.Argent", category: "render")

    public init(gpu: GPU) throws {
        device = gpu.device
        placeholder = try gpu.makeTexture(width: 1, height: 1, usage: .shaderRead)
        let library = try gpu.shaderLibrary()
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw GPUError.shaderFunctionMissing(name) }
            return try gpu.device.makeComputePipelineState(function: function)
        }
        self.pipeline = try pipeline("apply_print_lut")
        self.sharpenedPipeline = try pipeline("apply_print_lut_sharpened")
        self.tonedPipeline = try pipeline("apply_print_lut_toned")
        self.tonedSharpenedPipeline = try pipeline("apply_print_lut_sharpened_toned")
        canSharpen = sharpenedPipeline.maxTotalThreadsPerThreadgroup >= Self.sharpenTile * Self.sharpenTile
        canSharpenToned = tonedSharpenedPipeline.maxTotalThreadsPerThreadgroup >= Self.sharpenTile * Self.sharpenTile
        if !canSharpen {
            Self.log.error("capture sharpening off: this GPU allows \(self.sharpenedPipeline.maxTotalThreadsPerThreadgroup) threads per group, it needs \(Self.sharpenTile * Self.sharpenTile)")
        }
    }

    /// `grain` is read only when `params.grainScale` is above zero; without it a 1-pixel
    /// placeholder is bound. `sharpening`, the two masks' normalized blur kernels one after the
    /// other, `2 * params.sharpenRadius + 1` taps and then `2 * params.scalingRadius + 1`,
    /// sharpens the dye amounts first. `toneTable` (`PrintTone.table`) takes the toned kernels. `presence` is Saturation and
    /// Vibrance after the Print LUT (`PresencePrint`); a bypass by default.
    func encode(input: MTLTexture, output: MTLTexture, lut: MTLTexture, params: PrintParams,
                grain: GrainInputs? = nil, sharpening: [Float]? = nil,
                manual: ManualRenderSettings = .identity, toneTable: [SIMD4<Float>]? = nil,
                presence: PresencePrintParameters = .bypass, into commandBuffer: MTLCommandBuffer) throws {
        var refinements = try manual.parameters
        var presenceBlock = presence
        let curves = try curveInputs(manual.adjustments.curves)
        var curveParameters = curves.parameters
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
        // The kernels must be the size the parameters say and fit the shader's margin; anything
        // else is a caller's mistake, which would otherwise cache a soft render as sharpened.
        let radii = (Int(params.sharpenRadius), Int(params.scalingRadius))
        if let sharpening {
            precondition(max(radii.0, radii.1) <= CaptureSharpening.maxRadius
                         && sharpening.count == 2 * radii.0 + 2 * radii.1 + 2,
                         "sharpening kernels do not match their radii")
        }
        let kernel = (toneTable == nil ? canSharpen : canSharpenToned) ? sharpening : nil
        let plain = toneTable == nil ? pipeline : tonedPipeline
        encoder.setComputePipelineState(kernel == nil ? plain : (toneTable == nil ? sharpenedPipeline : tonedSharpenedPipeline))
        if let toneTable {
            var info = PrintToneTableInfo()
            toneTable.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 4) }
            encoder.setBytes(&info, length: MemoryLayout<PrintToneTableInfo>.stride, index: 5)
        }
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(lut, index: 2)
        encoder.setTexture(grain?.tileA ?? placeholder, index: 3)
        encoder.setTexture(grain?.tileB ?? placeholder, index: 4)
        encoder.setTexture(grain?.sigmas ?? placeholder, index: 5)
        encoder.setTexture(curves.texture, index: 6)
        var p = params
        encoder.setBytes(&p, length: MemoryLayout<PrintParams>.stride, index: 0)
        encoder.setBytes(&refinements, length: MemoryLayout<ManualCurveParameters>.stride, index: 2)
        encoder.setBytes(&curveParameters, length: MemoryLayout<ToneCurveParameters>.stride, index: 3)
        encoder.setBytes(&presenceBlock, length: MemoryLayout<PresencePrintParameters>.stride, index: PresencePrintParameters.bufferIndex)
        if let kernel {
            encoder.setBytes(kernel, length: kernel.count * MemoryLayout<Float>.stride, index: 1)
            let tile = Self.sharpenTile
            encoder.dispatchThreadgroups(MTLSize(width: (input.width + tile - 1) / tile, height: (input.height + tile - 1) / tile, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: tile, height: tile, depth: 1))
        } else {
            encoder.dispatchPixels(plain, width: input.width, height: input.height)
        }
        encoder.endEncoding()
    }

    /// One 16 KiB table per stock, replaced when the intent changes. No frame-sized
    /// texture or extra pass is needed; command buffers retain the table they encode.
    private func curveInputs(_ curves: ToneCurves) throws -> (texture: MTLTexture, parameters: ToneCurveParameters) {
        guard curves.hasEffect else { return (placeholder, ToneCurveParameters()) }
        curveLock.lock(); defer { curveLock.unlock() }
        if let cached = curveCache, cached.curves == curves { return (cached.texture, cached.parameters) }
        let compiled = try curves.compiled()
        let count = compiled.channels[0].samples.count
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: count,
                                                                 height: 1, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw GPUError.textureAllocation }
        var values = [SIMD4<Float>](); values.reserveCapacity(count)
        for i in 0..<count {
            values.append(SIMD4(compiled.channels[0].samples[i], compiled.channels[1].samples[i],
                                compiled.channels[2].samples[i], compiled.channels[3].samples[i]))
        }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, count, 1), mipmapLevel: 0, withBytes: $0.baseAddress!,
                            bytesPerRow: count * MemoryLayout<SIMD4<Float>>.stride)
        }
        var parameters = ToneCurveParameters()
        parameters.tableSize = UInt32(count)
        // Version 1 keeps its original storage conversion for saved render provenance.
        // Version 2 guards only the final result, after all curve channels have composed.
        parameters.finiteOutput = curves.version == "2026-10-09-curves-2" ? 1 : 0
        for i in 0..<4 {
            parameters.startSlope[i] = compiled.channels[i].startSlope
            parameters.endSlope[i] = compiled.channels[i].endSlope
            if compiled.channels[i].active { parameters.activeMask |= 1 << UInt32(i) }
        }
        curveCache = (curves, texture, parameters)
        return (texture, parameters)
    }
}
