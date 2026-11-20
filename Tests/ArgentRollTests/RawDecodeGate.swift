import Testing

/// Runs the suites that decode the samples one at a time. Swift Testing runs suites in parallel,
/// and a debug build's in-house decoder spends about 2 core-seconds a frame on its tiles (215 ms on
/// ten cores, measured), so a develop in one suite took the stock-switch timing checks of another
/// from 2 ms to 230 to 470 ms (docs/decoder.md, section 14).
struct RawDecodeGate: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        await RawDecodeTurns.shared.take()
        do {
            try await function()
        } catch {
            await RawDecodeTurns.shared.give()
            throw error
        }
        await RawDecodeTurns.shared.give()
    }
}

extension Trait where Self == RawDecodeGate {
    /// The suite decodes the samples, so it waits for other such suites.
    static var rawDecodes: Self { Self() }
}

/// One suite at a time, first come first served.
private actor RawDecodeTurns {
    static let shared = RawDecodeTurns()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func take() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func give() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
