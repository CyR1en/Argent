import Foundation
import Metal

/// Repairs in-window chroma from nearby out-of-window camera hues, preserving luminance.
public final class Defringe {
    public static let version = "2026-11-14-2-kernel-l"

    public struct HueTrack: Sendable {
        public static let feather: Float = 3.2
        public let knots: [Float]
        public let strength: [Float]
        public static let purple = HueTrack(
            knots: [
                247.9, 253.8, 259.9, 266.3, 273.5, 281.5, 290.3, 300.1, 312.2, 327.8, 351.1,
                377.8, 393.7, 404.4, 412.5, 418.1, 425.1, 430.1, 435.1, 440.1, 445.1,
            ],
            strength: strengths(
                points: [
                    245: 0, 250: 0.35, 255: 0.48, 260: 0.46, 265: 0.47, 270: 0.48,
                    275: 0.50, 280: 0.52, 285: 0.55, 290: 0.60, 295: 0.66, 300: 0.73, 305: 0.82, 310: 0.92,
                    40: 0.89, 45: 0.74, 50: 0.61, 55: 0.52, 60: 0.46, 65: 0.44, 70: 0.43, 75: 0.46,
                    80: 0.51, 85: 0.58, 90: 0.11, 95: 0,
                ], plateau: { $0 >= 315 || $0 <= 35 }, level: 1))
        public static let green = HueTrack(
            knots: [
                87.3, 92.2, 99.2, 106.5, 114.7, 126.5, 140.6, 156.9, 175.2, 193.2, 207.0,
                217.8, 226.9, 233.5, 240.2, 245.9, 250.9, 255.8, 260.6, 265.5, 270.3,
            ],
            strength: strengths(
                points: [
                    80: 0, 85: 0.37, 90: 0.66, 95: 0.78, 100: 0.95, 230: 0.87, 235: 0.76,
                    240: 0.66, 245: 0.57, 250: 0.51, 255: 0.47, 260: 0.45, 265: 0.46, 270: 0.47, 275: 0.31,
                    280: 0,
                ],
                plateau: { (105...225).contains($0) }, level: 0.98))

        private static func strengths(points: [Int: Float], plateau: (Int) -> Bool, level: Float)
            -> [Float]
        {
            stride(from: 0, to: 360, by: 5).map { points[$0] ?? (plateau($0) ? level : 0) }
        }
        public func coordinate(of angle: Float) -> Float {
            var a = angle.truncatingRemainder(dividingBy: 360)
            if a < 0 { a += 360 }
            // Pick the turn nearest the track's midpoint, including the gap beyond its ends.
            if a < (knots[0] + knots[20]) / 2 - 180 { a += 360 }
            let i = min(max((0..<20).last(where: { knots[$0] <= a }) ?? 0, 0), 19)
            return Float(i * 5) + 5 * (a - knots[i]) / (knots[i + 1] - knots[i])
        }
        public func score(angle: Float, low: Float, high: Float) -> Float {
            var a = angle.truncatingRemainder(dividingBy: 360)
            if a < 0 { a += 360 }
            let x = a / 5
            let i = Int(x)
            let k = strength[i] + (strength[(i + 1) % 72] - strength[i]) * (x - Float(i))
            let t = coordinate(of: a)
            let f = Self.feather
            return k * min(max((t - low + f) / f, 0), 1) * min(max((high + f - t) / f, 0), 1)
        }
    }

    public enum Constants {
        static let chromaLow: Float = 0.06, chromaHigh: Float = 0.10
        static let shadowFloor: Float = 0.004, donorColour: Float = 0.8
        static let frontier: Float = 0.075, leastReach: Float = 0.25
    }
    public static func reach(amount: Float) -> Float { amount }
    static func runs(amount: Float, scale: Float) -> Bool {
        amount > 0 && reach(amount: amount) * scale >= Constants.leastReach
    }
    var bandRows = 512
    private let gpu: GPU
    private let horizontal: MTLComputePipelineState, repair: MTLComputePipelineState
    private let tables: MTLBuffer
    private struct Parameters {
        var firstRow: UInt32, scratchFirstRow: UInt32
        var purpleRadius: Float, purpleLow: Float, purpleHigh: Float
        var greenRadius: Float, greenLow: Float, greenHigh: Float
        var chromaLow = Constants.chromaLow, chromaHigh = Constants.chromaHigh
        var y0 = Constants.shadowFloor, donorColour = Constants.donorColour
        var frontier = Constants.frontier, feather = HueTrack.feather
    }
    public init(gpu: GPU) throws {
        let library = try gpu.device.makeLibrary(source: ShaderSource.defringe, options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw GPUError.shaderFunctionMissing(name)
            }
            return try gpu.device.makeComputePipelineState(function: function)
        }
        horizontal = try pipeline("defringe_horizontal")
        repair = try pipeline("defringe_repair")
        let values =
            HueTrack.purple.knots + HueTrack.purple.strength + HueTrack.green.knots
            + HueTrack.green.strength
        guard
            let buffer = values.withUnsafeBytes({
                gpu.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            })
        else { throw GPUError.textureAllocation }
        tables = buffer
        self.gpu = gpu
    }
    func repair(
        _ source: MTLTexture, into destination: MTLTexture, with parameters: DefringeParameters,
        scale: Float
    ) throws {
        precondition(
            source !== destination && source.pixelFormat == .rgba16Float
                && destination.pixelFormat == .rgba16Float
                && source.width == destination.width && source.height == destination.height)
        func radius(_ band: DefringeParameters.Band?) -> Float {
            guard let band, Self.runs(amount: band.amount, scale: scale) else { return 0 }
            return Self.reach(amount: band.amount) * scale
        }
        var p = Parameters(
            firstRow: 0, scratchFirstRow: 0, purpleRadius: radius(parameters.purple),
            purpleLow: parameters.purple?.hueLow ?? 0, purpleHigh: parameters.purple?.hueHigh ?? 0,
            greenRadius: radius(parameters.green), greenLow: parameters.green?.hueLow ?? 0,
            greenHigh: parameters.green?.hueHigh ?? 0)
        let colours = p.purpleRadius > 0 && p.greenRadius > 0 ? 2 : 1
        let halo = Int(ceil(max(p.purpleRadius, p.greenRadius)))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: source.width,
            height: min(source.height, bandRows + 2 * halo), mipmapped: false)
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = colours
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let sums = gpu.device.makeTexture(descriptor: descriptor) else { throw GPUError.textureAllocation }
        guard let buffer = gpu.queue.makeCommandBuffer() else { throw GPUError.noCommandQueue }
        for first in stride(from: 0, to: source.height, by: bandRows) {
            let rows = min(bandRows, source.height - first)
            let scratchFirst = max(0, first - halo)
            let scratchRows = min(source.height, first + rows + halo) - scratchFirst
            p.firstRow = UInt32(first)
            p.scratchFirstRow = UInt32(scratchFirst)
            guard let encoder = buffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
            encoder.setComputePipelineState(horizontal)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(sums, index: 1)
            encoder.setBuffer(tables, offset: 0, index: 1)
            encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 0)
            encoder.dispatchThreadgroups(
                MTLSize(width: (source.width + 127) / 128, height: scratchRows, depth: colours),
                threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
            encoder.endEncoding()
            guard let repairEncoder = buffer.makeComputeCommandEncoder() else { throw GPUError.noEncoder }
            repairEncoder.setComputePipelineState(repair)
            repairEncoder.setTexture(source, index: 0)
            repairEncoder.setTexture(sums, index: 1)
            repairEncoder.setTexture(destination, index: 2)
            repairEncoder.setBuffer(tables, offset: 0, index: 1)
            repairEncoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 0)
            repairEncoder.dispatchPixels(repair, width: source.width, height: rows)
            repairEncoder.endEncoding()
        }
        buffer.commit()
        withExtendedLifetime((source, destination, sums, tables)) { buffer.waitUntilCompleted() }
        if let error = buffer.error { throw error }
    }
}
