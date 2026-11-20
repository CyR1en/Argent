import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ArgentCore

/// Vision's cost and its gate's agreement with S4's, for the docs; not regressions. Run with ARGENT_MEASURE=1, one test at a
/// time, in a release build:
///
///     ARGENT_MEASURE=1 swift test -c release -Xswiftc -enable-testing --filter AppleSegmentationMeasureTests/warmTimesAndMemory
///
/// `warmTimesAndMemory` reads the prints named by ARGENT_SEGMENTATION_PRINTS (paths, comma-separated), or the CC0 sample's
/// neutral print, and runs every request, or only ARGENT_SEGMENTATION_REQUEST (`subject`, `person` or `water`), since R6
/// measured each alone. `gateAgainstS4` reads S4's neutral prints (ARGENT_GATE_PRINTS, a folder of `<stem>.jpg`) and S4's classifier
/// logs (ARGENT_GATE_LOG, comma-separated: `vprobe-neutral2560.jsonl`, `vprobe-syn.jsonl`, `vprobe-mir.jsonl`); both are
/// private frames under the masking research folder, never in Git.
@Suite(.serialized) struct AppleSegmentationMeasureTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["ARGENT_MEASURE"] == "1" }
    static let source = SeedSource(sourceSHA256: String(repeating: "0", count: 64), app: "AppleSegmentationMeasureTests")

    static func load(_ path: String) throws -> AppleSegmentation.Picture {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw MaskError.invalid("\(path) can be read") }
        return try AppleSegmentation.Picture(image)
    }

    static func footprintMiB() -> (current: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    static func load() -> String {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? String(format: "%.2f %.2f %.2f", loads[0], loads[1], loads[2]) : "unknown"
    }

    static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    /// The plan's warm times (Subject 14 ms, Person 35 ms at 2560 px, R2; the water score 7.7 ms, S5) and R6's resident memory
    /// (+106 to 144 MiB, settling to 27 to 62 MiB after 20 s idle), in this process: the first call of each request, 30 warm
    /// calls each, and the footprint before, after, and 5, 10 and 20 s later.
    @Test(.enabled(if: AppleSegmentationMeasureTests.enabled))
    func warmTimesAndMemory() async throws {
        let paths = ProcessInfo.processInfo.environment["ARGENT_SEGMENTATION_PRINTS"]?.split(separator: ",").map(String.init) ?? []
        let pictures = try paths.isEmpty ? [("DSC06673", try NeutralPrintFixture.print.get())]
            : paths.map { (URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent, try Self.load($0)) }
        try await Task.sleep(for: .seconds(3))
        let before = Self.footprintMiB()
        print("MEASURE vision memory: before \(String(format: "%.1f", before.current)) MiB, load \(Self.load())")
        typealias Request = (name: String, run: (AppleSegmentation.Picture) throws -> Void)
        let only = ProcessInfo.processInfo.environment["ARGENT_SEGMENTATION_REQUEST"]
        let requests: [Request] = [
            ("subject", { _ = try AppleSegmentation.subject($0, source: Self.source) }),
            ("person", { _ = try AppleSegmentation.person($0, source: Self.source) }),
            ("water", { _ = try AppleSegmentation.waterScore($0) }),
        ].filter { only == nil || $0.name == only }
        for (name, picture) in pictures {
            for request in requests {
                let first = try Self.milliseconds { try request.run(picture) }
                var warm: [Double] = []
                for _ in 0..<30 { warm.append(try Self.milliseconds { try request.run(picture) }) }
                warm.sort()
                print("MEASURE vision \(request.name) on \(name) \(picture.width)x\(picture.height): first in process "
                      + String(format: "%.1f ms, warm min %.1f median %.1f p95 %.1f ms; load %@", first, warm[0], warm[15], warm[28], Self.load()))
            }
        }
        let after = Self.footprintMiB()
        print(String(format: "MEASURE vision memory: after use %.1f MiB (+%.1f), lifetime peak %.1f MiB", after.current,
                     after.current - before.current, after.peak))
        for (wait, more) in [(5, 5), (10, 5), (20, 10)] {
            try await Task.sleep(for: .seconds(more))
            let now = Self.footprintMiB()
            print(String(format: "MEASURE vision memory: %d s idle %.1f MiB (+%.1f)", wait, now.current, now.current - before.current))
        }
    }

    /// The gate on S4's 157 neutral prints against S4's own scores: decisions at 0.03, and the largest difference. S5 found
    /// none differing over 539 prints, scores within 0.043. Also what Subject and Person return on each, as a census of shapes.
    @Test(.enabled(if: AppleSegmentationMeasureTests.enabled && ProcessInfo.processInfo.environment["ARGENT_GATE_PRINTS"] != nil))
    func gateAgainstS4() throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: try #require(environment["ARGENT_GATE_PRINTS"]))
        var theirs: [String: Float] = [:]
        for log in environment["ARGENT_GATE_LOG"]?.split(separator: ",").map(String.init) ?? [] {
            for line in try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n") {
                guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let stem = row["stem"] as? String,
                      let labels = row["labels"] as? [[String: Any]] else { continue }
                var confidences: [String: Float] = [:]
                for label in labels { if let id = label["id"] as? String, let c = label["conf"] as? Double { confidences[id] = Float(c) } }
                if theirs[stem] == nil { theirs[stem] = WaterGate.score(confidences) }
            }
        }
        let stems = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) }.sorted()
        var compared = 0, differing: [String] = [], worst: (Float, String) = (0, ""), nearGate: Float = 0
        var shapes: [String: Int] = [:], subjects = 0, people = 0, passed = 0
        for stem in stems {
            let picture = try Self.load(folder.appendingPathComponent("\(stem).jpg").path)
            let score = try AppleSegmentation.waterScore(picture)
            if score.passes { passed += 1 }
            if let s4 = theirs[stem] {
                compared += 1
                if WaterGate.passes(s4) != score.passes { differing.append("\(stem) \(s4) \(score.score)") }
                let d = abs(s4 - score.score)
                if d > worst.0 { worst = (d, stem) }
                if min(s4, score.score) < 0.1 { nearGate = max(nearGate, d) }
            }
            let subject = try AppleSegmentation.subject(picture, source: Self.source)
            let person = try AppleSegmentation.person(picture, source: Self.source)
            if let seed = subject.seed { subjects += 1; shapes["subject \(seed.raster.width)x\(seed.raster.height)", default: 0] += 1 }
            if let seed = person.seed { people += 1; shapes["person \(seed.raster.width)x\(seed.raster.height) on \(picture.width > picture.height ? "landscape" : "portrait")", default: 0] += 1 }
            print("MEASURE gate \(stem) \(picture.width)x\(picture.height): \(score.score) (S4 \(theirs[stem].map { "\($0)" } ?? "-")); "
                  + "subject \(subject.seed == nil ? "none" : subject.provenance.parameters["instances"]! + " instances"); "
                  + "person \(person.seed.map { "\($0.raster.plane.filter { $0 >= 128 }.count) px" } ?? "none")")
        }
        print("MEASURE gate against S4: \(stems.count) prints, \(compared) with S4's score, \(differing.count) decisions differ at 0.03 \(differing); "
              + "largest difference \(worst.0) (\(worst.1)), largest where either is under 0.1: \(nearGate); \(passed) pass the gate")
        print("MEASURE seeds on S4's prints: subject on \(subjects), person on \(people) of \(stems.count); shapes \(shapes.sorted { $0.key < $1.key })")
        #expect(differing.isEmpty)
    }
}
