import Foundation
import Testing
@testable import ArgentCore

@Suite struct LensGeometryTests {
    @Test func storesTheFewestExactKnots() throws {
        let file = try LensGeometry(table: RadialTable(knots: LensCorrectionTests.sampleCurve.knots.map { 1 + Double($0) / 16384 }), scale: 1.002)
        let arbitrary = try LensGeometry(table: RadialTable(knots: (0...960).map { 1 + 0.00001 * sin(Double($0)) }), scale: 1)
        for (geometry, count) in [(file, 16), (arbitrary, 961)] {
            let data = try JSONEncoder().encode(geometry)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let text = try #require(object["knots"] as? String)
            let knots = try #require(Data(base64Encoded: text))
            #expect(knots.count == count * 4)
            #expect(try JSONDecoder().decode(LensGeometry.self, from: data) == geometry)
        }
    }

    @Test func refusesWhatTheStageRefuses() throws {
        for (knots, scale) in [([1.0, 0.5], 1.0), ([1, 1], 2.0), ([1, 3], 1.0)] {
            let table = try RadialTable(knots: knots)
            #expect(throws: LensCorrectionError.self) { try LensGeometry(table: table, scale: scale) }
            #expect(throws: LensCorrectionError.self) {
                try ResolvedLensCorrection(red: table, green: table, blue: table, gain: .one, status: .init(), scale: scale)
            }
        }
    }

    @Test func mapsTheSameSensorRadiusAndRoundTrips() throws {
        let a = try LensGeometry(table: RadialTable(knots: [1, 0.99, 0.96]), scale: 1)
        let b = try LensGeometry(table: RadialTable(knots: [1, 1]), scale: 1)
        let extent = MaskPoint(x: 1, y: 2.0 / 3)
        #expect(LensRemap(from: a, to: a, extent: extent) == nil)
        let forward = try #require(LensRemap(from: a, to: b, extent: extent))
        let backward = try #require(LensRemap(from: b, to: a, extent: extent))
        let radius = Double(hypot(extent.x, extent.y) / 2)
        for i in 0...100 {
            let t = Float(i) / 100
            let p = MaskPoint(x: extent.x / 2 + t * extent.x / 2, y: extent.y / 2 + t * extent.y / 2)
            let q = forward.point(p)
            let u = Double(hypot(q.x - extent.x / 2, q.y - extent.y / 2)) / radius
            let rho = Double(t) * a.table.value(at: Double(t)) / a.scale
            #expect(abs(rho - u * b.table.value(at: u) / b.scale) < 1e-6)
        }
        #expect(forward.ratio(at: MaskPoint(x: 8, y: -9)) == forward.ratio.last!)
        let lens = MaskLens(picture: b, legacy: a, extent: extent)
        let shape = MaskShape.linear(.init(full: .init(x: 0.1, y: 0.1), zero: .init(x: 0.2, y: 0.2)))
        #expect(lens.toPicture(shape) == forward)
        #expect(lens.toMask(shape) == backward)
        let fileCurve = try LensGeometry(table: RadialTable(knots: (0..<16).map { 1 - 0.03 * pow(Double($0) / 15, 2) }), scale: 1)
        let picture = try MaskSpace(width: 7008, height: 4672)
        let file = SonyLensCorrection(distortionSetting: 17, distortion: LensCorrectionTests.rising)
        let amounts = try [50, 150, 200].map { amount in
            LensResolver.resolve(file, picture: picture, settings: try LensSettings(arguments: "distortion-amount=\(amount)")).geometry
        }
        for curve in [a, fileCurve] + amounts {
            var worst: Float = 0
            for (picture, legacy) in [(b, curve), (curve, b)] {
                let lens = MaskLens(picture: picture, legacy: legacy, extent: extent)
                let toMask = try #require(lens.toMask(shape))
                let toPicture = try #require(lens.toPicture(shape))
                for i in 0..<1000 {
                    let t = Float(i) / 999
                    let p = MaskPoint(x: extent.x / 2 * (1 + t), y: extent.y / 2 * (1 + t))
                    let mapped = toMask.point(p)
                    guard (0...extent.x).contains(mapped.x), (0...extent.y).contains(mapped.y) else { continue }
                    let back = toPicture.point(mapped)
                    worst = max(worst, hypot(back.x - p.x, back.y - p.y) * 7008)
                }
            }
            print("LC6 round trip \(curve.digest.prefix(12)): \(worst) px at 7008")
            #expect(worst < 0.1, "both directions over 1,000 radii: \(worst) px")
        }
    }
}

extension LensGeometryTests {
    @Test func amount150StoresItsTableAndRoundTrips() throws {
        let file = SonyLensCorrection(distortionSetting: 17, distortion: LensCorrectionTests.sampleCurve)
        let lens = LensResolver.resolve(file, picture: try MaskSpace(width: 7008, height: 4672),
                                        settings: try LensSettings(arguments: "distortion-amount=150"))
        let data = try JSONEncoder().encode(lens.geometry)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try #require(object["knots"] as? String)
        #expect(Data(base64Encoded: encoded)?.count == 16 * 4)
        let restored = try JSONDecoder().decode(LensGeometry.self, from: data)
        #expect(restored == lens.geometry && restored.table == lens.green)
    }
}
