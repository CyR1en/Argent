import AppKit
import ArgentCore
import SwiftUI
import Testing
@testable import ArgentApp

/// The main window's colour space is the output space (J): the pictures, made in that space, go on screen as they are, and the
/// window server matches the window to the display, rather than Core Animation matching each film on the CPU while the main
/// thread waits (about 20 ms a 4536-pixel film).
@MainActor @Suite(.serialized) struct WindowChromeTests {
    @Test(arguments: OutputSpace.allCases)
    func theWindowsSpaceIsTheOutputSpace(space: OutputSpace) throws {
        let wanted = try #require(WindowChrome.colorSpace(for: space)?.cgColorSpace)
        #expect(wanted.name == space.colorSpace.name)
    }

    @Test func aWindowTakesTheSpaceAndFollowsItsChange() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: WindowShellBackground(space: .sRGB))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 where window.colorSpace?.cgColorSpace?.name != CGColorSpace.sRGB { try await Task.sleep(for: .milliseconds(10)) }
        #expect(window.colorSpace?.cgColorSpace?.name == CGColorSpace.sRGB)
        host.rootView = WindowShellBackground(space: .displayP3)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 where window.colorSpace?.cgColorSpace?.name != CGColorSpace.displayP3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(window.colorSpace?.cgColorSpace?.name == CGColorSpace.displayP3)
    }

    @Test(arguments: [true, false])
    func workspaceShadowDarkensTheChromeAlongTheLeadingAndTopEdges(isDark: Bool) throws {
        let theme = ThemeCatalog.theme(id: "graphite")
        let palette = try #require(isDark ? theme.dark.first?.palette : theme.light?.palette)
        let view = DevelopProof(palette: palette, pictures: [])
            .frame(width: DevelopProof.size.width, height: DevelopProof.size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)

        func luma(_ x: Int, _ y: Int) throws -> CGFloat {
            let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            return color.redComponent
        }

        // Above the rail icons (y = 72) and along the empty title strip (x = 220):
        // far chrome stays brighter than mid-shadow, which stays brighter than the edge shadow.
        let farChrome = try luma(4, 72)
        let midLeading = try luma(50, 72)
        let nearLeading = try luma(57, 72)
        let farTop = try luma(220, 10)
        let nearTop = try luma(220, 49)
        #expect(nearLeading < midLeading)
        #expect(midLeading < farChrome)
        #expect(nearTop < farTop)
    }

    @Test func cutoutWorkspaceShadowKeepsItsInteriorTransparentWhileCastingTheOuterShadow() throws {
        let shadow = WorkspaceShadow(cornerRadius: Graphite.Metric.dockRadius, isDark: true,
                                     fill: .black, cutoutInterior: true)
            .frame(width: 120, height: 60)
            .padding(40)
            .frame(width: 200, height: 140)

        let renderer = ImageRenderer(content: shadow)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)

        let center = try #require(rep.colorAt(x: 100, y: 70))
        let outsideEdge = try #require(rep.colorAt(x: 37, y: 70))
        #expect(center.alphaComponent < 0.01)
        #expect(outsideEdge.alphaComponent > 0.05)
    }

    /// A panel in the inspector's column draws after the workspace, so its shadow crossed the gutter onto a zoomed frame that ran
    /// to the workspace's edge (a white edge fell from 255 to 242 at 2x). Spared, a white photograph there stays white, at its edge
    /// and inside its rounded corner, while the shadow still falls on the chrome in the gutter and above the panel.
    @Test(arguments: [(true, false), (true, true), (false, false), (false, true)])
    func aPanelsShadowStaysOffThePhotographBesideIt(isDark: Bool, cutoutInterior: Bool) throws {
        let gutter = Graphite.Metric.inspectorGutter
        let shape = RoundedRectangle(cornerRadius: Graphite.Metric.workspaceRadius, style: .continuous)
        func render(spared: Bool) throws -> NSBitmapImageRep {
            // The workspace from 40 to 240 points, the panel from 252 to 452, both from 40 to 200, on a mid-gray chrome.
            let scene = HStack(spacing: gutter) {
                Color.white.frame(width: 200, height: 160).clipShape(shape)
                Color.gray.frame(width: 200, height: 160).clipShape(shape)
                    .background {
                        WorkspaceShadow(isDark: isDark, fill: .gray, cutoutInterior: cutoutInterior,
                                        sparedLeadingGap: spared ? gutter : nil)
                    }
            }
            .padding(40)
            .background(Color(white: 0.5))
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        func luma(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) throws -> CGFloat {
            try #require(rep.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB)).redComponent
        }

        let spared = try render(spared: true), unspared = try render(spared: false)
        // The photograph's edge, half a point in, and inside its top trailing corner.
        #expect(try luma(spared, 239.5, 120) > 0.999)
        #expect(try luma(spared, 230, 46) > 0.999)
        // The seam sees the shadow: left to fall there, it darkens the edge.
        #expect(try luma(unspared, 239.5, 120) < 0.995)
        // The chrome in the gutter and above the panel still takes the shadow.
        let farChrome = try luma(spared, 10, 120)
        #expect(try luma(spared, 246, 120) < farChrome)
        #expect(try luma(spared, 350, 36) < farChrome)
    }

    /// The Settings preview's panel spares its workspace as the window's does: the workspace beside it keeps its own colour at its edge.
    @Test(arguments: [true, false])
    func theProofsPanelShadowStaysOffItsWorkspace(isDark: Bool) throws {
        let theme = ThemeCatalog.theme(id: "graphite")
        let palette = try #require(isDark ? theme.dark.first?.palette : theme.light?.palette)
        let view = DevelopProof(palette: palette, pictures: [])
            .frame(width: DevelopProof.size.width, height: DevelopProof.size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let rep = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))

        // The workspace ends where the inspector's column begins. In its empty edge beside the grid, mid-height, half a point in
        // is as bright as 16 points further from the panel; the shadow left to fall there darkens it by about 3 levels.
        func luma(_ x: CGFloat) throws -> CGFloat {
            try #require(rep.colorAt(x: Int(x * 2), y: 500)?.usingColorSpace(.sRGB)).redComponent
        }
        let edgeX = DevelopProof.size.width - Graphite.Metric.inspectorWidth - 0.5
        #expect(abs(try luma(edgeX) - luma(edgeX - Graphite.Metric.edge + 2.5)) < 0.75 / 255)
    }

    /// Reduce Transparency is set on the view's environment rather than read from the Mac running the tests, so both cases run
    /// everywhere: with it off the preference decides the state; with it on the window always follows its active state.
    @Test(arguments: [false, true])
    func inactiveWindowFollowsChangesToTransparencyPreference(reduceTransparency: Bool) async throws {
        let settings = AppearanceSettings(defaults: ScratchDefaults())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: WindowShellBackground(space: .sRGB, settings: settings)
            .environment(\._accessibilityReduceTransparency, reduceTransparency))
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        func backdrop(in view: NSView) -> NSVisualEffectView? {
            if let effect = view as? NSVisualEffectView, effect.blendingMode == .behindWindow { return effect }
            return view.subviews.lazy.compactMap { backdrop(in: $0) }.first
        }
        let effect = try #require(backdrop(in: host))
        let enabledState: NSVisualEffectView.State = reduceTransparency ? .followsWindowActiveState : .active
        #expect(!window.isKeyWindow)
        #expect(effect.state == enabledState)

        for enabled in [false, true] {
            settings.keepsTransparencyWhenInactive = enabled
            let expected = enabled ? enabledState : .followsWindowActiveState
            host.layoutSubtreeIfNeeded()
            for _ in 0..<100 where effect.state != expected { try await Task.sleep(for: .milliseconds(10)) }
            #expect(effect.state == expected)
        }
    }
}
