import ArgentCore
import ImageIO
import SwiftUI

/// The miniature is laid out in window points before it is scaled to its proof.
struct DevelopProof: View {
    static let size = CGSize(width: 760, height: 452)

    let palette: ThemePalette
    let pictures: [CGImage?]
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var colors: GraphiteColors { GraphiteColors(palette) }
    private static let railSymbols = [
        "film.stack", nil, "square.grid.2x2", "photo", nil, "square.3.layers.3d",
        "slider.horizontal.3", nil, "square.and.arrow.up", nil, "gearshape",
    ]

    var body: some View {
        VStack(spacing: 0) {
            titleStrip
                .zIndex(1)
            HStack(spacing: 0) {
                rail
                    .zIndex(1)
                workspace
                panel
                    .frame(width: Graphite.Metric.inspectorPanelWidth)
                    .padding(.horizontal, Graphite.Metric.inspectorGutter)
            }
            .padding(.bottom, Graphite.Metric.workspaceInset)
        }
        .background {
            AppearanceSettings.shared.shellStyle(for: palette, reduceTransparency: reduceTransparency).overlay
                .background(colors.proofBackdrop)
        }
        .foregroundStyle(colors.text)
        .font(Graphite.Typeface.body)
        .accessibilityHidden(true)
    }

    private var titleStrip: some View {
        ZStack {
            VStack(spacing: 1) {
                Text("Sample roll").font(Graphite.Typeface.chipTitle)
                Text("24 frames · Auto ready").font(Graphite.Typeface.caption.monospacedDigit())
            }

            HStack(spacing: Graphite.Metric.s) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(colors.ink.opacity(0.22)).frame(width: 12, height: 12)
                }
            }
            .padding(.leading, 20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Argent")
                .font(Graphite.Typeface.wordmark)
                .padding(.leading, Graphite.Metric.titleStripLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(colors.ink)
        .frame(height: Graphite.Metric.titleStripHeight)
    }

    private var rail: some View {
        VStack(spacing: 2) {
            ForEach(Self.railSymbols.indices, id: \.self) { index in
                if let symbol = Self.railSymbols[index] {
                    Image(systemName: symbol)
                        .font(.system(size: Graphite.Metric.railIcon, weight: .light))
                        .frame(width: Graphite.Metric.railItem, height: Graphite.Metric.railItem)
                        .background {
                            if symbol == "square.and.arrow.up" {
                                RoundedRectangle(cornerRadius: Graphite.Metric.railItemRadius)
                                    .fill(colors.segmentThumb)
                                    .shadow(color: Graphite.shadow, radius: 4, y: 1)
                            }
                        }
                } else {
                    colors.ink.opacity(0.09)
                        .frame(width: 20, height: 1)
                        .padding(.vertical, 4)
                }
            }
        }
        .foregroundStyle(colors.shellSecondaryText)
        .frame(width: Graphite.Metric.railWidth)
        .frame(maxHeight: .infinity)
    }

    private var workspace: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.workspaceRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 14) {
            segments(["All 24", "Flagged 3", "Unflagged 21"])
            VStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: Graphite.Metric.m) {
                        ForEach(0..<3, id: \.self) { column in
                            frame(row * 3 + column)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Graphite.Metric.edge)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.workspace, in: shape)
        .background { WorkspaceShadow(isDark: colors.isDark, fill: colors.workspace) }
        .overlay {
            if contrast == .increased { shape.strokeBorder(colors.strongBorder, lineWidth: 1) }
        }
    }

    private func frame(_ index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.thumbnailRadius)
        return VStack(spacing: 5) {
            ProofPhotograph(picture: pictures.indices.contains(index) ? pictures[index] : nil, index: index)
                .aspectRatio(3.0 / 2, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark")
                        .font(Graphite.Typeface.pill)
                        .foregroundStyle(colors.proofHighlight)
                        .frame(width: 15, height: 15)
                        .background(colors.proofBadgeShadow, in: Circle())
                        .overlay { Circle().strokeBorder(colors.proofHighlight.opacity(0.3), lineWidth: 1) }
                        .padding(5)
                }
                .clipShape(shape)
                .overlay {
                    if index == 1 {
                        shape.strokeBorder(colors.workspace, lineWidth: 2)
                            .padding(-2)
                        RoundedRectangle(cornerRadius: Graphite.Metric.thumbnailRadius + 4)
                            .strokeBorder(colors.selection, lineWidth: 2)
                            .padding(-4)
                    }
                }
            Text(verbatim: "DSC0\(4051 + index)")
                .font(Graphite.Typeface.caption.monospacedDigit())
                .foregroundStyle(index == 1 ? colors.text : colors.secondaryText)
        }
    }

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.workspaceRadius, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Develop").font(Graphite.Typeface.panelTitle)
                Spacer()
                Image(systemName: "xmark")
                    .font(Graphite.Typeface.row)
                    .foregroundStyle(colors.secondaryText)
            }
            Text("24 frames · Portra 400")
                .foregroundStyle(colors.secondaryText)
                .padding(.top, 4)
            panelDivider
            Text("Save to")
                .font(Graphite.Typeface.small)
                .foregroundStyle(colors.secondaryText)
            field(height: 36) {
                Label("Sample roll / Export", systemImage: "folder")
                    .padding(.horizontal, Graphite.Metric.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, Graphite.Metric.s)
            panelDivider
            VStack(spacing: 10) {
                panelRow("Format") {
                    field {
                        HStack {
                            Text("JPEG")
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(Graphite.Typeface.caption)
                                .foregroundStyle(colors.secondaryText)
                        }
                        .padding(.horizontal, Graphite.Metric.m)
                    }
                }
                panelRow("Quality") {
                    field {
                        HStack(spacing: 0) {
                            Text("92").monospacedDigit().frame(width: 54)
                            colors.ink.opacity(0.12).frame(width: 1)
                            qualityTrack.padding(.horizontal, Graphite.Metric.m)
                        }
                    }
                }
                panelRow("Grain") { segments(["Natural", "Off"], fillsWidth: true) }
            }
            Spacer(minLength: 0)
            Text("Develop 24")
                .font(Graphite.Typeface.row.weight(.semibold))
                .foregroundStyle(colors.onPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background {
                    RoundedRectangle(cornerRadius: Graphite.Metric.actionRadius)
                        .fill(LinearGradient(colors: [colors.primaryTop, colors.primaryBottom],
                                             startPoint: .top, endPoint: .bottom))
                        .shadow(color: Graphite.shadow, radius: 2, y: 1)
                }
        }
        .padding(.horizontal, Graphite.Metric.inspectorPadding)
        .padding(.top, Graphite.Metric.edge)
        .padding(.bottom, Graphite.Metric.inspectorPadding)
        // As the live panel's surface (`graphiteFloating`), in this palette: solid with Reduce Transparency, a firm
        // edge with Increase Contrast, and a shadow kept off the workspace beside it.
        .background {
            shape.fill(colors.floatingOpaque.opacity(reduceTransparency
                ? 1 : FloatingSurface.tintOpacity(isCard: false, isDark: colors.isDark)))
        }
        .clipShape(shape)
        .background {
            WorkspaceShadow(cornerRadius: Graphite.Metric.workspaceRadius, isDark: colors.isDark,
                            fill: colors.floatingOpaque, cutoutInterior: !reduceTransparency,
                            sparedLeadingGap: Graphite.Metric.inspectorGutter)
        }
        .overlay {
            if contrast == .increased { shape.strokeBorder(colors.strongBorder, lineWidth: 1) }
        }
    }

    private var panelDivider: some View {
        colors.ink.opacity(0.09).frame(height: 1).padding(.vertical, 13)
    }

    private func panelRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: title).frame(width: 78, alignment: .leading)
            control()
        }
    }

    private func segments(_ titles: [String], fillsWidth: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.actionRadius)
        return HStack(spacing: 0) {
            ForEach(titles.indices, id: \.self) { index in
                Text(verbatim: titles[index])
                    .foregroundStyle(index == 0 ? colors.text : colors.secondaryText)
                    .padding(.horizontal, fillsWidth ? 0 : 14)
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
                    .frame(height: 24)
                    .background {
                        if index == 0 {
                            RoundedRectangle(cornerRadius: Graphite.Metric.segmentRadius)
                                .fill(colors.segmentThumb)
                        }
                    }
            }
        }
        .padding(2)
        .background(shape.fill(colors.ink.opacity(0.05)))
        .overlay { shape.strokeBorder(colors.ink.opacity(0.12), lineWidth: 1) }
    }

    private func field<Content: View>(height: CGFloat = Graphite.Metric.controlHeight,
                                     @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.controlRadius)
        return content()
            .frame(height: height)
            .background(shape.fill(colors.ink.opacity(0.05)))
            .overlay { shape.strokeBorder(colors.ink.opacity(0.12), lineWidth: 1) }
    }

    private var qualityTrack: some View {
        GeometryReader { geometry in
            let filled = geometry.size.width * 0.84
            Capsule().fill(colors.ink.opacity(0.2))
                .overlay(alignment: .leading) {
                    Capsule().fill(colors.text).frame(width: filled)
                }
                .overlay(alignment: .leading) {
                    Capsule().fill(colors.proofHighlight).frame(width: 22, height: 14)
                        .shadow(color: Graphite.shadow, radius: 2, y: 1)
                        .offset(x: filled - 11)
                }
        }
        .frame(height: 4)
    }
}

/// The Settings specimen has its own controller so it cannot replace the open frame's sample or listener.
struct FrameSurroundSpecimen: View {
    let picture: CGImage?
    let palette: ThemePalette
    let ambient: Bool
    let intensity: Double
    let showsShadow: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controller = FrameSurroundController()
    private static let sampleID = URL(fileURLWithPath: "/FrameSurroundSpecimen")
    static let standIn: CGImage? = {
        if let url = Bundle.module.url(forResource: "FrameSurroundSpecimen", withExtension: "jpg",
                                       subdirectory: "Resources"),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        let renderer = ImageRenderer(content: ProofPhotograph(picture: nil, index: 0))
        renderer.proposedSize = ProposedViewSize(width: 112, height: 168)
        return renderer.cgImage
    }()

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height * 0.78
            let width = height * 2 / 3
            let displayed = picture ?? Self.standIn
            let image = ambient ? displayed : nil
            ZStack {
                GraphiteColors(palette).photoSurround
                if ambient {
                    FrameSurroundView(controller: controller, workspaceSize: geometry.size, palette: palette,
                                      outputSpace: .sRGB, intensity: intensity, reduceMotion: reduceMotion,
                                      fallbackImage: image.map { (Self.sampleID, $0) })
                }
                ProofPhotograph(picture: displayed, index: 0)
                    .frame(width: width, height: height)
                    .shadow(color: Graphite.shadow.opacity(showsShadow ? 0.87 : 0), radius: 2, y: 1)
                    .shadow(color: Graphite.shadow.opacity(showsShadow ? 1 : 0), radius: 10, y: 7)
            }
            .onChange(of: geometry.size, initial: true) {
                controller.updateGeometry(photoRect: CGRect(x: (geometry.size.width - width) / 2,
                                                            y: (geometry.size.height - height) / 2,
                                                            width: width, height: height), for: Self.sampleID)
            }
            .task(id: image.map(ObjectIdentifier.init)) {
                if let image {
                    controller.submit(image: image, for: Self.sampleID, space: .sRGB,
                                      pacing: reduceMotion ? .instant : .step, seedSynchronously: true)
                }
            }
        }
        .clipped()
    }
}

private struct ProofPhotograph: View {
    let picture: CGImage?
    let index: Int

    var body: some View {
        GeometryReader { geometry in
            if let picture {
                Image(decorative: picture, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                Self.standInFrame(index)
            }
        }
    }

    private typealias Artwork = Graphite.ProofArtwork

    private static func standInFrame(_ index: Int) -> some View {
        horizon(Artwork.scenes[index])
            .overlay {
                switch index {
                case 1:
                    HStack(alignment: .bottom, spacing: 7) {
                        ForEach([0.8, 0.6, 1.0], id: \.self) { height in
                            Ellipse().fill(sampleColor(Artwork.trees))
                                .frame(width: 18, height: 32 * height)
                        }
                    }
                    .blur(radius: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                case 2:
                    Silhouette().fill(sampleColor(Artwork.figure))
                        .frame(width: 26, height: 50)
                        .blur(radius: 1)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                case 4:
                    HStack(spacing: 12) {
                        ForEach(Artwork.streetlights, id: \.self) { tone in
                            Circle().fill(sampleColor(tone)).frame(width: 7, height: 7)
                        }
                    }
                    .blur(radius: 2.5)
                case 7:
                    Circle().fill(sampleColor(Artwork.moon))
                        .frame(width: 24, height: 24)
                        .blur(radius: 7)
                        .offset(x: 9, y: -4)
                default:
                    EmptyView()
                }
            }
    }

    private struct Silhouette: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.21, y: rect.minY,
                                           width: rect.width * 0.58, height: rect.height * 0.26))
                path.addEllipse(in: CGRect(x: rect.minX, y: rect.minY + rect.height * 0.32,
                                           width: rect.width, height: rect.height * 0.68))
            }
        }
    }

    private static func horizon(_ tones: [UInt32]) -> LinearGradient {
        LinearGradient(stops: zip(tones, [0, 0.49, 0.56, 1]).map { .init(color: sampleColor($0), location: $1) },
                       startPoint: .top, endPoint: .bottom)
    }

    private static func sampleColor(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
              blue: Double(hex & 255) / 255)
    }
}
