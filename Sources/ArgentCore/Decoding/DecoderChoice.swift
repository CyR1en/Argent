import Darwin
import Foundation
import os

/// How a session sends files to decoders (docs/decoder.md, "How the choice works").
public enum DecoderRoute: String, Sendable, CaseIterable {
    /// The default since 2026-10-19, the owner's decision: Apple's RAW 9, the learned demosaic and
    /// denoise, for every a7 IV file in a mode it takes (lossless L, uncompressed and lossy
    /// compressed, full frame and APS-C) at every ISO, and RAW 8 for the rest: lossless M and S,
    /// other bodies, and any file RAW 9 does not take or fails on (docs/decoder.md section 18).
    case raw9
    /// M8's route, kept for comparison and as a way back: the in-house decoder for lossless L and
    /// uncompressed to ISO 3200, RAW 8 for the rest (docs/decoder.md sections 14 to 17).
    case inHouse = "inhouse"
    /// RAW 8 for every file: the pinned classic decoder, the reference the in-house decoder was
    /// fitted to and RAW 9 is checked against, for comparison and measurement.
    case apple
}

/// Which decoder the app decodes a file with: Apple's RAW 9 for the a7 IV's Bayer modes, Apple's
/// RAW 8 for everything else, and on M8's route the in-house decoder for the files it takes and is
/// verified on (docs/decoder.md, sections 14 and 18).
///
/// The in-house decoder takes only the a7 IV's lossless L and uncompressed files, full frame and
/// APS-C (`InHouseDecoder.supports`), which hold the same samples. Its colour, demosaic, distortion
/// correction, tiles and strip reading hold at any ISO; its noise
/// reduction is matched to Apple's on the CC0 samples (full frame at ISO 250, APS-C at 640) and, above
/// them, on frames simulated with the a7 IV's published noise, which stand in for real ones: on
/// RawNIND's real a7C ladder, real frames and the same scene simulated match at strengths within 8
/// percent (docs/research/noise-and-hardware.md). A frame shot above `inHouseISOLimit` goes to
/// Apple's decoder.
public enum DecoderChoice: String, Sendable, Codable {
    case inHouse = "in-house"
    /// Apple's RAW 8, pinned.
    case apple
    /// Apple's RAW 9, the learned demosaic and denoise.
    case raw9

    /// The highest ISO the in-house decoder is used at on its route (docs/decoder.md section 17): the highest at
    /// which it still matches Apple's by the measures that admitted it to ISO 1250, on real frames
    /// (Imaging Resource's still life and gallery, photographyblog's frames). At 3200 the still life's
    /// gray edge rises 1.15 times as slowly as Apple's, as at 800 (1.10) and inside the 1.15 admitted
    /// there, flat L* is 1.10 of Apple's and flat a*b* 0.60 with the colour raised near neutral
    /// (`InHouseNoiseReduction.neutralGain`), the print within 1.39 dE2000 a pixel of Apple's, and a dark
    /// frame reads Apple's level within 0.004 stops; at 4000 and 5000 (the still life's 3200 frame with
    /// their noise added, which reproduces the real 6400 frame) the gray edge is 1.21 and 1.18 times as
    /// slow, at 6400 1.28, past what was admitted. Lossless L and uncompressed hold the same samples,
    /// so one limit serves both. 1250 until 2026-10-18 (the top of Apple's low tier, from a published
    /// noise model and the a7C, docs/research/noise-and-hardware.md); 640 until 2026-10-07. Below it the
    /// noise, and what the noise reduction does, only fall.
    public static let inHouseISOLimit = 3200

    /// The decoder version a decode by this decoder records in its pins.
    public var decoderVersion: String {
        switch self {
        case .inHouse: return InHouseDecoder.version
        case .apple: return AppleRawDecoder.pinnedDecoderVersion
        case .raw9: return AppleRawDecoder.learnedDecoderVersion
        }
    }

    /// The decoder for `url` on `route`, read from its header without decoding. On RAW 9's route:
    /// RAW 9 for an a7 IV file in a mode it takes (`RawMode.learned`), RAW 8 for any other file and for
    /// every file on a macOS before 27, which has no RAW 9. On the
    /// in-house route: the in-house decoder for an a7 IV lossless L or uncompressed file, full frame or
    /// APS-C, at ISO 3200 or below, RAW 8 for any other file, including one whose ISO cannot be read.
    public static func of(_ url: URL, route: DecoderRoute = .raw9) -> DecoderChoice {
        (try? read(url, route: route)) ?? .apple
    }

    /// `of(_:route:)`, throwing `InHouseDecodeError.unreadable` or `DecodeError.unreadable` for a file
    /// that cannot be read now, which says nothing of the decoder it goes to once it can.
    static func read(_ url: URL, route: DecoderRoute = .raw9) throws -> DecoderChoice {
        switch route {
        case .apple:
            return .apple
        case .raw9:
            // RAW 9 is macOS 27's, the deployment target, so every Mac that runs Argent has it.
            let layout: ARWLayout
            do {
                layout = try ARWLayout.read(from: url)
            } catch let error where error is CocoaError || error is POSIXError {
                throw DecodeError.unreadable(url, "\(error)")
            } catch {
                return .apple
            }
            return BodyProfile.named(layout.model)?.mode(for: layout)?.learned == true ? .raw9 : .apple
        case .inHouse:
            do {
                guard let iso = try InHouseDecoder.check(url).info.iso else { return .apple }
                return inHouse(iso: iso) ? .inHouse : .apple
            } catch InHouseDecodeError.unreadable(let url, let why) {
                throw InHouseDecodeError.unreadable(url, why)
            } catch {
                return .apple
            }
        }
    }

    /// The decoder that made `frame`, from the version it records.
    public static func of(_ frame: LinearFrame) -> DecoderChoice { of(decoderVersion: frame.decoderVersion) }

    /// The decoder a decode's recorded version names.
    public static func of(decoderVersion: String) -> DecoderChoice {
        switch decoderVersion {
        case InHouseDecoder.version: return .inHouse
        case AppleRawDecoder.learnedDecoderVersion: return .raw9
        default: return .apple
        }
    }

    /// Whether a supported file at `iso` goes to the in-house decoder on its route.
    public static func inHouse(iso: Int) -> Bool { iso > 0 && iso <= inHouseISOLimit }
}

/// The decoder each file of a session goes to, read once per file and shared by everything that
/// decodes, so the sheet, the frame view and a develop agree, and their caches and recipes are keyed
/// by the decoder that made each frame (`decoderVersion(for:)`). A file the chosen decoder fails on,
/// RAW 9 or the in-house decoder, goes to RAW 8 for the rest of the session while that version of the
/// file remains; a file it cannot read, its share dropped, does not.
///
/// Safe to use from any thread.
public final class DecoderChoices: @unchecked Sendable {
    /// How this session sends files to decoders.
    public let route: DecoderRoute
    private let lock = NSLock()
    /// What is known of each file, by path: its choice and, once read, Apple's white-balance
    /// read-back, with the version of the file they were read at.
    private var known: [String: Known] = [:]
    private struct Known {
        var source: Stamp
        var choice: DecoderChoice
        var readback: DecodeReadback?
    }
    /// Versions the chosen decoder failed on this session, by path.
    private var failed: [String: Stamp] = [:]
    private var inHouseAvailable = true
    /// Paths whose RAW 9 decode throws, for the fallback's tests: what it throws and how many more
    /// times; under `lock`.
    private var refused: [String: (error: any Error, times: Int)] = [:]

    /// The environment variable and the user default that pick the route: `apple` sends every file
    /// to RAW 8, `inhouse` takes M8's route, and anything else, or nothing, RAW 9's. A user default
    /// can be given at launch: `open -a Argent --args -ArgentDecoder apple`. The variable wins.
    public static let environmentKey = "ARGENT_DECODER"
    public static let defaultsKey = "ArgentDecoder"

    /// The route this process was asked for.
    public static var requestedRoute: DecoderRoute {
        route(named: ProcessInfo.processInfo.environment[environmentKey] ?? UserDefaults.standard.string(forKey: defaultsKey))
    }

    /// The route a switch's value names: `apple` (or `raw8`), `inhouse` (or `in-house`), else RAW 9's.
    public static func route(named name: String?) -> DecoderRoute {
        switch name?.lowercased() {
        case "apple", "raw8": return .apple
        case "inhouse", "in-house": return .inHouse
        default: return .raw9
        }
    }

    public init(route: DecoderRoute = DecoderChoices.requestedRoute) {
        self.route = route
    }

    /// The decoder `url` goes to this session.
    public func choice(for url: URL) -> DecoderChoice {
        (try? readChoice(for: url)) ?? .apple
    }

    /// The in-house route without its decoder, on a machine where it cannot run.
    private var inHouseLost: Bool { route == .inHouse && lock.withLock { !inHouseAvailable } }

    /// The same choice, preserving file-system read errors for a caller that is about to decode.
    func readChoice(for url: URL) throws -> DecoderChoice {
        if route == .apple || inHouseLost { return .apple }
        let path = url.path
        guard let stamp = Self.stamp(path) else { return try DecoderChoice.read(url, route: route) }
        if let choice: DecoderChoice = lock.withLock({
            guard failed[path] != stamp else { return .apple }
            guard let entry = known[path], entry.source == stamp else { return nil }
            return entry.choice
        }) { return choice }
        // A file that cannot be read now, its share dropped, is read again for the next request.
        let choice = try DecoderChoice.read(url, route: route)
        guard Self.stamp(path) == stamp, !inHouseLost else { return .apple }
        return lock.withLock {
            guard failed[path] != stamp else { return .apple }
            // Another request may have read the file meanwhile, and kept its read-back with it.
            if let entry = known[path], entry.source == stamp { return entry.choice }
            known[path] = Known(source: stamp, choice: choice)
            return choice
        }
    }

    /// File identity and times: a replacement can have the same size and modification date. Status
    /// time is kept only on local volumes; on SMB Apple's mapping can move it without a write.
    struct Stamp: Equatable {
        struct Time: Equatable {
            var seconds: Int
            var nanoseconds: Int
            init(_ time: timespec) {
                seconds = time.tv_sec
                nanoseconds = time.tv_nsec
            }
        }
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modified: Time
        var changed: Time?
    }

    static func stamp(_ path: String) -> Stamp? {
        var info = stat(), volume = statfs()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let local = statfs(path, &volume) == 0 && volume.f_flags & UInt32(MNT_LOCAL) != 0
        return Stamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                     modified: Stamp.Time(info.st_mtimespec), changed: local ? Stamp.Time(info.st_ctimespec) : nil)
    }

    /// Apple's read-back for `url` if it has been read this session.
    func knownReadback(_ url: URL) -> DecodeReadback? {
        let path = url.path
        guard let stamp = Self.stamp(path) else { return nil }
        return lock.withLock {
            guard let entry = known[path], entry.source == stamp else { return nil }
            return entry.readback
        }
    }

    /// Keeps Apple's read-back for `url`, read when the file had `stamp`; dropped when the file has
    /// changed since, so a read-back never goes with other contents.
    func keepReadback(_ readback: DecodeReadback, for url: URL, readAt stamp: Stamp?) {
        guard let stamp, Self.stamp(url.path) == stamp else { return }
        lock.withLock {
            guard let entry = known[url.path], entry.source == stamp else { return }
            known[url.path]?.readback = readback
        }
    }

    /// The decoder version a decode of `url` records this session, which keys what is made from it.
    public func decoderVersion(for url: URL) -> String { choice(for: url).decoderVersion }

    /// The decoder chosen for `url` failed on it when it had `stamp`: that version goes to RAW 8 while
    /// unchanged.
    func noteFailure(_ url: URL, readAt stamp: Stamp?) {
        guard let stamp, Self.stamp(url.path) == stamp else { return }
        lock.withLock { failed[url.path] = stamp }
    }

    /// The in-house decoder cannot run on this machine: every file goes to Apple's.
    func noteUnavailable() {
        lock.withLock { inHouseAvailable = false }
    }

    /// Makes RAW 9's next `times` decodes of the file at `url` throw `error`, for tests: by default as
    /// though RAW 9 failed on the file, for good.
    func refuseRAW9(_ url: URL, with error: (any Error)? = nil, times: Int = .max) {
        let error = error ?? DecodeError.versionUnsupported(url, version: AppleRawDecoder.learnedDecoderVersion)
        lock.withLock { refused[url.path] = (error, times) }
    }

    /// What a test made RAW 9's decode of the file at `url` throw now, if anything.
    func raw9Refusal(_ url: URL) -> (any Error)? {
        lock.withLock {
            guard let refusal = refused[url.path], refusal.times > 0 else { return nil }
            refused[url.path]?.times -= 1
            return refusal.error
        }
    }
}

/// Decodes each file with the decoder `DecoderChoices` gives it, and with RAW 8 when that decoder,
/// RAW 9 or the in-house decoder, fails on it, so a frame that Apple's decoder can read always
/// decodes. A file that cannot be read, its share dropped, is an error from any of them: given to
/// RAW 8, a develop would record the frame as one its decoder fails on (`Develop.fallbackFrom`). So is
/// a failure of the machine rather than the file, the GPU's, Metal's or Core Image's render's, once
/// tried again.
///
/// A frame from the in-house decoder carries the white-balance read-back Apple's decode would have
/// recorded, read from the file's metadata through Apple's camera profile without decoding
/// (`AppleRawDecoder.readback(of:)`), since auto development reads the camera's own white balance
/// from it. Opening the file in Core Image costs about 43 ms (measured), most of an in-house decode,
/// so it is read once per file a session, beside the first decode. A RAW 9 frame carries RAW 9's
/// own. Safe to use from several threads at once.
public final class ChosenDecoder: RawDecoder, @unchecked Sendable {
    public let choices: DecoderChoices
    private let apple: AppleRawDecoder
    private let inHouse: InHouseDecoder?
    /// Bounds the in-house decodes running at once; `nil` for no bound.
    private let inHouseSlots: DispatchSemaphore?
    private let keepLock = NSLock()
    private var keeps = true
    /// Whether the in-house decoder keeps its mosaic and pyramid buffers, 271 MB at 33 MP, for its next
    /// decode, which saves 6 to 22 ms a decode; a develop bound by its encodes lets them go after each.
    public var keepsInHouseBuffers: Bool {
        get { keepLock.withLock { keeps } }
        set { keepLock.withLock { keeps = newValue } }
    }
    private static let log = Logger(subsystem: "camera.argent.Argent", category: "decode")

    /// `contextPerDecode` is Apple's decoder's (`AppleRawDecoder.init`). `inHouseAtOnce` bounds the
    /// in-house decodes running at once, each of which holds a full-size frame and its pyramid
    /// levels however small the decode, while Apple's decodes run beside them unbounded. The in-house
    /// decoder is made only on its route. Builds the GPU pipelines; call it on one thread.
    public init(gpu: GPU, choices: DecoderChoices, contextPerDecode: Bool = false, inHouseAtOnce: Int? = nil) {
        self.choices = choices
        inHouseSlots = inHouseAtOnce.map { DispatchSemaphore(value: max(1, $0)) }
        apple = AppleRawDecoder(gpu: gpu, contextPerDecode: contextPerDecode)
        if choices.route != .inHouse {
            inHouse = nil
        } else {
            do {
                inHouse = try InHouseDecoder(gpu: gpu)
            } catch {
                Self.log.error("in-house decoder unavailable, every frame goes to Apple's: \(String(describing: error), privacy: .public)")
                choices.noteUnavailable()
                inHouse = nil
            }
        }
    }

    public func decode(_ url: URL, options: DecodeOptions) throws -> LinearFrame {
        try autoreleasepool { try decodeNow(url, options: options) }
    }

    /// In a pool of its own, as Apple's decoder decodes: a command buffer holds the textures it used,
    /// a full-size frame among them, until it is released.
    private func decodeNow(_ url: URL, options: DecodeOptions) throws -> LinearFrame {
        let choice = try choices.readChoice(for: url)
        if let inHouse, choice == .inHouse {
            let source = DecoderChoices.stamp(url.path)
            do {
                // The read-back on another thread while the tiles and the GPU work.
                var readback = choices.knownReadback(url)
                let reading = DispatchGroup(), box = ReadbackBox()
                if readback == nil {
                    let stamp = DecoderChoices.stamp(url.path)
                    DispatchQueue.global(qos: .userInitiated).async(group: reading) { [choices] in
                        guard let read = AppleRawDecoder.readback(of: url) else { return }
                        choices.keepReadback(read, for: url, readAt: stamp)
                        box.value = read
                    }
                }
                // The slot is the decode's alone, not the read-back's.
                inHouseSlots?.wait()
                let decoded = Result {
                    try Self.retried(unless: { $0 is InHouseDecodeError }) { try inHouse.decode(url, options: options) }
                }
                if !keepsInHouseBuffers { inHouse.trim() }
                inHouseSlots?.signal()
                let frame = try decoded.get()
                if readback == nil {
                    reading.wait()
                    readback = box.value
                }
                return LinearFrame(image: frame.image, decoderVersion: frame.decoderVersion, scale: frame.scale,
                                   pins: frame.pins, readback: readback, picture: frame.picture)
            } catch {
                // A read the file system failed is the file's volume, not the decoder: thrown as it is, and
                // the frame is the in-house decoder's again once its share is back.
                if case InHouseDecodeError.unreadable = error { throw error }
                // Nor is a failure of the machine, twice (`retried`): thrown and not noted, as for RAW 9.
                guard error is InHouseDecodeError else { throw error }
                Self.log.error("in-house decode failed, decoding with Apple's: \(String(describing: error), privacy: .public)")
                choices.noteFailure(url, readAt: source)
            }
        }
        // Apple's decode is the larger: the in-house decoder's idle mosaics and pyramid levels, up to
        // 386 MB, do not wait through it for the next in-house frame.
        inHouse?.trim()
        var classic = options
        classic.appleDecoder = .classic
        if choice == .raw9 {
            let source = DecoderChoices.stamp(url.path)
            var learned = options
            learned.appleDecoder = .learned
            do {
                return try Self.retried(unless: { $0 is DecodeError }) {
                    if let refusal = choices.raw9Refusal(url) { throw refusal }
                    return try apple.decode(url, options: learned)
                }
            } catch {
                // A file the file system cannot read now is its volume's failure, not RAW 9's: thrown, and
                // the frame is RAW 9's again once it can be read.
                guard Self.readable(url) else { throw DecodeError.unreadable(url, "\(error)") }
                // Only the decoder's own errors say the file is at fault: the rest come from the GPU, Metal
                // or Core Image's render (`retried`). Given to RAW 8, such a frame's develop would pin it to
                // RAW 8 (`Develop.fallbackFrom`); thrown and not noted, it fails, and is RAW 9's next time.
                guard error is DecodeError else { throw error }
                Self.log.error("RAW 9 decode failed, decoding with RAW 8: \(String(describing: error), privacy: .public)")
                choices.noteFailure(url, readAt: source)
            }
        }
        return try apple.decode(url, options: classic)
    }

    /// `decode`, run once more when it throws an error `isTheFiles` does not claim: one from the machine,
    /// as a texture the GPU could not allocate while memory was short or a command buffer or render
    /// Metal or Core Image failed, which says nothing of the file and may pass a moment later.
    private static func retried(unless isTheFiles: (any Error) -> Bool, _ decode: () throws -> LinearFrame) throws -> LinearFrame {
        do {
            return try decode()
        } catch let error where !isTheFiles(error) {
            log.error("decode failed for the machine, trying again: \(String(describing: error), privacy: .public)")
            return try decode()
        }
    }

    /// Whether the file at `url` can be opened for reading now.
    static func readable(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    /// Frees what the decoders keep for the next decode.
    public func trim() {
        inHouse?.trim()
    }

    /// The bytes the in-house decoder keeps for its next decode, which that decode will not allocate.
    public var inHouseKeptBytes: Int { inHouse?.keptBytes ?? 0 }

    private final class ReadbackBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: DecodeReadback?
        var value: DecodeReadback? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
