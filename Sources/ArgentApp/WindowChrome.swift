import AppKit
import ArgentCore
import SwiftUI

struct WindowShellBackground: View {
    let space: OutputSpace
    var settings: AppearanceSettings = .shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        settings.shellStyle(reduceTransparency: reduceTransparency).overlay
            .background {
                WindowChrome(space: space, keepsTransparencyWhenInactive: settings.keepsTransparencyWhenInactive && !reduceTransparency)
            }
    }
}

/// A two-layer drop shadow under the inset rounded workspace and floating surfaces so they share
/// one borderless elevated edge. Drawn behind the clipped surface from two sibling shapes inset by
/// 1 pt rather than directly on the content subtree, so dynamic sheets, Metal surrounds and panels
/// never pay an offscreen shadow pass and no fill fringe can show at fractional scales. Set
/// `cutoutInterior` for translucent frosted surfaces so the interior stays transparent for backdrop
/// blur.
struct WorkspaceShadow: View {
    struct Layer: Equatable, Sendable {
        let opacity: Double
        let radius: CGFloat
        let y: CGFloat
    }

    var cornerRadius: CGFloat = Graphite.Metric.workspaceRadius
    let isDark: Bool
    let fill: Color
    var cutoutInterior = false
    /// The gap to a surface on the leading side, as tall and as round as this one, that the shadow
    /// must not fall on: the workspace beside a panel in the inspector's column, so the panel never
    /// darkens a photograph that runs to the workspace's edge. Only the shadow is masked, never the panel.
    var sparedLeadingGap: CGFloat?

    static let inset: CGFloat = 1
    /// Padding around the compositing group when punching out the interior so the blur tail is never clipped.
    private static let cutoutPad: CGFloat = 40

    /// The wide ambient lift and tight edge shadow for a dark or light palette.
    static func layers(isDark: Bool) -> (wide: Layer, tight: Layer) {
        if isDark {
            (Layer(opacity: 0.36, radius: 14, y: 2), Layer(opacity: 0.28, radius: 3.5, y: 0.5))
        } else {
            (Layer(opacity: 0.11, radius: 13, y: 2), Layer(opacity: 0.07, radius: 3, y: 0.5))
        }
    }

    var body: some View {
        let caster = RoundedRectangle(cornerRadius: max(0, cornerRadius - Self.inset), style: .continuous)
        let (wide, tight) = Self.layers(isDark: isDark)
        Group {
            if cutoutInterior {
                let cutout = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                ZStack {
                    caster.fill(Color.black)
                        .padding(Self.cutoutPad + Self.inset)
                        .shadow(color: .black.opacity(wide.opacity), radius: wide.radius, y: wide.y)
                    caster.fill(Color.black)
                        .padding(Self.cutoutPad + Self.inset)
                        .shadow(color: .black.opacity(tight.opacity), radius: tight.radius, y: tight.y)
                    cutout.fill(Color.black)
                        .padding(Self.cutoutPad)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .padding(-Self.cutoutPad)
            } else {
                ZStack {
                    caster.fill(fill)
                        .padding(Self.inset)
                        .shadow(color: .black.opacity(wide.opacity), radius: wide.radius, y: wide.y)
                    caster.fill(fill)
                        .padding(Self.inset)
                        .shadow(color: .black.opacity(tight.opacity), radius: tight.radius, y: tight.y)
                }
            }
        }
        .sparingLeadingNeighbor(gap: sparedLeadingGap, cornerRadius: cornerRadius, pad: Self.cutoutPad)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension View {
    /// Masks the shadow off a leading neighbour `gap` points away (`WorkspaceShadow.sparedLeadingGap`), padded so the blur's
    /// tail elsewhere is never clipped.
    @ViewBuilder func sparingLeadingNeighbor(gap: CGFloat?, cornerRadius: CGFloat, pad: CGFloat) -> some View {
        if let gap {
            padding(pad)
                .mask { SparedLeadingNeighbor(gap: gap, pad: pad, cornerRadius: cornerRadius) }
                .padding(-pad)
        } else {
            self
        }
    }
}

/// Everything around a shadowed surface except its leading neighbour: a rounded rectangle as tall as
/// the surface, `gap` points before it, reaching past the padded rect so only its trailing corners show.
private struct SparedLeadingNeighbor: Shape {
    let gap: CGFloat
    let pad: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let surface = rect.insetBy(dx: pad, dy: pad)
        let neighborMinX = rect.minX - 2 * cornerRadius
        let neighbor = CGRect(x: neighborMinX, y: surface.minY,
                              width: max(0, surface.minX - gap - neighborMinX), height: surface.height)
        return Path(rect).subtracting(Path(roundedRect: neighbor, cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Gives the main window a title bar as tall as the title strip (`Graphite.Metric.titleStripHeight`),
/// so macOS centres the close, minimize and zoom buttons on the strip's line beside the chip. An
/// empty unified toolbar makes the bar that tall; the bar stays transparent and titleless, and
/// the window's content still runs under it, where `TitleStrip` draws the chip and actions.
///
/// It also gives the window the output space as its colour space (`WindowChrome.colorSpace(for:)`), so the pictures, which are all
/// made in that space, go on screen as they are: the window server matches the whole window to the display, on the GPU. In the
/// display's own space, Core Animation matched each new film to it on the CPU (`CA::Render::copy_image` through vImage, on SwiftUI's
/// prepare-image queue) while the main thread waited for it in its commit: about 20 ms a 4536-pixel film, so a drag at 2x lost half
/// its refreshes, two thirds on a frame whose print came faster (measured, J).
struct WindowChrome: NSViewRepresentable {
    let space: OutputSpace
    let keepsTransparencyWhenInactive: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ChromeView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ChromeView else { return }
        view.state = keepsTransparencyWhenInactive ? .active : .followsWindowActiveState
        view.space = space
        view.matchSpace()
    }

    /// The window's colour space for pictures in `space`: that space, which holds every colour the inspector and the sheet draw.
    static func colorSpace(for space: OutputSpace) -> NSColorSpace? { NSColorSpace(cgColorSpace: space.colorSpace) }

    private final class ChromeView: NSVisualEffectView {
        var space: OutputSpace?

        func matchSpace() {
            guard let window, let space, let wanted = WindowChrome.colorSpace(for: space), window.colorSpace != wanted else { return }
            window.colorSpace = wanted
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            matchSpace()
            guard let window, window.toolbar == nil else { return }
            let toolbar = NSToolbar(identifier: "camera.argent.titleStrip")
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
    }
}
