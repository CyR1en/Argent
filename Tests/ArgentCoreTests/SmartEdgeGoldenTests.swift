import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArgentCore

/// Every kind of record that could exist before `SmartEdge`, byte for byte: digests of its render, its first slice, its slots' identity,
/// its record and its digest, taken at `12728eb`, before any change of this task, by this same test (which compiles there unchanged).
@Suite struct SmartEdgeGoldenTests {
    private static let picture = try! MaskSpace(width: 7008, height: 4672)

    static func sha(_ bytes: some DataProtocol) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }
    static func sha(_ bits: [UInt16]) -> String { bits.withUnsafeBytes { sha(Data($0)) } }
    static func sha(_ values: [Float]) -> String { values.withUnsafeBytes { sha(Data($0)) } }

    static func id(_ n: UInt8) -> UUID { UUID(uuid: (n, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n)) }

    /// One of each: no masks; gradients; a brush; a Follow edges stroke's measured shape (schema 3); Sky, Person, Subject and Background on
    /// today's path, alone with Exposure (tier 2) and tone-only (tier 1); a Feather (schema 2); and composed.
    static func sets(soft: MaskRaster, hard: MaskRaster, person: MaskRaster, shape: MaskRaster) throws -> [(name: String, masks: [Mask])] {
        let frame = try MaskFrame(orientation: 1, width: 7008, height: 4672, decoder: .raw9, lensCorrection: true)
        let exposure = try ManualAdjustments(exposureEV: -1.5), tone = try ManualAdjustments(highlights: -40, shadows: 30)
        let stroke = BrushStroke(radius: 0.04, feather: 1, flow: 0.8,
                                 points: try PackedPoints.pack([MaskPoint(x: 0.6, y: 0.15), MaskPoint(x: 0.75, y: 0.2), MaskPoint(x: 0.9, y: 0.12)]))
        let brush = MaskComponent(operation: .subtract, shape: .brush(BrushPaint(frame: frame, strokes: [stroke])))
        let followed = BrushStroke(followEdges: true, radius: 0.02, points: try PackedPoints.pack([MaskPoint(x: 0.25, y: 0.2)]),
                                   measured: try MeasuredStroke(raster: shape.ref, x: 400, y: 300, pictureWidth: 7008, pictureHeight: 4672))
        let gradient = MaskComponent(shape: .linear(.init(full: MaskPoint(x: 0.1, y: 0.1), zero: MaskPoint(x: 0.9, y: 0.6))))
        let radial = MaskComponent(operation: .intersect, shape: .radial(.init(center: MaskPoint(x: 0.5, y: 0.3), semiAxisA: 0.3, semiAxisB: 0.2, angle: 0.3, feather: 40)))
        let sky = try Refine.component(.sky, soft), personal = try Refine.component(.person, person)
        let subject = try Refine.component(.subject, hard), background = try Refine.component(.background, hard)
        var feathered = subject
        if case .smart(var selection) = feathered.shape { selection.feather = 40; feathered.shape = .smart(selection) }
        return [("no masks", []),
                ("gradients", [Mask(id: id(1), components: [gradient, radial], adjustments: exposure)]),
                ("brush", [Mask(id: id(2), components: [brush.replacing(.add)], adjustments: exposure)]),
                ("follow edges", [Mask(id: id(3), components: [MaskComponent(shape: .brush(BrushPaint(frame: frame, strokes: [followed])))], adjustments: exposure)]),
                ("sky", [Mask(id: id(4), components: [sky], adjustments: exposure)]),
                ("person", [Mask(id: id(5), components: [personal], adjustments: exposure)]),
                ("subject", [Mask(id: id(6), components: [subject], adjustments: exposure)]),
                ("subject tone", [Mask(id: id(7), components: [subject], adjustments: tone)]),
                ("background", [Mask(id: id(8), components: [background], adjustments: exposure)]),
                ("subject inverted", [Mask(id: id(9), components: [try Refine.component(.subject, hard, invert: true)], adjustments: exposure)]),
                ("feathered", [Mask(id: id(10), components: [feathered], adjustments: exposure)]),
                ("composed", [Mask(id: id(11), components: [subject, brush], adjustments: exposure)]),
                ("two selections", [Mask(id: id(12), components: [subject, try Refine.component(.person, person, operation: .intersect)], adjustments: exposure),
                                    Mask(id: id(13), components: [sky], adjustments: try ManualAdjustments(exposureEV: 0.7))])]
    }

    /// Each record's digests, as `12728eb` printed them.
    @Test func everyRecordThatExistsRendersAsBefore() throws {
        let gpu = try GPU()
        let (pixels, matte) = Refine.scene(width: 1200, height: 800)
        let soft = try Refine.seed(matte: matte, width: 1200, height: 800, seedWidth: 378, seedHeight: 252, binary: false)
        let hard = try Refine.seed(matte: matte, width: 1200, height: 800, seedWidth: 512, seedHeight: 512, binary: true)
        let person = try Refine.seed(matte: matte, width: 1200, height: 800, seedWidth: 504, seedHeight: 378, binary: false)
        let shape = try MaskRaster(width: 120, height: 40, plane: (0..<4800).map { UInt8($0 % 200) })
        gpu.maskRefiner.seeds = Refine.Seeds([soft, hard, person, shape])
        let renderer = try FilmRenderer(gpu: gpu, stock: LightCompilerBaselineTests.toyStock())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out: [String: [String]] = [:]
        for (name, masks) in try Self.sets(soft: soft, hard: hard, person: person, shape: shape) {
            let frame = try MaskRender.frame(gpu, pixels, width: 1200, picture: Self.picture)
            let settings = DevelopSettings(halation: true, sharpen: true, manual: try MaskRender.manual(try ManualAdjustments(shadows: 20), masks: masks, reference: 0.3))
            let render = Self.sha(MaskRender.bits(try renderer.render(frame, settings: settings).image.texture))
            let set = try MaskSet(masks: masks)
            if masks.isEmpty {
                out[name] = [render, Self.sha(try encoder.encode(set))]
                continue
            }
            let inputs = try #require(try Refine.scene(renderer, frame, settings).masks)
            out[name] = [render, Self.sha(inputs.coverage.values(slot: 0)), inputs.coverage.identity, Self.sha(try encoder.encode(set)), set.digest]
        }
        print("edge goldens: " + String(decoding: try encoder.encode(out), as: UTF8.self))
        #expect(out == Self.golden)
    }

    static let golden: [String: [String]] = [
        "background": ["b4d10b4db72110d368c02bfaa5c126cdaf0bc70389865dfe6156940a0bef73df", "760ea2a7177db93bff0561ae743984b73a0ab91a4939ca1385d87c67607a2360", "8365402ea047527368c57db80cda9a9d601a2242e08006e45a2f90182d65f43f", "b5839dbe11cfba070e72b5ede7acd1838319a87d81b788c472928440b79ab599", "dd280562267bc188bc807d5723ff88d40c691b9b1017869512dfef2332fb84bc"],
        "brush": ["e1843c825dcd76962d0fde69cd17202267cde45b83b2402f8ab99b260a9b1508", "6812618663502703b03d498fd160c401e54eb9cdc9fa2b5ff78482acda89708a", "f7bf052fbea035f5d619f6453271f5215c984949f1131fee1576da46fd4f0c8f", "1c5c1ca6bd176025cdf5e5fe357a7a1c1f8f36a186bb4b5dbb8f626a9a4fb4be", "2e94be1d6726b7ba4065c235f1ae6ec9b2af823c68cb455ac6bf781896ac009a"],
        "composed": ["4216c447c44330b6e8ffdad4cf39347a5ae8d4138164953e6e3f49af463c2755", "774ec9083431b81aad83c66b53cb8d23232978d213a04698d2c4656972f3bdb2", "6562abcebd603cb1edd424d854a3ee0c051b84bcc794efc056f9d02c94a1687f", "4da9fca413fc199a44a4fff3095273e488846754e8e39e61cfde89eac090747d", "cfeb97225e46adccaabc4653c06ef7dce94fee574c29c9641ad680e9e6546082"],
        "feathered": ["1ee2cd4de7c11f1bbb7e5be5acecc9e1de361af740bb9f5ac92568734bef886b", "8072157229af92923d8156dcac4ea45feded4cbd12da37e9cb7040f93192042d", "b1e58267616df31a9f44d83672cf979890f20bb83eace46b4f70ae94c1fac46e", "dfe9b6c7b5e7796d23c13523673d1e3bbec19ca7d8f57cb546aaf3be90022367", "444bf3095c791ad697afdf28e06dfcb1ea353f6d1bd28d53a8be714cd7fa35d0"],
        "follow edges": ["41508c3c457bda2681c7a52670994c17dbe04ee8941de8a6b875cdc1229a048c", "21894cdc8c8b2962542f4002bb8d9c06ea3e4d7bfdd42af6ed6a1abc8bb6f464", "594e381798ad783ed657f941f1599378f4ce40e3123eb3e6ec82de855edd4359", "4dedb2ae508e51dc8404c3d28a59625b62ae92b0579cef8df82d5e535842e034", "3e4f8cf4e431551dd7f77a234b96904a2a00ad5e1c3a6b5249176b821a11c67c"],
        "gradients": ["c9da347d3ff5aed37a377289624474234178e7399a73fcf9955716b0c697da40", "380263d6082eb844f063a353534d49674bee815fa3eb3a0998650335f67614b4", "90503abb3cece7dccb8ff4355bb52f016f543903c57f876e457876cc9ffca2f8", "e8fa4f6184a1a8253941a5a0a2dee009a2492b6b9ea3d46ead859d2cae60cbd5", "d1e32e632ba16ee97e345104bdeff1af4166db36a48a82ff10bc98353cac4137"],
        "no masks": ["5ed6d9d344a8531ea08c261eb1cc221f71a94b7c78530ccb5ccebe17d2f30f4f", "9a0927d1dbd0f2cf6c381984e3569761821d7f4b7087621c44066e9a56d95bb1"],
        "person": ["d5d4aaa16474de75e3fb67f79f4956b5548342ae1c90668382dd4b70e026c4aa", "d6cb498457186670f84d4210237f606d34eb6596450def6c6989f30e3d6e9f20", "75d293caf6af18715db0200d8a6ed2255b37caf5ecdb0355ff7a1dc1f1be2858", "607b49fa1bf70336c49294137dde260c5cf7b3ad7824ede016056ae30831fd9f", "445be469e88f55d282b37bd404db3f6ec1652acdb8c91ff56895657141164018"],
        "sky": ["cb1da63637a61cdb023d514303e19fc46d3559b7336b09e3182d1d0443d5743e", "f14cb7fdbbac67bda2fbb16c5c264b7ef0837fa2077c6ae7be0cc0af9d0fcf71", "7430277ca5c55ea30b00545363f08109a416500d44a9b35dfb56969bf3d8a839", "f3fb6875f615fa3caee2ea75770c02d7bbb6d9aa9c84b5c3e2d3293ad078f3d4", "3aa142e1bca39fd69b888951a09d5351095178e96bcb708664b0d43b3bc61ec3"],
        "subject": ["eac8e80f1335ae5dcdeb25fb48eb098d36d55b50c0e8768b92f947c1ebd3d726", "4c5812b57f52b68e142ce32930a798d8640a5b8093fade0eae8732cc5a2945f6", "6f9ba88cc0b8d9e1b8cff3bf6add22eebb967989c5fd723513603ce6f89fd99d", "074ade038948117c38be72010ee1da9faea4d0e469b267b44ccd581ea7f7ec46", "c286096530c307b15809b79a90a0e440ce1a9e314d5cf57ecb9cb1babce0d484"],
        "subject inverted": ["b4d10b4db72110d368c02bfaa5c126cdaf0bc70389865dfe6156940a0bef73df", "760ea2a7177db93bff0561ae743984b73a0ab91a4939ca1385d87c67607a2360", "7c6526ce0b9020175bc1c620fbe814d50aadc75ae810deaa6bae65c812a4b5a9", "eb14ec893b1c0e2510b2f03bfa1103f4a9d604d245c2f69be8f33a0e96a3bfb4", "682313e4faf5081a1f32f7197dc7b4ed4199529153d2f815c284d48864ac0c84"],
        "subject tone": ["ee29a062318228cd0683568e13a8f5894a7855d17bd162a5d03c15f55d5bb90c", "4c5812b57f52b68e142ce32930a798d8640a5b8093fade0eae8732cc5a2945f6", "6f9ba88cc0b8d9e1b8cff3bf6add22eebb967989c5fd723513603ce6f89fd99d", "993e26a6466ba28850012f65998157401e8ae325adb21405b3b4d53c7c9fa6a7", "a6e6161432d34a6a5a81a50abd4003b22c1773630bd45f27563264a2437dd4fc"],
        "two selections": ["ef6c65e699b7e2e572f26a390949275cd6c7a631ed8c4b6fbe601e2d6b647bb9", "719f7fb18c23068d9365c220ca78a61db1e32d5c1ea97f812867c5f9e110bc4f", "9a59aeac09fa3d9b688f4a9c1e7efa5b5a349f8f6dae4ecea03142b1719245d9", "3ec92550baa3bee6153b41a1cc08e9985d230f8e3313ff556ac3f1c39ac5a108", "97e4048f570d7b7ade9535e2c7d5aeb5fc019b43476e820c1631125977fb7689"],
    ]
}

extension MaskComponent {
    fileprivate func replacing(_ operation: MaskOperation) -> MaskComponent { MaskComponent(operation: operation, shape: shape, invert: invert) }
}
