import Foundation

// Parity driver for the mask analysis' Python port of R5's arithmetic (mask_models.RampTables.r5_level).
// Compiled together with R5's snapshot of Sources/ArgentCore and R5's harness file cpuref.swift, unmodified, so the
// arithmetic run here is R5's own `SceneCPU.gains`. It reads cases from a JSON file (argument 1) and prints, for each case,
// the stops of exposure and of tone gain. Tables are arrays of gains in stops on a grid `start + i * step`.

extension ManualToneTables {
    /// A pair of tables from arrays, for the arithmetic only (the film's transfer plays no part in `SceneCPU.gains`).
    init(start: Float, step: Float, global: [Float]?, local: [Float]?, count: Int) {
        self.start = start
        self.step = step
        self.global = global ?? [Float](repeating: 0, count: count)
        self.local = local ?? [Float](repeating: 0, count: count)
        self.globalActive = global != nil
        self.localActive = local != nil
        self.transfer = [Float](repeating: 0, count: count)
        self.regularized = [Float](repeating: 0, count: count)
    }
}

func floats(_ any: Any?) -> [Float]? { (any as? [Double])?.map { Float($0) } }

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
let start = Float(root["start"] as! Double), step = Float(root["step"] as! Double), count = root["count"] as! Int
for item in root["cases"] as! [[String: Any]] {
    let panelJSON = item["panel"] as! [String: Any]
    let panel = ManualToneTables(start: start, step: step, global: floats(panelJSON["global"]), local: floats(panelJSON["local"]), count: count)
    var layers: [MaskLayerCPU] = []
    for l in item["layers"] as! [[String: Any]] {
        let t = ManualToneTables(start: start, step: step, global: floats(l["global"]), local: floats(l["local"]), count: count)
        layers.append(MaskLayerCPU(exposure: Float(l["exposure"] as! Double), tables: t))
    }
    // reference = log2 0.18 cancels SceneCPU's "- log2 0.18": the level is x + E0 + the masks' exposure
    let scene = SceneCPU(E0: Float(item["E0"] as! Double), reference: log2_018, global: panel, layers: layers)
    let g = scene.gains(x: Float(item["x"] as! Double), xb: Float(item["xb"] as! Double), c: (item["c"] as! [Double]).map { Float($0) })
    print(String(format: "%.9g %.9g", g.exposure, g.tone))
}
