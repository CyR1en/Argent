import AppKit
import ArgentCore
import ArgentRoll
import SwiftUI

/// The quick develop dialog, over the roll: what Develop This Frame and Develop N Frames ask before they develop, from
/// a frame's menu or the Frame menu (`RollModel.askToDevelop`; docs/M2-shell.md, section 26). The frames it is for, the
/// folder their files go to with Choose…, and Format, Quality, Color space and Grain, as the Develop page's panel has
/// them (`DevelopFolderField`, `DevelopOutputRows`). They are the dialog's own until its Develop is pressed, which makes
/// them the roll's folder and the choices kept for every roll and develops the frames (`confirmQuickDevelop`). Escape,
/// Cancel or a click beside it closes it with nothing changed.
struct QuickDevelopSheet: View {
    /// The dialog's choices, its frames as the roll has them and whether its Develop can start, given by the layer that
    /// shows it (`QuickDevelopLayer`): on its way out the card keeps the last it was given, so it fades as it stood.
    let asked: QuickDevelop
    let frames: [Frame]
    let canDevelop: Bool
    @Environment(RollModel.self) private var model
    /// The dialog has the keys while it is up, so none reaches the sheet or the frame under it.
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: Self.title(frames))
                .font(Graphite.Typeface.panelTitle)
                .foregroundStyle(Graphite.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: DevelopStatusText.summary(model, frames: frames))
                .font(Graphite.Typeface.body)
                .foregroundStyle(Graphite.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 18)
            SectionDivider()
            ViewThatFits(in: .vertical) {
                settings
                ScrollView { settings }
                    .scrollBounceBehavior(.basedOnSize)
            }
            SectionDivider()
            HStack(spacing: Graphite.Metric.s) {
                Text("The Develop page keeps these settings.")
                    .font(Graphite.Typeface.small)
                    .foregroundStyle(Graphite.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { model.cancelQuickDevelop() }
                    .buttonStyle(.graphite(.secondary))
                    .keyboardShortcut(.cancelAction)
                // A number typed in Quality is written when its field lets go of the keys, which a click on this button
                // does not make it do: the field lets go first, so the develop is made with what the dialog shows.
                Button(DevelopPrimary.develop(count: frames.count).title) {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    model.confirmQuickDevelop()
                }
                    .buttonStyle(.graphite(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canDevelop)
                    .help(Self.help(frames))
                    .accessibilityLabel(DevelopPrimary.develop(count: frames.count).accessibilityLabel)
            }
            .padding(.top, 18)
        }
        .padding(24)
        // 440 points, narrower where the workspace is, as beside the Adjust inspector in the smallest window.
        .frame(maxWidth: 440)
        .graphiteCard(cornerRadius: 18)
        .padding(.horizontal, Graphite.Metric.l)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Develop settings")
        .accessibilityAddTraits(.isModal)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The open panel is not modal: a folder chosen there after this dialog has gone is for this dialog's frames
            // alone, not for another asked for since.
            DevelopFolderField(choice: folder) { [frames = asked.frames] folder in
                if model.quickDevelop?.frames == frames { model.quickDevelop?.folder.base = folder }
            }
                .padding(.vertical, 16)
            SectionDivider()
            DevelopOutputRows(output: output, ownGrain: model.quickDevelopGrain(for: frames))
                .padding(.vertical, 18)
        }
    }

    /// The dialog's choices; once it is on its way out, as it last had them.
    private var folder: Binding<DevelopFolder> {
        Binding(get: { model.quickDevelop?.folder ?? asked.folder }, set: { model.quickDevelop?.folder = $0 })
    }

    private var output: Binding<OutputSettings> {
        Binding(get: { [asked] in model.quickDevelop?.output ?? asked.output }, set: { model.quickDevelop?.output = $0 })
    }

    /// "Develop DSC06673" for one frame, by its name; "Develop 3 frames" for several.
    static func title(_ frames: [Frame]) -> String {
        frames.count == 1 ? "Develop \(frames[0].name)" : "Develop \(DevelopStatusText.frames(frames.count))"
    }

    static func help(_ frames: [Frame]) -> String {
        "Develop \(frames.count == 1 ? "this frame" : "these \(frames.count) frames") into the folder shown, with these settings. Return."
    }
}

/// The quick develop dialog on the workspace, over the roll and a scrim that closes it: the workspace shows it while
/// the model has one (`RollModel.quickDevelop`). It reads the dialog's choices here and hands them to the card, so a
/// choice made in it redraws the dialog and not the workspace under it.
struct QuickDevelopLayer: View {
    @Environment(RollModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let asked = model.quickDevelop
        ZStack {
            if let asked {
                Color.black.opacity(0.3)
                    .contentShape(Rectangle())
                    .onTapGesture { model.cancelQuickDevelop() }
                    .transition(.opacity)
                    .accessibilityHidden(true)
                QuickDevelopSheet(asked: asked, frames: model.quickDevelopFrames, canDevelop: model.canConfirmQuickDevelop)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? nil : Graphite.Motion.panel, value: asked != nil)
    }
}

extension View {
    /// Returns the keys to the photograph or grid when the stock shelf or Quick Develop closes.
    func restoreWorkspaceFocus(_ focus: @escaping () -> Void) -> some View {
        background { WorkspaceFocusWatch(focus: focus) }
    }
}

/// Observe the layers here so changes inside Quick Develop or the mask models' screen do not redraw the workspace beneath them.
private struct WorkspaceFocusWatch: View {
    @Environment(RollModel.self) private var model
    let focus: () -> Void

    var body: some View {
        let dialogShown = model.isSheetShown
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: dialogShown) { if !dialogShown { focus() } }
            .onChange(of: model.isStockShelfVisible) { _, shown in
                if !shown, !dialogShown, model.workspacePage == .roll { focus() }
            }
    }
}
