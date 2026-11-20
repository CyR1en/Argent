import ArgentRoll
import Foundation

func copyKeepers(_ arguments: [String]) -> Never {
    guard arguments.count == 4, arguments[2] == "--names" else {
        fail("usage: argent-spike copy <card folder> <destination> --names DSC00001.ARW,DSC00002.ARW", code: 2)
    }
    let card = URL(fileURLWithPath: arguments[0], isDirectory: true)
    let folder = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let names = arguments[3].split(separator: ",").map { String($0) }
    let dcim = card.appendingPathComponent("DCIM")
    let places = ((try? FileManager.default.contentsOfDirectory(atPath: dcim.path)) ?? [])
        .filter(CardScanner.isDCFFolder).sorted().map { dcim.appendingPathComponent($0) } + [card]
    var raws: [URL] = []
    for name in names {
        let found = places.map { $0.appendingPathComponent(name) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !found.isEmpty else { fail("\(name) is not on \(card.path)", code: 2) }
        raws += found
    }

    let tally = Tally()
    let copy = Task {
        do {
            _ = try await KeeperCopy.run(raws, to: folder) { raw, outcome in await tally.add(raw, outcome) }
            print(await tally.summary)
            exit(0)
        } catch is CancellationError {
            print(await tally.summary)
            fail("stopped by Ctrl-C", code: 130)
        } catch let stopped as KeeperCopy.Stopped {
            print(await tally.summary)
            fail("stopped at \(stopped)", code: 1)
        } catch {
            fail("\(error)", code: 1)
        }
    }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { copy.cancel() }
    interrupt.resume()
    dispatchMain()
}

private func fail(_ message: String, code: Int32) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("copy: \(message)\n".utf8))
    exit(code)
}

private actor Tally {
    private var copied = 0
    private var alreadyThere = 0
    private var conflicts = 0
    private var failed = 0

    func add(_ raw: URL, _ outcome: KeeperCopy.Outcome) {
        let name = raw.lastPathComponent
        switch outcome {
        case .copied(let sha256):
            copied += 1
            print("copied         \(name)  \(sha256)")
        case .alreadyThere(let sha256):
            alreadyThere += 1
            print("already there  \(name)  \(sha256)")
        case .conflict(let existing):
            conflicts += 1
            print("conflict       \(name)  \(existing.path) holds another file of that name")
        case .failed(let failure):
            failed += 1
            print("failed         \(name)  \(failure)")
        }
    }

    var summary: String {
        "copied \(copied), already there \(alreadyThere), conflicts \(conflicts)" + (failed > 0 ? ", failed \(failed)" : "")
    }
}
