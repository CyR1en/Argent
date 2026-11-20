import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Presence's two GPU blocks are written twice, in Swift and in Metal (`ShaderSource.presenceParameters`). These hold the two to one
/// layout: the same fields in the same order, and the GPU reading each field at the bytes Swift wrote it to.
@Suite struct PresenceParametersTests {
    struct Field: Equatable, CustomStringConvertible {
        let name: String
        let kind: String
        let count: Int
        var description: String { count == 1 ? "\(kind) \(name)" : "\(kind) \(name)[\(count)]" }
    }

    /// A block's fields as Swift declares them, in order.
    static func swiftFields(_ block: Any) -> [Field] {
        Mirror(reflecting: block).children.map { child in
            let name = child.label ?? "?"
            if child.value is UInt32 { return Field(name: name, kind: "uint", count: 1) }
            if child.value is Float { return Field(name: name, kind: "float", count: 1) }
            let elements = Mirror(reflecting: child.value).children
            return Field(name: name, kind: elements.allSatisfy { $0.value is Float } ? "float" : "?", count: elements.count)
        }
    }

    /// The same block's fields as the Metal text declares them.
    static func metalFields(_ name: String) throws -> [Field] {
        let text = ShaderSource.presenceParameters
        let start = try #require(text.range(of: "struct \(name) {"))
        let end = try #require(text.range(of: "};", range: start.upperBound..<text.endIndex))
        return text[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line in
            let words = line.trimmingCharacters(in: .whitespaces).dropLast().split(separator: " ")
            guard words.count == 2 else { return nil }
            let parts = words[1].split(separator: "[")
            let count = parts.count == 2 ? Int(parts[1].dropLast()) ?? 0 : 1
            return Field(name: String(parts[0]), kind: String(words[0]), count: count)
        }
    }

    /// Every 4-byte slot of `block` filled with its own normal float's bits, then what Swift reads in each field, in order.
    static func filled<Block>(_ block: Block) -> (block: Block, bits: [UInt32]) {
        var block = block
        withUnsafeMutableBytes(of: &block) { raw in
            for slot in 0..<raw.count / 4 { raw.storeBytes(of: 0x4000_0000 | UInt32(slot), toByteOffset: 4 * slot, as: UInt32.self) }
        }
        let bits = Mirror(reflecting: block).children.flatMap { child -> [UInt32] in
            if let value = child.value as? UInt32 { return [value] }
            if let value = child.value as? Float { return [value.bitPattern] }
            return Mirror(reflecting: child.value).children.compactMap { ($0.value as? Float)?.bitPattern }
        }
        return (block, bits)
    }

    /// What the GPU reads of `block`: its size, then each field in Swift's order, every element of an array.
    static func gpuRead<Block>(_ block: Block, as name: String, fields: [Field]) throws -> [UInt32] {
        let gpu = try GPU()
        let reads = fields.flatMap { field in
            field.count == 1 ? ["as_type<uint>(p.\(field.name))"] : (0..<field.count).map { "as_type<uint>(p.\(field.name)[\($0)])" }
        }
        let body = reads.enumerated().map { "    out[\($0.offset + 1)] = \($0.element);" }.joined(separator: "\n")
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        \(ShaderSource.presenceParameters)
        kernel void read_block(constant \(name) &p [[buffer(0)]], device uint *out [[buffer(1)]]) {
            out[0] = sizeof(\(name));
        \(body)
        }
        """
        let library = try gpu.device.makeLibrary(source: source, options: nil)
        let pipeline = try gpu.device.makeComputePipelineState(function: try #require(library.makeFunction(name: "read_block")))
        let output = try #require(gpu.device.makeBuffer(length: 4 * (reads.count + 1), options: .storageModeShared))
        let commandBuffer = try #require(gpu.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        withUnsafeBytes(of: block) { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: output.contents().bindMemory(to: UInt32.self, capacity: reads.count + 1), count: reads.count + 1))
    }

    @Test func theSceneBlocksMirrorsAgree() throws {
        let fields = Self.swiftFields(PresenceSceneParameters())
        #expect(fields == (try Self.metalFields("PresenceSceneParameters")))
        let (block, bits) = Self.filled(PresenceSceneParameters())
        let read = try Self.gpuRead(block, as: "PresenceSceneParameters", fields: fields)
        #expect(Int(read[0]) == MemoryLayout<PresenceSceneParameters>.size, "the two sizes")
        #expect(Array(read.dropFirst()) == bits, "each field at the bytes Swift wrote it to")
        #expect(MemoryLayout<PresenceSceneParameters>.size == 4 * bits.count, "no padding")
    }

    @Test func thePrintBlocksMirrorsAgree() throws {
        let fields = Self.swiftFields(PresencePrintParameters())
        #expect(fields == (try Self.metalFields("PresencePrintParameters")))
        let (block, bits) = Self.filled(PresencePrintParameters())
        let read = try Self.gpuRead(block, as: "PresencePrintParameters", fields: fields)
        #expect(Int(read[0]) == MemoryLayout<PresencePrintParameters>.size, "the two sizes")
        #expect(Array(read.dropFirst()) == bits, "each field at the bytes Swift wrote it to")
        #expect(MemoryLayout<PresencePrintParameters>.size == 4 * bits.count, "no padding")
    }

    /// A field added to one mirror and not the other fails here, and so does one moved.
    @Test func aFieldInOneMirrorOnlyIsSeen() throws {
        var swift = Self.swiftFields(PresenceSceneParameters())
        swift.swapAt(2, 3)
        #expect(swift != (try Self.metalFields("PresenceSceneParameters")))
        #expect(Self.swiftFields(PresencePrintParameters()).dropLast() != (try Self.metalFields("PresencePrintParameters"))[...])
    }
}
