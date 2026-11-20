import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import Vision

/// Subject, Person and Background from macOS Vision, and Vision's water score for the Sky seed's gate, on the frame's neutral
/// print (masking plan section 3: `LUT3D.neutralPrint` over the frame's own decode, about 2560 px on the long side).
///
/// Every request runs on one fixed pixel path, `Picture`: an 8-bit sRGB `CGImage`, upright, with no alpha. Vision's bytes are
/// the same across processes, devices and both API surfaces, but a linear half-float input changes them slightly (R2), so
/// nothing else is ever fed. Each request's revision is pinned, as `FaceMeter`'s is, though the segmentation requests have
/// only one each (R2): what pins a seed is that its pixels are stored, never regenerated (plan section 3, "Why store the
/// result"). The calls are synchronous, as `FaceMeter.detections` is; the caller picks the queue. No request sets a compute
/// device: forcing one on Vision's tap request killed R2's process with SIGKILL, and on the others it changed nothing.
///
/// An empty result is a result, not an error (plan section 5): each request returns `.nothingFound` with what it ran, and
/// throws only when Vision itself fails.
public enum AppleSegmentation {
    /// Subject: `VNGenerateForegroundInstanceMaskRequest`, revision 1 (its only one).
    public static let subjectEngine = "vision.foreground-instance"
    public static let subjectRevision = 1
    /// Person: `VNGeneratePersonSegmentationRequest`, revision 1 (its only one), at `.accurate`, 8-bit.
    public static let personEngine = "vision.person-segmentation"
    public static let personRevision = 1

    /// The one picture every request reads: the caller's `CGImage` drawn once into 8-bit sRGB, red, green, blue and a padding
    /// byte of 255, rows from the top, and the SHA-256 of those bytes, which the seed's provenance records.
    public struct Picture: @unchecked Sendable {
        /// Immutable once made.
        public let image: CGImage
        public let width: Int
        public let height: Int
        /// SHA-256 of `ARGENT-PICTURE-1`, both sides and the pixels' bytes, 64 lowercase hex digits.
        public let sha256: String

        /// Draws `image` into the fixed path. An 8-bit sRGB picture keeps its bytes; any other is converted by Core Graphics,
        /// the same way every time.
        public init(_ image: CGImage) throws {
            let width = image.width, height = image.height
            guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw MaskError.invalid("a picture has a size")
            }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { throw MaskError.invalid("a picture can be drawn in 8-bit sRGB") }
            for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
            var hash = SHA256()
            hash.update(data: Data("ARGENT-PICTURE-1\n".utf8))
            for side in [UInt32(width), UInt32(height)] { withUnsafeBytes(of: side.littleEndian) { hash.update(bufferPointer: $0) } }
            bytes.withUnsafeBytes { hash.update(bufferPointer: $0) }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let made = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw MaskError.invalid("a picture can be drawn in 8-bit sRGB")
            }
            self.image = made
            self.width = width
            self.height = height
            self.sha256 = MaskSet.hex(hash.finalize())
        }

        /// The picture's red, green, blue and padding bytes, rows from the top.
        public var bytes: [UInt8] {
            guard let data = image.dataProvider?.data else { return [] }
            return Array(Data(referencing: data as NSData))
        }

        fileprivate func handler() -> VNImageRequestHandler {
            // The print is already upright, as the decode is.
            VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        }
    }

    // MARK: Subject and Background

    /// Subject: every foreground instance as one mask (decision 11), Vision's 512 × 512 label map with each instance set to 255
    /// (S3: refines as well as Apple's scaled mask at a tenth to a fortieth of its bytes). The map spans the whole picture
    /// whatever its aspect. `.nothingFound` when Vision finds no instance, as on about 30 % of landscapes (R2: 21 of 70 frames).
    public static func subject(_ picture: Picture, source: SeedSource) throws -> SmartResult {
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.revision = VNGenerateForegroundInstanceMaskRequestRevision1
        try picture.handler().perform([request])
        var parameters = ["request.revision": String(subjectRevision)]
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            parameters["instances"] = "0"
            return .nothingFound(.subject, source.provenance(engine: subjectEngine, revision: subjectRevision,
                                                             parameters: parameters, picture: picture))
        }
        let labels = try plane(of: observation.instanceMask)
        parameters["instances"] = String(observation.allInstances.count)
        parameters["confidence"] = "\(observation.confidence)"
        parameters["seed"] = "labels > 0"
        let raster = try MaskRaster(width: labels.width, height: labels.height, plane: labels.plane.map { $0 > 0 ? 255 : 0 })
        let provenance = source.provenance(engine: subjectEngine, revision: subjectRevision, parameters: parameters, picture: picture)
        guard raster.plane.contains(255) else { return .nothingFound(.subject, provenance) }
        return .seed(SmartSeed(kind: .subject, raster: raster, provenance: provenance))
    }

    /// Background: Subject's raster with the kind `.background`, which the coverage reads as `1 − v`. It is not a second raster:
    /// both name the same pixels and the same provenance. `.nothingFound` when there is no subject to set it apart, since the
    /// inverse of nothing is the whole frame (R2).
    public static func background(_ picture: Picture, source: SeedSource) throws -> SmartResult {
        background(from: try subject(picture, source: source))
    }

    /// Background from a Subject result already made on the same picture.
    public static func background(from subject: SmartResult) -> SmartResult {
        switch subject {
        case .seed(let seed): return .seed(SmartSeed(kind: .background, raster: seed.raster, provenance: seed.provenance, edge: seed.edge))
        case .nothingFound(_, let provenance): return .nothingFound(.background, provenance)
        }
    }

    // MARK: Person

    /// Person: everyone in the frame as one matte, Vision's `.accurate` matte as returned, 8-bit, 2016 × 1512 for a landscape
    /// (R2, S3). It is 4:3 whatever the picture's aspect and is stretched over the whole picture, `uv = (x + 0.5) / w` on both
    /// axes, which registers (S3: scale error under 0.8 %, x and y alike). Vision returns a blank matte when it sees nobody,
    /// so `.nothingFound` when no pixel reaches the selected level, 0.5, with the matte's largest value in its provenance.
    /// Vision also calls some things people that are not (R2: dogs, a flower, a faucet); the Subtract brush repairs those.
    public static func person(_ picture: Picture, source: SeedSource) throws -> SmartResult {
        let request = VNGeneratePersonSegmentationRequest()
        request.revision = VNGeneratePersonSegmentationRequestRevision1
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try picture.handler().perform([request])
        guard let observation = request.results?.first else {
            throw MaskError.invalid("Vision's person segmentation returned no matte")
        }
        let matte = try plane(of: observation.pixelBuffer)
        var parameters = ["request.revision": String(personRevision), "quality": "accurate", "format": "OneComponent8",
                          "confidence": "\(observation.confidence)", "returned": "\(matte.width)x\(matte.height)"]
        let maximum = matte.plane.max() ?? 0
        guard maximum >= SmartSeed.selectedLevel else {
            parameters["maximum"] = String(maximum)
            return .nothingFound(.person, source.provenance(engine: personEngine, revision: personRevision, parameters: parameters,
                                                            picture: picture))
        }
        let provenance = source.provenance(engine: personEngine, revision: personRevision, parameters: parameters, picture: picture)
        return .seed(SmartSeed(kind: .person, raster: try MaskRaster(width: matte.width, height: matte.height, plane: matte.plane),
                               provenance: provenance))
    }

    // MARK: the water gate

    /// Vision's water score for the Sky seed's gate: `VNClassifyImageRequest` at revision 2 on the picture, the largest
    /// confidence of `WaterGate.identifiers`. S5 measured its decisions on 539 prints against S4's tool: none differs at 0.03.
    public static func waterScore(_ picture: Picture) throws -> WaterScore {
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        try picture.handler().perform([request])
        let wanted = Set(WaterGate.identifiers)
        var labels: [String: Float] = [:]
        for observation in request.results ?? [] where wanted.contains(observation.identifier) {
            labels[observation.identifier] = max(labels[observation.identifier] ?? 0, observation.confidence)
        }
        return WaterScore(labels: labels)
    }

    // MARK: reading Vision's buffers

    /// A one-byte-a-pixel buffer's bytes, rows from the top, without its row padding.
    static func plane(of buffer: CVPixelBuffer) throws -> (width: Int, height: Int, plane: [UInt8]) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else {
            throw MaskError.invalid("Vision returned a mask that is not 8-bit")
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self), rowBytes >= width else {
            throw MaskError.invalid("Vision returned a mask that cannot be read")
        }
        var plane = [UInt8](repeating: 0, count: width * height)
        plane.withUnsafeMutableBufferPointer { out in
            for y in 0..<height { (out.baseAddress! + y * width).update(from: base + y * rowBytes, count: width) }
        }
        return (width, height, plane)
    }
}
