import CoreGraphics
import ImageIO
import Vision

public enum PreviewScoring {
    public static let faceQualityRevision = VNDetectFaceCaptureQualityRequestRevision3
    public static let aestheticsRevision = VNCalculateImageAestheticsScoresRequestRevision1
    public static let featurePrintRevision = VNGenerateImageFeaturePrintRequestRevision2

    public struct MissingResult: Error, CustomStringConvertible {
        public var request: String
        public var description: String { "Vision gave no \(request) result" }
    }

    /// `image`'s scores, with `orientation` turning it upright as the frame's Exif orientation
    /// does. The face quality is the best face's, `nil` when Vision finds none.
    public static func scores(of image: CGImage, orientation: CGImagePropertyOrientation) throws -> PreviewScores {
        let faces = VNDetectFaceCaptureQualityRequest()
        faces.revision = faceQualityRevision
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        aesthetics.revision = aestheticsRevision
        let print = VNGenerateImageFeaturePrintRequest()
        print.revision = featurePrintRevision
        // One request a call: several in one call run on Vision's own capacity-limited queue, and
        // from more threads than it has places they wait on each other for good.
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        for request in [faces, aesthetics, print] as [VNRequest] { try handler.perform([request]) }
        guard let score = aesthetics.results?.first else { throw MissingResult(request: "aesthetics") }
        guard let observation = print.results?.first, observation.elementType == .float else {
            throw MissingResult(request: "feature print")
        }
        return PreviewScores(faceQuality: faces.results?.compactMap(\.faceCaptureQuality).max().map(Double.init),
                             aesthetics: Double(score.overallScore),
                             featurePrint: observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
    }
}
