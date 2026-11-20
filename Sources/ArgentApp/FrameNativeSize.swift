import ArgentRoll
import Foundation

/// Native dimensions belong to a particular version of a frame, just like its rendered pictures.
struct FrameNativeSize {
    let request: FrameSourceRequest
    let pixels: Int

    func pixels(for request: FrameSourceRequest) -> Int? {
        self.request == request ? pixels : nil
    }

    /// A header read may outlive the view task that requested it. Neither cancellation nor a
    /// replacement of the file may publish the old dimensions into the current frame view.
    static func load(_ request: FrameSourceRequest,
                     read: @Sendable (URL) async -> Int = { url in
                         await Task.detached(priority: .userInitiated) { FrameZoom.fullPixels(of: url) }.value
                     }) async -> FrameNativeSize? {
        guard !Task.isCancelled, SourceStamp.of(request.frame) == request.source else { return nil }
        let pixels = await read(request.frame)
        guard !Task.isCancelled, SourceStamp.of(request.frame) == request.source else { return nil }
        return FrameNativeSize(request: request, pixels: pixels)
    }
}
