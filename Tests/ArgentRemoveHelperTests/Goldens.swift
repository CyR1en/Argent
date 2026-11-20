import Foundation
@testable import ArgentRemoveHelper

/// The tensors package H1 recorded from ObjectClear in PyTorch (`$R/goldens`, outside the repository and never in Git): four runs,
/// every tensor a port crosses. Suites that read them are enabled only where the folder is, with the reason.
struct Goldens {
    /// `ARGENT_REMOVE_GOLDENS`, else where the research keeps them.
    static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["ARGENT_REMOVE_GOLDENS"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents/ArgentResearch/remove-20261116.noindex/goldens", isDirectory: true)
    }()
    static let runs = ["p161-8-1.0", "p161-20-2.5", "p247-8-1.0", "p247-20-2.5"]
    static var present: Bool {
        runs.allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("manifest.json").path) }
    }

    let folder: URL
    let width: Int
    let height: Int
    let steps: Int
    let guidance: Float
    /// UNet rows a step: 2 when guided.
    let batch: Int

    init(_ run: String) throws {
        folder = Self.root.appendingPathComponent(run, isDirectory: true)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as! [String: Any]
        width = manifest["width"] as! Int
        height = manifest["height"] as! Int
        steps = manifest["steps"] as! Int
        guidance = Float(manifest["guidance"] as! Double)
        batch = manifest["unet batch"] as! Int
    }

    var latentWidth: Int { width / 8 }
    var latentHeight: Int { height / 8 }

    /// A float32 `.npy`, little-endian, C order: its values.
    func tensor(_ name: String) throws -> [Float] {
        let data = try Data(contentsOf: folder.appendingPathComponent(name + ".npy"))
        let headerLength = Int(data[8]) | Int(data[9]) << 8
        let header = String(decoding: data[10..<(10 + headerLength)], as: UTF8.self)
        precondition(header.contains("'<f4'") && header.contains("'fortran_order': False"), "\(name): \(header)")
        let body = data.dropFirst(10 + headerLength)
        return body.withUnsafeBytes { raw in
            (0..<(raw.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self))) }
        }
    }

    func step(_ index: Int, _ name: String) throws -> [Float] {
        try tensor(String(format: "step_%02d/", index) + name)
    }

    /// A recorded PNG's bytes: `channels` 3 for the pictures, 1 for the mask and the maps.
    func picture(_ name: String, channels: Int, latent: Bool = false) throws -> [UInt8] {
        let w = latent ? latentWidth : width, h = latent ? latentHeight : height
        guard let bytes = Pictures.pixels(of: folder.appendingPathComponent(name + ".png"), width: w, height: h, channels: channels) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: name])
        }
        return bytes
    }
}

/// The worst difference of two tensors, and how many values differ at all.
func difference(_ a: [Float], _ b: [Float]) -> (worst: Float, differing: Int) {
    precondition(a.count == b.count, "\(a.count) values against \(b.count)")
    var worst: Float = 0, differing = 0
    for i in a.indices where a[i] != b[i] {
        worst = max(worst, abs(a[i] - b[i]))
        differing += 1
    }
    return (worst, differing)
}

/// Peak signal to noise of two 8-bit pictures, in dB.
func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
    precondition(a.count == b.count)
    var squared = 0.0
    for i in a.indices {
        let d = Double(a[i]) - Double(b[i])
        squared += d * d
    }
    let mean = squared / Double(a.count)
    return mean == 0 ? .infinity : 10 * log10(255 * 255 / mean)
}
