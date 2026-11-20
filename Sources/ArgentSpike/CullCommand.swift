import ArgentCore
import ArgentRoll
import Foundation
import os

func cull(_ arguments: [String]) -> Never {
    var scoresPath: String?
    var folder: String?
    var settings = CullSettings()
    var iterator = arguments.makeIterator()
    func number() -> Double {
        guard let value = iterator.next().flatMap(Double.init), value.isFinite, value >= 0 else { usage() }
        return value
    }
    while let argument = iterator.next() {
        switch argument {
        case "--scores":
            guard let value = iterator.next() else { usage() }
            scoresPath = value
        case "--soft-focus-below": settings.softFocusBelow = number()
        case "--eyes-closed-below": settings.eyesClosedBelow = number()
        case "--keep-eyes-closed": settings.leavesEyesClosed = false
        case "--burst-gap": settings.burstGap = number()
        case "--same-moment-within": settings.sameMomentWithin = number()
        case _ where !argument.hasPrefix("-") && folder == nil: folder = argument
        default: usage()
        }
    }
    switch (scoresPath, folder) {
    case let (path?, nil): cullScores(path, settings)
    case let (nil, folder?): cullCard(URL(fileURLWithPath: folder), settings)
    default: usage()
    }
}

private func cullScores(_ path: String, _ settings: CullSettings) -> Never {
    let frames: [CullInput]
    do {
        frames = try CullScoreFile.read(Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        fail("\(path): \(error.localizedDescription)")
    }
    let start = ContinuousClock.now
    let verdicts = Cull.verdicts(frames, settings: settings)
    let elapsed = ContinuousClock.now - start
    printTable(frames, verdicts)
    FileHandle.standardError.write(String(format: "verdicts for %d frames in %.2f ms\n", verdicts.count, elapsed.milliseconds).data(using: .utf8)!)
    exit(0)
}

private func cullCard(_ folder: URL, _ settings: CullSettings) -> Never {
    let scored = OSAllocatedUnfairLock(initialState: (scored: 0, total: 0))
    let start = ContinuousClock.now
    let pass = Task {
        do {
            let cull = try await CardCull.run(folder: folder, settings: settings) { done, total in scored.withLock { $0 = (done, total) } }
            printTable(cull.frames, cull.verdicts)
            FileHandle.standardError.write(String(format: "scored %d frames in %.2f s\n", cull.frames.count,
                                                  (ContinuousClock.now - start).seconds).data(using: .utf8)!)
            exit(0)
        } catch is CancellationError {
            let (done, total) = scored.withLock { $0 }
            FileHandle.standardError.write(String(format: "stopped: scored %d of %d frames in %.2f s\n", done, total,
                                                  (ContinuousClock.now - start).seconds).data(using: .utf8)!)
            exit(130)
        } catch {
            fail("\(error)")
        }
    }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { pass.cancel() }
    interrupt.resume()
    withExtendedLifetime(interrupt) { dispatchMain() }
}

private func printTable(_ frames: [CullInput], _ verdicts: [CullVerdict]) {
    let scores = Dictionary(uniqueKeysWithValues: frames.compactMap { frame in frame.scores.map { (frame.path, $0) } })
    let pathWidth = verdicts.map(\.path.count).max() ?? 0
    let burstWidth = String(verdicts.last?.burst ?? 0).count
    func right(_ text: String, _ width: Int) -> String { String(repeating: " ", count: max(0, width - text.count)) + text }
    var counts: [String: Int] = [:]
    for verdict in verdicts {
        let measured = scores[verdict.path].map {
            "face " + right($0.faceQuality.map { String(format: "%.3f", $0) } ?? "-", 5)
                + "  aesthetics " + String(format: "%6.3f", $0.aesthetics)
        } ?? "unreadable".padding(toLength: 29, withPad: " ", startingAt: 0)
        let reason: String?
        switch verdict.reason {
        case nil: reason = nil
        case .failed: reason = "failed"
        case .softFocus: reason = "softFocus"
        case .eyesClosed: reason = "eyesClosed"
        case .sameMoment: reason = "sameMoment"
        }
        var fate = reason.map { "leave \($0)" } ?? "keep"
        if case let .sameMoment(keeper) = verdict.reason { fate += " \(keeper)" }
        if let reason { counts[reason, default: 0] += 1 }
        print("\(verdict.path.padding(toLength: pathWidth, withPad: " ", startingAt: 0))  burst \(right(String(verdict.burst), burstWidth))  \(measured)  \(fate)")
    }
    let left = counts.values.reduce(0, +)
    let reasons = ["failed", "softFocus", "eyesClosed", "sameMoment"].compactMap { name in counts[name].map { "\(name) \($0)" } }
    print("keep \(verdicts.count - left), leave \(left)" + (reasons.isEmpty ? "" : " (\(reasons.joined(separator: ", ")))"))
    fflush(stdout)
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}
