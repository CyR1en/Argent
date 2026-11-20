import ArgentCore
import Foundation

// argent-remove: the helper that holds the model Remove runs (docs/remove-plan.md, section 4.5). The app starts it on a folder in
// its container and talks to it through that folder's files: `engine.json` for its state, `want` for whether the model should be
// loaded, and one folder a job (`RemovalFolder`, which the app reads through `FolderEngine`), and
// the process's exit is the model unloaded.
//
//     argent-remove --root DIR --models DIR       the four Core AI graphs in DIR (Contents/Resources/Models in the app)
//     argent-remove --root DIR --fake             no model: FakeRemovalEngine's drawing, for the suites
//
// Options: --idle SECONDS (600; 0 for never), --stale SECONDS (30), --fake-prepare-seconds, --fake-load-seconds,
// --fake-step-seconds, --fake-compile-seconds, --fake-prepares.

let usage = "usage: argent-remove --root DIR (--models DIR | --fake) [--idle S] [--stale S]\n"
var arguments = ArraySlice(CommandLine.arguments.dropFirst())
var root: URL?, models: URL?, fake = false
var options = RemoveServer.Options(root: URL(fileURLWithPath: "/"))
var delays = FakeModel.Delays()

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data(text.utf8))
    exit(EX_USAGE)
}

while let argument = arguments.popFirst() {
    func value() -> String {
        guard let value = arguments.popFirst() else { fail(usage) }
        return value
    }
    func seconds() -> TimeInterval {
        guard let seconds = TimeInterval(value()), seconds >= 0 else { fail(usage) }
        return seconds
    }
    switch argument {
    case "--root": root = URL(fileURLWithPath: value(), isDirectory: true)
    case "--models": models = URL(fileURLWithPath: value(), isDirectory: true)
    case "--fake": fake = true
    case "--idle": options.idle = seconds()
    case "--stale": options.stale = seconds()
    case "--fake-prepare-seconds": delays.prepare = seconds()
    case "--fake-load-seconds": delays.load = seconds()
    case "--fake-step-seconds": delays.step = seconds()
    case "--fake-compile-seconds": delays.compile = seconds()
    case "--fake-prepares": delays.prepares = true
    default: fail(usage)
    }
}
guard let root, fake != (models != nil) else { fail(usage) }
options.root = root.standardizedFileURL
do {
    try FileManager.default.createDirectory(at: options.root, withIntermediateDirectories: true)
} catch {
    fail("argent-remove: \(options.root.path) cannot be made: \(error.localizedDescription)\n")
}

let model: any RemovalModel = models.map {
    ObjectClearModel(directory: $0.standardizedFileURL, ledgerFile: options.root.appendingPathComponent(".compiled.json"))
} ?? FakeModel(delays)
await RemoveServer(options: options, model: model).serve()
