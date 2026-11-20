import Foundation
@testable import ArgentCore

/// A small stock built in code, so render-graph tests need neither the bake tool nor a
/// raw file. Both LUTs mix their channels a little, so a swapped or dropped channel shows.
enum ToyStock {
    static let boxSpeed: Float = 400
    static let densityRange: Float = 3
    /// Unequal and not one, so an offset that forgets to divide by it shows.
    static let exposurePerUnit = SIMD3<Float>(0.82, 0.84, 0.79)
    static var exposurePerUnitList: [Float] { [exposurePerUnit.x, exposurePerUnit.y, exposurePerUnit.z] }

    /// Log-encoded exposure to normalized dye amounts.
    static func negative(_ e: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(0.15 + 0.60 * e.x + 0.05 * e.y,
              0.20 + 0.55 * pow(e.y, 1.2) + 0.05 * e.z,
              0.25 + 0.50 * e.z + 0.05 * e.x)
    }

    /// Normalized dye amounts to display-linear light. Denser negatives print lighter, as on paper.
    static func print(_ d: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(0.9 * pow(d.x, 1.5) + 0.05 * d.y,
              0.9 * pow(d.y, 1.5) + 0.05 * d.z,
              0.9 * pow(d.z, 1.5) + 0.05 * d.x)
    }

    static func lut(size: Int, _ function: (SIMD3<Float>) -> SIMD3<Float>) -> LUT3D {
        var values: [Float] = []
        values.reserveCapacity(size * size * size * 3)
        let denominator = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let out = function(SIMD3(Float(r), Float(g), Float(b)) / denominator)
                    values += [out.x, out.y, out.z]
                }
            }
        }
        return try! LUT3D(size: size, values: values)
    }

    static func make(size: Int = 17) -> Stock {
        Stock(id: "toy", displayName: "Toy", status: "synthetic", boxSpeed: boxSpeed, densityRange: densityRange,
              exposurePerUnit: exposurePerUnit, negative: lut(size: size, negative), print: lut(size: size, print))
    }

    /// The manifest `argent-bake` writes, as a dictionary so tests can break one field at a
    /// time. Schema 2 is the default; `schema: 1` gives the older shape, which names no
    /// binary files and carries no `exposurePerUnit`.
    static func manifest(size: Int = 9, schema: Int = 2) -> [String: Any] {
        var negative: [String: Any] = [
            "file": "negative.cube",
            "size": size,
            "logEncoding": ["stopsBelowMidGray": 8, "stopsAboveMidGray": 5, "midGray": 0.18],
        ]
        var print: [String: Any] = ["file": "print.cube", "size": size]
        var manifest: [String: Any] = [
            "schema": schema,
            "id": "toy",
            "displayName": "Toy",
            "status": "synthetic",
            "boxSpeed": boxSpeed,
            "densityRange": densityRange,
        ]
        if schema >= 2 {
            negative["binary"] = "negative.lut3d"
            print["binary"] = "print.lut3d"
            print["exposurePerUnit"] = exposurePerUnitList
            manifest["bake"] = [
                "tool": "argent-bake", "version": "test", "paper": "toy",
                "daylightFiltration": [0, 0, 0], "midGrayLogExposure": -1.5418,
                "negativeModel": ["source": "ToyStock.swift"],
            ]
        }
        manifest["negative"] = negative
        manifest["print"] = print
        return manifest
    }

    /// Writes a stock folder into a fresh temporary directory and returns it. The `.cube`
    /// files are always written; `binary` also writes the `.lut3d` files the schema 2
    /// manifest names, as the bake does.
    static func write(size: Int = 9, manifest: [String: Any]? = nil, binary: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("argent-toy-stock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let negative = lut(size: size, self.negative)
        let print = lut(size: size, self.print)
        try negative.cubeText(title: "toy negative")
            .write(to: directory.appendingPathComponent("negative.cube"), atomically: true, encoding: .utf8)
        try print.cubeText(title: "toy print")
            .write(to: directory.appendingPathComponent("print.cube"), atomically: true, encoding: .utf8)
        if binary {
            try negative.binaryData().write(to: directory.appendingPathComponent("negative.lut3d"))
            try print.binaryData().write(to: directory.appendingPathComponent("print.lut3d"))
        }
        let json = try JSONSerialization.data(withJSONObject: manifest ?? self.manifest(size: size))
        try json.write(to: directory.appendingPathComponent(Stock.manifestName))
        return directory
    }
}
