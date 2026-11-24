import SwiftUI

/// The About window: the name in the display face, the version, what the stocks are built from, and the models' notice: the DINOv3 License asks for
/// "Built with DINOv3" where a product built with it is described (Subject's S3OD and EoMT, Sky's EoMT).
struct AboutView: View {
    static let windowID = "about"

    /// Datasheet status (spec, Film library, amended 2026-10-07): no stock is fitted to scans.
    static let statusNote = """
        Most stocks are based on Kodak and Fujifilm datasheets. ColorPlus 200 uses Gold 200 as a proxy; \
        Tungsten 800 uses CineStill's published C-41 curves with proxy spectra. \
        Portra Natural reduces Portra 160's coupling for gentler skin colour. None is fitted to lab scans.
        """

    /// The smart masks' models are not Argent's and not under its licence: their notice, and where their terms are.
    static let modelsNote = """
        Built with DINOv3. Subject, Background and Sky use models made by others, under their own licences; Argent shows the Subject models' licences before they download.
        """

    /// "Version 0.2.0 (412)" for a release; a nightly or a local build names its channel and commit,
    /// "Version 0.1.0 nightly (412 · a1b2c3d)". scripts/build-app.sh writes the keys from the v* tag.
    static func versionText(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let short = info?["ArgentVersion"] as? String
            ?? info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String
        let channel = info?["ArgentChannel"] as? String
        let commit = info?["ArgentCommit"] as? String
        var text = "Version \(short)"
        if let channel, channel != "release" { text += " \(channel)" }
        var detail = [build].compactMap(\.self)
        if channel != "release", let commit { detail.append(commit) }
        if !detail.isEmpty { text += " (\(detail.joined(separator: " · ")))" }
        return text
    }

    private var version: String { Self.versionText() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Argent")
                    .font(DisplayFace.font(size: 34, face: "Medium"))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: version)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(verbatim: Self.statusNote)
                .foregroundStyle(.secondary)
            Text(verbatim: Self.modelsNote)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Graphite.Metric.xl)
        .padding(.top, 8)
        .frame(width: 440)
        .containerBackground(Graphite.chrome, for: .window)
        // In the chosen theme, as the main window is.
        .preferredColorScheme(AppearanceSettings.shared.colorScheme)
    }
}
