import Foundation
import Testing
@testable import ArgentCore

@Suite struct DevelopSettingsTests {
    @Test func ratedAtBelowBoxSpeedAddsExposure() {
        #expect(DevelopSettings(ratedAt: 200).exposureStops(boxSpeed: 400) == 1)
        #expect(DevelopSettings(ratedAt: 800).exposureStops(boxSpeed: 400) == -1)
        #expect(DevelopSettings(ratedAt: 400).exposureStops(boxSpeed: 400) == 0)
        #expect(DevelopSettings().exposureStops(boxSpeed: 400) == 0)
    }

    @Test func printOffsetIsLog10OfTwoPerStopOverTheRange() {
        let stop = Float(log10(2.0)) / 3
        let overall = DevelopSettings(printExposure: 1).printOffset(densityRange: 3, exposurePerUnit: SIMD3(repeating: 1))
        #expect(max(abs(overall.x - stop), abs(overall.y - stop), abs(overall.z - stop)) < 1e-6)

        let balanced = DevelopSettings(labBalance: SIMD3(1, 0, -2), printExposure: 0.5)
            .printOffset(densityRange: 3, exposurePerUnit: SIMD3(repeating: 1))
        #expect(abs(balanced.x - 1.5 * stop) < 1e-6)
        #expect(abs(balanced.y - 0.5 * stop) < 1e-6)
        #expect(abs(balanced.z - -1.5 * stop) < 1e-6)
    }

    @Test func printOffsetDividesByTheStocksExposurePerUnit() {
        let perUnit = SIMD3<Float>(0.5, 0.8, 2)
        let settings = DevelopSettings(labBalance: SIMD3(1, 0, -2), printExposure: 0.5)
        let offset = settings.printOffset(densityRange: 2.5, exposurePerUnit: perUnit)
        let stop = Float(log10(2.0)) / 2.5
        #expect(abs(offset.x - 1.5 * stop / 0.5) < 1e-6)
        #expect(abs(offset.y - 0.5 * stop / 0.8) < 1e-6)
        #expect(abs(offset.z - -1.5 * stop / 2) < 1e-6)
    }

    @Test func defaultSettingsLeaveTheFilmAlone() {
        let settings = DevelopSettings()
        #expect(settings.exposureStops(boxSpeed: 400) == 0)
        #expect(settings.printOffset(densityRange: 3, exposurePerUnit: SIMD3(repeating: 1)) == .zero)
        #expect(settings.printOffset(densityRange: 3, exposurePerUnit: ToyStock.exposurePerUnit) == .zero)
    }
}

@Suite struct StockLoadingTests {
    @Test func loadsWhatTheBakeToolWrites() throws {
        let directory = try ToyStock.write(size: 9, binary: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stock = try Stock.load(from: directory)
        #expect(stock.id == "toy")
        #expect(stock.status == "synthetic")
        #expect(stock.boxSpeed == 400)
        #expect(stock.densityRange == 3)
        #expect(stock.exposurePerUnit == ToyStock.exposurePerUnit)
        #expect(stock.negative.size == 9 && stock.print.size == 9)
        #expect(stock.negative.encoding == LogEncoding())
        #expect(stock.negative.encoding.stopsAboveMidGray == 5)

        // The binary file holds the floats exactly.
        let expected = ToyStock.lut(size: 9, ToyStock.negative)
        #expect(stock.negative.values == expected.values)
    }

    @Test func fallsBackToTheCubeWhenTheBinaryFileIsMissing() throws {
        // The schema 2 manifest names the binaries, but only the .cube files are written.
        let directory = try ToyStock.write(size: 9)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stock = try Stock.load(from: directory)
        #expect(stock.exposurePerUnit == ToyStock.exposurePerUnit)
        // The cube text keeps six decimals, so the round trip is exact to about 1e-6.
        let expected = ToyStock.lut(size: 9, ToyStock.negative)
        for (a, b) in zip(stock.negative.values, expected.values) {
            #expect(abs(a - b) < 1e-5)
        }
    }

    @Test func fallsBackToATabSeparatedCube() throws {
        let directory = try ToyStock.write(size: 9)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spaced = try Stock.load(from: directory)
        for name in ["negative.cube", "print.cube"] {
            let url = directory.appendingPathComponent(name)
            try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: " ", with: "\t")
                .write(to: url, atomically: true, encoding: .utf8)
        }

        let tabbed = try Stock.load(from: directory)
        #expect(tabbed.negative.values == spaced.negative.values)
        #expect(tabbed.print.values == spaced.print.values)
    }

    @Test func fallsBackToACRLFCube() throws {
        let directory = try ToyStock.write(size: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lf = try Stock.load(from: directory)
        for name in ["negative.cube", "print.cube"] {
            let url = directory.appendingPathComponent(name)
            try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\n", with: "\r\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }

        let crlf = try Stock.load(from: directory)
        #expect(crlf.negative.values == lf.negative.values)
        #expect(crlf.print.values == lf.print.values)
    }

    @Test func prefersTheBinaryFileOverTheCube() throws {
        let directory = try ToyStock.write(size: 9, binary: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A .cube that would not parse proves the loader never opened it.
        for name in ["negative.cube", "print.cube"] {
            try "LUT_3D_SIZE 9\nnot a number\n".write(to: directory.appendingPathComponent(name),
                                                       atomically: true, encoding: .utf8)
        }

        let stock = try Stock.load(from: directory)
        #expect(stock.print.values == ToyStock.lut(size: 9, ToyStock.print).values)
    }

    @Test func aBrokenBinaryFileIsAnErrorNotAFallback() throws {
        let directory = try ToyStock.write(size: 9, binary: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("print.lut3d")
        try Data(contentsOf: binary).prefix(100).write(to: binary)

        #expect(throws: StockError.self) { try Stock.load(from: directory) }
    }

    @Test func loadsASchema1ManifestWithUnitExposurePerUnit() throws {
        let directory = try ToyStock.write(manifest: ToyStock.manifest(schema: 1))
        defer { try? FileManager.default.removeItem(at: directory) }

        let stock = try Stock.load(from: directory)
        #expect(stock.exposurePerUnit == SIMD3<Float>(repeating: 1))
        #expect(stock.negative.size == 9)
    }

    /// A stock carries the name the app shows and, apart from it, the film it models, which the
    /// app names in full in one descriptive line. A manifest
    /// written before the field existed, or for a stock modelled on no film, has none.
    @Test func readsTheFilmTheStockModelsApartFromItsName() throws {
        var manifest = ToyStock.manifest()
        manifest["displayName"] = "Portra 400"
        manifest["modelledFilm"] = "Kodak Portra 400"
        manifest["status"] = "datasheet"
        let directory = try ToyStock.write(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stock = try Stock.load(from: directory)
        #expect(stock.displayName == "Portra 400" && stock.modelledFilm == "Kodak Portra 400")
        #expect(stock.afterLine == "After Kodak Portra 400: Argent's model of the film, built from its published datasheet.")

        for film in [nil, NSNull(), ""] as [Any?] {
            var other = ToyStock.manifest()
            other["modelledFilm"] = film
            let folder = try ToyStock.write(manifest: other)
            defer { try? FileManager.default.removeItem(at: folder) }
            let unnamed = try Stock.load(from: folder)
            #expect(unnamed.displayName == "Toy" && unnamed.modelledFilm == nil && unnamed.afterLine == nil)
        }
    }

    @Test func readsTheLogEncodingFromTheManifest() throws {
        var manifest = ToyStock.manifest()
        manifest["negative"] = [
            "file": "negative.cube", "size": 9,
            "logEncoding": ["stopsBelowMidGray": 6, "stopsAboveMidGray": 6, "midGray": 0.2],
        ]
        let directory = try ToyStock.write(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stock = try Stock.load(from: directory)
        #expect(stock.negative.encoding == LogEncoding(stopsBelowMidGray: 6, stopsAboveMidGray: 6, midGray: 0.2))
    }

    @Test func rejectsAMissingManifest() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("argent-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: StockError.self) { try Stock.load(from: empty) }
    }

    @Test func rejectsAnUnknownSchema() throws {
        for schema in [0, 3] {
            var manifest = ToyStock.manifest()
            manifest["schema"] = schema
            let directory = try ToyStock.write(manifest: manifest)
            defer { try? FileManager.default.removeItem(at: directory) }
            #expect(throws: StockError.self, "schema \(schema)") { try Stock.load(from: directory) }
        }
    }

    @Test func rejectsASizeThatDisagreesWithTheCube() throws {
        var manifest = ToyStock.manifest(size: 9)
        manifest["print"] = ["file": "print.cube", "size": 17, "exposurePerUnit": ToyStock.exposurePerUnitList]
        let directory = try ToyStock.write(size: 9, manifest: manifest)
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = #expect(throws: StockError.self) { try Stock.load(from: directory) }
        guard case .sizeMismatch = error else { Issue.record("expected sizeMismatch, got \(String(describing: error))"); return }
    }

    @Test func rejectsASizeThatDisagreesWithTheBinary() throws {
        var manifest = ToyStock.manifest(size: 9)
        manifest["print"] = ["file": "print.cube", "binary": "print.lut3d", "size": 17,
                             "exposurePerUnit": ToyStock.exposurePerUnitList]
        let directory = try ToyStock.write(size: 9, manifest: manifest, binary: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = #expect(throws: StockError.self) { try Stock.load(from: directory) }
        guard case .sizeMismatch = error else { Issue.record("expected sizeMismatch, got \(String(describing: error))"); return }
    }

    @Test func rejectsASchema2ManifestWithoutExposurePerUnit() throws {
        var manifest = ToyStock.manifest()
        manifest["print"] = ["file": "print.cube", "binary": "print.lut3d", "size": 9]
        let directory = try ToyStock.write(manifest: manifest, binary: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = #expect(throws: StockError.self) { try Stock.load(from: directory) }
        guard case .badValue(let what) = error, what.contains("exposurePerUnit") else {
            Issue.record("expected a badValue naming exposurePerUnit, got \(String(describing: error))")
            return
        }
    }

    @Test func rejectsNonPositiveDensityRangeAndBoxSpeed() throws {
        for (key, value) in [("densityRange", 0.0), ("boxSpeed", -400.0)] {
            var manifest = ToyStock.manifest()
            manifest[key] = value
            let directory = try ToyStock.write(manifest: manifest)
            defer { try? FileManager.default.removeItem(at: directory) }
            #expect(throws: StockError.self, "\(key) = \(value)") { try Stock.load(from: directory) }
        }
    }

    @Test func rejectsABadExposurePerUnit() throws {
        for values in [[0.8, 0.8], [0.8, 0, 0.8], [0.8, -1, 0.8]] as [[Double]] {
            var manifest = ToyStock.manifest()
            manifest["print"] = ["file": "print.cube", "size": 9, "exposurePerUnit": values]
            let directory = try ToyStock.write(manifest: manifest)
            defer { try? FileManager.default.removeItem(at: directory) }
            #expect(throws: StockError.self, "exposurePerUnit \(values)") { try Stock.load(from: directory) }
        }
    }

    @Test func rejectsInvalidHalationBeforeItCanReachTheGPU() throws {
        let invalid: [(String, Double)] = [("strength", -0.01), ("greenShare", -0.1),
                                          ("greenShare", 1.1), ("radiusMicrometres", 0),
                                          ("radiusMicrometres", -180)]
        for (key, value) in invalid {
            var manifest = ToyStock.manifest()
            var halation = ["strength": 0.015, "greenShare": 0.25, "radiusMicrometres": 180.0]
            halation[key] = value
            manifest["halation"] = halation
            let directory = try ToyStock.write(manifest: manifest)
            defer { try? FileManager.default.removeItem(at: directory) }
            let error = #expect(throws: StockError.self, "\(key) = \(value)") { try Stock.load(from: directory) }
            guard case .badValue(let what) = error else {
                Issue.record("expected badValue, got \(String(describing: error))")
                continue
            }
            #expect(what.contains("halation"))
        }
    }

    @Test func loadsEnabledHalationAndAcceptsTheBakesDisabledZeroRadius() throws {
        for strength in [0.0, 0.015] {
            var manifest = ToyStock.manifest()
            manifest["halation"] = ["strength": strength, "greenShare": 0.25,
                                    "radiusMicrometres": strength > 0 ? 180.0 : 0.0]
            let directory = try ToyStock.write(manifest: manifest)
            defer { try? FileManager.default.removeItem(at: directory) }
            let stock = try Stock.load(from: directory)
            if strength == 0 {
                #expect(stock.halation == nil)
            } else {
                #expect(stock.halation == Stock.Halation(strength: 0.015, greenShare: 0.25, radiusMicrometres: 180))
            }
        }
    }

    @Test func rejectsFilesOutsideTheStockFolder() throws {
        for (key, file) in [("file", "../negative.cube"), ("binary", "../negative.lut3d")] {
            var manifest = ToyStock.manifest()
            var negative = manifest["negative"] as! [String: Any]
            negative[key] = file
            manifest["negative"] = negative
            let directory = try ToyStock.write(manifest: manifest, binary: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            #expect(throws: StockError.self, "\(key) \(file)") { try Stock.load(from: directory) }
        }
    }

    /// The load time the spike reports, measured on a stock the size the bake writes.
    /// The M0 addendum measured about 440 ms for two 65 cubed `.cube` files.
    @Test func loadsABinaryStockMuchFasterThanTheCube() throws {
        let directory = try ToyStock.write(size: 65, manifest: ToyStock.manifest(size: 65), binary: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ContinuousClock()

        var start = clock.now
        let fromBinary = try Stock.load(from: directory)
        let binaryMilliseconds = (clock.now - start).milliseconds

        for name in ["negative.lut3d", "print.lut3d"] {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        start = clock.now
        let fromCube = try Stock.load(from: directory)
        let cubeMilliseconds = (clock.now - start).milliseconds

        print(String(format: "MEASURE 65^3 stock load: binary %.1f ms, cube %.1f ms", binaryMilliseconds, cubeMilliseconds))
        #expect(fromBinary.negative.size == 65 && fromCube.negative.size == 65)
        #expect(binaryMilliseconds < cubeMilliseconds)
        for (a, b) in zip(fromBinary.print.values, fromCube.print.values) where abs(a - b) >= 1e-5 {
            Issue.record("binary and cube tables differ: \(a) versus \(b)")
            break
        }
    }
}
