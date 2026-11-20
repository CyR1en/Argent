import ArgentRoll
import Foundation
import Testing
@testable import ArgentApp

@MainActor @Suite struct FrameNativeSizeTests {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-native-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func request(_ url: URL) -> FrameSourceRequest {
        FrameSourceRequest(frame: url, source: SourceStamp.of(url))
    }

    @Test func replacingAFrameAtTheSamePathInvalidatesItsDimensions() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("frame.ARW")
        try Data([1]).write(to: url)
        let originalRequest = request(url)
        let original = try #require(await FrameNativeSize.load(originalRequest, read: { _ in 7008 }))
        try Data([2, 3]).write(to: url, options: .atomic)
        let replacementRequest = request(url)
        #expect(originalRequest != replacementRequest)
        #expect(original.pixels(for: replacementRequest) == nil)
        let replacement = try #require(await FrameNativeSize.load(replacementRequest, read: { _ in 3480 }))
        #expect(replacement.pixels(for: replacementRequest) == 3480)
        #expect(await FrameNativeSize.load(originalRequest, read: { _ in 7008 }) == nil)
    }

    @Test func aCancelledSlowFrameCannotOverwriteTheNextFramesDimensions() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.ARW"), next = folder.appendingPathComponent("next.ARW")
        try Data([1]).write(to: first)
        try Data([2]).write(to: next)
        let firstRequest = request(first), nextRequest = request(next)
        let read = SuspendedRead()
        var displayed: FrameNativeSize?
        let previousTask = Task {
            if let result = await FrameNativeSize.load(firstRequest, read: { _ in await read.value() }) {
                displayed = result
            }
        }
        await read.waitUntilStarted()
        previousTask.cancel()
        displayed = await FrameNativeSize.load(nextRequest, read: { _ in 3480 })
        await read.finish(with: 7008)
        await previousTask.value
        #expect(displayed?.pixels(for: nextRequest) == 3480)
    }

    @Test func replacingTheFileDuringAReadRejectsItsDimensions() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("frame.ARW")
        try Data([1]).write(to: url)
        let originalRequest = request(url)
        let read = SuspendedRead()
        let task = Task { await FrameNativeSize.load(originalRequest, read: { _ in await read.value() }) }
        await read.waitUntilStarted()
        // The watcher has not yet restarted the view task, so this must also be safe without cancellation.
        try Data([2, 3]).write(to: url, options: .atomic)
        await read.finish(with: 7008)
        #expect(await task.value == nil)
        let replacementRequest = request(url)
        let replacement = await FrameNativeSize.load(replacementRequest, read: { _ in 3480 })
        #expect(replacement?.pixels(for: replacementRequest) == 3480)
    }

    /// Like the detached header reader, this finishes even if the task awaiting it was cancelled.
    private actor SuspendedRead {
        private var result: CheckedContinuation<Int, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func value() async -> Int {
            await withCheckedContinuation {
                result = $0
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if result != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish(with pixels: Int) {
            result?.resume(returning: pixels)
            result = nil
        }
    }
}
