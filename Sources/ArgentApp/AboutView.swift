import SwiftUI

/// The About window: the name in the display face, the version, and what the stocks are built
/// from. Argent is a personal app, so it carries no licence or notices (docs/deferred.md).
struct AboutView: View {
    static let windowID = "about"

    /// Datasheet status (spec, Film library, amended 2026-10-07): no stock is fitted to scans.
    static let statusNote = """
        Most stocks are based on Kodak and Fujifilm datasheets. ColorPlus 200 uses Gold 200 as a proxy; \
        Tungsten 800 uses CineStill's published C-41 curves with proxy spectra. \
        Portra Natural reduces Portra 160's coupling for gentler skin colour. None is fitted to lab scans.
        """

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

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
