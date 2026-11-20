import Foundation

/// A settings-free read of one version of a raw.
public struct LensFile: Sendable, Equatable {
    public let correction: SonyLensCorrection?
    public let picture: MaskSpace?
    public let metadata: LensMetadata?

    public init(correction: SonyLensCorrection?, picture: MaskSpace?, metadata: LensMetadata?) {
        self.correction = correction
        self.picture = picture
        self.metadata = metadata
    }

    public init(reading url: URL) {
        var correction: SonyLensCorrection?, picture: MaskSpace?
        func read() {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            guard let reader = try? TIFFReader(handle: handle),
                  let layout = try? ARWLayout.parse(reader),
                  let foundPicture = try? AppleRawDecoder.fullSizePicture(native: CGSize(width: layout.cropSize.width, height: layout.cropSize.height),
                                                                    orientation: .up, layout: layout),
                  let ifd0 = try? reader.readIFD(at: reader.firstIFDOffset),
                  let subIFDs = try? ifd0[0x014A].map({ try reader.integers($0) })
            else { return }
            picture = foundPicture
            for offset in subIFDs {
                guard let ifd = try? reader.readIFD(at: offset) else { continue }
                let subfileType = (try? ifd[0x00FE].map { try reader.integers($0).first ?? 0 }) ?? 0
                guard subfileType == 0, ifd[0x0103] != nil else { continue }
                correction = SonyLensCorrection.parse(ifd, reader: reader)
                return
            }
        }
        read()
        self.init(correction: correction, picture: picture, metadata: try? LensMetadata.read(from: url))
    }
}

public struct LensAvailability: Sendable, Equatable {
    public enum Distortion: Sendable, Equatable { case file(cameraOff: Bool), none(String) }
    public let distortion: Distortion
    public var distortionLine: String {
        switch distortion {
        case .file(let cameraOff): "Distortion, from the file" + (cameraOff ? ", camera set to Off" : "")
        case .none(let reason): "Distortion, " + reason
        }
    }
}

public enum LensResolver {
    public static func resolve(_ file: SonyLensCorrection?, picture: MaskSpace, settings: LensSettings) -> ResolvedLensCorrection {
        let base: ResolvedLensCorrection
        if let file, file.distortionState != .absent, file.distortionState != .identity, let curve = file.distortion {
            do {
                let table = try RadialTable(knots: curve.knots.map { 1 + Double($0) / 16384 })
                if LensWarp.readRises(curve) {
                    base = try ResolvedLensCorrection(red: table, green: table, blue: table, gain: .one,
                                                      status: .init(distortion: .file), width: picture.width, height: picture.height)
                } else { base = .uncorrected("the file's curve folds the picture") }
            } catch LensCorrectionError.readRadiusFalls {
                base = .uncorrected("the file's curve folds the picture")
            } catch LensCorrectionError.localScale {
                base = .uncorrected("the file's curve is too strong for the stage")
            } catch { base = .uncorrected("the file's curve cannot be read") }
        } else { base = .uncorrected("none in the file") }
        let legacy = file?.correctsDistortion == true ? base.geometry : ResolvedLensCorrection.identity.geometry
        let result: ResolvedLensCorrection
        if base.status.distortion != .file {
            result = base
        } else if !settings.distortion.isOn || settings.distortion.amount == 0 {
            result = .identity
        } else if settings.distortion.amount == 100 {
            result = base
        } else {
            do {
                let made = try LensAmount.scaled(base.green, scale: base.scale,
                                                 amount: settings.distortion.amount, picture: picture)
                result = try ResolvedLensCorrection(red: made.table, green: made.table, blue: made.table, gain: .one,
                                                    status: .init(distortion: .file), scale: made.scale)
            } catch { result = .uncorrected("the amount is too strong for this lens") }
        }
        let vignetted: ResolvedLensCorrection
        if settings.vignetting.amount == 0 {
            vignetted = result
        } else {
            let p = pow(2, (Double(settings.vignetting.midpoint) - 50) / 25)
            let gain = try! RadialTable(knots: (0...RadialTable.intervals).map { i in
                pow(2, (Double(settings.vignetting.amount) / 100) * 2 * pow(Double(i) / Double(RadialTable.intervals), p))
            })
            vignetted = try! ResolvedLensCorrection(red: result.red, green: result.green, blue: result.blue, gain: gain,
                                                    status: result.status, scale: result.scale)
        }
        return vignetted.remembering(legacy: legacy).defringing(DefringeParameters(settings.defringe)).removing(settings.removals)
    }

    public static func resolve(_ file: LensFile, settings: LensSettings) -> ResolvedLensCorrection {
        guard let picture = file.picture else {
            return ResolvedLensCorrection.uncorrected("none in the file").defringing(DefringeParameters(settings.defringe)).removing(settings.removals)
        }
        return resolve(file.correction, picture: picture, settings: settings)
    }

    public static func correction(for url: URL, settings: LensSettings) -> ResolvedLensCorrection {
        resolve(LensFile(reading: url), settings: settings)
    }

    public static func availability(_ file: LensFile) -> LensAvailability {
        switch resolve(file, settings: .default).status.distortion {
        case .file: LensAvailability(distortion: .file(cameraOff: file.correction?.distortionState == .offByCamera))
        case .none(let reason): LensAvailability(distortion: .none(reason))
        case .off: LensAvailability(distortion: .none("none in the file"))
        }
    }
}
