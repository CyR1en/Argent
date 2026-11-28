import ArgentRoll
import SwiftUI

/// Develop again over the same destination: the frames already developed from the same recipe are
/// skipped, so what is left is the frames that failed or were not started, and any a setting has
/// changed. Resume after a stop goes on with the frames that develop had, whatever the sheet shows
/// now; Develop again after failures alone is Roll > Develop, the frames shown.
private struct DevelopAgainButton: View {
    @Environment(RollModel.self) private var model
    let report: DevelopReport

    var body: some View {
        Button(report.wasStopped ? "Resume" : "Develop again") {
            model.isIssueDetailsShown = false
            model.develop(resuming: report.wasStopped ? report : nil)
        }
        .buttonStyle(.graphite(.secondary, size: .small))
        .disabled(report.wasStopped ? (!model.canStartDevelop || model.developDestination == nil) : !model.menus.canDevelop)
        .help(report.wasStopped
              ? "Develop the stopped develop's frames not started and any that failed; frames already developed with these settings are skipped."
              : "Develop the frames shown; those already developed with these settings are skipped, so the ones that failed develop again. Command-D.")
    }
}

/// The popover: what the last develop did, each frame it could not write and why, and the raws
/// left out of the roll.
struct IssueDetails: View {
    @Environment(RollModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let report = model.lastDevelop, report.isUnfinished { unfinished(report) }
                    if !model.missingStockReasons.isEmpty { missingStocksSection(model.missingStockReasons) }
                    if let unreadable = model.roll?.unreadable, !unreadable.isEmpty { unreadableSection(unreadable) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if let report = model.lastDevelop, !report.files.isEmpty {
                    Button("Reveal in Finder") { model.revealDeveloped() }
                        .buttonStyle(.graphite(.secondary, size: .small))
                        .help("Show the developed files in Finder. Shift-Command-R.")
                }
                if let report = model.lastDevelop, report.isUnfinished {
                    DevelopAgainButton(report: report)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
        .foregroundStyle(Graphite.text)
    }

    private func unfinished(_ report: DevelopReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: report.failures.isEmpty ? "Develop stopped"
                 : report.failures.count == 1 ? "1 frame not developed" : "\(report.failures.count) frames not developed")
                .font(Graphite.Typeface.sectionTitle)
            Text(verbatim: "\(report.countsLine), in \(DevelopStatusText.abbreviated(report.destination))")
                .font(Graphite.Typeface.label)
                .foregroundStyle(Graphite.secondaryText)
            if report.wasStopped {
                // Not failed: the stopped develop did not reach them, whatever an earlier one did.
                Text(verbatim: "Stopped before \(report.stopped == 1 ? "1 frame" : "\(report.stopped) frames"). Resume goes on with them; frames already developed with these settings are skipped.")
                    .font(Graphite.Typeface.label)
                    .foregroundStyle(Graphite.secondaryText)
            }
            if let shared = report.sharedReason {
                // The destination, not the frames: say it once.
                Text(verbatim: shared)
                    .font(Graphite.Typeface.label)
                Text(verbatim: report.failures.map(\.fileName).joined(separator: ", "))
                    .font(Graphite.Typeface.label)
                    .foregroundStyle(Graphite.secondaryText)
            } else {
                ForEach(report.failures, id: \.frame.url) { failure in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: failure.fileName)
                            .font(Graphite.Typeface.label)
                        Text(verbatim: failure.reason)
                            .font(Graphite.Typeface.small)
                            .foregroundStyle(Graphite.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func missingStocksSection(_ reasons: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: reasons.count == 1 ? "Missing film stock" : "Missing film stocks")
                .font(Graphite.Typeface.sectionTitle)
            ForEach(reasons, id: \.self) { reason in
                Text(verbatim: reason)
                    .font(Graphite.Typeface.label)
                    .foregroundStyle(Graphite.secondaryText)
            }
        }
    }

    private func unreadableSection(_ unreadable: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: unreadable.count == 1 ? "1 raw file could not be read" : "\(unreadable.count) raw files could not be read")
                .font(Graphite.Typeface.sectionTitle)
            Text(verbatim: unreadable.count == 1 ? "Its header could not be read, so it is not in the roll and does not develop."
                 : "Their headers could not be read, so they are not in the roll and do not develop.")
                .font(Graphite.Typeface.label)
                .foregroundStyle(Graphite.secondaryText)
            ForEach(unreadable, id: \.self) { url in
                Text(verbatim: model.roll.map { Self.relativePath(url, in: $0.folder) } ?? url.lastPathComponent)
                    .font(Graphite.Typeface.label)
            }
        }
    }

    /// The file's path inside the roll, so a card's DCIM folders tell same-named files apart.
    static func relativePath(_ url: URL, in folder: URL) -> String {
        let base = folder.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }
}
