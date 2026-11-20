#if DEBUG
import AppKit
import ArgentCore
import ArgentRoll
import ImageIO
import os
import SwiftUI
import UserNotifications

/// Debug builds only: lets a script drive the running app where UI automation cannot reach,
/// by posting a distributed notification named `camera.argent.Argent.drive` whose object is a
/// command; a build under another bundle identifier listens on that identifier followed by
/// `.drive`, so it can be driven beside the app and never answers another app's commands. Menu
/// commands go through the real menu bar, so they exercise what a click would. Replies go to the
/// unified log, subsystem camera.argent.Argent, category drive.
///
///     state                      the model, as one line of JSON
///     menus [MENU]               every menu item, or MENU's, with its enabled state and its help tag
///     menu File>Open Recent>X    performs a menu item by its titles (not Quit, which waits on this callback's queue)
///     quit                       quits as Argent > Quit does, saves first
///     develop-page show|close|press|folder FOLDER|state  the Develop page: shown, closed, its button pressed, FOLDER as if chosen, what it says
///     card open|dismiss          presses a button in the card bar
///     snapshot NAME              each window as a PNG in the container's tmp folder
///     appearance light|dark|system  sets Mode, as Settings > Appearance does
///     theme ID [DARK]            selects a theme by its catalog id, and its dark version DARK, as Settings does
///     backdrop on|off            whether the Rolls page shows its backdrop, as Settings does
///     backdrop                   the backdrop's state: whether a view is in the window, shown and ready to draw; the
///                                field in points and cells; the link's rate and the display's most; whether the motion
///                                is lively; and over the last second the frames drawn and a frame's GPU time, mean and worst
///     backdrop pointer X Y | X0 Y0 X1 Y1 SECONDS | away | off  the backdrop's pointer held at X Y in the field's
///                                points from its top left, or moved along a line over SECONDS and held at its end, or
///                                held away, whatever the real one does; off gives it back to the tracking area
///     backdrop still on|off      the backdrop held still as under Reduce Motion, or let move; off returns it to the
///                                system's setting
///     backdrop active on|off|app  the backdrop paced as in the active app, or in the background, whatever the app is
///                                (a script cannot bring it forward); app returns it to the app's state
///     settings [close]           opens the Settings page, or leaves it for the roll
///     settings import [burst-gap short|normal|long | soft-focus strict|normal|loose | eyes-closed leave|keep |
///                                same-moment narrow|normal|wide | cull on|off | destination pictures|choose|FOLDER]  sets
///                                one of the import panel's rows as the panel does, FOLDER as if chosen and choose pressing
///                                Choose…; replies with every row, and for a chosen folder whether its bookmark resolves
///                                and the app can write there
///     rolls [show|source|close|state]  the Rolls page: shown, its Import roll sheet opened or closed; replies with the
///                                library's rolls, each with its covers and whether it was reached
///     import start               presses Import on the card on offer; replies once its frames are judged, with the
///                                seconds the read took
///     import toggle NAME|N       sends a frame the other way, as a click on it does: by file name, or the Nth shown, from 1
///     import filter all|import|left  which frames the review shows, as its filter sets it
///     import select first|last|NAME  selects a frame and brings it into view, as Home, End or an arrow does
///     import close               Close, as Escape does; the card is offered again if it is still there
///     import folder NAME         imports the folder of the library roll NAME, as if chosen in Import from a folder…'s panel
///     import go                  presses Import on the review page; replies once the roll is open or the copy has
///                                stopped, with the seconds to the end of the copy and to the roll, each count the
///                                page showed while copying, and how many frames were new
///     import cancel              Cancel while the frames are copied, as Escape does; the frames copied stay, and
///                                the review comes back as it was, saying how many frames are in the folder, if any
///     import state               the import as one line of JSON: its state, the counts, the filter, the selection,
///                                the cells on screen and how many show their preview, and the first 30 frames shown
///                                with what each one's badge says
///     notifications              what the app has delivered to Notification Center
///     window W H [fix]           resizes the main window's content to W by H points; fix holds it there (not
///                                resizable meanwhile), where a tiling window manager would grow it; window 0 0 free
///                                lets it grow again
///     window minimize|hide|restore|state  the main window minimized to the Dock, or the app hidden as
///                                Command-H hides it, or put back; each replies with the window's occlusion state
///                                and whether the kernel has the app napping
///     frame N                    opens the frame view on the roll's frame N, counted from 0
///     lens SETTINGS|default|reset|status  sets Lens intent; replies after a film of those settings is shown
///                                vignette=-100...100,vignette-midpoint=0...100 (defaults 0 and 50)
///     flag N|unflag N            flags or unflags the roll's frame N, counted from 0, as Frame > Flag does
///     filter all|flagged|unflagged  which frames the sheet shows and Develop develops, as View > Show sets it
///     flags                      the roll's flags and filter: frames flagged and shown, the selection, the
///                                frame open, the heading's line, whether Develop can start and the flags are saved
///     select N [toggle|range] | select all | select none  selects the roll's frame N on the sheet as a click does, with
///                                Command (toggle) or Shift (range) held; every frame shown, as Edit > Select All does; or
///                                the lead alone, as Escape leaves it; replies with the frames selected
///     frames remove | move ROLL | new NAME | state  the frames selected leave the roll: to the Trash, as Remove from
///                                Roll… does once Move to Trash is chosen (the alert is not shown); into the library's
///                                roll ROLL, or a new roll NAME, as Move to Roll does; replies once the files have moved,
///                                with the notice's line; state says whether they can leave, and the rolls to move to
///     picture                    the frame view's layout and film, and the layers that show a picture
///     film NAME [PIXELS]         the frame view's film render as a PNG in the container's tmp folder; with
///                                PIXELS, the shown frame rendered as the frame view renders it at that long side
///     space sRGB|displayP3|adobeRGB  sets the output colour space, as the Develop page does, and with it the previews' (it is saved)
///     trim                       frees what a develop frees before it starts, to measure what is left
///     accessibility LABEL|*      the main window's elements labelled or titled LABEL, with their role, value and help; * lists them all
///     issues state|details|close|retry|dismiss  the issues row: what it says, its popover, Resume or Develop Again, closing it
///     compare on|off | auto on|off  the neutral raw in the frame view, as holding Space or Hold to compare does; or Compare to
///                                Auto, as its button does
///     zoom [in|out|actual|fit|smart X Y|pinch M X Y [end]|pan DX DY [end]]  the frame view's zoom as the View
///                                menu, smart zoom, a pinch event or a scroll changes it (points in the frame's
///                                area), then where it stands and the picture on top
///     window-id                  the main window's number, for screencapture -l
///     adjust show|hide|reset|auto-on|auto-off|undo|redo|copy-all|start-original|start-auto|reset-original|SLIDER VALUE
///                                the manual inspector and the Light tab's sliders, SLIDER by its name, exposure to blacks
///                                and texture to saturation; copy-all gives every frame the shown frame's Light, Presence,
///                                curves and masks; start-original and start-auto choose Start from, reset-original is
///                                Frame > Reset to Original
///     curve CHANNEL IN:OUT...    the shown frame's curve on tone, red, green or blue, as points 0 to 255
///     grain natural|off          the Develop page's grain choice, which the previews follow
///     adjust-measure             30 warm exposure renders, with latency, memory and cache counts
///     key KEY...                 key presses sent through the app as the keyboard's are, menus first; KEY is
///                                tab, return, enter, escape, delete, space, left, right, up, down, home, end,
///                                plus, minus, a character, with cmd+, shift+, option+ or ctrl+ in front
///     focus                      what has keyboard focus, and the shown frame's curves; for a Light slider, whether it
///                                shows the clipping view
///     hit X Y                    the views a click at AX's global point X Y lands on, innermost first, each with its
///                                frame in the window's points from the top left
///     mouse click X Y [N] [cmd|shift] | drag X Y DX [opt] [hold S] [shot]  mouse events for the main window at AX's global
///                                points (from the first screen's top), posted as the window server's are: N clicks, with
///                                Command or Shift held if cmd or shift, or a
///                                press, ten moves DX to the right with Option held if opt, the release S seconds (1) later;
///                                with what the frame view shows during the drag (with shot, as film-drag.png) and after
///     clip-latency [N]           N exposure changes, each followed by Lightroom's clipping view (highlights, then
///                                shadows), timed to the display frame that carries it; with the print-limits probe alone
///     latency [N] [mask [CONTROL]|lens [CONTROL]]  N slider changes (exposure by default); Lens takes
///                                distortion, a defringe slider, vignette or vignette-midpoint, defaulting to distortion. Each is made in a display frame as a slider drag's are,
///                                timed to the first frame that carries the new film; p50/p95/max; with mask, the selected
///                                mask's CONTROL (exposure, or contrast..., amount, warmth, magenta) instead, or mask 0's with none selected
///     compare-latency [N]        Compare to Auto turned on N times in a display frame, counting those
///                                the next refresh carries
///     develop-measure FOLDER [jpeg|heic|tiff16] [quality:N] [p3] [grain-off] [refining:N] [boosted] [timeline]  develops the
///                                roll into FOLDER at full size, sRGB unless p3, timed, with the kernel's peak footprint
///                                against the memory target, the refinements started meanwhile, and the window's occlusion
///                                and the app's nap state as it starts and ends; with refining:N, posted once frame N,
///                                opened first, has begun its refinement; boosted begins it inside this notification's
///                                delivery, whose importance boost keeps the app from napping until the develop ends;
///                                timeline samples the footprint every 2 ms beside the develop's stages and the previews'
///                                work, into timeline-TIME.tsv in the tmp folder
///     memory                     the footprint, and what the previews, the thumbnails and the developer hold, and the
///                                MallocLargeCache the app was launched with
///     shown [NAME]               what the frame view draws on top: its frame, the layout's pixels, which picture and its
///                                size, and whether it is the last film put up; with NAME, that picture as a PNG in the
///                                tmp folder
///     decode-measure N PIXELS [clear|reclaim|renew]  frame N's film at PIXELS through the frame view's path, from nothing
///                                kept (after the develop's trim and a second for memory to come back): the kernel's peak
///                                above the start for the decode and film, then for the neutral raw, and the footprint
///                                0 to 3 s after; with clear or reclaim, the sheet's Core Image context is asked to let its
///                                caches go, or its resources, as the film is up; with renew, it is replaced
///     refine on|off|state        the frame view's refinement of Apple's scaled decodes, and its counts
///     browse-measure step|jump [MS]  opens every frame in roll order, or every second and then the rest, each
///                                on screen MS (2000) ms: times to the first and the refined film, peak footprint,
///                                rendered-image bytes; a line a frame in browse-ORDER-TIME.txt in the tmp folder
///     latency-refining FRAME [N] opens FRAME and makes latency's N changes (20) as its refinement starts
///     nap-probe progress SECONDS [still]|render PIXELS  what wakes a napping app: the develop's progress row
///                                alone, a frame done every 0.3 s, still without its animation; or the shown frame
///                                decoded and rendered three times at PIXELS through the frame view's path
///     launch-time                the process's start to the window's first display frame, the empty state's
///                                unless a roll came with the launch, with when the app was made and its content appeared
///     sheet-measure [SECONDS]    from the empty state, armed for the next roll Launch Services hands over (open -a):
///                                from its arrival to the display frames with the roll on screen, the first sheet cell's
///                                embedded preview, and every visible cell's; then every frame's preview at the cells'
///                                size from the same loader, the rows not on screen included
///     stock-measure [N]          N stock switches on the sheet, each made in a display frame, timed to the first frame
///                                with every visible cell's film through the new stock up; a line a switch in
///                                stock-TIME.txt in the tmp folder
///     scroll-measure [PT/S] [SECONDS]  moves the contact sheet's (or a card's review's) own scroll view a display frame at a time at PT/S
///                                (2400), top to bottom and back, for two passes or SECONDS (8) of scrolling, and times the
///                                display frames: p50, p95, p99 and the longest, the refreshes missed, hitch time; then what
///                                the previews began meanwhile, by kind, the rendered pictures kept before and after, and the
///                                masks' field cache's hits, bakes and allocations; a line a display frame in scroll-TIME.tsv
///                                in the tmp folder
///     wheel DY                   a continuous scroll event of DY points sent to the window over its middle, as the
///                                window server's are, then where the sheet's scroll view stands
///     decoders                   how many of the roll's frames each decoder takes, and the first in-house frame
///     remove fake [MS] | stroke X Y [X Y...] [option] | return | cancel | again N | better N | delete N | state  Remove on
///                                the shown frame, with no pointer: fake gives the session an engine with no model, each step
///                                MS long (400), for a recording; stroke paints a click or a stroke through points in
///                                fractions of the picture, as the Remove brush does, with Option held if option; return and
///                                cancel are Return and Escape; again, better and delete are the row's Try Again, Better and
///                                Delete, on the removal its row numbers N; each replies with the selection and the frame's
///                                rows
///     mask arm brush|linear|radial [add|subtract|intersect] | disarm  a mask tool in hand or put down, as a tile does, or
///                                to add to the selected mask as its menus do; then `mask state`
///     mask tab light|curve|masks|lens  the Adjust inspector on that tab, as the View menu does
///     mask state                 the tool, the tab, the routing's state and what reached the canvas, as one line of JSON
///     mask where                 the area, the picture and the window, in the global points AX and CGEvent use
///     mask takes X Y [cmd]       whether the routing rule gives the canvas a press at area point X Y
///     mask press X Y [N] [cmd] [opt] [shift]  N clicks at area point X Y, posted as the window server's are, with those
///                                modifiers; the frame still open after; with the brush in hand, its state (`mask brush`)
///     mask drag X Y DX DY [cmd] [opt] [shift]  a press at area point X Y and a drag by DX DY; the zoom's offset before and
///                                after; with the brush in hand, a stroke, and its state
///     mask brush [size|feather|flow V | erase on|off]  the brush's settings, what it paints or that it waits for its first
///                                stroke, the ring, strokes ended, cancelled and refused, the undo step's name, the last
///                                stroke's report (events, their intervals, ticks) and the overlay's live pictures
///     mask paint [hold S] [step PT] X Y X Y ...  a stroke along the polyline through these points, in long sides of the picture: a
///                                press, moves PT (3) points apart a few milliseconds apart, posted as the window server's are, and the release S
///                                seconds (0) after the last move, with the pointer still; then `mask brush`
///     mask dump NAME             the selected brush's last Follow edges stroke as dump-NAME.json in the tmp folder (points in long sides, radius, feather,
///                                flow, the kept shape's place) and dump-NAME.png (the kept shape); then where it went
///     mask overlay-png NAME      the overlay's picture as it is, 8-bit gray, as overlay-NAME.png in the tmp folder
///     mask slider CONTROL        the slider named by CONTROL (exposure..., amount) of the tab on show made first responder
///     mask add linear|radial     a gradient placed as M or Shift-M then Return do; then `mask read`
///     mask list                  the shown frame's masks, a line of name, switch, Amount, what it does and its parts
///     mask select N [C]|none     selects mask N from 0, and its component C; or nothing
///     mask read                  the selected mask's shape in full, and the edit's compiler and the gate on it
///     mask set CONTROL V | amount V  the selected mask's slider, as one gesture; CONTROL a Light control, warmth or magenta
///     mask shape linear FX FY ZX ZY | radial CX CY A B ANGLE FEATHER  the selected mask's first component's shape, in long
///                                sides (ANGLE in degrees), as one gesture, as its numbers in the panel set it
///     mask feather F             the selected mask's smart selection's Feather (the selected component's, else its first
///                                selection's), 0 to 100, as one gesture, as its row in the panel sets it
///     mask handles               the selected gradient's handles at their area points
///     mask drag-measure HANDLE|at X Y [SECONDS] [PT/S]  the selected gradient's HANDLE (center, middle, ...), or area point X Y,
///                                pressed and dragged round a circle at PT/S (600) for SECONDS (8), a mouse event in each display
///                                frame as the window server coalesces a real drag's, then released: the display link's refreshes
///                                lost (frames that passed with no callback), the longest interval, hitch time, the print's flushes
///                                and the films put up; at X Y is the same drag where there may be nothing to move
///     mask slider-drag CONTROL [SECONDS] [PT/S]  the tab's slider CONTROL (exposure..., amount) pressed on its knob and dragged to
///                                and fro over its track at PT/S (150) for SECONDS (8), an event a display frame, measured as
///                                drag-measure is, with the films put up
///     compare split on|off|at F  the split comparison on or off, or its divider at fraction F of the area; compare split gives where it is
///     compare divider-measure [SECONDS] [PT/S] [SPAN] [model]  a drag of the divider, posted through the window (or with `model` the position written per refresh, as the
///                                drag gesture writes it), to and fro over SPAN points (240) at PT/S (400), for SECONDS (8), measured as `mask slider-drag` is, with the range the position took
///     zoom measure pan|pinch [SECONDS] [PT/S]  a pan by the model's own calls, or a pinch about the area's middle, at PT/S (pan) or a sine of the zoom, a step each
///                                display frame for SECONDS (8), then the gesture's end; refreshes lost as `mask slider-drag` measures them
///     mask overlay               whether the overlay shows, its colour, and the rasters made and pictures published
///     mask show on|off           the Overlay switch
///     mask sharp                 the sharp raster up (its size and region of the picture), whether one is waited for, how many were read and the last one's time
///     mask overlay-png NAME [sharp]  the overlay's picture as it is, or with `sharp` the sharp raster; 8-bit gray, as overlay-NAME.png in the tmp folder
///     mask compiler VERSION      writes the shown edit's Light compiler, as an older save holds it, with no undo step
///     mask cursor                the system cursor, by name
///     mask chords                the enabled menu items' key equivalents, and any two that share a chord
///     mask pins                  the shown frame's pins: each mask's from 0 at its area point, the component it stands for, selected,
///                                hovered, off, on its handle; whether they show and take the pointer and why, and the overlay
///     mask pin hover N|at X Y|off  the pointer moved onto mask N's pin, to area point X Y or off the area, as a move posted the
///                                window server's way reaches the canvas (or, where it does not, given to the canvas); then `mask pins`
///     mask pin press N [opt]     a click on mask N's pin, posted; then `mask read` and `mask pins`
///     mask pin drag N DX [opt] [hold S]  a press on mask N's pin, a drag DX to the right in ten moves and, S seconds (0) later, the
///                                release, posted; what the edit, the print and the tag held halfway, then `mask read` and the undo step
///     mask pin drag-measure N [SECONDS] [PT/S] [SPAN]  an Option-drag on mask N's pin to and fro over SPAN points (136) at PT/S (150)
///                                for SECONDS (8), one event a display frame, measured as `mask slider-drag` is
///     mask pins-measure [SECONDS]  nothing moving, the pointer still: the display link's refreshes over SECONDS (10) with the pins
///                                up, then as long with them down
///     smart add sky|subject|person|background  a tile's click on the shown frame: replies at once with the row's words,
///                                then `smart-done` once the selection lands (or comes to nothing) and the overlay is up, timed
///                                from the click: the row's first word, each stage, the arrival, the red, and the footprint
///     smart list                 the shown frame's smart masks: name, row words, seed id, gate score and veto, provenance
///     smart act N cancel|paintInstead|remove|retry|update|keep  a row's button, on mask N from 0
///     smart tab-closed|tab-opened  what closing or opening the Masks tab does: DA3 let go with the last tab, and the pictures
///                                kept for a click; or kept
///     smart simulate-older N     mask N's seed recorded as made by an earlier model, as after an update; then `smart list`
///     smart memory               the footprint, the queue's runs and unloads, whether DA3 is loaded
///     masks-measure [cold]       the smart masks' models in this app: what is bundled, whether "Preparing masks" is needed, the
///                                preparation timed (after deleting the compiled copies with cold), the shown frame's input
///                                picture, DA3 and EoMT run on it warm, and the footprint two seconds after each unload
@MainActor
enum Automation {
    private static let log = Logger(subsystem: "camera.argent.Argent", category: "drive")
    private static var observer: NSObjectProtocol?
    /// When the app was made (stocks loaded, model built) and its content first appeared, and the
    /// presentation time of the window's first display frame after that, for `launch-time`.
    private static var launch: (made: CFTimeInterval?, appeared: CFTimeInterval?, shown: CFTimeInterval?, empty: Bool) = (nil, nil, nil, false)
    /// When Launch Services last handed over a roll, for `sheet-measure`.
    private static var opened: CFTimeInterval?

    static func noteAppMade() { launch.made = CACurrentMediaTime() }
    static func noteOpen() { opened = CACurrentMediaTime() }
    /// The main window while `window minimize` or `window hide` has it out of sight, and its
    /// frame before.
    private static var hidden: (window: NSWindow, frame: NSRect)?

    /// `camera.argent.Argent.drive`, or the bundle identifier's own for a build under another.
    static var notificationName: Notification.Name {
        Notification.Name((Bundle.main.bundleIdentifier ?? "camera.argent.Argent") + ".drive")
    }

    static func start(model: RollModel) {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: notificationName, object: nil, queue: .main) { [weak model] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let model else { return }
                run(command, model: model)
            }
        }
        log.notice("drive: listening")
        noteLaunch(model)
    }

    /// The first display frame after the content appeared: once the window is up, the next tick of
    /// its display link, whose target is when the frame it prepares is shown.
    private static func noteLaunch(_ model: RollModel) {
        let appeared = CACurrentMediaTime()
        launch.appeared = appeared
        Task {
            while mainWindow()?.contentView == nil, CACurrentMediaTime() - appeared < 5 {
                try? await Task.sleep(for: .milliseconds(1))
            }
            guard let view = mainWindow()?.contentView else { return }
            let clock = FrameClock(view: view)
            let tick = await clock.next()
            clock.stop()
            launch.shown = tick.target
            launch.empty = model.roll == nil && !model.isScanning
        }
    }

    private static func run(_ command: String, model: RollModel) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "state": reply("state", state(model))
        case "quit":
            // From the run loop rather than this main-queue callback: Quit waits for the app's saves,
            // which run on the main queue and cannot while a block of it is still running.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            reply("quit", "posted")
        case "menus": reply("menus", menus(argument))
        case "menu": reply("menu", perform(path: argument) ? "performed \(argument)" : "no enabled item \(argument)")
        case "develop-page":
            // "develop-page folder /path" stands in for Choose…, which automation cannot drive.
            let values = argument.split(separator: " ", maxSplits: 1).map(String.init)
            switch values.first ?? "" {
            case "show": model.showDevelopPage()
            case "close": model.closeDevelopPage()
            case "press": model.performDevelopPrimary()
            case "folder" where values.count > 1: model.chooseDestination(URL(fileURLWithPath: values[1], isDirectory: true))
            case "state":
                reply("develop-page", developPage(model))
                return
            default:
                reply("error", "develop-page show|close|press|folder FOLDER|state")
                return
            }
            reply("develop-page", argument)
        case "quick-develop":
            // The quick develop dialog: "ask" is Frame > Develop This Frame… on the selection; "folder /path" stands in
            // for Choose…, and "format jpeg|heic|tiff16" for the Format menu, which automation cannot drive.
            let values = argument.split(separator: " ", maxSplits: 1).map(String.init)
            switch values.first ?? "" {
            case "ask": model.developSelection()
            case "develop": model.confirmQuickDevelop()
            case "cancel": model.cancelQuickDevelop()
            case "folder" where values.count > 1: model.quickDevelop?.folder.base = URL(fileURLWithPath: values[1], isDirectory: true)
            case "format" where values.count > 1:
                guard let format = OutputSettings.Format(rawValue: values[1]) else {
                    reply("error", "quick-develop format jpeg|heic|tiff16")
                    return
                }
                model.quickDevelop?.output.format = format
            case "state":
                reply("quick-develop", quickDevelop(model))
                return
            default:
                reply("error", "quick-develop ask|develop|cancel|folder FOLDER|format FORMAT|state")
                return
            }
            reply("quick-develop", argument)
        case "card":
            if let card = model.offeredCard {
                if argument == "open" { model.openCard(card) } else { model.dismissCard(card) }
            }
            reply("card", argument)
        case "snapshot": reply("snapshot", snapshot(argument))
        case "appearance":
            AppearanceSettings.shared.setMode(ThemeMode(rawValue: argument) ?? .system)
            reply("appearance", argument)
        case "theme":
            let theme = argument.split(separator: " ").map(String.init)
            guard let id = theme.first, ThemeCatalog.themes.contains(where: { $0.id == id }) else {
                reply("error", "theme \(ThemeCatalog.themes.map(\.id).joined(separator: "|")) [DARK]")
                return
            }
            if theme.count > 1 { AppearanceSettings.shared.selectDarkVersion(theme[1], of: id) } else { AppearanceSettings.shared.selectTheme(id) }
            reply("theme", argument)
        case "backdrop": backdrop(argument)
        case "settings":
            if argument == "close" {
                model.showWorkspacePage(.roll)
            } else if argument == "import" || argument.hasPrefix("import ") {
                importSettings(String(argument.dropFirst("import".count)).trimmingCharacters(in: .whitespaces), model: model)
                return
            } else {
                model.showWorkspacePage(.settings)
            }
            reply("settings", argument)
        case "import": importReview(argument, model: model)
        case "rolls":
            switch argument {
            case "source": model.showImportSource()
            case "close": model.isImportSourceShown = false
            case "show", "": model.showWorkspacePage(.rolls)
            case "state": break
            default:
                reply("error", "rolls show|source|close|state")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let rolls = model.library.map { roll in
                    "\(roll.name) \(roll.origin.rawValue) \(roll.frameCount.map(String.init) ?? "?") frames, "
                        + "\(model.rollCovers[roll.id]?.count ?? 0) covers\(model.unavailableRolls.contains(roll.id) ? ", not reached" : "")"
                }
                reply("rolls", "page \(model.workspacePage), sheet \(model.isImportSourceShown): " + rolls.joined(separator: " | "))
            }
        case "notifications":
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let text = delivered.map { "\($0.request.content.title): \($0.request.content.body)" }.joined(separator: " | ")
                Task { @MainActor in reply("notifications", text.isEmpty ? "none" : text) }
            }
        case "active": reply("active", "\(NSApp.isActive)")
        case "window" where ["minimize", "hide", "restore", "state"].contains(argument):
            conceal(argument)
        case "window":
            let size = argument.split(separator: " ").compactMap { Double($0) }
            if size.count == 2, let window = mainWindow() {
                // "window W H fix": the window held at that size, not resizable meanwhile, which a tiling
                // window manager then leaves alone, for screenshots at set sizes.
                // "window 0 0 free" lets it grow again.
                if argument.hasSuffix(" fix") {
                    window.styleMask.remove(.resizable)
                } else if argument.hasSuffix(" free") {
                    window.styleMask.insert(.resizable)
                    reply("window", "free")
                    return
                }
                // A new origin as well, which takes a tiled window out of its tile.
                let content = NSRect(x: 60, y: 60, width: size[0], height: size[1])
                window.setFrame(window.frameRect(forContentRect: content), display: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    reply("window", "content \(window.contentView?.bounds.size ?? .zero), frame \(window.frame)")
                }
            } else {
                reply("error", "window W H")
            }
        case "frame":
            if let index = Int(argument), let roll = model.roll, roll.frames.indices.contains(index) {
                model.selection = index
                model.openFrame()
                reply("frame", roll.frames[index].name)
            } else {
                reply("error", "no frame \(argument)")
            }
        case "lens":
            guard let frame = model.shownFrame, let films = model.films, let folder = model.roll?.folder else {
                reply("error", "lens SETTINGS|default|reset|status, with a frame open"); return
            }
            Task { @MainActor in
                if argument == "status" {
                    guard let file = await films.lensFile(for: frame) else { reply("error", "raw is gone"); return }
                    reply("lens", "\(file.metadata?.summary ?? "No lens named in the file") | \(LensResolver.availability(file).distortionLine)")
                    return
                }
                do {
                    let settings = try LensSettings(arguments: argument == "reset" ? "default" : argument)
                    await model.prepareManualAdjustments(for: frame)
                    guard model.canAdjust(frame) else { reply("error", model.manualIssue(for: frame) ?? "Auto not ready"); return }
                    model.setManualAdjustments(model.manualAdjustments(for: frame).settingLens(settings), for: frame)
                    let geometry = films.lensCorrection(for: frame, settings: settings)?.geometry
                    let deadline = CACurrentMediaTime() + 15
                    while CACurrentMediaTime() < deadline {
                        guard model.roll?.folder == folder, model.films === films, model.shownFrame?.url == frame.url else {
                            reply("error", "roll or shown frame changed while waiting for lens film"); return
                        }
                        if let held = model.maskEditor.pictureLens(on: frame), held.settings == settings,
                           held.lens.picture == geometry, FrameShowProbe.film?.settings.lens == settings {
                            reply("lens", "\(frame.name) \(settings.arguments) \(held.lens.picture.digest.prefix(12)) film shown")
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    reply("error", "timed out waiting for film at Lens settings")
                } catch { reply("error", error.localizedDescription) }
            }
        case "flag", "unflag":
            if let index = Int(argument), let roll = model.roll, roll.frames.indices.contains(index) {
                model.setFlag(parts[0] == "flag", for: roll.frames[index])
                reply(parts[0], "\(roll.frames[index].name) \(model.isFlagged(roll.frames[index]) ? "flagged" : "unflagged")")
            } else {
                reply("error", "no frame \(argument)")
            }
        case "filter":
            guard let filter = FlagFilter(rawValue: argument) else { reply("error", "filter all|flagged|unflagged"); return }
            model.showFrames(filter)
            reply("filter", flags(model))
        case "flags": reply("flags", flags(model))
        case "select":
            let values = argument.split(separator: " ").map(String.init)
            if values.first == "all" {
                model.selectAllShown()
            } else if values.first == "none" {
                model.collapseSelection()
            } else if let index = values.first.flatMap(Int.init), let roll = model.roll, roll.frames.indices.contains(index) {
                let click: SelectionClick = values.dropFirst().first == "toggle" ? .toggle : values.dropFirst().first == "range" ? .range : .alone
                model.select(roll.frames[index], click)
            } else {
                reply("error", "select N [toggle|range] | all | none"); return
            }
            reply("select", selection(model))
        case "frames":
            let values = argument.split(separator: " ", maxSplits: 1).map(String.init)
            let frames = model.selectedFrames
            switch values.first {
            case "state", nil:
                reply("frames", selection(model)); return
            case "remove":
                let ask = model.askAboutRemovingFrames
                model.askAboutRemovingFrames = { _ in true }
                model.removeFromRoll(frames)
                model.askAboutRemovingFrames = ask
            case "move":
                guard let target = model.moveTargets.first(where: { $0.name == values.last }) else {
                    reply("error", "no roll \(values.last ?? "") among \(model.moveTargets.map(\.name))"); return
                }
                model.moveFrames(frames, toRoll: target.id)
            case "new":
                guard values.count == 2 else { reply("error", "frames new NAME"); return }
                model.moveFrames(frames, toNewRollNamed: values[1])
            default:
                reply("error", "frames remove | move ROLL | new NAME | state"); return
            }
            Task {
                await model.frameMoveTask?.value
                reply("frames", selection(model))
            }
        case "picture": picture(model).forEach { reply("picture", $0) }
        case "film":
            let values = argument.split(separator: " ").map(String.init)
            if values.count == 2, let pixels = Int(values[1]) {
                Task { reply("film", await film(model, name: values[0], pixels: pixels)) }
            } else {
                reply("film", film(model, name: argument))
            }
        case "space":
            guard let space = OutputSpace(rawValue: argument) else { reply("error", "space sRGB|displayP3|adobeRGB"); return }
            model.output.space = space
            reply("space", space.rawValue)
        case "trim":
            model.trimForDevelop()
            reply("trim", "done")
        case "memory": reply("memory", memory(model))
        case "shown": reply("shown", shown(model, name: argument))
        case "decode-measure":
            let values = argument.split(separator: " ").compactMap { Int($0) }
            guard values.count == 2, let roll = model.roll, roll.frames.indices.contains(values[0]), let films = model.films else {
                reply("error", "decode-measure N PIXELS [clear|reclaim|renew]"); return
            }
            let frame = roll.frames[values[0]], pixels = values[1], stock = model.stockIndex(for: frame)
            let release = ["clear", "reclaim", "renew"].first { argument.hasSuffix(" " + $0) }
            Task {
                model.trimForDevelop()
                try? await Task.sleep(for: .seconds(1))
                let mb = { (bytes: Int) in "\(bytes >> 20) MB" }
                let start = DevelopBudget.footprint()
                resetFootprintPeak()
                let began = CACurrentMediaTime()
                let space = model.output.space
                let film = await films.frameFilm(frame, stock: stock, settings: model.settings(for: frame, stock: stock), space: space, pixels: pixels)
                let filmTime = CACurrentMediaTime() - began
                let filmPeak = max(footprintPeakSinceReset(), DevelopBudget.footprint()), afterFilm = DevelopBudget.footprint()
                resetFootprintPeak()
                let neutral = await films.frameNeutral(frame, lens: model.lensSettings(for: frame), space: space, pixels: pixels)
                let neutralPeak = max(footprintPeakSinceReset(), DevelopBudget.footprint())
                let released = CACurrentMediaTime()
                if let release { films.releaseCoreImageMemory(release) }
                var course: [String] = []
                for milliseconds in [0, 100, 250, 500, 1000, 2000, 3000] {
                    let wait = released + Double(milliseconds) / 1000 - CACurrentMediaTime()
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    course.append("\(milliseconds) ms \(DevelopBudget.footprint() >> 20)")
                }
                reply("decode-measure", "\(frame.name) \(films.decoderChoices.choice(for: frame.url).rawValue) at \(pixels) px:"
                      + " film \(film.map { "\($0.width)x\($0.height)" } ?? "none") in \(Int(filmTime * 1000)) ms, peak \(mb(filmPeak)) from \(mb(start)) (+\(mb(filmPeak - start))),"
                      + " \(mb(afterFilm)) after; neutral \(neutral == nil ? "none" : "made"), peak \(mb(neutralPeak)) (+\(mb(neutralPeak - afterFilm)));"
                      + " after the neutral\(release.map { ", \($0)," } ?? ""): \(course.joined(separator: ", ")) MB | \(films.heldReport)")
            }
        case "accessibility": accessibility(argument).forEach { reply("accessibility", $0) }
        case "issues":
            switch argument {
            case "details": model.isIssueDetailsShown = true
            case "close": model.isIssueDetailsShown = false
            case "retry":
                // The bar's button: Resume after a stop, with that develop's frames; else Develop Again.
                model.isIssueDetailsShown = false
                model.develop(resuming: model.lastDevelop?.wasStopped == true ? model.lastDevelop : nil)
            case "dismiss": model.areIssuesDismissed = true
            default: break
            }
            reply("issues", argument == "state" ? issues(model) : argument)
        case "adjust":
            let values = argument.split(separator: " ").map(String.init)
            if argument == "show" { model.isAdjustmentsShown = true; reply("adjust", "shown") }
            else if argument == "hide" { model.isAdjustmentsShown = false; reply("adjust", "hidden") }
            else if argument == "reset", let frame = model.shownFrame {
                model.resetManualAdjustments(for: frame); reply("adjust", "reset")
            } else if argument == "start-original" || argument == "start-auto", let frame = model.shownFrame {
                // The inspector's Start from.
                model.startFrom(argument == "start-original" ? .original : .auto, for: frame)
                reply("adjust", "start \(model.startingPoint(for: frame).rawValue)")
            } else if argument == "reset-original", let frame = model.shownFrame {
                model.startFromOriginal(for: frame, actionName: "Reset to Original")
                reply("adjust", "start \(model.startingPoint(for: frame).rawValue)")
            } else if argument == "auto-on" { model.isComparingAuto = true; reply("adjust", "auto") }
            else if argument == "auto-off" { model.isComparingAuto = false; reply("adjust", "edited") }
            else if argument == "undo" { model.manualUndoManager?.undo(); reply("adjust", "undo") }
            else if argument == "redo" { model.manualUndoManager?.redo(); reply("adjust", "redo") }
            else if argument == "copy-all", let roll = model.roll {
                Task { reply("adjust", await copyAdjustments(model, roll: roll)) }
            }
            else if values.count == 2, let slider = ManualAdjustments.Slider(name: values[0]),
                    let number = Float(values[1]), let frame = model.shownFrame {
                Task {
                    await model.prepareManualAdjustments(for: frame)
                    do {
                        let adjustments = try model.manualAdjustments(for: frame).setting(slider, to: number)
                        guard model.canAdjust(frame) else { reply("error", model.manualIssue(for: frame) ?? "Auto not ready"); return }
                        model.setManualAdjustments(adjustments, for: frame)
                        reply("adjust", "\(slider.name) \(number)")
                    } catch { reply("error", error.localizedDescription) }
                }
            } else { reply("error", "adjust show|hide|reset|auto-on|auto-off|undo|redo|copy-all|start-original|start-auto|reset-original|SLIDER VALUE") }
        case "curve":
            let values = argument.split(separator: " ").map(String.init)
            guard let channel = values.first.flatMap(ToneCurves.Channel.init(rawValue:)), let frame = model.shownFrame else {
                reply("error", "curve tone|red|green|blue IN:OUT..."); return
            }
            Task {
                await model.prepareManualAdjustments(for: frame)
                do {
                    let points = try values.dropFirst().map { pair -> CurvePoint in
                        let numbers = pair.split(separator: ":").compactMap { Int($0) }
                        guard numbers.count == 2 else { throw CocoaError(.formatting) }
                        return try CurvePoint(input: numbers[0], output: numbers[1])
                    }
                    let curves = model.manualAdjustments(for: frame).curves
                    let changed = try curves.setting(channel, to: curves.curve(for: channel).setting(points: points))
                    guard model.canAdjust(frame) else { reply("error", model.manualIssue(for: frame) ?? "Auto not ready"); return }
                    model.setToneCurves(changed, for: frame)
                    reply("curve", focus(model))
                } catch { reply("error", error.localizedDescription) }
            }
        case "adjust-measure":
            guard let frame = model.shownFrame, let films = model.films, let layout = model.frameLayout else {
                reply("error", "open a frame before measuring"); return
            }
            let stock = model.stockIndex(for: frame), size = layout.pixels(frame), space = model.output.space
            Task {
                var settings = model.settings(for: frame, stock: stock)
                _ = await films.frameFilm(frame, stock: stock, settings: settings, space: space, pixels: size)
                let decodes = films.decodeCount
                var milliseconds: [Double] = []
                var peak = DevelopBudget.footprint()
                for index in 0..<30 {
                    do {
                        let values = try settings.manual.adjustments.setting(.exposure, to: Float(index + 1) / 20)
                        settings.manual = try ManualRenderSettings(adjustments: values, referenceStops: settings.manual.referenceStops,
                                                                   version: settings.manual.version)
                        let start = Date.timeIntervalSinceReferenceDate
                        guard await films.frameFilm(frame, stock: stock, settings: settings, space: space, pixels: size) != nil else {
                            reply("error", "manual measure render failed"); return
                        }
                        milliseconds.append((Date.timeIntervalSinceReferenceDate - start) * 1000)
                        peak = max(peak, DevelopBudget.footprint())
                    } catch { reply("error", error.localizedDescription); return }
                }
                milliseconds.sort()
                reply("adjust-measure", "\(size)px 30 renders p50=\(milliseconds[15])ms p95=\(milliseconds[28])ms peakFootprint=\(peak) cache=\(films.renderedCacheBytes)/\(films.renderedCacheLimit) entries=\(films.renderedCacheCount) newDecodes=\(films.decodeCount - decodes)")
            }
        case "compare":
            if argument.hasPrefix("split") || argument.hasPrefix("divider-measure") { compareSplit(argument, model: model); return }
            if argument.hasPrefix("auto ") {
                model.isComparingAuto = argument == "auto on"
            } else {
                model.isComparing = argument == "on"
            }
            reply("compare", argument)
        case "zoom":
            let values = argument.split(separator: " ").map(String.init)
            let numbers = values.dropFirst().compactMap { Double($0) }.map { CGFloat($0) }
            let ended = values.last == "end"
            if values.first == "measure" { zoomMeasure(values, model: model); return }
            switch values.first {
            case "in": model.zoomFrame(.zoomIn)
            case "out": model.zoomFrame(.zoomOut)
            case "actual": model.zoomFrame(.actualSize)
            case "fit": model.zoomFrame(.fit)
            case "smart" where numbers.count == 2: model.smartZoomFrame(at: CGPoint(x: numbers[0], y: numbers[1]))
            case "pinch" where numbers.count == 3:
                model.pinchFrame(by: numbers[0], at: CGPoint(x: numbers[1], y: numbers[2]), ended: ended)
            case "pan" where numbers.count == 2:
                model.panFrame(by: CGSize(width: numbers[0], height: numbers[1]), ended: ended)
            case nil, "state": break
            default: reply("error", "no zoom \(argument)"); return
            }
            // After SwiftUI has drawn what the zoom changed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { reply("zoom", zoomState(model)) }
        case "window-id": reply("window-id", mainWindow().map { "\($0.windowNumber)" } ?? "none")
        case "key":
            for name in argument.split(separator: " ").map(String.init) {
                guard press(name) else { reply("error", "no key \(name)"); return }
            }
            // After SwiftUI has applied what the keys changed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { reply("key", "\(argument) → \(focus(model))") }
        case "focus": reply("focus", focus(model))
        case "hit":
            let values = argument.split(separator: " ").compactMap { Double($0) }
            guard values.count == 2, let window = mainWindow(), let frameView = window.contentView?.superview,
                  let first = NSScreen.screens.first else {
                reply("error", "hit X Y"); return
            }
            var view = frameView.hitTest(window.convertPoint(fromScreen: NSPoint(x: values[0], y: first.frame.maxY - values[1])))
            var chain: [String] = []
            while let found = view, chain.count < 10 {
                let frame = found.convert(found.bounds, to: nil)
                let name = String(describing: type(of: found)).prefix { $0 != "<" }
                chain.append("\(name) (\(Int(frame.minX)),\(Int(window.frame.height - frame.maxY)) \(Int(frame.width))x\(Int(frame.height)))")
                view = found.superview
            }
            reply("hit", chain.joined(separator: " < "))
        case "mouse":
            let values = argument.split(separator: " ").map(String.init)
            guard values.count >= 3, let window = mainWindow(), let x = Double(values[1]), let y = Double(values[2]),
                  let first = NSScreen.screens.first else {
                reply("error", "mouse click X Y [N] [cmd|shift] | drag X Y DX [opt] [hold S]"); return
            }
            // AX's global points, from the top of the first screen, into the window's.
            let point = window.convertPoint(fromScreen: NSPoint(x: x, y: first.frame.maxY - y))
            if values[0] == "click" {
                let count = values.count > 3 ? Int(values[3]) ?? 1 : 1
                // With Command or Shift held, as a click that selects several frames is.
                let flags: NSEvent.ModifierFlags = values.contains("cmd") ? .command : values.contains("shift") ? .shift : []
                // Apart, as a hand's are: SwiftUI's tap gestures do not take a press and a release in one turn.
                Task {
                    for click in 1...max(1, count) {
                        postMouse(.leftMouseDown, at: point, in: window, flags: flags, clicks: click)
                        try? await Task.sleep(for: .milliseconds(30))
                        postMouse(.leftMouseUp, at: point, in: window, flags: flags, clicks: click)
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    reply("mouse", "clicked \(count)x at \(point) | \(focus(model))")
                }
            } else if values[0] == "drag", values.count >= 4, let dx = Double(values[3]) {
                let flags: NSEvent.ModifierFlags = values.contains("opt") ? .option : []
                let hold = values.firstIndex(of: "hold").flatMap { values.count > $0 + 1 ? Double(values[$0 + 1]) : nil } ?? 1
                postMouse(.leftMouseDown, at: point, in: window, flags: flags)
                for step in 1...10 {
                    postMouse(.leftMouseDragged, at: NSPoint(x: point.x + dx * Double(step) / 10, y: point.y), in: window, flags: flags)
                }
                // The slider tracks the drag in its own event loop; the main queue still runs meanwhile.
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                    let during = shown(model, name: values.contains("shot") ? "drag" : "")
                    postMouse(.leftMouseUp, at: NSPoint(x: point.x + dx, y: point.y), in: window, flags: flags)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        reply("mouse", "during: \(during) || after: \(shown(model, name: "")) || \(focus(model))")
                    }
                }
            } else {
                reply("error", "mouse click X Y [N] | drag X Y DX [opt] [hold S]")
            }
        case "masks-measure":
            guard let frame = model.shownFrame, let films = model.films else { reply("error", "open a frame before masks-measure"); return }
            Task { await masksMeasure(cold: argument == "cold", frame: frame, lens: model.lensSettings(for: frame), films: films) }
        case "develop-measure":
            let values = argument.split(separator: " ").map(String.init)
            guard let folder = values.first.map({ URL(fileURLWithPath: $0, isDirectory: true) }), let roll = model.roll else {
                reply("error", "develop-measure FOLDER [jpeg|heic|tiff16] [quality:N] [p3] [grain-off] [refining:N] [boosted] [timeline]"); return
            }
            let options = Set(values.dropFirst())
            let measure: @MainActor @Sendable () -> Void = {
                Task { reply("develop-measure", await developMeasure(model, roll: roll, into: folder, options: options)) }
            }
            if options.contains("boosted") { measure() } else { outsideDelivery(measure) }
        case "nap-probe":
            let values = argument.split(separator: " ").map(String.init)
            let what = values.first ?? "", number = values.dropFirst().first.flatMap(Double.init)
            guard what == "progress" || what == "render" else { reply("error", "nap-probe progress SECONDS [still]|render PIXELS"); return }
            outsideDelivery {
                Task {
                    reply("nap-probe", what == "progress" ? await napProbeProgress(model, seconds: number ?? 8, still: values.contains("still"))
                        : await napProbeRender(model, pixels: Int(number ?? 6000)))
                }
            }
        case "grain":
            guard let grain = OutputSettings.Grain(rawValue: argument) else { reply("error", "grain natural|off"); return }
            model.output.grain = grain
            reply("grain", grain.rawValue)
        case "refine":
            guard let films = model.films else { reply("error", "no films"); return }
            if argument == "on" { films.refinesFrameDecodes = true } else if argument == "off" { films.refinesFrameDecodes = false }
            let counts = films.refinementCounts
            let shown = model.shownFrame.flatMap { frame in model.frameLayout.map { films.isFrameDecodeRefined(frame, lens: model.lensSettings(for: frame), pixels: $0.pixels(frame)) } }
            reply("refine", "on \(films.refinesFrameDecodes) started \(counts.started) installed \(counts.installed) dropped \(counts.dropped)"
                  + " shown refined \(shown.map { "\($0)" } ?? "none")")
        case "browse-measure":
            let values = argument.split(separator: " ").map(String.init)
            guard let order = values.first, ["step", "jump"].contains(order), let roll = model.roll, model.films != nil else {
                reply("error", "browse-measure step|jump [MS]"); return
            }
            let dwell = values.dropFirst().first.flatMap(Int.init) ?? 2000
            Task { reply("browse-measure", await browseMeasure(model, roll: roll, order: order, dwell: dwell)) }
        case "latency-refining":
            let values = argument.split(separator: " ").compactMap { Int($0) }
            guard let index = values.first, let roll = model.roll, roll.frames.indices.contains(index),
                  let view = mainWindow()?.contentView, let films = model.films else {
                reply("error", "latency-refining FRAME [N]"); return
            }
            let frame = roll.frames[index], count = values.dropFirst().first ?? 20
            let before = films.refinementCounts
            model.selection = index
            model.openFrame()
            Task {
                guard await refinementStarted(films, after: before.started) else {
                    reply("latency-refining", "no refinement started within 5 s"); return
                }
                await model.prepareManualAdjustments(for: frame)
                guard model.canAdjust(frame) else { reply("error", "not ready to adjust: \(model.manualIssue(for: frame) ?? "Auto not shown")"); return }
                let clock = FrameClock(view: view)
                defer { clock.stop() }
                let line = await settingsLatency(model, frame: frame, count: count, clock: clock, slider: .light(.exposure))
                let after = films.refinementCounts
                reply("latency-refining", line + " | refinement started \(after.started - before.started) installed \(after.installed - before.installed)"
                      + " dropped \(after.dropped - before.dropped)")
            }
        case "clip-latency":
            guard let frame = model.shownFrame, let view = mainWindow()?.contentView, model.canAdjust(frame) else {
                reply("error", "open a frame that is ready to adjust"); return
            }
            let count = Int(argument) ?? 20
            Task {
                let clock = FrameClock(view: view)
                defer { clock.stop() }
                reply("clip-latency", await clippingLatency(model, frame: frame, count: count, clock: clock))
            }
        case "latency", "compare-latency":
            guard let frame = model.shownFrame, let view = mainWindow()?.contentView, model.canAdjust(frame) else {
                reply("error", "open a frame that is ready to adjust"); return
            }
            let words = argument.split(separator: " ").map(String.init)
            let count = words.first.flatMap { Int($0) } ?? 30
            let maskControl = words.contains("mask") ? (words.last == "mask" ? "exposure" : words.last ?? "exposure") : nil
            let lensControl: LensSettings.Control?
            if let index = words.firstIndex(of: "lens") {
                let name = words.indices.contains(index + 1) ? words[index + 1] : "distortion"
                guard let control = LensSettings.Control(rawValue: name) else { reply("error", "unknown lens control: \(name)"); return }
                lensControl = control
            } else { lensControl = nil }
            Task {
                let clock = FrameClock(view: view)
                defer { clock.stop() }
                let line: String
                if parts[0] == "compare-latency" {
                    line = await comparisonLatency(model, frame: frame, count: count, clock: clock)
                } else if let maskControl {
                    line = await maskLatency(model, frame: frame, control: maskControl, count: count, clock: clock)
                } else {
                    line = await settingsLatency(model, frame: frame, count: count, clock: clock, slider: lensControl.map { .lens($0) } ?? .light(.exposure))
                }
                reply(parts[0], line)
            }
        case "launch-time": reply("launch-time", launchTime(model))
        case "sheet-measure":
            guard let view = mainWindow()?.contentView, model.roll == nil, !model.isScanning else {
                reply("error", "sheet-measure [SECONDS] from the empty state"); return
            }
            let limit = Double(argument) ?? 30
            opened = nil
            SheetProbe.previews.removeAll()
            SheetProbe.films.removeAll()
            Task {
                let clock = FrameClock(view: view)
                defer { clock.stop() }
                reply("sheet-measure", await sheetMeasure(model, limit: limit, clock: clock))
            }
            reply("sheet-armed", "waiting \(Int(limit)) s for a roll")
        case "stock-measure":
            guard model.roll != nil, !model.isFrameOpen, let films = model.films, films.stocks.count > 1,
                  let view = mainWindow()?.contentView else {
                reply("error", "stock-measure [N] on the contact sheet"); return
            }
            let count = Int(argument) ?? 10
            Task {
                let clock = FrameClock(view: view)
                defer { clock.stop() }
                reply("stock-measure", await stockMeasure(model, films: films, count: count, clock: clock))
            }
        case "scroll-measure":
            guard model.workspacePage == .importReview || model.roll != nil && !model.isFrameOpen,
                  let view = mainWindow()?.contentView, let scroller = sheetScroller(in: view) else {
                reply("error", "scroll-measure [PT/S] [SECONDS] on the contact sheet"); return
            }
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            let speed = numbers.first ?? 2400, seconds = numbers.count > 1 ? numbers[1] : 8
            Task {
                let clock = FrameClock(view: view)
                defer { clock.stop() }
                // What the previews did during the scroll: the renders begun, by kind, the masks' field cache, and the rendered
                // pictures kept, so a settled sheet that renders while it scrolls says so.
                let work = WorkCount(), films = model.films
                let fieldsBefore = films?.maskFieldStatistics, keptBefore = films?.renderedCacheCount ?? 0
                films?.observeWork = { note in work.add(note) }
                let measured = await scrollMeasure(scroller, speed: speed, seconds: seconds, clock: clock)
                films?.observeWork = nil
                var line = measured + " | began " + work.summary + ", rendered kept \(keptBefore) to \(films?.renderedCacheCount ?? 0)"
                if let before = fieldsBefore, let after = films?.maskFieldStatistics {
                    line += ", fields hits \(after.hits - before.hits) bakes \(after.bakes - before.bakes) allocations \(after.allocations - before.allocations)"
                }
                reply("scroll-measure", line)
            }
        case "wheel":
            guard let window = mainWindow(), let view = window.contentView, let scroller = sheetScroller(in: view),
                  let delta = Int32(argument),
                  let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0),
                  let screen = window.screen ?? NSScreen.main else { reply("error", "wheel DY on the contact sheet"); return }
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.location = CGPoint(x: window.frame.midX, y: screen.frame.maxY - window.frame.midY)
            guard let wheel = NSEvent(cgEvent: event) else { reply("error", "no event"); return }
            let before = scroller.contentView.bounds.minY
            window.sendEvent(wheel)
            reply("wheel", "\(before) to \(scroller.contentView.bounds.minY)")
        case "mask": mask(argument, model: model)
        case "smart": smart(argument, model: model)
        case "remove": remove(argument, model: model)
        case "decoders":
            guard let roll = model.roll, let films = model.films else { reply("error", "no roll"); return }
            let choices = roll.frames.map { films.decoderChoices.choice(for: $0.url) }
            let first = choices.firstIndex(of: .inHouse), firstRAW9 = choices.firstIndex(of: .raw9)
            reply("decoders", "\(roll.frames.count) frames on the \(films.decoderChoices.route.rawValue) route: RAW 9 \(choices.filter { $0 == .raw9 }.count),"
                  + " RAW 8 \(choices.filter { $0 == .apple }.count), in-house \(choices.filter { $0 == .inHouse }.count)"
                  + (firstRAW9.map { " | first RAW 9 frame \($0) \(roll.frames[$0].name)" } ?? " | no RAW 9 frame")
                  + (first.map { " | first in-house frame \($0) \(roll.frames[$0].name)" } ?? " | no in-house frame"))
        default: reply("error", "unknown command \(command)")
        }
    }

    /// `body` on the main queue, outside the notification being handled. distnoted passes on the
    /// poster's importance, and dispatch carries that boost into every block queued while handling
    /// it, so work begun inside the delivery keeps the app from napping until it ends; a detached
    /// block begins it with none, as a develop begun from the window has.
    private static func outsideDelivery(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async(execute: DispatchWorkItem(flags: .detached) { MainActor.assumeIsolated { body() } })
    }

    private static func importReview(_ argument: String, model: RollModel) {
        let words = argument.split(separator: " ", maxSplits: 1).map(String.init)
        let value = words.count > 1 ? words[1] : ""
        func shown(_ name: String) -> ImportFrame.ID? {
            guard case .reviewing(let review) = model.importSession else { return nil }
            if let number = Int(name), review.shown.indices.contains(number - 1) { return review.shown[number - 1].id }
            return review.shown.first { $0.name == name }?.id
        }
        switch words.first ?? "" {
        case "start":
            guard let card = model.offeredCard, model.canImport(card) else {
                reply("error", "import start needs a card on offer that Import can read"); return
            }
            outsideDelivery {
                let began = CACurrentMediaTime()
                model.startImport(card)
                Task {
                    await model.importTask?.value
                    reply("import", String(format: "%.2f s ", CACurrentMediaTime() - began) + importState(model))
                }
            }
            return
        case "toggle":
            guard let id = shown(value) else { reply("error", "import toggle NAME|N while a card is reviewed"); return }
            model.reviewImport { $0.toggle(id) }
        case "filter":
            guard let filter = ImportFilter(rawValue: value) else { reply("error", "import filter all|import|left"); return }
            model.reviewImport { $0.show(filter) }
        case "select":
            if value == "first" || value == "last" {
                model.reviewImport { $0.selectEnd(last: value == "last") }
            } else if let id = shown(value) {
                model.reviewImport { $0.selection = id }
            } else {
                reply("error", "import select first|last|NAME"); return
            }
        case "go":
            guard case .reviewing(let review) = model.importSession, review.canCopy else {
                reply("error", "import go while a card is reviewed with frames to import"); return
            }
            outsideDelivery {
                let trail = ImportTrail()
                model.startCopy()
                let task = model.importTask
                if trail.keepsFollowing(model.importSession) { followImport(model, trail.keepsFollowing) }
                Task {
                    await task?.value
                    let roll = model.roll.map { "\($0.folder.path) \(RollModel.framesText($0.frames.count))" } ?? "none"
                    reply("import", String(format: "%.2f s copy, %.2f s to the roll, ", trail.copySeconds ?? .nan, CACurrentMediaTime() - trail.began)
                          + "\(trail.counts.first ?? "none") to \(trail.counts.last ?? "none") in \(trail.counts.count) steps, "
                          + "\(trail.finished ?? "not finished"), roll \(roll), " + importState(model))
                }
            }
            return
        case "cancel":
            guard case .copying = model.importSession else { reply("error", "import cancel while the frames are copied"); return }
            model.cancelCopy()
        case "close": model.closeImport()
        case "folder":
            // A library roll's folder, reached through its bookmark, as if chosen in Import from a folder…'s panel; its access
            // is held for the rest of the session.
            guard let entry = model.library.first(where: { $0.name == value }), let folder = model.bookmarks.resolve(entry) else {
                reply("error", "import folder NAME of a library roll"); return
            }
            _ = folder.startAccessingSecurityScopedResource()
            outsideDelivery {
                model.startImport(folder: folder)
                Task {
                    await model.importTask?.value
                    reply("import", importState(model))
                }
            }
            return
        case "state": break
        default:
            reply("error", "import start|toggle NAME|filter all|import|left|select first|last|NAME|go|cancel|close|folder NAME|state"); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { reply("import", importState(model)) }
    }

    @MainActor final class ImportTrail {
        let began = CACurrentMediaTime()
        var counts: [String] = []
        var copySeconds: CFTimeInterval?
        var finished: String?

        func keepsFollowing(_ session: ImportSession) -> Bool {
            if case .copying(_, _, let done, let total) = session {
                let count = ImportTopBar.copyingText(done, of: total)
                if counts.last != count { counts.append(count) }
                return true
            }
            copySeconds = CACurrentMediaTime() - began
            if case .finished(_, _, let new, let total) = session { finished = "\(new) of \(total) new" }
            return false
        }
    }

    private static func followImport(_ model: RollModel, _ keepsFollowing: @escaping @MainActor (ImportSession) -> Bool) {
        withObservationTracking { _ = model.importSession } onChange: {
            Task { @MainActor in if keepsFollowing(model.importSession) { followImport(model, keepsFollowing) } }
        }
    }

    private static func importState(_ model: RollModel) -> String {
        var object: [String: Any] = ["0state": "idle"]
        switch model.importSession {
        case .idle: break
        case .scanning(let card, let done, let total):
            object = ["0state": "scanning", "card": card.name, "done": done, "of": total]
        case .copying(let review, let folder, let done, let total):
            object = ["0state": "copying", "card": review.card.name, "folder": folder.path, "done": done, "of": total,
                      "0shown": ImportTopBar.copyingText(done, of: total)]
        case .finished(let card, let folder, let new, let total):
            object = ["0state": "finished", "card": card.name, "folder": folder.path, "new": new, "of": total]
        case .failed(let card, let message, let imported):
            object = ["0state": "failed", "card": card.name, "message": message,
                      "imported": imported.map { "\($0.count) in \($0.folder.path)" } ?? NSNull()]
        case .reviewing(let review):
            let visible = ImportProbe.visibleFrames()
            object = ["0state": "reviewing", "0summary": review.summary, "card": review.card.name, "frames": review.frames.count,
                      "filter": review.filter.rawValue, "shownCount": review.shown.count,
                      "selection": review.selection.map(ImportFrame.name) ?? NSNull(), "stopped": review.stop?.text ?? NSNull(),
                      "visible": visible.count, "visibleLoaded": visible.filter(ImportProbe.loaded.contains).count,
                      "visibleRange": visible.isEmpty ? NSNull() : "\(ImportFrame.name(visible[0])) to \(ImportFrame.name(visible[visible.count - 1]))",
                      "shown": review.shown.prefix(30).map { frame in
                          let badge = review.badge(frame.id)?.text
                          return "\(frame.name) \(review.isKept(frame.id) ? "import" : "left")" + (badge.map { " \($0)" } ?? "")
                      }]
        }
        object["page"] = "\(model.workspacePage)"
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func importSettings(_ change: String, model: RollModel) {
        let words = change.split(separator: " ", maxSplits: 1).map(String.init)
        let row = words.first, value = words.count > 1 ? words[1] : ""
        if row == "burst-gap", let choice = BurstGapChoice(rawValue: value) {
            model.importSettings.cull.burstGap = choice.seconds
        } else if row == "soft-focus", let choice = SoftFocusChoice(rawValue: value) {
            choice.apply(to: &model.importSettings.cull)
        } else if row == "eyes-closed", value == "leave" || value == "keep" {
            model.importSettings.cull.leavesEyesClosed = value == "leave"
        } else if row == "same-moment", let choice = SameMomentChoice(rawValue: value) {
            model.importSettings.cull.sameMomentWithin = choice.within
        } else if row == "cull", value == "on" || value == "off" {
            model.importSettings.isCulling = value == "on"
        } else if row == "destination", value == "pictures" {
            model.setImportDestination(.pictures)
        } else if row == "destination", value == "choose" {
            model.chooseImportDestination()
        } else if row == "destination", value.hasPrefix("/") {
            model.setImportDestination(.folder(URL(fileURLWithPath: value, isDirectory: true)))
        } else if row != nil {
            reply("error", "settings import [burst-gap short|normal|long | soft-focus strict|normal|loose | eyes-closed leave|keep | "
                  + "same-moment narrow|normal|wide | cull on|off | destination pictures|choose|FOLDER]")
            return
        }
        let cull = model.importSettings.cull
        var rows = ["burst-gap \(BurstGapChoice(cull)?.rawValue ?? "\(cull.burstGap)")",
                    "soft-focus \(SoftFocusChoice(cull)?.rawValue ?? "\(cull.softFocusBelow)/\(cull.eyesClosedBelow)")",
                    "eyes-closed \(cull.leavesEyesClosed ? "leave" : "keep")",
                    "same-moment \(SameMomentChoice(cull)?.rawValue ?? "\(cull.sameMomentWithin)")",
                    "cull \(model.importSettings.isCulling ? "on" : "off")"]
        switch model.importSettings.destination {
        case .folder(let folder):
            let kept = model.bookmarks.destination(atPath: folder.path)
            let accessing = kept?.startAccessingSecurityScopedResource() ?? false
            let writable = FileManager.default.isWritableFile(atPath: (kept ?? folder).path)
            if accessing { kept?.stopAccessingSecurityScopedResource() }
            rows.append("destination \(folder.path) bookmark \(kept != nil) writable \(writable)")
        case .pictures:
            rows.append("destination pictures")
        }
        reply("settings", rows.joined(separator: ", "))
    }

    private static func reply(_ kind: String, _ text: String) {
        log.notice("drive \(kind, privacy: .public): \(text, privacy: .public)")
    }

    /// `remove`: a selection and Return on the shown frame, as the Remove brush and the keys make them, and what the tab then shows.
    private static func remove(_ argument: String, model: RollModel) {
        let values = argument.split(separator: " ").map(String.init)
        guard let frame = model.shownFrame else { reply("error", "open a frame before remove"); return }
        switch values.first ?? "state" {
        case "fake":
            guard let films = model.films else { reply("error", "remove fake needs a stock"); return }
            let engine = FakeRemovalEngine(stepDelay: .milliseconds(values.count > 1 ? Int(values[1]) ?? 400 : 400))
            model.removalRuns.steps = LiveRemovalSteps(films: films, library: model.recipeLibrary, makeEngine: { engine })
            model.removeTabShown(for: frame)
        case "stroke":
            let numbers = values.dropFirst().compactMap(Double.init)
            guard numbers.count >= 2, numbers.count.isMultiple(of: 2) else { reply("error", "remove stroke X Y [X Y...] [option]"); return }
            let points = stride(from: 0, to: numbers.count, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
            let modifiers: NSEvent.ModifierFlags = values.last == "option" ? .option : []
            // The canvas says where on the picture and where in the frame view's area; the area's only tells a click from a stroke.
            func event(_ phase: MaskCanvasEvent.Phase, _ point: CGPoint) -> MaskCanvasEvent {
                MaskCanvasEvent(phase: phase, fractions: point, point: CGPoint(x: point.x * 1000, y: point.y * 1000), modifiers: modifiers, clickCount: 1)
            }
            model.removeTabShown(for: frame)
            model.removeBrush(event(.press, points[0]), on: frame)
            for point in points.dropFirst() { model.removeBrush(event(.drag, point), on: frame) }
            model.removeBrush(event(.release, points[points.count - 1]), on: frame)
        case "return": model.commitRemoval(on: frame)
        case "cancel": model.cancelNewestRemoval(on: frame)
        case "again", "better", "delete":
            guard values.count == 2, let number = Int(values[1]),
                  let row = model.removalRows(for: frame).first(where: { $0.number == number && !$0.isPending }) else {
                reply("error", "remove \(values[0]) N: the number of a removal the frame has"); return
            }
            if values[0] == "delete" {
                model.deleteRemoval(row.id, on: frame)
            } else {
                model.remakeRemoval(row.id, better: values[0] == "better", on: frame)
            }
        case "state": break
        default: reply("error", "remove fake [MS] | stroke X Y [X Y...] [option] | return | cancel | again N | better N | delete N | state"); return
        }
        let selection = model.remove.selection
        let selected = selection.coverage.map { coverage in
            "\(coverage.width)x\(coverage.height) \(coverage.values.filter { $0 >= 128 }.count * 100 / max(1, coverage.values.count)) % selected"
        } ?? "nothing selected"
        let rows = model.removalRows(for: frame).map { row in
            "\(row.title)\(row.isPending ? " pending" : row.isOn ? "" : " off")\(row.includesEffects ? "" : " object only")"
                + (row.caption.map { " \"\($0.text)\"" } ?? "")
        }
        reply("remove", "\(selected)\(selection.isSnapping ? ", snapping" : ""), snap \(selection.snapsToObject ? "on" : "off") \(selection.snap), "
              + "engine \(model.remove.engine) | " + (rows.isEmpty ? "no rows" : rows.joined(separator: " || ")))
    }

    /// `smart`: a smart tile's click and what came of it, the rows, their buttons and the Masks tab closing.
    private static func smart(_ argument: String, model: RollModel) {
        let values = argument.split(separator: " ").map(String.init)
        guard let frame = model.shownFrame else { reply("error", "open a frame before smart"); return }
        func mb() -> Int { DevelopBudget.footprint() >> 20 }
        func row(_ index: Int, _ mask: Mask) -> String {
            let selection = mask.components.lazy.compactMap { if case .smart(let s) = $0.shape { s } else { nil } }.first
            let raster = selection?.raster
            let p = raster.flatMap { model.manualEdits[frame.url]?.maskNotes.rasters[$0.id.hex]?.parameters } ?? [:]
            return "\(index) \(model.maskName(mask.id, for: frame)) [\(selection?.kind.rawValue ?? "none")] "
                + "\(model.smartStatus(of: mask, for: frame)?.text ?? "made") seed \(raster.map { "\($0.id.hex.prefix(12)) \($0.width)x\($0.height)" } ?? "none")"
                + (p["gate.score"].map { " gate \($0) veto ran \(p["veto.ran"] ?? "?") fired \(p["veto.fired"] ?? "?") removed \(p["veto.removedSelectedShare"] ?? "?")" } ?? "")
                + (selection?.kind == .sky && raster != nil ? " | \(p["model.square"] ?? "no square recorded (the edge-repeated one)")" : "")
                + (p["design"].map { " edge \(selection?.edge.rawValue ?? "?") design \($0) outcome \(p["outcome"] ?? "?") rule \(p["rule.in"] ?? "?") ev \(p["rule.evScene"] ?? "none") iso \(p["rule.iso"] ?? "none") argmax \(p["iou.argmax"] ?? "?") selected \(p["selected.share"] ?? "?") gate \(p["gate.ran"] ?? "?") \(p["gate.stuffShare"] ?? "") tiles \(p["matte.tiles"] ?? "-")" } ?? "")
                + (p["fallback"].map { " fallback \($0)" } ?? "")
        }
        switch values.first ?? "" {
        case "add":
            guard values.count == 2, let kind = SmartKind(rawValue: values[1]) else { reply("error", "smart add sky|subject|person|background"); return }
            let before = Set(model.masks(for: frame).map(\.id))
            let start = CACurrentMediaTime(), footprint = mb()
            model.addSmartMask(kind, for: frame)
            guard let mask = model.masks(for: frame).first(where: { !before.contains($0.id) }) else {
                reply("error", "no mask made: \(model.smartAvailability(kind).reason ?? (model.canAddMask(frame) ? "?" : "the frame cannot take a mask"))")
                return
            }
            let first = model.smartStatus(of: mask, for: frame)?.text ?? "none"
            reply("smart", "added \(model.maskName(mask.id, for: frame)) row says \"\(first)\" footprint \(footprint) MB")
            let id = mask.id, store = model.maskEditor.overlay
            Task { @MainActor in
                var arrivedPublishes: Int?
                var peak = footprint
                while CACurrentMediaTime() - start < 120 {
                    peak = max(peak, mb())
                    let timing = model.smartMasks.timings[id]
                    let current = model.mask(id, for: frame)
                    let done = current.map { $0.pendingSmart.isEmpty } ?? true
                    let quiet = current.flatMap { model.smartStatus(of: $0, for: frame) }.map { !$0.isBusy } ?? false
                    if done, timing?.arrived != nil, arrivedPublishes == nil { arrivedPublishes = store.publishCount }
                    if let published = arrivedPublishes, store.publishCount > published || CACurrentMediaTime() - (timing?.arrived ?? start) > 2 {
                        let shown = store.publishCount > published ? CACurrentMediaTime() : nil
                        func ms(_ t: CFTimeInterval?) -> String { t.map { String(format: "%.0f", ($0 - start) * 1000) } ?? "-" }
                        reply("smart-done", "\(kind.rawValue) arrived \(ms(timing?.arrived)) ms red \(ms(shown)) ms | stages \(timing?.stages.joined(separator: " > ") ?? "") | "
                              + (current.map { row(0, $0) } ?? "gone") + " | footprint \(footprint) peak \(peak) now \(mb()) MB")
                        return
                    }
                    if quiet || current == nil {
                        reply("smart-done", "\(kind.rawValue) after \(String(format: "%.0f", (CACurrentMediaTime() - start) * 1000)) ms: "
                              + (current.map { row(0, $0) } ?? "gone") + " | stages \(timing?.stages.joined(separator: " > ") ?? "")")
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                reply("smart-done", "\(kind.rawValue) timed out")
            }
        case "list":
            reply("smart", model.masks(for: frame).enumerated().map { row($0.offset, $0.element) }.joined(separator: " || "))
        case "act":
            let masks = model.masks(for: frame)
            guard values.count == 3, let index = Int(values[1]), masks.indices.contains(index),
                  let action = SmartRowStatus.Action(rawValue: values[2]) else { reply("error", "smart act N cancel|paintInstead|remove|retry|update|keep"); return }
            model.perform(action, on: masks[index].id, for: frame)
            reply("smart", model.masks(for: frame).enumerated().map { row($0.offset, $0.element) }.joined(separator: " || "))
        case "tab-closed":
            model.masksTabDisappeared()
            reply("smart", "tab closed; footprint \(mb()) MB")
        case "tab-opened":
            model.masksTabAppeared()
            model.masksTabShows(frame)
            reply("smart", "tab open \(model.smartMasks.inference?.isTabOpen == true); footprint \(mb()) MB")
        case "simulate-older":
            // A model change, simulated: mask N's seed recorded as made by an earlier recipe of its model, as a seed saved before an
            // update of the app would be. The seed and the mask stay as they are; only the provenance's note of the model changes.
            let masks = model.masks(for: frame)
            guard values.count == 2, let index = Int(values[1]), masks.indices.contains(index),
                  let raster = masks[index].components.lazy.compactMap({ if case .smart(let s) = $0.shape { s.raster } else { nil } }).first,
                  var provenance = model.manualEdits[frame.url]?.maskNotes.rasters[raster.id.hex] else {
                reply("error", "smart simulate-older N, N a smart mask with its seed"); return
            }
            if let recipe = provenance.parameters["model.recipe"] {
                provenance.parameters["model.recipe"] = recipe + "-earlier"
            } else {
                provenance.engineRevision = "0"
            }
            model.manualEdits[frame.url]?.maskNotes.rasters[raster.id.hex] = provenance
            model.saveManualFrame(frame)
            reply("smart", model.masks(for: frame).enumerated().map { row($0.offset, $0.element) }.joined(separator: " || "))
        case "memory":
            let stats = model.smartMasks.inference?.statistics
            Task { @MainActor in
                let bundled = (model.smartMasks.inference?.engine as? BundledSmartMasks)?.models
                let loaded = await bundled?.skyRunner.isLoaded
                let subjectLoaded = await bundled?.subjectRunner.isLoaded, matteLoaded = await bundled?.matteRunner.isLoaded
                reply("smart", "footprint \(mb()) MB | runs \(stats?.runs ?? 0) joined \(stats?.joined ?? 0) kept \(stats?.kept ?? 0) "
                      + "unloads \(stats?.unloads ?? 0) | DA3 loaded \(loaded.map { "\($0)" } ?? "no queue") S3OD loaded \(subjectLoaded.map { "\($0)" } ?? "-") "
                      + "ViTMatte loaded \(matteLoaded.map { "\($0)" } ?? "-") | \(model.films?.heldReport ?? "")")
            }
        default:
            reply("error", "smart add KIND | list | act N ACTION | tab-closed | memory")
        }
    }

    /// `masks-measure`: the bundled models measured in this process, sandboxed, as P0-S1b and P0-S5 measured their probes. The
    /// ledger is the app's own; the replies are `masks-measure` lines, the last one `done`.
    private static func masksMeasure(cold: Bool, frame: Frame, lens: LensSettings, films: FilmPreviews) async {
        func say(_ text: String) { reply("masks-measure", text) }
        func mb() -> Int { DevelopBudget.footprint() / 1_000_000 }
        func seconds(since start: ContinuousClock.Instant) -> Double { (ContinuousClock.now - start).seconds }
        func cacheMB() -> Int {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("coreai-cache")
            var total = 0
            for case let file as URL in FileManager.default.enumerator(at: caches, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) ?? .init() {
                total += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            }
            return total / 1_000_000
        }
        let models = MaskModels(ledgerFile: ApplicationSupport.folder.appendingPathComponent("Mask models.json"))
        say("bundled \(models.directory?.path ?? "none"), Sky available \(models.isSkyAvailable) \(models.unavailable.map(\.description)), "
            + "macOS \(MaskModels.osBuild), needs preparation \(models.needsPreparation), coreai-cache \(cacheMB()) MB, footprint \(mb()) MB")
        guard models.isSkyAvailable else { say("done"); return }
        do {
            if cold {
                try models.deleteCompiledCopies()
                say("cold: compiled copies deleted, coreai-cache \(cacheMB()) MB, needs preparation \(models.needsPreparation)")
            }
            var start = ContinuousClock.now
            let report = try await models.prepare { progress in
                Task { @MainActor in reply("masks-measure", "progress \(progress.step) \(String(format: "%.2f", progress.fraction))") }
            }
            say(String(format: "prepared in %.2f s: specialise DA3 %.2f, EoMT %.2f; warm DA3 %.2f, EoMT %.2f; stale deleted %@; coreai-cache %d MB; needs preparation %@",
                       seconds(since: start), report.specialiseSeconds[.sky] ?? 0, report.specialiseSeconds[.water] ?? 0,
                       report.warmSeconds[.sky] ?? 0, report.warmSeconds[.water] ?? 0, "\(report.staleDeleted)", cacheMB(), "\(models.needsPreparation)"))
            start = ContinuousClock.now
            guard let picture = await films.maskInputPicture(frame, lens: lens) else { say("no input picture"); say("done"); return }
            let first = seconds(since: start)
            start = ContinuousClock.now
            _ = await films.maskInputPicture(frame, lens: lens)
            say(String(format: "input picture %d × %d from a %d × %d decode (%@): %.3f s, kept %.4f s; digest %@",
                       picture.width, picture.height, picture.source.decodeWidth, picture.source.decodeHeight, picture.source.decoderVersion,
                       first, seconds(since: start), String(picture.digest.prefix(16))))
            let base = mb()
            start = ContinuousClock.now
            var sky = try await models.sky(for: picture)
            let firstSky = seconds(since: start)
            var calls: [Double] = [], clicks: [Double] = [], digests: Set<String> = [sky.digest]
            for _ in 0..<20 {
                start = ContinuousClock.now
                sky = try await models.sky(for: picture)
                clicks.append(seconds(since: start)); calls.append(sky.seconds); digests.insert(sky.digest)
            }
            let running = mb()
            await models.unloadSky()
            let atUnload = mb()
            try await Task.sleep(for: .seconds(2))
            let seed = sky.seed
            say(String(format: "DA3: first %.3f s (load and run); warm call min %.3f median %.3f s, with the square %.3f s; %d distinct outputs; "
                        + "footprint %d MB before, %d running, %d at unload, %d 2 s after; seed %d × %d, %.1f %% at 0.5",
                        firstSky, calls.min()!, calls.sorted()[10], clicks.sorted()[10], digests.count, base, running, atUnload, mb(),
                        seed.width, seed.height, 100 * Double(seed.values.filter { $0 >= 0.5 }.count) / Double(seed.values.count)))
            start = ContinuousClock.now
            var maps = try await models.water(for: picture)
            let firstWater = seconds(since: start)
            var gated: [Double] = []
            digests = [maps.digest]
            for _ in 0..<10 {
                start = ContinuousClock.now
                maps = try await models.water(for: picture)
                gated.append(seconds(since: start)); digests.insert(maps.digest)
            }
            calls = []
            for _ in 0..<20 { maps = try await models.water(for: picture, keepLoaded: true); calls.append(maps.seconds); digests.insert(maps.digest) }
            let waterRunning = mb()
            await models.unloadAll()
            try await Task.sleep(for: .seconds(2))
            say(String(format: "EoMT: first %.3f s (load, run, unload); a gated click's load, run and unload median %.3f s; warm call min %.3f median %.3f s; "
                        + "%d distinct outputs; footprint %d MB running, %d 2 s after unload; water at 0.5 on %.2f %% of the map",
                        firstWater, gated.sorted()[5], calls.min()!, calls.sorted()[10], digests.count, waterRunning, mb(),
                        100 * Double(maps.water.filter { $0 >= 0.5 }.count) / Double(maps.water.count)))
            if models.isSubjectAvailable {
                let before = mb()
                start = ContinuousClock.now
                var s3 = try await models.subject(for: picture)
                let firstS3 = seconds(since: start)
                let s3Running = mb()
                var cycles: [Double] = []
                var s3Digests: Set<String> = [s3.digest]
                for _ in 0..<10 {
                    start = ContinuousClock.now
                    s3 = try await models.subject(for: picture)
                    cycles.append(seconds(since: start)); s3Digests.insert(s3.digest)
                }
                try await Task.sleep(for: .seconds(2))
                say(String(format: "S3OD: first %.3f s (load, run, unload); a click's load, run and unload median %.3f s; %d distinct outputs; footprint %d MB before, %d just after the run, %d 2 s after; argmax %d",
                            firstS3, cycles.sorted()[5], s3Digests.count, before, s3Running, mb(), s3.selectedIndex))
                let seedPlane = s3.selectedContent.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
                let seed = try MaskRaster(width: s3.layout.contentWidth, height: s3.layout.contentHeight, plane: seedPlane)
                start = ContinuousClock.now
                let first = try await models.matte(seed: seed, on: picture)
                let firstMatte = seconds(since: start)
                let matteRunning = mb()
                var matteCycles: [Double] = []
                for _ in 0..<3 {
                    start = ContinuousClock.now
                    _ = try await models.matte(seed: seed, on: picture)
                    matteCycles.append(seconds(since: start))
                }
                try await Task.sleep(for: .seconds(2))
                say(String(format: "ViTMatte: %d tiles; first %.3f s (load, tile loop, unload, trimap and composite included); warm median %.3f s; unknown band %.2f %% of the frame; footprint %d MB after the matte, %d 2 s after; alpha %d x %d",
                            first.tiles, firstMatte, matteCycles.sorted()[1], first.unknownShare * 100, matteRunning, mb(), first.alpha.width, first.alpha.height))
            } else {
                say("Subject's models are not all here: \(models.subjectMissing.map(\.description) ?? "?")")
            }
        } catch {
            say("error \(error)")
        }
        say("done")
    }

    // MARK: Masks

    private static func mask(_ argument: String, model: RollModel) {
        let values = argument.split(separator: " ").map(String.init)
        let editor = model.maskEditor
        let window = mainWindow()
        /// An area point into the window's, through the canvas.
        func windowPoint(_ x: Double, _ y: Double) -> NSPoint? {
            editor.canvas?.convert(NSPoint(x: x, y: y), to: nil)
        }
        func offset() -> String { String(format: "%.1f,%.1f", model.frameZoom.offset.width, model.frameZoom.offset.height) }
        switch values.first ?? "" {
        case "arm":
            guard values.count >= 2, let tool = MaskEditor.Tool(rawValue: values[1]) else {
                reply("error", "mask arm brush|linear|radial [add|subtract|intersect]"); return
            }
            let operation = values.count > 2 ? MaskOperation(rawValue: values[2]) : nil
            if tool == .brush { model.armBrush(adding: operation) } else { editor.arm(tool, operation: operation) }
            reply("mask", maskState(model))
        case "disarm":
            editor.reset()
            reply("mask", maskState(model))
        case "tab":
            guard values.count == 2, let tab = AdjustInspectorTab(rawValue: values[1]) else {
                reply("error", "mask tab light|curve|masks|lens"); return
            }
            model.showInspector(tab: tab)
            reply("mask", maskState(model))
        case "state":
            reply("mask", maskState(model))
        case "where":
            guard let canvas = editor.canvas, let window, let geometry = canvas.geometry?(), let first = NSScreen.screens.first else {
                reply("error", "no canvas"); return
            }
            func global(_ point: NSPoint) -> CGPoint {
                let screen = window.convertPoint(toScreen: point)
                return CGPoint(x: screen.x, y: first.frame.maxY - screen.y)
            }
            let origin = global(canvas.convert(NSPoint.zero, to: nil))
            let top = global(NSPoint(x: 0, y: window.frame.height))
            let picture = geometry.picture.offsetBy(dx: origin.x, dy: origin.y)
            reply("mask", "area \(geometry.area.width)x\(geometry.area.height) at \(origin.x),\(origin.y)"
                  + " | picture in area \(geometry.picture.minX),\(geometry.picture.minY) \(geometry.picture.width)x\(geometry.picture.height)"
                  + " | picture global \(picture.minX),\(picture.minY) \(picture.width)x\(picture.height)"
                  + " | window global \(top.x),\(top.y) \(window.frame.width)x\(window.frame.height) | key \(window.isKeyWindow) active \(NSApp.isActive)")
        case "takes":
            guard values.count >= 3, let x = Double(values[1]), let y = Double(values[2]) else { reply("error", "mask takes X Y [cmd]"); return }
            reply("mask", "takes \(x),\(y): \(editor.canvasTakesPress(at: CGPoint(x: x, y: y), command: values.contains("cmd")))")
        case "press":
            guard values.count >= 3, let x = Double(values[1]), let y = Double(values[2]), let window, let point = windowPoint(x, y) else {
                reply("error", "mask press X Y [N] [cmd], with a frame open"); return
            }
            let count = values.count > 3 ? Int(values[3]) ?? 1 : 1
            let flags = modifiers(values)
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            Task {
                for click in 1...max(1, count) {
                    postMouse(.leftMouseDown, at: point, in: window, flags: flags, clicks: click)
                    try? await Task.sleep(for: .milliseconds(30))
                    postMouse(.leftMouseUp, at: point, in: window, flags: flags, clicks: click)
                    try? await Task.sleep(for: .milliseconds(60))
                }
                try? await Task.sleep(for: .milliseconds(500))
                reply("mask", "pressed \(count)x at \(x),\(y): frame open \(model.isFrameOpen) | responder \(responder) to \(focus(model)) | \(maskState(model))"
                      + (editor.tool == .brush ? " | \(brushState(model))" : ""))
            }
        case "drag":
            guard values.count >= 5, let x = Double(values[1]), let y = Double(values[2]), let dx = Double(values[3]), let dy = Double(values[4]),
                  let window, let start = windowPoint(x, y), let end = windowPoint(x + dx, y + dy) else {
                reply("error", "mask drag X Y DX DY [cmd], with a frame open"); return
            }
            let flags = modifiers(values)
            let before = offset()
            Task {
                postMouse(.leftMouseDown, at: start, in: window, flags: flags)
                try? await Task.sleep(for: .milliseconds(20))
                for step in 1...10 {
                    let t = Double(step) / 10
                    postMouse(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                              in: window, flags: flags)
                    try? await Task.sleep(for: .milliseconds(8))
                }
                postMouse(.leftMouseUp, at: end, in: window, flags: flags)
                try? await Task.sleep(for: .milliseconds(400))
                reply("mask", "dragged from \(x),\(y) by \(dx),\(dy)\(values.contains("cmd") ? " with Command" : ""): offset \(before) to \(offset()) | \(maskState(model))"
                      + (editor.tool == .brush ? " | \(brushState(model))" : ""))
            }
        case "paint":
            // A stroke along a polyline in long sides (task N), press, moves and release posted as the window server's are, so the canvas, the
            // brush and the overlay run as for a real stroke; `hold S` keeps the pointer still before the release, for a look mid-stroke.
            var rest = Array(values.dropFirst()), hold = 0.0, spacing = 3.0
            while rest.first == "hold" || rest.first == "step", rest.count >= 2, let number = Double(rest[1]) {
                if rest[0] == "hold" { hold = number } else { spacing = number }
                rest.removeFirst(2)
            }
            let numbers = rest.compactMap { Double($0) }
            guard let window, let geometry = editor.canvas?.geometry?(), numbers.count >= 4, numbers.count % 2 == 0, numbers.count == rest.count else {
                reply("error", "mask paint [hold S] [step PT] X Y X Y ..., long sides, with a frame open"); return
            }
            let points = stride(from: 0, to: numbers.count, by: 2).map { geometry.point(for: MaskPoint(x: Float(numbers[$0]), y: Float(numbers[$0 + 1]))) }
            Task {
                guard let first = points.first, let start = windowPoint(first.x, first.y) else { return }
                postMouse(.leftMouseDown, at: start, in: window)
                try? await Task.sleep(for: .milliseconds(20))
                var at = start
                for (a, b) in zip(points, points.dropFirst()) {
                    let count = max(1, Int(hypot(b.x - a.x, b.y - a.y) / spacing))
                    for step in 1...count {
                        let t = CGFloat(step) / CGFloat(count)
                        if let point = windowPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t) {
                            at = point
                            postMouse(.leftMouseDragged, at: point, in: window)
                        }
                        try? await Task.sleep(for: .milliseconds(4))
                    }
                }
                if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
                postMouse(.leftMouseUp, at: at, in: window)
                try? await Task.sleep(for: .milliseconds(400))
                reply("mask", "painted \(points.count) points: \(maskState(model))" + (editor.tool == .brush ? " | \(brushState(model))" : ""))
            }
        case "dump":
            guard values.count == 2, let frame = model.shownFrame else { reply("error", "mask dump NAME, with a frame open"); return }
            let selected = model.selectedMask(for: frame) ?? model.masks(for: frame).last
            let strokes = selected?.components.flatMap { component -> [BrushStroke] in
                if case .brush(let paint) = component.shape { paint.strokes } else { [] }
            } ?? []
            guard let stroke = strokes.last(where: { $0.measured != nil }), let measured = stroke.measured,
                  let raster = try? model.maskSeedStore.load(measured.raster) else {
                reply("error", "mask dump: no Follow edges stroke on the selected brush"); return
            }
            let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            let pngURL = folder.appendingPathComponent("dump-\(values[1]).png"), jsonURL = folder.appendingPathComponent("dump-\(values[1]).json")
            let json: [String: Any] = ["points": stroke.points.points.map { [$0.x, $0.y] }, "radius": stroke.radius, "feather": stroke.feather, "flow": stroke.flow,
                                       "x": measured.x, "y": measured.y, "width": raster.width, "height": raster.height,
                                       "pictureWidth": measured.pictureWidth, "pictureHeight": measured.pictureHeight, "png": pngURL.path]
            do {
                guard writeGray(raster.plane, width: raster.width, height: raster.height, to: pngURL) else { reply("error", "mask dump: no PNG written"); return }
                try JSONSerialization.data(withJSONObject: json).write(to: jsonURL)
                reply("mask", "dumped \(jsonURL.path) | \(raster.width)x\(raster.height) at \(measured.x),\(measured.y) on \(measured.pictureWidth)x\(measured.pictureHeight) | \(stroke.points.count) points")
            } catch { reply("error", "mask dump: \(error)") }
        case "overlay-png":
            let sharp = values.count == 3 && values[2] == "sharp"
            guard values.count == 2 || sharp, let image = sharp ? editor.overlay.sharp?.image : editor.overlay.image else {
                reply("error", "mask overlay-png NAME [sharp]: no such overlay up"); return
            }
            let name = "overlay-\(values[1]).png"
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
            var gray = [UInt8](repeating: 0, count: image.width * image.height)
            let drawn = gray.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drawn, writeGray(gray, width: image.width, height: image.height, to: url) else {
                reply("error", "mask overlay-png: could not draw it"); return
            }
            reply("mask", "overlay \(url.path) \(image.width)x\(image.height) live \(editor.overlay.isLive)")
        case "slider":
            let group: AdjustmentSliderGroup = model.adjustTab == .masks ? .mask : model.adjustTab == .lens ? .lens : .light
            guard values.count == 2, let window, let content = window.contentView,
                  let slider = AdjustmentSliderControl.sliders(in: group, under: content).first(where: { slider in
                      if group == .lens, let control = LensSettings.Control(rawValue: values[1]) {
                          return slider.spec.order == AdjustmentSliderSpec.lensAmount(control).order
                      }
                      return slider.spec.title.lowercased() == values[1].lowercased()
                  }) else {
                reply("error", "mask slider CONTROL, on the Light or Lens tab or with a mask selected"); return
            }
            let accepted = window.makeFirstResponder(slider)
            reply("mask", "slider \(values[1]) focused \(accepted) | \(focus(model))")
        case "add":
            guard values.count == 2, let tool = MaskEditor.Tool(rawValue: values[1]), model.shownFrame != nil else {
                reply("error", "mask add linear|radial, with a frame open"); return
            }
            model.perform(.newMask(tool))
            let placed = model.placeArmedGradient()
            reply("mask", "placed \(placed) | \(maskRead(model))")
        case "list":
            guard let frame = model.shownFrame else { reply("error", "no frame open"); return }
            let lines = model.masks(for: frame).enumerated().map { index, mask in
                "\(index) \(model.maskName(mask.id, for: frame)): \(mask.isEnabled ? "on" : "off") amount \(mask.amount) \(MaskSummary.line(for: mask))"
                    + " [\(mask.components.map { "\($0.operation.rawValue) \(MaskSummary.title(of: $0.shape))\($0.invert ? " inverted" : "")" }.joined(separator: ", "))]"
            }
            reply("mask", "\(lines.count) masks" + (lines.isEmpty ? "" : ": " + lines.joined(separator: " | ")))
        case "select":
            guard let frame = model.shownFrame else { reply("error", "no frame open"); return }
            if values.count == 2, values[1] == "none" {
                editor.selection = nil
            } else if values.count >= 2, let index = Int(values[1]), model.masks(for: frame).indices.contains(index) {
                editor.selection = MaskEditor.Selection(mask: model.masks(for: frame)[index].id, component: values.count > 2 ? Int(values[2]) : nil)
            } else { reply("error", "mask select N [C]|none"); return }
            reply("mask", maskRead(model))
        case "read":
            reply("mask", maskRead(model))
        case "set":
            guard let frame = model.shownFrame, let id = editor.selection?.mask, values.count == 3, let number = Float(values[2]) else {
                reply("error", "mask set CONTROL V, with a mask selected"); return
            }
            let balance = MaskBalanceControl(named: values[1])
            // A control it does not know is an error, not a gesture that changes nothing: `mask set warmth` once passed for one.
            guard values[1] == "amount" || balance != nil || ManualAdjustments.Control(rawValue: values[1]) != nil else {
                reply("error", "mask set CONTROL V: CONTROL is amount, a Light control, warmth or magenta"); return
            }
            model.beginManualGesture(for: frame)
            editor.sliderBegan()
            if values[1] == "amount" {
                model.setMaskAmount(number / 100, mask: id, for: frame)
            } else if let balance {
                model.setMaskBalance(balance, to: number, mask: id, for: frame)
            } else if let control = ManualAdjustments.Control(rawValue: values[1]) {
                model.setMaskValue(control, to: number, mask: id, for: frame)
            }
            editor.sliderEnded()
            model.endManualGesture(for: frame, actionName: "Adjust Mask")
            reply("mask", maskRead(model))
        case "shape":
            let numbers = values.dropFirst(2).compactMap { Float($0) }
            guard let frame = model.shownFrame, let id = editor.selection?.mask, values.count >= 2 else {
                reply("error", "mask shape linear FX FY ZX ZY | radial CX CY A B ANGLE FEATHER, with a mask selected"); return
            }
            let shape: MaskShape
            switch (values[1], numbers.count) {
            case ("linear", 4):
                shape = .linear(.init(full: MaskPoint(x: numbers[0], y: numbers[1]), zero: MaskPoint(x: numbers[2], y: numbers[3])))
            case ("radial", 6):
                shape = .radial(.init(center: MaskPoint(x: numbers[0], y: numbers[1]), semiAxisA: numbers[2], semiAxisB: numbers[3],
                                      angle: numbers[4] * .pi / 180, feather: numbers[5]))
            default:
                reply("error", "mask shape linear FX FY ZX ZY | radial CX CY A B ANGLE FEATHER"); return
            }
            model.beginManualGesture(for: frame)
            editor.shapeRowBegan()
            model.setComponentShape(shape.stamped(editor.lens(on: frame)?.picture), of: id, component: 0, for: frame)
            editor.shapeRowEnded()
            model.endManualGesture(for: frame, actionName: "Adjust Gradient")
            reply("mask", maskRead(model))
        case "feather":
            let isSmart = { (component: MaskComponent) -> Bool in if case .smart = component.shape { true } else { false } }
            guard let frame = model.shownFrame, let id = editor.selection?.mask, values.count == 2, let number = Float(values[1]),
                  let mask = model.mask(id, for: frame),
                  let index = editor.selection?.component.flatMap({ mask.components.indices.contains($0) && isSmart(mask.components[$0]) ? $0 : nil })
                      ?? mask.components.firstIndex(where: isSmart),
                  let shape = MaskShapeField.selectionFeather.setting(number, in: mask.components[index].shape) else {
                reply("error", "mask feather F, 0 to 100, with a smart mask selected"); return
            }
            model.beginManualGesture(for: frame)
            editor.shapeRowBegan()
            model.setComponentShape(shape, of: id, component: index, for: frame)
            editor.shapeRowEnded()
            model.endManualGesture(for: frame, actionName: MaskShapeField.actionName(of: shape))
            reply("mask", maskRead(model))
        case "stroke":
            // One brush stroke as a new component of the selected mask, one undo step: the painting UI's stand-in.
            // mask stroke add|subtract X Y X Y ... [radius R] [feather F] [flow L], positions and radius in long sides.
            guard let frame = model.shownFrame, let id = editor.selection?.mask, let mask = model.mask(id, for: frame), values.count >= 4,
                  let operation = MaskOperation(rawValue: values[1]) else {
                reply("error", "mask stroke add|subtract X Y X Y ... [radius R] [feather F] [flow L], with a mask selected"); return
            }
            var numbers: [Float] = [], settings: [String: Float] = ["radius": 0.02, "feather": 0.6, "flow": 1]
            var index = 2
            while index < values.count {
                if settings[values[index]] != nil, index + 1 < values.count, let value = Float(values[index + 1]) {
                    settings[values[index]] = value; index += 2
                } else if let value = Float(values[index]) {
                    numbers.append(value); index += 1
                } else { reply("error", "mask stroke: \(values[index])?"); return }
            }
            guard numbers.count >= 2, numbers.count % 2 == 0 else { reply("error", "mask stroke needs X Y pairs"); return }
            let points = stride(from: 0, to: numbers.count, by: 2).map { MaskPoint(x: numbers[$0], y: numbers[$0 + 1]) }
            // The frame the stroke was painted on: the mask's smart selection's, else the first brush's.
            let painted = mask.components.lazy.compactMap { $0.shape.frame }.first
            guard var painted, let packed = try? PackedPoints.pack(points) else { reply("error", "mask stroke: no painted frame or bad points"); return }
            painted.geometry = editor.lens(on: frame)?.picture
            let stroke = BrushStroke(radius: settings["radius"]!, feather: settings["feather"]!, flow: settings["flow"]!, points: packed)
            model.beginManualGesture(for: frame)
            let written = model.appendMaskComponent(MaskComponent(operation: operation, shape: .brush(BrushPaint(frame: painted, strokes: [stroke]))),
                                                    to: id, for: frame)
            model.endManualGesture(for: frame, actionName: "Paint")
            reply("mask", "stroke \(written ? "added" : "refused") | \(maskRead(model))")
        case "handles":
            guard let frame = model.shownFrame, let geometry = editor.canvas?.geometry?(), let shape = editor.shapeUnderHandles(in: frame) else {
                reply("mask", "no handles"); return
            }
            reply("mask", MaskHandleModel.handles(of: shape, in: geometry)
                .map { "\($0.handle) \(String(format: "%.1f,%.1f", $0.point.x, $0.point.y))" }.joined(separator: " | "))
        case "drag-measure":
            // From a handle of the selected gradient, or with `at X Y` from an area point, for the same drag where
            // there is nothing to move (a frame with no masks).
            let at = values.count >= 4 && values[1] == "at"
            let rest = Array(values.dropFirst(at ? 4 : 2))
            guard let frame = model.shownFrame, let window, let view = window.contentView, let geometry = editor.canvas?.geometry?(),
                  values.count >= 2 else {
                reply("error", "mask drag-measure HANDLE|at X Y [SECONDS] [PT/S], with a gradient selected or a frame open"); return
            }
            let start: CGPoint
            if at, let x = Double(values[2]), let y = Double(values[3]) {
                start = CGPoint(x: x, y: y)
            } else if let shape = editor.shapeUnderHandles(in: frame),
                      let handle = MaskHandleModel.handles(of: shape, in: geometry).first(where: { "\($0.handle)" == values[1] }) {
                start = handle.point
            } else {
                reply("error", "mask drag-measure HANDLE|at X Y [SECONDS] [PT/S], with a gradient selected or a frame open"); return
            }
            let seconds = rest.count > 0 ? Double(rest[0]) ?? 8 : 8, speed = rest.count > 1 ? Double(rest[1]) ?? 600 : 600
            Task {
                let clock = FrameClock(view: view)
                defer { clock.stop() }
                reply("mask", await dragMeasure(model, frame: frame, from: start, seconds: seconds, speed: speed, clock: clock, window: window))
            }
        case "slider-drag":
            // A slider's knob pressed and dragged to and fro along its track, measured as `drag-measure` is.
            let group: AdjustmentSliderGroup = model.adjustTab == .masks ? .mask : model.adjustTab == .lens ? .lens : .light
            guard values.count >= 2, let frame = model.shownFrame, let window, let view = window.contentView,
                  let slider = AdjustmentSliderControl.sliders(in: group, under: view)
                    .first(where: { slider in
                        if group == .lens, let control = LensSettings.Control(rawValue: values[1]) {
                            return slider.spec.order == AdjustmentSliderSpec.lensAmount(control).order
                        }
                        return slider.spec.title.lowercased() == values[1].lowercased()
                    }) else {
                reply("error", "mask slider-drag CONTROL [SECONDS] [PT/S], on the Light or Lens tab or with a mask selected"); return
            }
            let seconds = values.count > 2 ? Double(values[2]) ?? 8 : 8, speed = values.count > 3 ? Double(values[3]) ?? 150 : 150
            Task {
                let clock = FrameClock(view: view)
                defer { clock.stop() }
                reply("mask", await sliderDragMeasure(model, frame: frame, slider: slider, seconds: seconds, speed: speed, clock: clock,
                                                      window: window))
            }
        case "brush":
            // The brush's state, or one of its settings set as the panel sets it. Follow edges goes through A's own action, with the brush
            // in hand, so it compiles its kernels as A does.
            if values.count == 3, let number = Float(values[2]) {
                switch values[1] {
                case "size": editor.brush.settings.size = number
                case "feather": editor.brush.settings.feather = number
                case "flow": editor.brush.settings.flow = number
                default: reply("error", "mask brush [size|feather|flow V | erase on|off | follow on|off]"); return
                }
            } else if values.count == 3, values[1] == "erase" {
                editor.brush.settings.erase = values[2] == "on"
            } else if values.count == 3, values[1] == "follow", ["on", "off"].contains(values[2]) {
                guard editor.tool == .brush else { reply("error", "mask brush follow on|off, with the brush in hand"); return }
                if editor.brush.settings.followEdges != (values[2] == "on") { model.toggleFollowEdges() }
            } else if values.count != 1 {
                reply("error", "mask brush [size|feather|flow V | erase on|off | follow on|off]"); return
            }
            reply("mask", brushState(model))
        case "overlay":
            guard let frame = model.shownFrame else { reply("error", "no frame open"); return }
            let shown = model.overlayComponents(for: frame) != nil
            let image = editor.overlay.image.map { "\($0.width)x\($0.height)" } ?? "none"
            let refined = model.films.map { films in
                let overlays = films.refinedOverlayStatistics, refiner = films.maskRefinerStatistics
                return " | refined overlays made \(overlays.made) kept \(overlays.kept), refiner builds \(refiner.builds) hits \(refiner.hits)"
            } ?? ""
            reply("mask", "shown \(shown) hover \(editor.hover.map { "\($0)" } ?? "none") | on \(editor.isOverlayOn) placed \(editor.justPlaced) colour \(editor.overlayColour.rawValue) image \(image)"
                  + " | rasters \(editor.overlay.rasterCount) published \(editor.overlay.publishCount) flushes \(editor.flushCount)" + refined
                  + (editor.overlay.image.map { " | " + overlayEdges($0) } ?? ""))
        case "show":
            guard values.count == 2, ["on", "off"].contains(values[1]) else { reply("error", "mask show on|off"); return }
            editor.setOverlay(on: values[1] == "on")
            reply("mask", "overlay \(values[1])")
        case "sharp":
            guard model.shownFrame != nil else { reply("error", "no frame open"); return }
            let up = editor.overlay.sharp
            reply("mask", "sharp \(up.map { "\($0.image.width)x\($0.image.height) over \($0.fractions)" } ?? "none") waiting \(editor.overlay.isSharpWaiting)"
                  + (model.films?.regionCoverageFailureDescription.map { " | failed: \($0)" } ?? "")
                  + String(format: " | read %d, last %.1f ms | decode %@", editor.overlay.sharpCount, editor.overlay.sharpSeconds * 1000,
                           model.films.map { "\($0.frameDecodeStatistic)" } ?? "none"))
        case "compiler":
            guard let frame = model.shownFrame, values.count == 2, model.manualEdits[frame.url] != nil else {
                reply("error", "mask compiler VERSION, on an edited frame"); return
            }
            model.manualEdits[frame.url]?.curveVersion = values[1]
            model.saveManualFrame(frame)
            reply("mask", maskRead(model))
        case "cursor":
            let named: [(String, NSCursor)] = [("arrow", .arrow), ("crosshair", .crosshair), ("openHand", .openHand), ("closedHand", .closedHand),
                                               ("resizeLeftRight", .resizeLeftRight), ("iBeam", .iBeam)]
            let current = NSCursor.currentSystem
            reply("mask", "cursor \(named.first { $0.1.image.tiffRepresentation == current?.image.tiffRepresentation }?.0 ?? "other")")
        case "pins", "pin", "pins-measure":
            pins(values, model: model, window: window)
        case "chords":
            var enabled: [String: [String]] = [:]
            func walk(_ menu: NSMenu, _ prefix: String) {
                prepare(menu)
                for item in menu.items where !item.isSeparatorItem {
                    let path = prefix.isEmpty ? item.title : "\(prefix)>\(item.title)"
                    if let submenu = item.submenu { walk(submenu, path); continue }
                    guard item.isEnabled, !item.keyEquivalent.isEmpty else { continue }
                    let flags = item.keyEquivalentModifierMask
                    let chord = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "")
                        + (flags.contains(.command) ? "⌘" : "") + item.keyEquivalent
                    enabled[chord, default: []].append(path)
                }
            }
            if let main = NSApp.mainMenu { walk(main, "") }
            let clashes = enabled.filter { $0.value.count > 1 }.map { "\($0.key): \($0.value.joined(separator: " and "))" }.sorted()
            reply("mask", "\(enabled.count) enabled chords; \(clashes.isEmpty ? "no clashes" : "CLASHES " + clashes.joined(separator: " | "))"
                  + " | plain: " + enabled.keys.filter { !$0.contains("⌘") && !$0.contains("⌃") }.sorted().joined(separator: " "))
        default:
            reply("error", "mask arm|disarm|tab|state|where|takes|press|drag|slider|slider-drag|cursor|chords|add|list|select|read|set|handles|drag-measure|shape|overlay|compiler|brush|pins|pin|pins-measure")
        }
    }

    // MARK: Pins

    /// `mask pins`, `mask pin ...` and `mask pins-measure`: the pins as they stand, the pointer on them, a click, a drag, and their cost.
    private static func pins(_ values: [String], model: RollModel, window: NSWindow?) {
        let editor = model.maskEditor
        guard let frame = model.shownFrame, let canvas = editor.canvas, let window, let geometry = canvas.geometry?() else {
            reply("error", "mask pins|pin|pins-measure, with a frame open"); return
        }
        func point(_ p: CGPoint) -> String { String(format: "%.1f,%.1f", p.x, p.y) }
        func index(_ id: UUID?) -> String { id.flatMap { id in model.masks(for: frame).firstIndex { $0.id == id } }.map(String.init) ?? "none" }
        func line() -> String {
            let geometry = canvas.geometry?() ?? geometry, inputs = editor.pinInputs(on: frame)
            let pins = editor.pins(on: frame, geometry: geometry)
            let why = [inputs.isMasksTabShown ? nil : "no masks tab", inputs.hasMasks ? nil : "no masks", inputs.isHidden ? "hidden by H" : nil,
                       inputs.standsDown ? "masks stand down" : nil, inputs.isArmed ? "tool in hand" : nil, inputs.isPlacing ? "placing" : nil,
                       inputs.isPointerInArea || inputs.isPinPressed ? nil : "pointer away"].compactMap { $0 }
            let items = pins.map { pin in
                "\(index(pin.id)) at \(point(pin.point)) component \(pin.component)" + (pin.isSelected ? " selected" : "") + (pin.isHovered ? " hovered" : "")
                    + (pin.isEnabled ? "" : " off") + (pin.isOnHandle ? " on its handle" : "")
            }
            let overlay = model.overlayComponents(for: frame) != nil
            return "\(pins.count) pins of \(model.masks(for: frame).count) masks: shown \(MaskPinVisibility.isShown(inputs)) live \(MaskPinVisibility.isLive(inputs))"
                + (why.isEmpty ? "" : " (\(why.joined(separator: ", ")))") + " | in area \(editor.isPointerInArea) hovered \(index(editor.hoveredPin))"
                + " selected \(index(editor.selection?.mask)) | overlay \(overlay) hover \(editor.hover.map { "\($0)" } ?? "none")"
                + " | seeds read \(editor.pinSeeds.readCount) found \(editor.pinSeeds.points.count)"
                + (items.isEmpty ? "" : " | " + items.joined(separator: " | "))
        }
        /// Mask N's pin, in the area.
        func pinPoint(_ word: String?) -> CGPoint? {
            guard let word, let n = Int(word), model.masks(for: frame).indices.contains(n) else { return nil }
            let id = model.masks(for: frame)[n].id
            return editor.pins(on: frame, geometry: geometry).first { $0.id == id }?.point
        }
        func windowPoint(_ p: CGPoint) -> NSPoint { canvas.convert(NSPoint(x: p.x, y: p.y), to: nil) }
        let flags = modifiers(values)
        switch (values[0], values.count > 1 ? values[1] : "") {
        case ("pins", _):
            reply("mask", line())
        case ("pin", "hover"):
            let target: CGPoint?
            if values.count > 2, values[2] == "off" { target = nil }
            else if values.count > 4, values[2] == "at", let x = Double(values[3]), let y = Double(values[4]) { target = CGPoint(x: x, y: y) }
            else if let found = pinPoint(values.count > 2 ? values[2] : nil) { target = found }
            else { reply("error", "mask pin hover N|at X Y|off"); return }
            // Off: a point beyond the area's corner, which no tracking area of the canvas holds.
            let moved = target ?? CGPoint(x: -40, y: -40)
            postMouse(.mouseMoved, at: windowPoint(moved), in: window, flags: flags)
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                let reached = target.map { t in canvas.pointerLocation.map { hypot($0.x - t.x, $0.y - t.y) < 0.5 } ?? false }
                    ?? (canvas.pointerLocation == nil || !editor.isPointerInArea)
                if !reached { canvas.pointerMoved(to: target) }
                try? await Task.sleep(for: .milliseconds(150))
                reply("mask", "hover \(target.map(point) ?? "off") \(reached ? "by the posted move" : "given to the canvas: the posted move did not reach it") | \(line())")
            }
        case ("pin", "press"):
            guard let at = pinPoint(values.count > 2 ? values[2] : nil) else { reply("error", "mask pin press N [opt]"); return }
            Task {
                postMouse(.leftMouseDown, at: windowPoint(at), in: window, flags: flags)
                try? await Task.sleep(for: .milliseconds(30))
                postMouse(.leftMouseUp, at: windowPoint(at), in: window, flags: flags)
                try? await Task.sleep(for: .milliseconds(400))
                reply("mask", "pressed pin \(values[2]) at \(point(at)) | \(maskRead(model)) || \(line())")
            }
        case ("pin", "drag"):
            guard let at = pinPoint(values.count > 2 ? values[2] : nil), values.count > 3, let dx = Double(values[3]) else {
                reply("error", "mask pin drag N DX [opt] [hold S]"); return
            }
            let undoBefore = model.manualUndoManager?.undoActionName ?? "none"
            Task {
                postMouse(.leftMouseDown, at: windowPoint(at), in: window, flags: flags)
                try? await Task.sleep(for: .milliseconds(20))
                var halfway = ""
                for step in 1...10 {
                    postMouse(.leftMouseDragged, at: windowPoint(CGPoint(x: at.x + dx * Double(step) / 10, y: at.y)), in: window, flags: flags)
                    try? await Task.sleep(for: .milliseconds(16))
                    if step == 5 {
                        let id = editor.selection?.mask, edit = id.flatMap { model.mask($0, for: frame) }
                        let printed = id.flatMap { id in model.printedEdit(for: frame)?.adjustments.masks.masks.first { $0.id == id } }
                        halfway = "halfway: edit amount \(edit.map { "\($0.amount)" } ?? "none") print \(printed.map { "\($0.amount)" } ?? "none")"
                            + " adjusting \(editor.isAdjusting) tag \(editor.pinAmountTag(on: frame, geometry: canvas.geometry?() ?? geometry)?.text ?? "none")"
                            + " overlay \(model.overlayComponents(for: frame) != nil) | \(line())"
                    }
                }
                let hold = values.firstIndex(of: "hold").flatMap { values.count > $0 + 1 ? Double(values[$0 + 1]) : nil } ?? 0
                if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
                postMouse(.leftMouseUp, at: windowPoint(CGPoint(x: at.x + dx, y: at.y)), in: window, flags: flags)
                try? await Task.sleep(for: .milliseconds(400))
                reply("mask", "dragged pin \(values[2]) by \(dx)\(values.contains("opt") ? " with Option" : ""): \(halfway) || undo before \(undoBefore)"
                      + " after \(model.manualUndoManager?.undoActionName ?? "none") | \(maskRead(model)) || \(line())")
            }
        case ("pin", "drag-measure"):
            guard let at = pinPoint(values.count > 2 ? values[2] : nil), let view = window.contentView else {
                reply("error", "mask pin drag-measure N [SECONDS] [PT/S] [SPAN]"); return
            }
            let seconds = values.count > 3 ? Double(values[3]) ?? 8 : 8, speed = values.count > 4 ? Double(values[4]) ?? 150 : 150
            let span = values.count > 5 ? Double(values[5]) ?? 136 : 136
            Task {
                let clock = FrameClock(view: view)
                defer { clock.stop() }
                reply("mask", await pinDragMeasure(model, frame: frame, from: at, seconds: seconds, speed: speed, span: span, clock: clock,
                                                   window: window, canvas: canvas))
            }
        case ("pins-measure", _):
            guard let view = window.contentView else { reply("error", "no window"); return }
            let seconds = values.count > 1 ? Double(values[1]) ?? 10 : 10
            Task {
                let clock = FrameClock(view: view)
                defer { clock.stop() }
                @MainActor func run() async -> String {
                    var stamps: [CFTimeInterval] = []
                    let began = CACurrentMediaTime(), cpu = mainThreadCPU()
                    var tick = await clock.next()
                    while tick.now - began < seconds { stamps.append(tick.timestamp); tick = await clock.next() }
                    return refreshes(stamps, window: window) + String(format: ", main thread CPU %.0f ms", (mainThreadCPU() - cpu) * 1000)
                }
                // The pointer still on the picture's middle, away from any pin's reach unless one is there.
                let middle = geometry.center
                canvas.pointerMoved(to: middle)
                for _ in 0..<30 { _ = await clock.next() }
                let up = MaskPinVisibility.isShown(editor.pinInputs(on: frame)), shown = editor.shownPins(on: frame, geometry: geometry).count
                let with = await run()
                canvas.pointerMoved(to: nil)
                for _ in 0..<30 { _ = await clock.next() }
                let without = await run()
                reply("mask", String(format: "pins-measure %.0f s: pins up %@ (%d drawn): ", seconds, "\(up)", shown) + with + " || pins down: " + without)
            }
        default:
            reply("error", "mask pins | pin hover N|at X Y|off | pin press N [opt] | pin drag N DX [opt] | pin drag-measure N [S] [PT/S] [SPAN] | pins-measure [S]")
        }
    }

    /// An Option-drag on a pin measured as `sliderDragMeasure` measures the Amount slider's: the press on the pin with Option held, then
    /// one drag event in each display frame, to and fro over `span` points round the pin at `speed` points a second, for `seconds`, then the
    /// release. Through the canvas, the editor and the row's own calls (`RollModel.moveMaskAmount`), so the print path is the slider's.
    private static func pinDragMeasure(_ model: RollModel, frame: Frame, from start: CGPoint, seconds: Double, speed: Double, span: Double,
                                       clock: FrameClock, window: NSWindow, canvas: MaskCanvasView) async -> String {
        func windowPoint(_ x: CGFloat) -> NSPoint { canvas.convert(NSPoint(x: x, y: start.y), to: nil) }
        let low = start.x - span / 2, editor = model.maskEditor
        let amountBefore = editor.selection.flatMap { model.mask($0.mask, for: frame) }?.amount
        let since = CACurrentMediaTime()
        var stamps: [CFTimeInterval] = []
        _ = await clock.next()
        let cpuBefore = mainThreadCPU()
        postMouse(.leftMouseDown, at: windowPoint(start.x), in: window, flags: .option)
        let began = CACurrentMediaTime()
        var tick = await clock.next()
        var printOnly = true
        while tick.now - began < seconds {
            stamps.append(tick.timestamp)
            // A triangle wave from the pin, rightward first, so the drag starts where the press did.
            let travelled = span / 2 + (tick.now - began) * speed, phase = travelled.truncatingRemainder(dividingBy: 2 * span)
            let x = low + (phase <= span ? phase : 2 * span - phase)
            postMouse(.leftMouseDragged, at: windowPoint(x), in: window, flags: .option)
            if let id = editor.selection?.mask, model.mask(id, for: frame)?.amount != amountBefore { printOnly = false }
            tick = await clock.next()
        }
        postMouse(.leftMouseUp, at: windowPoint(start.x), in: window, flags: .option)
        let cpu = mainThreadCPU() - cpuBefore, elapsed = CACurrentMediaTime() - began
        for _ in 0..<30 { _ = await clock.next() }
        let films = FrameShowProbe.shown.filter { $0.frame == frame.url && $0.time >= since }
        let renders = model.films?.renderTimes(since: since) ?? []
        let after = editor.selection.flatMap { model.mask($0.mask, for: frame) }?.amount
        return String(format: "pin drag-measure %.1f s at %.0f pt/s over %.0f pt, zoom %.2f, %@px: ", seconds, speed, span, model.frameZoom.scale,
                      "\(model.frameLayout?.pixels(frame) ?? 0)")
            + refreshes(stamps, window: window)
            + String(format: " | films %d, amount %@ to %@, the edit unchanged until the release %@, undo %@ | main thread CPU %.0f ms, %.1f%% of the drag",
                     films.count, amountBefore.map { "\($0)" } ?? "none", after.map { "\($0)" } ?? "none", "\(printOnly)",
                     model.manualUndoManager?.undoActionName ?? "none", cpu * 1000, 100 * cpu / max(elapsed, 1e-3))
            + filmTimes(films) + renderTimes(renders)
            + (films.first { $0.time >= began }.map { String(format: " | press to print %.0f ms", ($0.time - began) * 1000) } ?? " | press to print none")
    }

    /// A slider dragged as a hand would, measured as a handle's drag is (`dragMeasure`): its knob pressed, then one drag event in each
    /// display frame, to and fro over the middle 80 % of its track at `speed` points a second, for `seconds`, then released. The
    /// slider's own tracking loop takes the events, as it takes a real drag's; each step goes through the row's binding, as a hand's does.
    private static func sliderDragMeasure(_ model: RollModel, frame: Frame, slider: AdjustmentSliderControl, seconds: Double, speed: Double,
                                          clock: FrameClock, window: NSWindow) async -> String {
        guard let cell = slider.cell as? NSSliderCell else { return "no slider cell" }
        let track = cell.barRect(flipped: slider.isFlipped), knob = cell.knobRect(flipped: slider.isFlipped)
        func windowPoint(_ x: CGFloat) -> NSPoint { slider.convert(NSPoint(x: x, y: knob.midY), to: nil) }
        let low = track.minX + 0.1 * track.width, high = track.maxX - 0.1 * track.width, span = max(1, high - low)
        // The press must land on the slider, not on whatever covers it or a list scrolled over it.
        if let root = window.contentView?.superview ?? window.contentView {
            let hit = root.hitTest(root.convert(windowPoint(knob.midX), from: nil))
            guard hit === slider || hit?.isDescendant(of: slider) == true else {
                return "the knob of \(slider.spec.title) is under \(hit.map { String(describing: type(of: $0)) } ?? "nothing")"
            }
        }
        let valueBefore = slider.doubleValue, since = CACurrentMediaTime()
        var stamps: [CFTimeInterval] = []
        _ = await clock.next()
        let cpuBefore = mainThreadCPU()
        postMouse(.leftMouseDown, at: windowPoint(knob.midX), in: window)
        let began = CACurrentMediaTime()
        var tick = await clock.next()
        while tick.now - began < seconds {
            stamps.append(tick.timestamp)
            // A triangle wave from the knob's place, so the drag starts where the press did.
            let travelled = (knob.midX - low) + (tick.now - began) * speed, phase = travelled.truncatingRemainder(dividingBy: 2 * span)
            let x = low + (phase <= span ? phase : 2 * span - phase)
            postMouse(.leftMouseDragged, at: windowPoint(x), in: window)
            tick = await clock.next()
        }
        postMouse(.leftMouseUp, at: windowPoint(knob.midX), in: window)
        // The drag's own events end here; the tracking loop takes the release on its next turn.
        let cpu = mainThreadCPU() - cpuBefore, elapsed = CACurrentMediaTime() - began
        for _ in 0..<30 { _ = await clock.next() }
        let films = FrameShowProbe.shown.filter { $0.frame == frame.url && $0.time >= since }
        let renders = model.films?.renderTimes(since: since) ?? []
        return String(format: "slider-drag %@ %.1f s at %.0f pt/s over %.0f pt, zoom %.2f, %@px: ", slider.spec.title, seconds, speed, span,
                      model.frameZoom.scale, "\(model.frameLayout?.pixels(frame) ?? 0)")
            + refreshes(stamps, window: window) + String(format: " | films %d, value %.2f to %.2f | main thread CPU %.0f ms, %.1f%% of the drag",
                                                         films.count, valueBefore, slider.doubleValue, cpu * 1000, 100 * cpu / max(elapsed, 1e-3))
            + filmTimes(films) + renderTimes(renders)
            + (films.first { $0.time >= began }.map { String(format: " | press to print %.0f ms", ($0.time - began) * 1000) } ?? " | press to print none")
    }

    /// The films a drag put up: their longer sides, how many from a refined decode, and their times from request to screen.
    private static func filmTimes(_ films: [(frame: URL, refined: Bool, time: CFTimeInterval, side: Int, seconds: CFTimeInterval)]) -> String {
        guard !films.isEmpty else { return " | films none" }
        let sides = Dictionary(grouping: films, by: \.side).map { "\($0.value.count)x\($0.key)" }.sorted().joined(separator: " ")
        let times = films.map { $0.seconds * 1000 }.sorted()
        return String(format: " | films %@, %d refined, request to screen median %.0f p95 %.0f ms", sides, films.filter(\.refined).count,
                      times[times.count / 2], times[min(times.count - 1, Int(Double(times.count) * 0.95))])
    }

    /// The renders a drag set off, every view's: how many, and their GPU time and whole time to a picture, median and 95th percentile.
    private static func renderTimes(_ renders: [(gpu: Double, whole: Double)]) -> String {
        guard !renders.isEmpty else { return " | renders none" }
        func cent(_ values: [Double], _ p: Double) -> Double { let s = values.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] * 1000 }
        let gpu = renders.map(\.gpu), whole = renders.map(\.whole)
        return String(format: " | renders %d, GPU median %.1f p95 %.1f ms, whole median %.1f p95 %.1f ms", renders.count, cent(gpu, 0.5),
                      cent(gpu, 0.95), cent(whole, 0.5), cent(whole, 0.95))
    }

    /// The display link's ticks over a drag, counted as P0-S2 counted them: the refreshes the display gave less the callbacks that came
    /// (refreshes lost), the median and longest interval, and the hitch time, each interval's excess over one refresh.
    private static func refreshes(_ stamps: [CFTimeInterval], window: NSWindow) -> String {
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        let refresh = 1000.0 / Double(max(1, window.screen?.maximumFramesPerSecond ?? 120))
        let sorted = intervals.sorted(), median = sorted.isEmpty ? refresh : sorted[sorted.count / 2]
        let span = (stamps.last ?? 0) - (stamps.first ?? 0)
        let lost = max(0, Int((span * 1000 / refresh).rounded()) - intervals.count)
        let hitch = intervals.reduce(0.0) { $0 + max(0, $1 - refresh) }
        return String(format: "%d ticks of %d refreshes, interval median %.2f ms max %.2f ms, refreshes lost %d (%.1f%%), hitch %.0f ms",
                      stamps.count, Int((span * 1000 / refresh).rounded()) + 1, median, intervals.max() ?? 0, lost,
                      100 * Double(lost) / max(1, span * 1000 / refresh), hitch)
    }

    /// A handle dragged as a hand would, measured as P0-S2 measured its strokes: from the handle's area point round a circle of 60
    /// points at `speed`, one drag event posted in each display frame (the window server coalesces a real drag to one a refresh), for
    /// `seconds`, then released. The display link's own timestamps give the refreshes lost (intervals past one and a half of the
    /// median, each counting the refreshes it spanned less one), the longest interval and the hitch time (each interval's excess over
    /// the median); with them the edit's flushes, the films put up for the frame meanwhile and the zoom.
    private static func dragMeasure(_ model: RollModel, frame: Frame, from start: CGPoint, seconds: Double, speed: Double,
                                    clock: FrameClock, window: NSWindow) async -> String {
        guard let canvas = model.maskEditor.canvas else { return "no canvas" }
        func windowPoint(_ point: CGPoint) -> NSPoint { canvas.convert(NSPoint(x: point.x, y: point.y), to: nil) }
        let radius = 60.0, flushesBefore = model.maskEditor.flushCount
        // Counted by time: the probe keeps the last 256 films only, so a count before and after stops moving in a long session.
        let since = CACurrentMediaTime()
        var stamps: [CFTimeInterval] = []
        _ = await clock.next()
        let cpuBefore = mainThreadCPU()
        postMouse(.leftMouseDown, at: windowPoint(start), in: window)
        let began = CACurrentMediaTime()
        var tick = await clock.next()
        while tick.now - began < seconds {
            stamps.append(tick.timestamp)
            // Out from the handle to the circle over its first quarter turn, then round it.
            let t = tick.now - began, angle = t * speed / radius, reach = min(1, t * speed / radius / (Double.pi / 2))
            let point = CGPoint(x: start.x + radius * reach * sin(angle), y: start.y - radius * reach * (1 - cos(angle)) / 2)
            postMouse(.leftMouseDragged, at: windowPoint(point), in: window)
            tick = await clock.next()
        }
        postMouse(.leftMouseUp, at: windowPoint(start), in: window)
        let cpu = mainThreadCPU() - cpuBefore, elapsed = CACurrentMediaTime() - began
        // And the release's own refreshes: where a tab's change waits for the stroke to land.
        var after: [CFTimeInterval] = [tick.timestamp]
        for _ in 0..<30 { after.append(await clock.next().timestamp) }
        let released = zip(after.dropFirst(), after).map { ($0 - $1) * 1000 }
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        // As P0-S2 counted: the refreshes the display gave over the drag less the callbacks that came, and each interval's excess over
        // one refresh.
        let refresh = 1000.0 / Double(max(1, window.screen?.maximumFramesPerSecond ?? 120))
        let sorted = intervals.sorted(), median = sorted.isEmpty ? refresh : sorted[sorted.count / 2]
        let span = (stamps.last ?? 0) - (stamps.first ?? 0)
        let lost = max(0, Int((span * 1000 / refresh).rounded()) - intervals.count)
        let hitch = intervals.reduce(0.0) { $0 + max(0, $1 - refresh) }
        let shownFilms = FrameShowProbe.shown.filter { $0.frame == frame.url && $0.time >= since }, films = shownFilms.count
        let renders = model.films?.renderTimes(since: since) ?? []
        // The press's own refreshes: the first intervals after it, where a stroke that makes a mask hitched (G).
        let first = intervals.prefix(6).map { String(format: "%.1f", $0) }.joined(separator: " ")
        let brush = String(format: " | main thread CPU %.0f ms, %.1f%% of the drag | first intervals %@ ms | after the release max %.1f ms",
                           cpu * 1000, 100 * cpu / max(elapsed, 1e-3), first, released.max() ?? 0)
            + filmTimes(shownFilms) + renderTimes(renders) + (model.maskEditor.tool == .brush ? " | brush \(model.maskEditor.brush.lastReport)" : "")
        return String(format: "drag-measure %.1f s at %.0f pt/s, zoom %.2f, %@px: %d ticks of %d refreshes, interval median %.2f ms max %.2f ms,"
                      + " refreshes lost %d (%.1f%%), hitch %.0f ms | flushes %d, films %d, print %.0f ms | %@",
                      seconds, speed, model.frameZoom.scale, "\(model.frameLayout?.pixels(frame) ?? 0)", stamps.count,
                      Int((span * 1000 / refresh).rounded()) + 1, median, intervals.max() ?? 0, lost,
                      100 * Double(lost) / max(1, span * 1000 / refresh), hitch, model.maskEditor.flushCount - flushesBefore, films,
                      model.maskEditor.printSeconds * 1000, maskState(model)) + brush
    }

    /// The overlay's coverage next to the picture's left, right and top edges, 0 to 255: the mean of its first four lines and of lines 16
    /// to 19 in, over the lines that are covered (at least 250) 24 lines in. Where a selection's seed is low at the frame's edge (a pale
    /// strip), the first mean falls under the second.
    private static func overlayEdges(_ image: CGImage) -> String {
        let w = image.width, h = image.height
        guard w > 40, h > 40, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data else { return "edges none" }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h), row = context.bytesPerRow
        // The context's row 0 is the image's top.
        func at(_ x: Int, _ y: Int) -> Double { Double(bytes[y * row + x]) }
        func side(_ name: String, _ count: Int, _ value: (Int, Int) -> Double) -> String {
            let lines = (0..<count).filter { value($0, 24) >= 250 }
            guard !lines.isEmpty else { return "\(name) none" }
            func mean(_ ds: Range<Int>) -> Double { lines.reduce(0) { total, i in total + ds.reduce(0) { $0 + value(i, $1) } / Double(ds.count) } / Double(lines.count) }
            return String(format: "%@ %.0f/%.0f over %d", name, mean(0..<4), mean(16..<20), lines.count)
        }
        return "edges " + [side("left", h) { at($1, $0) }, side("right", h) { at(w - 1 - $1, $0) }, side("top", w) { at($0, $1) }].joined(separator: ", ")
    }

    /// The main thread's own CPU time so far, user and system: what its work cost, however much else ran on the Mac meanwhile, where
    /// refreshes lost also count the time it waited for a core. Called on the main thread.
    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }

    /// The modifiers a `mask press` or `mask drag` names: cmd, opt, shift.
    private static func modifiers(_ values: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if values.contains("cmd") { flags.insert(.command) }
        if values.contains("opt") { flags.insert(.option) }
        if values.contains("shift") { flags.insert(.shift) }
        return flags
    }

    /// The brush: its settings, what it paints, whether it waits for its first stroke, its ring, and its last stroke's report.
    private static func brushState(_ model: RollModel) -> String {
        let editor = model.maskEditor, brush = editor.brush, settings = brush.settings
        let target = model.shownFrame.flatMap { brush.target(on: $0, model: model) }
        func index(of mask: UUID) -> Int? { model.shownFrame.flatMap { model.masks(for: $0).firstIndex { $0.id == mask } } }
        let pending = model.shownFrame.flatMap(model.brushPendingRow(on:)).map { "\($0)" } ?? "none"
        let ring = editor.canvas.map { canvas in
            canvas.ring.isShown ? String(format: "ring at %.1f,%.1f r %.1f/%.1f", canvas.ring.position.x, canvas.ring.position.y,
                                         canvas.ring.radii?.outer ?? 0, canvas.ring.radii?.inner ?? 0) : "ring hidden"
        } ?? "no canvas"
        return String(format: "brush size %.1f feather %.0f flow %.0f erase %@ follow %@", settings.size, settings.feather, settings.flow,
                      settings.erase ? "on" : "off", settings.followEdges ? "on" : "off")
            + " | target \(target.map { target in "\(index(of: target.mask) ?? -1):\(target.component ?? -1)" } ?? "none")"
            + " pending \(pending) painting \(brush.isPainting) | \(ring) | strokes \(brush.counts.ended) cancelled \(brush.counts.cancelled)"
            + " refused \(brush.counts.refused)\(brush.lastRefusal.map { " (\($0))" } ?? "") | undo \(model.manualUndoManager?.undoActionName ?? "none")"
            + " | last \(brush.lastReport) | overlay live \(editor.overlay.isLive) published \(editor.overlay.publishCount)"
    }

    /// The selected mask's shape in full, and the edit's compiler with the gate on it.
    private static func maskRead(_ model: RollModel) -> String {
        guard let frame = model.shownFrame else { return "no frame open" }
        let edit = model.manualEdits[frame.url]
        var line = "compiler \(edit?.curveVersion ?? "none") gate \(model.maskCompilerGate(for: frame)) canAdd \(model.canAddMask(frame))"
            + " masks \(model.masks(for: frame).count) undo \(model.manualUndoManager?.undoActionName ?? "")"
        guard let selection = model.maskEditor.selection, let mask = model.selectedMask(for: frame) else { return line + " | none selected" }
        line += " | \(model.maskName(mask.id, for: frame)) component \(selection.component.map(String.init) ?? "none") \(mask.isEnabled ? "on" : "off") amount \(mask.amount) \(MaskSummary.line(for: mask))"
        for component in mask.components {
            line += " | \(component.operation.rawValue)\(component.invert ? " inverted" : ""): "
            switch component.shape {
            case .linear(let g): line += "linear full \(g.full.x),\(g.full.y) zero \(g.zero.x),\(g.zero.y)"
            case .radial(let g): line += "radial centre \(g.center.x),\(g.center.y) axes \(g.semiAxisA),\(g.semiAxisB) angle \(g.angle) feather \(g.feather)"
            case .brush: line += MaskSummary.title(of: component.shape)
            case .smart(let selection): line += "\(MaskSummary.title(of: component.shape)) feather \(selection.feather)"
            }
        }
        return line
    }

    /// The masks tool's state, one line of JSON (the unified log cuts a long one).
    private static func maskState(_ model: RollModel) -> String {
        let editor = model.maskEditor
        var state: [String: Any] = [
            "tool": editor.tool?.rawValue ?? "none", "tab": model.adjustTab.rawValue, "inspector": model.isAdjustmentsShown,
            "open": model.isFrameOpen, "canvas": editor.canvas != nil, "over": MaskCanvasView.pointerOverArmedCanvas,
            "presses": editor.canvasCounts.press, "drags": editor.canvasCounts.drag, "releases": editor.canvasCounts.release,
            "deletes": editor.deletePresses, "stock": model.stockIndex, "scale": (model.frameZoom.scale * 1000).rounded() / 1000,
            "clipping": model.lightClipping.map { "\($0)" } ?? "none",
            "split": model.isSplitComparing ? (model.splitPosition * 1000).rounded() / 1000 : -1,
            "masks": model.shownFrame.map { model.masks(for: $0).count } ?? 0, "selected": editor.selection != nil,
            "painting": editor.brush.isPainting,
        ]
        if let event = editor.lastCanvasEvent {
            state["last"] = String(format: "%.4f,%.4f", event.fractions.x, event.fractions.y)
        }
        if let geometry = editor.canvas?.geometry?() {
            state["picture"] = "\(geometry.picture.minX),\(geometry.picture.minY) \(geometry.picture.width)x\(geometry.picture.height)"
        }
        let data = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func state(_ model: RollModel) -> String {
        var phase = "idle"
        switch model.developPhase {
        case .idle: phase = "idle"
        case .developing(let progress): phase = "developing \(progress.processed)/\(progress.total)"
        case .done: phase = "done"
        }
        // The phase first, and the frames failed for good, whether the roll has settled and the
        // decision it settled on last (its revision's first 12 hex digits) beside it, which the
        // measuring scripts wait on: the log truncates a long line.
        let object: [String: Any] = [
            "0phase": phase,
            "0failed": model.measurementFailures.count,
            "0settled": model.isBalanced,
            "0revision": model.autoDecision.map { String($0.revision.prefix(12)) } ?? NSNull(),
            "roll": model.roll?.name ?? NSNull(),
            "folder": model.roll?.folder.path ?? NSNull(),
            "frames": model.roll?.frames.count ?? 0,
            "stock": model.stockName ?? NSNull(),
            "phase": phase,
            "destination": model.chosenDevelopFolder?.destination?.path ?? NSNull(),
            "page": "\(model.workspacePage)",
            "cards": model.cards.map { "\($0.name) \($0.rawCount.map(String.init) ?? "?") \($0.volume.path)" },
            "recents": model.recents.map(\.path),
            "message": model.message ?? NSNull(),
            "failures": model.lastDevelop?.failures.count ?? 0,
            "manualEdited": model.shownFrame.map { model.hasManualAdjustments($0) } ?? false,
            "manualReady": model.shownFrame.map { model.canAdjust($0) } ?? false,
            "manualStart": model.shownFrame.map { model.startingPoint(for: $0).rawValue } ?? NSNull(),
            "manualSave": model.manualSaveMessage ?? "Saved",
            "manualIssue": model.shownFrame.flatMap { model.manualIssue(for: $0) } ?? "none",
            "editRevision": model.editRevision,
            "footprint": DevelopBudget.footprint(),
            "renderCacheBytes": model.films?.renderedCacheBytes ?? 0,
            "firstFailure": model.lastDevelop?.failures.first.map { "\($0.fileName): \($0.reason)" } ?? NSNull(),
            "developed": model.lastDevelop?.files.count ?? 0,
            "decodes": model.films?.decodeCount ?? 0,
            "diskHits": model.films?.diskHitCount ?? 0,
            // Frames measured: every frame has its part when they and "0failed" add up to "frames".
            "analyzed": model.analyses.count,
            "clusters": model.roll.map { RollSmoothing.clusters($0.frames, analyses: model.analyses).map(\.count) } ?? [],
            "windows": NSApp.windows.filter(\.isVisible).map { "\($0.title) \(Int($0.frame.width))x\(Int($0.frame.height))" },
            "sheets": NSApp.windows.filter { $0.attachedSheet != nil }.map(\.title),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The roll's flags and filter, short enough for one line of the log: the frames flagged and
    /// shown (names up to twelve), the selection and the frame open by index from 0 and name, the
    /// heading's line, whether Develop can start, and whether the flags are saved.
    private static func flags(_ model: RollModel) -> String {
        let shown = model.shownFrames, selected = model.selectedFrame
        let object: [String: Any] = [
            "0filter": model.flagFilter.rawValue,
            "0flagged": model.flaggedCount,
            "0shown": shown.count,
            "frames": model.roll?.frames.count ?? 0,
            "shownNames": shown.prefix(12).map(\.name),
            "flaggedNames": (model.roll?.frames.filter(model.isFlagged) ?? []).prefix(12).map(\.name),
            "selection": selected.map { "\($0.id) \($0.name)" } ?? NSNull(),
            "selectionFlagged": selected.map(model.isFlagged) ?? false,
            "open": model.shownFrame.map { "\($0.id) \($0.name)" } ?? NSNull(),
            "subtitle": RollHeading.subtitle(model),
            "canDevelop": model.canDevelop,
            "unsaved": model.areFlagsUnsaved,
            "kept": model.otherFlags.count,
            "message": model.message ?? NSNull(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The frames selected on the sheet and whether they can leave the roll, short enough for one line of the log: the
    /// lead and the frames selected by index from 0 and name, the heading's line, the rolls Move to Roll offers, why
    /// the frames cannot leave, and the notice's and the message's lines.
    private static func selection(_ model: RollModel) -> String {
        let frames = model.selectedFrames
        let object: [String: Any] = [
            "0frames": model.roll?.frames.count ?? 0,
            "0lead": model.selectedFrame.map { "\($0.id) \($0.name)" } ?? NSNull(),
            "0selected": frames.prefix(16).map { "\($0.id) \($0.name)" },
            "0count": frames.count,
            "subtitle": RollHeading.subtitle(model),
            "canChange": model.canChangeFrames(frames),
            "why": model.changeFramesHelp ?? NSNull(),
            "moveTo": model.moveTargets.map(\.name),
            "menuBar": ["several": model.menus.isSeveralSelected, "canChange": model.menus.canChangeFrames],
            "notice": model.clipboardNotice?.text ?? NSNull(),
            "details": model.clipboardNotice?.plainDetails ?? [],
            "message": model.message ?? NSNull(),
            "page": "\(model.workspacePage)",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The Develop page: its button, its status' words, the folder a develop goes to and how many frames
    /// carry each mark, short enough for one line of the log.
    private static func developPage(_ model: RollModel) -> String {
        let marks = model.developMarks
        let status = model.developStatus
        let object: [String: Any] = [
            "page": "\(model.workspacePage)",
            "button": model.developPrimary.title,
            "enabled": model.canPerformDevelopPrimary,
            "title": status.map(DevelopStatusText.title) ?? NSNull(),
            "counts": status.map(DevelopStatusText.counts) ?? NSNull(),
            "summary": DevelopStatusText.summary(model, frames: model.framesToDevelop()),
            "folder": model.developDestination?.path ?? NSNull(),
            "developed": marks.values.count { $0 == .developed },
            "failed": marks.values.count { $0 == .failed },
            "ring": model.developFraction ?? NSNull(),
            "attention": model.developWantsAttention,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The quick develop dialog as it stands, or that none is up.
    private static func quickDevelop(_ model: RollModel) -> String {
        guard let asked = model.quickDevelop else { return "none" }
        let frames = model.quickDevelopFrames
        let object: [String: Any] = [
            "title": QuickDevelopSheet.title(frames),
            "frames": frames.map(\.name),
            "folder": asked.folder.destination?.path ?? NSNull(),
            // As the dialog shows them: the stock its frames share, one frame's own grain.
            "output": DevelopStatusText.outputSummary(asked.output, stock: model.stockNames[safe: model.sharedStockIndex(of: frames)]),
            "quality": asked.output.quality,
            "grain": (model.quickDevelopGrain(for: frames)?.own ?? asked.output.grain).title,
            "enabled": model.canConfirmQuickDevelop,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The issues bar and what it is made from, short enough for one line of the log.
    private static func issues(_ model: RollModel) -> String {
        var phase = "idle"
        switch model.developPhase {
        case .idle: phase = "idle"
        case .developing(let progress): phase = "developing \(progress.processed)/\(progress.total): \(progress.label)"
        case .done: phase = "done"
        }
        let object: [String: Any] = [
            "0phase": phase,
            "roll": model.roll?.name ?? NSNull(),
            "line": model.issuesLine ?? NSNull(),
            "shown": model.issuesLine != nil && !model.areIssuesDismissed,
            "details": model.isIssueDetailsShown,
            "counts": model.lastDevelop?.countsLine ?? NSNull(),
            "failed": model.lastDevelop?.failures.map { "\($0.fileName): \($0.reason)" } ?? [],
            "unreadable": model.roll?.unreadable.map(\.lastPathComponent) ?? [],
            "heading": RollHeading.title(model) ?? NSNull(),
            "subtitle": RollHeading.subtitle(model),
            "message": model.message ?? NSNull(),
            "destination": model.chosenDevelopFolder?.destination?.path ?? NSNull(),
            "page": "\(model.workspacePage)",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Every menu's items, or only the top-level menu titled `only`, since the log truncates a
    /// long line.
    private static func menus(_ only: String = "") -> String {
        var lines: [String] = []
        func walk(_ menu: NSMenu, _ prefix: String) {
            for item in menu.items where !item.isSeparatorItem {
                let path = prefix.isEmpty ? item.title : "\(prefix)>\(item.title)"
                if let submenu = item.submenu {
                    prepare(submenu)
                    walk(submenu, path)
                } else {
                    let help = item.toolTip.flatMap { $0.isEmpty ? nil : " {\($0)}" } ?? ""
                    lines.append("\(path)\(item.isEnabled ? "" : " [disabled]")\(item.isHidden ? " [hidden]" : "")\(help)")
                }
            }
        }
        if let main = NSApp.mainMenu {
            if only.isEmpty {
                walk(main, "")
            } else if let item = main.items.first(where: { $0.title == only }), let submenu = item.submenu {
                prepare(submenu)
                walk(submenu, only)
            }
        }
        return lines.joined(separator: " | ")
    }

    private static func perform(path: String) -> Bool {
        var menu = NSApp.mainMenu
        let titles = path.split(separator: ">").map(String.init)
        for (index, title) in titles.enumerated() {
            guard let current = menu else { return false }
            prepare(current)
            guard let itemIndex = current.items.firstIndex(where: { $0.title == title }) else { return false }
            let item = current.items[itemIndex]
            if index == titles.count - 1 {
                guard item.isEnabled else { return false }
                current.performActionForItem(at: itemIndex)
                return true
            }
            menu = item.submenu
        }
        return false
    }

    /// What AppKit does as a menu opens, which is when SwiftUI brings its items up to date.
    private static func prepare(_ menu: NSMenu) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.delegate?.menuWillOpen?(menu)
        menu.update()
        menu.delegate?.menuDidClose?(menu)
    }

    /// The main window's accessibility elements labelled `label`, as VoiceOver sees them.
    private static func accessibility(_ label: String) -> [String] {
        guard let root = mainWindow() else { return ["no window"] }
        // Read by selector: SwiftUI's elements are private classes, and the protocol's members
        // are ambiguous to Swift.
        func value(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        var found: [String] = []
        func walk(_ element: Any, depth: Int) {
            guard depth < 60, let object = element as? NSObject else { return }
            if label == "*" {
                // Every element with a role, for finding what an element calls itself.
                let role = value(object, "accessibilityRole") as? String ?? "?"
                let name = [value(object, "accessibilityLabel"), value(object, "accessibilityTitle")]
                    .compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " / ")
                let shown = value(object, "accessibilityValue").map { " = \($0)" } ?? ""
                let help = (value(object, "accessibilityHelp") as? String).map { " {\($0)}" } ?? ""
                if role != "?" { found.append("\(depth) \(role) \(name)\(shown)\(help)") }
            } else if value(object, "accessibilityLabel") as? String == label || value(object, "accessibilityTitle") as? String == label {
                let role = value(object, "accessibilityRole") as? String ?? "?"
                let shown = value(object, "accessibilityValue").map { " value \($0)" } ?? ""
                // A Bool, so through key-value coding rather than `perform`.
                let enabled = object.responds(to: NSSelectorFromString("isAccessibilityEnabled"))
                    ? (object.value(forKey: "accessibilityEnabled") as? Bool).map { " enabled \($0)" } ?? "" : ""
                found.append("\(role) \(label):\(shown)\(enabled) help \(value(object, "accessibilityHelp") as? String ?? "none")")
            }
            for child in value(object, "accessibilityChildren") as? [Any] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return found.isEmpty ? ["nothing labelled \(label)"] : found
    }

    /// Settings change to visible film: each exposure change is made just after a display
    /// frame starts, as a slider drag's are, all in one gesture. A change is counted visible in
    /// the first frame whose display link fires after the frame view put up a film rendered
    /// with exactly those settings; that frame's presentation time bounds it from above, by at
    /// most one refresh. Undone afterwards as the one gesture it is.
    private static func settingsLatency(_ model: RollModel, frame: Frame, count: Int, clock: FrameClock, slider: ManualAdjustments.Slider) async -> String {
        guard let window = mainWindow(), let layout = model.frameLayout else { return "no window" }
        let stock = model.stockIndex(for: frame), start = model.manualAdjustments(for: frame)
        var totals: [Double] = [], renders: [Double] = [], refresh: [Double] = []
        // As the row's gesture makes them: to the print, and to the edit at its end (`RollModel.moveLight`).
        model.beginLightAdjusting(for: frame)
        defer { model.endLightAdjusting(for: frame); model.manualUndoManager?.undo() }
        for index in 0..<count {
            let value: Float
            switch slider {
            case .lens(let control):
                let low = Int((try? start.lens.setting(control, to: control.range.lowerBound))?.value(for: control) ?? control.range.lowerBound)
                let high = Int((try? start.lens.setting(control, to: control.range.upperBound))?.value(for: control) ?? control.range.upperBound)
                value = Float(low + (Int(start.value(for: slider)) - low + index + 1) % (high - low + 1))
            case .light, .presence: value = start.exposureEV + Float(index + 1) * (start.exposureEV > 1 ? -0.05 : 0.05)
            }
            guard (try? start.setting(slider, to: value)) != nil else { return "slider out of range" }
            let tick = await clock.next()
            let changed = CACurrentMediaTime()
            model.moveLight(slider, to: value, for: frame)
            let expected = model.printSettings(for: frame, stock: stock)
            var shown: (time: CFTimeInterval, frame: FrameClock.Tick)?
            while shown == nil {
                let next = await clock.next()
                if let film = FrameShowProbe.film, film.settings == expected, film.time >= changed { shown = (film.time, next) }
                else if next.now - changed > 3 { return "change \(index + 1) not shown within 3 s" }
            }
            guard let shown else { continue }
            totals.append((shown.frame.target - changed) * 1000)
            renders.append((shown.time - changed) * 1000)
            refresh.append((tick.target - tick.timestamp) * 1000)
        }
        return "\(layout.pixels(frame))px \(count) changes: visible p50=\(percentile(totals, 0.5))ms p95=\(percentile(totals, 0.95))ms max=\(percentile(totals, 1))ms"
            + " | film up p50=\(percentile(renders, 0.5))ms p95=\(percentile(renders, 0.95))ms | refresh \(percentile(refresh, 0.5))ms"
            + " | active \(NSApp.isActive) visible \(window.occlusionState.contains(.visible))"
    }

    /// `settingsLatency` for a mask's slider: N changes of the selected mask's `control` (mask 0's with none selected), in one gesture as
    /// its row's drag makes them, each just after a display frame starts, timed to the first frame that carries the film with the new
    /// settings. Exposure steps 0.05 EV, Amount 1 %, the others 1, away from the end it is near. The masks' fields are baked before the
    /// first change, as a drag finds them, and what the cache did meanwhile is reported, to show that no slider baked one.
    private static func maskLatency(_ model: RollModel, frame: Frame, control: String, count: Int, clock: FrameClock) async -> String {
        guard let window = mainWindow(), let layout = model.frameLayout, let films = model.films else { return "no window" }
        let masks = model.masks(for: frame)
        guard let mask = model.selectedMask(for: frame) ?? masks.first else { return "the frame has no mask" }
        let isAmount = control == "amount", balance = MaskBalanceControl(named: control), light = ManualAdjustments.Control(rawValue: control)
        guard isAmount || balance != nil || light != nil else { return "unknown control \(control)" }
        let stock = model.stockIndex(for: frame)
        let start: Float = isAmount ? mask.amount * 100 : balance.map { $0.value(in: mask.balance) } ?? light.map { mask.adjustments.value(for: $0) } ?? 0
        let step: Float = control == "exposure" ? 0.05 : 1
        let high: Float = isAmount ? 200 : (control == "exposure" ? 5 : 100)
        let sign: Float = start + Float(count) * step > high ? -1 : 1
        var totals: [Double] = [], renders: [Double] = []
        let before = films.maskFieldStatistics
        // As the row's gesture makes them: to the print, and to the edit at its end (`RollModel.moveMaskValue`).
        model.beginMaskAdjusting(for: frame)
        defer {
            model.endMaskAdjusting(for: frame)
            model.manualUndoManager?.undo()
        }
        for index in 0..<count {
            let value = start + Float(index + 1) * step * sign
            _ = await clock.next()
            let changed = CACurrentMediaTime()
            if isAmount { model.moveMaskAmount(value / 100, mask: mask.id, for: frame) }
            else if let balance { model.moveMaskBalance(balance, to: value, mask: mask.id, for: frame) }
            else if let light { model.moveMaskValue(light, to: value, mask: mask.id, for: frame) }
            let expected = model.printSettings(for: frame, stock: stock)
            var shown: (time: CFTimeInterval, frame: FrameClock.Tick)?
            while shown == nil {
                let next = await clock.next()
                if let film = FrameShowProbe.film, film.settings == expected, film.time >= changed { shown = (film.time, next) }
                else if next.now - changed > 3 { return "change \(index + 1) not shown within 3 s" }
            }
            guard let shown else { continue }
            totals.append((shown.frame.target - changed) * 1000)
            renders.append((shown.time - changed) * 1000)
        }
        let after = films.maskFieldStatistics
        return "\(layout.pixels(frame))px zoom \(String(format: "%.2f", model.frameZoom.scale)) \(masks.count) masks, \(control) of \(model.maskName(mask.id, for: frame)), \(count) changes:"
            + " visible p50=\(percentile(totals, 0.5))ms p95=\(percentile(totals, 0.95))ms max=\(percentile(totals, 1))ms"
            + " | film up p50=\(percentile(renders, 0.5))ms p95=\(percentile(renders, 0.95))ms"
            + " | fields baked \(after.bakes - before.bakes) moved \(after.moves - before.moves) allocated \(after.allocations - before.allocations) hits \(after.hits - before.hits)"
            + " | active \(NSApp.isActive) visible \(window.occlusionState.contains(.visible))"
    }

    /// Lightroom's clipping view (`RollModel.lightClipping`): N exposure changes, each, once its film
    /// is up, followed by the highlight view (even changes) or the shadow view (odd) asked for just
    /// after a display frame starts, timed to the presentation of the first display frame whose body
    /// carries it, the print-limits probe for those new settings included. Before each change, the
    /// probe alone for settings no film uses (a half-unit Contrast). The edits are undone after.
    private static func clippingLatency(_ model: RollModel, frame: Frame, count: Int, clock: FrameClock) async -> String {
        guard let window = mainWindow(), let layout = model.frameLayout, let films = model.films else { return "no window" }
        let stock = model.stockIndex(for: frame), start = model.manualAdjustments(for: frame)
        var shown: [Double] = [], probes: [Double] = [], missed = 0
        model.beginManualGesture(for: frame)
        defer { model.lightClipping = nil; model.endManualGesture(for: frame); model.manualUndoManager?.undo() }
        for index in 0..<count {
            var probe = model.settings(for: frame, stock: stock)
            guard let values = try? start.setting(.exposure, to: start.exposureEV + Float(index + 1) * (start.exposureEV > 1 ? -0.05 : 0.05)),
                  let unused = try? ManualRenderSettings(adjustments: start.setting(.contrast, to: Float(index % 100) + 0.5),
                                                         referenceStops: probe.manual.referenceStops, version: probe.manual.version)
            else { return "exposure out of range" }
            probe.manual = unused
            let probing = CACurrentMediaTime()
            _ = await films.printLimits(stock: stock, settings: probe, space: model.output.space)
            probes.append((CACurrentMediaTime() - probing) * 1000)
            let changed = CACurrentMediaTime()
            model.setManualAdjustments(values, for: frame)
            let expected = model.settings(for: frame, stock: stock)
            while !(FrameShowProbe.film.map { $0.settings == expected && $0.time >= changed } ?? false) {
                if await clock.next().now - changed > 3 { return "change \(index + 1) not shown within 3 s" }
            }
            _ = await clock.next()
            let asked = CACurrentMediaTime()
            model.lightClipping = index % 2 == 0 ? .highlights : .shadows
            var seen: Double?
            while seen == nil {
                let next = await clock.next()
                if FrameShowProbe.displayed?.kind.hasPrefix("clipping") == true { seen = (next.target - asked) * 1000 }
                else if next.now - asked > 3 { break }
            }
            if let seen { shown.append(seen) } else { missed += 1 }
            model.lightClipping = nil
            for _ in 0..<3 { _ = await clock.next() }
        }
        return "\(layout.pixels(frame))px \(count) views: on screen p50=\(percentile(shown, 0.5))ms p95=\(percentile(shown, 0.95))ms"
            + " max=\(percentile(shown, 1))ms, missed \(missed) | probe alone p50=\(percentile(probes, 0.5))ms p95=\(percentile(probes, 0.95))ms"
            + " max=\(percentile(probes, 1))ms | active \(NSApp.isActive) visible \(window.occlusionState.contains(.visible))"
    }

    /// Launch to the empty state: from the process's start, as the kernel gives it, to the
    /// presentation time of the window's first display frame (`noteLaunch`), on the wall clock.
    private static func launchTime(_ model: RollModel) -> String {
        guard let appeared = launch.appeared, let shown = launch.shown else { return "no frame shown yet" }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else { return "no process start" }
        let started = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
        let wall = Date().timeIntervalSince1970 - CACurrentMediaTime()
        func ms(_ time: CFTimeInterval) -> String { String(format: "%.1f", (time + wall - started) * 1000) }
        return "process start to the first frame \(ms(shown)) ms (app made \(launch.made.map(ms) ?? "?") ms, content appeared \(ms(appeared)) ms),"
            + " empty state \(launch.empty)" + String(format: " | started %.3f shown %.3f", started, shown + wall)
            + " | active \(NSApp.isActive) recents \(model.recents.count)"
    }

    /// The contact sheet of a roll handed over by Launch Services, from its arrival
    /// (`AppDelegate.application(_:open:)`): each event is counted visible in the first display frame
    /// whose link fires after it, at that frame's presentation time. The roll is on screen once the
    /// model has it; first paint is the first sheet cell's embedded preview put up, the visible sheet
    /// every cell at least partly in the scroll view with its own. Previews fade in over 200 ms from
    /// there. Then every frame's preview at the cells' size from the sheet's loader, which holds
    /// those already made, timed from the same arrival.
    private static func sheetMeasure(_ model: RollModel, limit: Double, clock: FrameClock) async -> String {
        guard let window = mainWindow() else { return "no window" }
        let armed = CACurrentMediaTime()
        var began: CFTimeInterval?, installed: Double?, first: Double?, sheet: Double?, visible: [URL] = [], refresh: [Double] = []
        while sheet == nil {
            let tick = await clock.next()
            refresh.append((tick.target - tick.timestamp) * 1000)
            if tick.now - armed > limit {
                return "not done within \(Int(limit)) s: arrived \(began != nil), on screen \(installed.map { "\($0)" } ?? "no"),"
                    + " first paint \(first.map { "\($0)" } ?? "no"), \(SheetProbe.previews.count) previews, \(SheetProbe.visible.count) visible"
            }
            guard let start = began ?? opened else { continue }
            began = start
            guard model.roll.map({ !$0.frames.isEmpty }) == true else { continue }
            if installed == nil { installed = (tick.target - start) * 1000 }
            let shown = SheetProbe.previews.filter { $0.value.time >= start && $0.value.time < tick.now }
            if first == nil, !shown.isEmpty { first = (tick.target - start) * 1000 }
            visible = SheetProbe.visible
            if !visible.isEmpty, visible.allSatisfy({ shown[$0] != nil }) { sheet = (tick.target - start) * 1000 }
        }
        guard let start = began, let roll = model.roll, let pixels = visible.compactMap({ SheetProbe.previews[$0]?.pixels }).max() else {
            return "no roll"
        }
        let loader = model.thumbnails
        let decoded = await withTaskGroup(of: Bool.self) { group in
            for frame in roll.frames { group.addTask { await loader.thumbnail(for: frame, maxPixelSize: pixels) != nil } }
            var count = 0
            for await made in group where made { count += 1 }
            return count
        }
        let whole = (CACurrentMediaTime() - start) * 1000
        let wall = Date().timeIntervalSince1970 - CACurrentMediaTime()
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "none" }
        return "\(roll.frames.count) frames, \(visible.count) visible at \(pixels) px: roll on screen \(ms(installed)) ms,"
            + " first paint \(ms(first)) ms, visible sheet \(ms(sheet)) ms, every frame's preview \(ms(whole)) ms (\(decoded) of \(roll.frames.count))"
            + String(format: " | arrived %.3f", start + wall) + " | refresh \(percentile(refresh, 0.5))ms"
            + " | active \(NSApp.isActive) visible \(window.occlusionState.contains(.visible))"
    }

    /// Stock switch to the visible sheet re-rendered: from the sheet with every visible cell's film
    /// up, each switch is made just after a display frame starts, as a key press's is, to the next
    /// stock in library order, and counted visible in the first display frame whose link fires after
    /// the last visible cell put up its film through that stock, at that frame's presentation time.
    /// Films crossfade over 200 ms from there. The first switch to each stock renders from the kept
    /// decodes; one back to a stock already shown may come from the rendered-image cache. The stock
    /// in use is put back afterwards. A cell is checked against the stock it shows through, its frame's
    /// own or the roll's, and a switch is timed by the cells it changes: a frame with its own stock keeps it.
    private static func stockMeasure(_ model: RollModel, films: FilmPreviews, count: Int, clock: FrameClock) async -> String {
        guard let window = mainWindow(), let roll = model.roll else { return "no window" }
        let frames = Dictionary(roll.frames.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let original = model.stockIndex
        /// When the last of `visible` put up its film through the stock it shows through since `since`, if all have.
        func up(since: CFTimeInterval, before: CFTimeInterval, _ visible: [URL]) -> CFTimeInterval? {
            var latest = since
            for url in visible {
                guard let frame = frames[url], let film = SheetProbe.films[url] else { return nil }
                let stock = model.stockIndex(for: frame)
                guard film.stock == stock, film.time >= since, film.time < before,
                      film.settings == model.settings(for: frame, stock: stock) else { return nil }
                latest = max(latest, film.time)
            }
            return latest
        }
        let waited = CACurrentMediaTime()
        var visible: [URL] = []
        while true {
            let tick = await clock.next()
            visible = SheetProbe.visible
            if !visible.isEmpty, up(since: 0, before: tick.now, visible) != nil { break }
            if tick.now - waited > 60 { return "the visible sheet's films were not up within 60 s (\(visible.count) visible)" }
        }
        let apple = visible.filter { films.decoderChoices.choice(for: $0) != .inHouse }.count
        let pixels = visible.compactMap { SheetProbe.previews[$0]?.pixels }.max() ?? 0
        let decodes = films.decodeCount, hits = films.diskHitCount
        var lines: [String] = [], totals: [Double] = [], firsts: [Double] = [], ups: [Double] = [], refresh: [Double] = []
        var seen: Set<Int> = [original]
        for index in 0..<count {
            let stock = (model.stockIndex + 1) % films.stocks.count
            let name = films.stocks[stock].displayName
            for _ in 0..<3 { _ = await clock.next() }
            let tick = await clock.next()
            let changed = CACurrentMediaTime()
            let through = visible.map { url in frames[url].map(model.stockIndex(for:)) }
            model.selectStock(stock)
            // The cells the switch changes: those that follow the roll.
            let switched = zip(visible, through).filter { url, was in frames[url].map(model.stockIndex(for:)) != was }.map(\.0)
            guard !switched.isEmpty else {
                model.selectStock(original)
                return "switch \(index + 1) to \(name) changes no visible cell: each has a stock of its own"
            }
            var shown: (visible: Double, up: Double)?
            while shown == nil {
                let next = await clock.next()
                if let latest = up(since: changed, before: next.now, switched) {
                    shown = ((next.target - changed) * 1000, (latest - changed) * 1000)
                } else if next.now - changed > 10 { break }
            }
            guard let shown else {
                model.selectStock(original)
                return "switch \(index + 1) to \(name) not shown within 10 s"
            }
            let isFirst = seen.insert(stock).inserted
            refresh.append((tick.target - tick.timestamp) * 1000)
            totals.append(shown.visible)
            ups.append(shown.up)
            if isFirst { firsts.append(shown.visible) }
            lines.append(String(format: "%d %@ %@ visible %.1f film up %.1f", index + 1, name, isFirst ? "first" : "again", shown.visible, shown.up))
            // Past the crossfade before the next switch.
            try? await Task.sleep(for: .milliseconds(300))
        }
        model.selectStock(original)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stock-\(Int(Date().timeIntervalSince1970)).txt")
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return "\(count) switches, \(visible.count) visible cells (\(apple) Apple-decoded) at \(pixels) px:"
            + " visible p50=\(percentile(totals, 0.5))ms max=\(percentile(totals, 1))ms;"
            + " first through each stock (\(firsts.count)) p50=\(percentile(firsts, 0.5))ms max=\(percentile(firsts, 1))ms;"
            + " film up p50=\(percentile(ups, 0.5))ms max=\(percentile(ups, 1))ms"
            + " | decodes +\(films.decodeCount - decodes) disk reads +\(films.diskHitCount - hits) | refresh \(percentile(refresh, 0.5))ms"
            + " | active \(NSApp.isActive) visible \(window.occlusionState.contains(.visible)) | \(url.path)"
    }

    /// The tallest vertical scroll view in the window that has more to show than it does: the sheet's.
    private static func sheetScroller(in view: NSView) -> NSScrollView? {
        func walk(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(walk) }
        return walk(view)
            .filter { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 1 }
            .max { $0.frame.height < $1.frame.height }
    }

    /// The sheet scrolled end to end at `speed`, as a steady two-finger scroll, for `seconds`: each
    /// display frame moves the clip view by the distance due since the last, so a late frame jumps
    /// further, as it does under a finger, and every pass covers the whole sheet. The clip view rather
    /// than wheel events, which SwiftUI's scroll view takes only through a gesture of its own; its
    /// bounds are what its lazy layout follows. A frame's time is the gap between its vsync and the
    /// last one's; the display link's callback is the main thread's, so a gap past one refresh is a
    /// frame the app did not get to. It does not see what the render server drops, for which the
    /// script records Animation Hitches.
    private static func scrollMeasure(_ scroller: NSScrollView, speed: Double, seconds: Double, clock: FrameClock) async -> String {
        guard let document = scroller.documentView else { return "no document" }
        let clip = scroller.contentView
        let top = -scroller.contentInsets.top
        func end() -> Double { document.frame.height - clip.bounds.height + scroller.contentInsets.bottom }
        func move(to y: Double) {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroller.reflectScrolledClipView(clip)
        }
        var tsv = ["pass\ttimestamp\tgapMs\ty\tmainLateMs"], gaps: [Double] = [], refreshes: [Double] = []
        var pass = 0, duration = 0.0, distance = 0.0
        while pass < 2 || duration < seconds {
            let down = pass % 2 == 0
            move(to: down ? top : end())
            // The jump to the pass's start and what it brings in are not the scroll's.
            try? await Task.sleep(for: .milliseconds(400))
            var last = await clock.next(), y = clip.bounds.minY
            let started = last
            while last.now - started.now < 90 {
                let tick = await clock.next()
                y += speed * (tick.timestamp - last.timestamp) * (down ? 1 : -1)
                let done = down ? y >= end() : y <= top
                y = min(max(y, top), end())
                move(to: y)
                let gap = (tick.timestamp - last.timestamp) * 1000
                gaps.append(gap)
                refreshes.append((tick.target - tick.timestamp) * 1000)
                tsv.append(String(format: "%d\t%.4f\t%.2f\t%.1f\t%.2f", pass, tick.timestamp, gap, y, (tick.now - tick.timestamp) * 1000))
                last = tick
                if done { break }
            }
            duration += last.timestamp - started.timestamp
            distance += abs(clip.bounds.minY - (down ? top : end()))
            pass += 1
            if distance < 1 { return "the sheet did not move" }
        }
        let refresh = refreshes.sorted()[refreshes.count / 2]
        let missed = gaps.reduce(0) { $0 + max(0, Int(($1 / refresh).rounded()) - 1) }
        let hitch = gaps.filter { $0 > refresh * 1.5 }.reduce(0) { $0 + $1 - refresh }
        let name = "scroll-\(Int(Date().timeIntervalSince1970)).tsv"
        try? tsv.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return "\(pass) passes, " + String(format: "%.1f s, %.0f pt, %d frames at %.1f ms: ", duration, distance, gaps.count, refresh)
            + "p50 \(percentile(gaps, 0.5)) p95 \(percentile(gaps, 0.95)) p99 \(percentile(gaps, 0.99)) max \(percentile(gaps, 1)) ms, "
            + String(format: "missed %d (%.1f%%), hitch %.1f ms/s", missed, Double(missed) / Double(gaps.count + missed) * 100, hitch / duration)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> String {
        guard !values.isEmpty else { return "none" }
        let sorted = values.sorted()
        return String(format: "%.1f", sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded(.up)))])
    }

    /// Prepared comparison: Compare to Auto turned on just after a display frame starts. It made
    /// the next refresh if the comparison picture was in place before that refresh's display
    /// link fired and no frame was skipped between them.
    private static func comparisonLatency(_ model: RollModel, frame: Frame, count: Int, clock: FrameClock) async -> String {
        guard let window = mainWindow() else { return "no window" }
        var within = 0, notReady = 0, latencies: [Double] = [], refresh: [Double] = [], misses: [String] = []
        for _ in 0..<count {
            model.isComparingAuto = false
            for _ in 0..<3 { _ = await clock.next() }
            guard model.isAutoComparisonReady else { notReady += 1; continue }
            FrameShowProbe.automaticShown = nil
            let tick = await clock.next()
            let toggled = CACurrentMediaTime()
            model.isComparingAuto = true
            let next = await clock.next()
            let interval = tick.target - tick.timestamp
            refresh.append(interval * 1000)
            let shown = FrameShowProbe.automaticShown, late = next.timestamp - tick.target
            if let shown, shown < next.now, late < 0.5 * interval {
                within += 1
                latencies.append((tick.target - toggled) * 1000)
            } else {
                // Applied after the refresh's display link ran, or a refresh skipped in between.
                misses.append(String(format: "applied %@ skipped %.1fms", shown.map { String(format: "%+.1fms", ($0 - next.now) * 1000) } ?? "never", late * 1000))
            }
        }
        model.isComparingAuto = false
        let worst = latencies.max().map { String(format: "%.1f", $0) } ?? "none"
        let median = refresh.sorted().dropFirst(refresh.count / 2).first.map { String(format: "%.1f", $0) } ?? "?"
        return "\(within)/\(count - notReady) within the next refresh (not ready \(notReady)), worst toggle-to-refresh \(worst)ms"
            + " | refresh \(median)ms | active \(NSApp.isActive) visible \(window.occlusionState.contains(.visible))"
            + (misses.isEmpty ? "" : " | misses: " + misses.joined(separator: "; "))
    }

    /// A full-size develop of the open roll as the app makes one, timed from the post to the
    /// develop's end, with the kernel's peak physical footprint over it: the counter restarts as
    /// the develop is posted, so no sampler can miss the peak (docs/M2-shell.md section 10). The
    /// end is the develop task's own, not a poll's, since App Nap stretches a sleep's timer. The
    /// start is also given as a wall-clock time, to time the files' writes against. The output
    /// settings are put back afterwards.
    private static func developMeasure(_ model: RollModel, roll: Roll, into folder: URL, options: Set<String>) async -> String {
        let edited = roll.frames.filter { model.hasManualAdjustments($0) }.count
        if let option = options.first(where: { $0.hasPrefix("refining:") }), let films = model.films {
            // Posted while a refinement is under way, the case the memory gate must survive.
            guard let index = Int(option.dropFirst("refining:".count)), roll.frames.indices.contains(index) else { return "no frame \(option)" }
            let before = films.refinementCounts.started
            model.selection = index
            model.openFrame()
            guard await refinementStarted(films, after: before) else { return "no refinement started within 5 s" }
        }
        let refinements = model.films?.refinementCounts
        let saved = model.output
        defer { model.output = saved }
        var output = saved
        output.size = .full
        output.format = options.contains("tiff16") ? .tiff16 : options.contains("heic") ? .heic : .jpeg
        output.space = options.contains("p3") ? .displayP3 : .sRGB
        output.grain = options.contains("grain-off") ? .off : .natural
        if let quality = options.first(where: { $0.hasPrefix("quality:") }).flatMap({ Int($0.dropFirst("quality:".count)) }) {
            output.quality = quality
        }
        model.output = output
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let window = hidden?.window ?? mainWindow()
        let before = napState(window)
        let timeline = options.contains("timeline") ? MemoryTimeline() : nil
        if let timeline { model.films?.observeWork = { timeline.note("previews \($0)") } }
        let start = DevelopBudget.footprint()
        resetFootprintPeak()
        let wall = Date().timeIntervalSince1970
        let began = CACurrentMediaTime()
        timeline?.note("posted")
        model.startDevelop(to: folder)
        if let timeline {
            model.developer?.observeStage = { index, stage, begins in timeline.note("develop \(index) \(stage.rawValue) \(begins ? "+" : "-")") }
        }
        if let running = model.developTask { await running.value }
        let seconds = CACurrentMediaTime() - began
        let peak = max(footprintPeakSinceReset(), DevelopBudget.footprint())
        timeline?.note("ended")
        model.developer?.observeStage = nil
        let traced = timeline.map { timeline in
            model.films?.observeWork = nil
            return " | " + timeline.finish(name: "timeline-\(Int(wall))")
        } ?? ""
        let after = model.films?.refinementCounts
        let refined = refinements.flatMap { r in after.map { "refinements during it: started \($0.started - r.started), installed \($0.installed - r.installed), dropped \($0.dropped - r.dropped)" } } ?? ""

        let report = model.lastDevelop
        let written = report?.written ?? 0, failures = report?.failures.count ?? 0
        let mb = { (bytes: Int) in "\(bytes >> 20) MB" }
        return "\(written) of \(roll.frames.count) written \(output.format.rawValue) \(output.space.rawValue) grain \(output.grain.rawValue), "
            + "\(edited) with Light/Curve, "
            + String(format: "%.2f s, %.2f frames/s", seconds, Double(written) / max(seconds, 0.001))
            + ", peak \(mb(peak)) from \(mb(start)), target \(mb(DevelopBudget.target())), failures \(failures)"
            + (report?.failures.first.map { " (\($0.fileName): \($0.reason))" } ?? "")
            + String(format: " | started %.3f", wall) + " | before: \(before) | after: \(napState(window))"
            + (refined.isEmpty ? "" : " | " + refined) + (model.developer?.lastGateReport.map { " | " + $0 } ?? "") + traced
    }

    /// The frame view's zoom: its scale, offset and rendered scale, the pixels that asks for against the
    /// fitted frame's and the raw's, and the picture on top.
    private static func zoomState(_ model: RollModel) -> String {
        let zoom = model.frameZoom
        guard let room = model.frameZoomRoom else { return "no frame open" }
        let drawn = FrameShowProbe.displayed.map { "\($0.kind)" + ($0.image.map { " \($0.width)x\($0.height)" } ?? "") } ?? "nothing"
        return String(format: "scale %.4f offset %.1f,%.1f rendered %.4f | ", zoom.scale, zoom.offset.width, zoom.offset.height,
                      zoom.renderedScale)
            + "pixels \(zoom.pixels(in: room)) fit \(room.fitPixels) full \(room.fullPixels) area \(Int(room.area.width))x\(Int(room.area.height))"
            + " | on top: \(drawn)"
    }

    /// What the frame view draws on top, as of its last body: the shown frame and the layout's pixels,
    /// the frame and kind of the picture on top and its size, and whether it is the last film put up.
    /// With a name, that picture is written as a PNG.
    private static func shown(_ model: RollModel, name: String) -> String {
        let frame = model.shownFrame
        var line = "frame \(frame?.name ?? "none") at \(frame.flatMap { model.frameLayout?.pixels($0) } ?? 0) px"
        guard let drawn = FrameShowProbe.displayed else { return line + " | nothing drawn" }
        let image = drawn.image
        line += " | on top: \(drawn.frame.deletingPathExtension().lastPathComponent) \(drawn.kind)"
            + (image.map { " \($0.width)x\($0.height)" } ?? "")
        if let film = FrameShowProbe.lastFilm {
            let isLast = image.map { ObjectIdentifier($0) == film.image } ?? false
            line += String(format: ", %@ the last film put up (%dx%d, %.2f s ago)", isLast ? "is" : "not",
                           film.width, film.height, CACurrentMediaTime() - film.time)
        }
        if !name.isEmpty, let image { line += " | " + write(image, name: name) }
        return line
    }

    /// The footprint, and what the previews, the thumbnails and the developer hold, with the frame
    /// view's frame and its size, and the malloc setting the app is launched with (App/Info.plist).
    private static func memory(_ model: RollModel) -> String {
        let shown = model.shownFrame.map { frame in "\(frame.name) at \(model.frameLayout?.pixels(frame) ?? 0) px" } ?? "none"
        let largeCache = ProcessInfo.processInfo.environment["MallocLargeCache"] ?? "unset"
        return "footprint \(DevelopBudget.footprint() >> 20) MB | shown \(shown) | \(model.films?.heldReport ?? "no films")"
            + " | \(model.developer?.heldReport ?? "no developer") | phase \(model.isDeveloping ? "developing" : "idle")"
            + " | MallocLargeCache \(largeCache)"
    }

    /// The footprint every 2 ms on a thread of its own, with what the develop and the previews did
    /// meanwhile, for `develop-measure ... timeline`.
    final class MemoryTimeline: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [(time: Double, bytes: Int)] = []
        private var events: [(time: Double, what: String)] = []
        private var running = true
        private let start = CACurrentMediaTime()

        init() {
            samples.reserveCapacity(200_000)
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let sample = (CACurrentMediaTime() - start, DevelopBudget.footprint())
                    lock.withLock { samples.append(sample) }
                    usleep(2000)
                }
            }
        }

        func note(_ what: String) {
            let time = CACurrentMediaTime() - start
            lock.withLock { events.append((time, what)) }
        }

        /// Stops sampling, writes the samples and the events, in time order, to NAME.tsv in the tmp
        /// folder, and describes the peak: when, how high, and the work under way then.
        func finish(name: String) -> String {
            let (samples, events) = lock.withLock { () -> ([(time: Double, bytes: Int)], [(time: Double, what: String)]) in
                running = false
                return (self.samples, self.events)
            }
            var lines = samples.map { String(format: "%.4f\tfootprint\t%d", $0.time, $0.bytes >> 20) }
            lines += events.map { String(format: "%.4f\tevent\t%@", $0.time, $0.what) }
            lines.sort { Double($0.prefix { $0 != "\t" }) ?? 0 < Double($1.prefix { $0 != "\t" }) ?? 0 }
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).tsv")
            try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
            guard let peak = samples.max(by: { $0.bytes < $1.bytes }) else { return url.path }
            // What had begun and not ended by the peak.
            var open: [String] = []
            for event in events where event.time <= peak.time {
                if event.what.hasSuffix(" +") { open.append(String(event.what.dropLast(2))) }
                else if event.what.hasSuffix(" -"), let index = open.lastIndex(of: String(event.what.dropLast(2))) { open.remove(at: index) }
            }
            let trimmed = events.first { $0.what == "previews trim -" }.flatMap { trim in samples.first { $0.time >= trim.time } }
            return String(format: "sampled peak %d MB at %.3f s", peak.bytes >> 20, peak.time)
                + (trimmed.map { String(format: ", %d MB just after the trim at %.3f s", $0.bytes >> 20, $0.time) } ?? "")
                + " | under way at the peak: " + (open.isEmpty ? "nothing" : open.joined(separator: ", ")) + " | \(url.path)"
        }
    }

    /// Whether a refinement starts, beyond the `after` already started, within 5 s.
    private static func refinementStarted(_ films: FilmPreviews, after: Int) async -> Bool {
        let posted = CACurrentMediaTime()
        while films.refinementCounts.started <= after, CACurrentMediaTime() - posted < 5 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return films.refinementCounts.started > after
    }

    /// "Apple-decoded previews, 2026-10-16", B1 to B3: opens every frame of the roll in turn, in
    /// roll order (`step`, so each was decoded ahead) or every second frame and then the rest
    /// (`jump`, so none was), each on screen `dwell` milliseconds. For each frame, the time from
    /// opening it to its first film and to its refined film; over the pass, the kernel's interval
    /// peak footprint and the most the rendered images held. A line a frame goes to a file in the
    /// container's tmp folder.
    private static func browseMeasure(_ model: RollModel, roll: Roll, order: String, dwell: Int) async -> String {
        guard let films = model.films else { return "no films" }
        let count = roll.frames.count
        let indices = order == "jump" ? Array(stride(from: 0, to: count, by: 2)) + Array(stride(from: 1, to: count, by: 2))
            : Array(0..<count)
        var lines: [String] = [], firsts: [Double] = [], refineds: [Double] = []
        var unrefined = 0, apple = 0, cacheMax = 0
        let counts = films.refinementCounts, start = DevelopBudget.footprint()
        resetFootprintPeak()
        for index in indices {
            let frame = roll.frames[index]
            let decoder = films.decoderChoices.choice(for: frame.url)
            FrameShowProbe.shown.removeAll()
            let opened = CACurrentMediaTime()
            model.selection = index
            model.openFrame()
            try? await Task.sleep(for: .milliseconds(dwell))
            let shows = FrameShowProbe.shown.filter { $0.frame == frame.url && $0.time >= opened }
            let first = shows.first.map { ($0.time - opened) * 1000 }
            let refined = shows.first { $0.refined }.map { ($0.time - opened) * 1000 }
            if let first { firsts.append(first) }
            // Apple's frames, RAW 8's and RAW 9's, are refined.
            if decoder != .inHouse {
                apple += 1
                if let refined { refineds.append(refined) } else { unrefined += 1 }
            }
            cacheMax = max(cacheMax, films.renderedCacheBytes)
            func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "none" }
            lines.append("\(index) \(frame.name) \(decoder.rawValue) first \(ms(first)) refined \(ms(refined)) cache \(films.renderedCacheBytes)")
        }
        let peak = max(footprintPeakSinceReset(), DevelopBudget.footprint())
        let after = films.refinementCounts
        let stamp = Int(Date().timeIntervalSince1970)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("browse-\(order)-\(stamp).txt")
        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        let mb = { (bytes: Int) in "\(bytes >> 20) MB" }
        return "\(order) \(indices.count) frames, \(dwell) ms each, refinement \(films.refinesFrameDecodes ? "on" : "off"):"
            + " first film p50 \(percentile(firsts, 0.5)) p95 \(percentile(firsts, 0.95)) max \(percentile(firsts, 1)) ms (\(firsts.count) shown)"
            + " | refined, of \(apple) Apple frames: p50 \(percentile(refineds, 0.5)) p95 \(percentile(refineds, 0.95)) max \(percentile(refineds, 1)) ms, \(unrefined) not refined"
            + " | peak \(mb(peak)) from \(mb(start)) | rendered images at most \(cacheMax) of \(films.renderedCacheLimit) bytes"
            + " | refinements started \(after.started - counts.started) installed \(after.installed - counts.installed) dropped \(after.dropped - counts.dropped)"
            + " | \(url.path)"
    }

    /// `backdrop`: the Open roll page's backdrop on or off as Settings sets it, its pointer or its
    /// stillness held, and its state.
    private static func backdrop(_ argument: String) {
        let values = argument.split(separator: " ").map(String.init)
        switch values.first {
        case nil:
            reply("backdrop", backdropView().map { "view yes " + $0.debugState } ?? "view no")
            return
        case "on" where values.count == 1, "off" where values.count == 1:
            AppearanceSettings.shared.setShowsOpenRollBackdrop(values[0] == "on")
        case "still" where values.count == 2 && ["on", "off"].contains(values[1]):
            OpenRollBackdropView.debugStill = values[1] == "on" ? true : nil
        case "active" where values.count == 2 && ["on", "off", "app"].contains(values[1]):
            OpenRollBackdropView.debugActive = values[1] == "app" ? nil : values[1] == "on"
        case "pointer" where values.count == 2 && ["off", "away"].contains(values[1]):
            OpenRollBackdropView.debugPointer = values[1] == "away" ? .away : nil
        case "pointer" where [3, 6].contains(values.count) && values.dropFirst().allSatisfy { Double($0) != nil }:
            let numbers = values.dropFirst().compactMap { Double($0) }
            if numbers.count == 2 {
                OpenRollBackdropView.debugPointer = OpenRollBackdropPointerHold(at: CGPoint(x: numbers[0], y: numbers[1]))
            } else {
                OpenRollBackdropView.debugPointer = OpenRollBackdropPointerHold(
                    from: CGPoint(x: numbers[0], y: numbers[1]), to: CGPoint(x: numbers[2], y: numbers[3]),
                    start: CACurrentMediaTime(), duration: max(numbers[4], 0))
            }
        default:
            reply("error", "backdrop [on|off | pointer X Y | pointer X0 Y0 X1 Y1 SECONDS | pointer away|off | still on|off | active on|off|app]")
            return
        }
        backdropView()?.debugHoldsChanged()
        reply("backdrop", argument)
    }

    /// The Open roll page's backdrop in the main window, or in the window `window minimize` or
    /// `window hide` has out of sight.
    private static func backdropView() -> OpenRollBackdropView? {
        func find(_ view: NSView) -> OpenRollBackdropView? {
            if let backdrop = view as? OpenRollBackdropView { return backdrop }
            return view.subviews.lazy.compactMap(find).first
        }
        return (hidden?.window ?? mainWindow())?.contentView.flatMap(find)
    }

    /// `window minimize|hide|restore|state`: the window in the Dock, or the app hidden, each as App
    /// Nap finds an app in the background. A window cannot be moved off every screen: AppKit puts it
    /// back. The reply comes a second later, after the minimize's animation and the window server's
    /// occlusion change.
    private static func conceal(_ how: String) {
        guard let window = hidden?.window ?? mainWindow() else { reply("error", "no window"); return }
        switch how {
        case "minimize":
            if hidden == nil { hidden = (window, window.frame) }
            window.miniaturize(nil)
        case "hide":
            if hidden == nil { hidden = (window, window.frame) }
            NSApp.hide(nil)
        case "restore":
            if let saved = hidden {
                if NSApp.isHidden { NSApp.unhideWithoutActivation() }
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.setFrame(saved.frame, display: true)
                hidden = nil
            }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { reply("window", napState(window)) }
    }

    /// What App Nap goes by, the window's occlusion and whether the app is active, and whether
    /// the kernel has the app napping now.
    private static func napState(_ window: NSWindow?) -> String {
        let napping = isNapping().map { "\($0)" } ?? "unknown"
        guard let window else { return "no window, active \(NSApp.isActive), napping \(napping)" }
        let frame = window.frame
        return "visible \(window.occlusionState.contains(.visible)) minimized \(window.isMiniaturized) hidden \(NSApp.isHidden) active \(NSApp.isActive)"
            + " napping \(napping) thermal \(ProcessInfo.processInfo.thermalState.rawValue)"
            + " frame \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
    }

    /// The develop's progress row alone, with no develop behind it: a frame done every 0.3 s for
    /// `seconds`, without the row's animation if `still`, then gone.
    private static func napProbeProgress(_ model: RollModel, seconds: Double, still: Bool) async -> String {
        let window = hidden?.window ?? mainWindow()
        let before = napState(window), start = CACurrentMediaTime()
        var transaction = Transaction()
        transaction.disablesAnimations = still
        var progress = DevelopProgress(total: 30)
        withTransaction(transaction) { model.developPhase = .developing(progress) }
        while CACurrentMediaTime() - start < seconds {
            try? await Task.sleep(for: .milliseconds(300))
            progress.record(.developed(URL(fileURLWithPath: "/dev/null")))
            withTransaction(transaction) { model.developPhase = .developing(progress) }
        }
        withTransaction(transaction) { model.developPhase = .idle }
        return String(format: "progress %.2f s | before: ", CACurrentMediaTime() - start) + before + " | after: " + napState(window)
    }

    /// The shown frame decoded and rendered three times at about `pixels` through the frame view's
    /// path, each written as a PNG, with nothing on screen changed.
    private static func napProbeRender(_ model: RollModel, pixels: Int) async -> String {
        let window = hidden?.window ?? mainWindow()
        let before = napState(window), start = CACurrentMediaTime()
        var films: [String] = []
        for index in 0..<3 { films.append(await film(model, name: "nap-probe-\(index)", pixels: pixels - index)) }
        return String(format: "render %.2f s | ", CACurrentMediaTime() - start) + films.joined(separator: ", ")
            + " | before: " + before + " | after: " + napState(window)
    }

    /// Whether the kernel is suppressing the process, App Nap's lower priority, throttled I/O
    /// and coalesced timers: its PROC_FLAG_SUPPRESSED, nil when it cannot be read.
    private static func isNapping() -> Bool? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_flags & UInt32(PROC_FLAG_SUPPRESSED) != 0
    }

    /// Gives every other frame of the roll the shown frame's Light, Curve and masks through the paste itself (`RollModel.paste`), as
    /// one undo step, without touching the clipboard and, as this hook always did, without the frame's own Rated at and Lab balance.
    /// Each frame pins its own Auto as the paste pins it, once its recipe is read, its raw verified and measured and the roll settled,
    /// so no frame need be opened first; it takes the masks as another picture does, new ids and no smart seeds, which measured the
    /// shown frame. The reply's first part is as it was; a frame left out is named after it.
    private static func copyAdjustments(_ model: RollModel, roll: Roll) async -> String {
        guard let shown = model.shownFrame else { return "open a frame first" }
        let others = roll.frames.filter { $0.url != shown.url }
        guard let task = model.paste(model.clipboard(of: shown), parts: [.light, .presence, .curve, .masks], to: others, batch: true),
              let report = await task.value else { return "\(shown.name)'s values could not be pasted now" }
        let left = report.skipped.map { "\($0.name): \($0.why)" }.joined(separator: "; ")
        return "\(report.pasted.count) frames given \(shown.name)'s values; \(roll.frames.filter { model.hasManualAdjustments($0) }.count) of \(roll.frames.count) edited"
            + (left.isEmpty ? "" : " | left out: " + left)
    }

    /// The kernel's peak footprint since `resetFootprintPeak()`, as the develop memory tests read it.
    private static func footprintPeakSinceReset() -> Int {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int(info.ri_interval_max_phys_footprint) : 0
    }

    private static func resetFootprintPeak() {
        typealias Control = @convention(c) (pid_t, Int32, UnsafeMutableRawPointer?) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_rlimit_control") else { return }
        _ = unsafeBitCast(symbol, to: Control.self)(getpid(), RLIMIT_FOOTPRINT_INTERVAL,
                                                    UnsafeMutableRawPointer(bitPattern: UInt(FOOTPRINT_INTERVAL_RESET)))
    }

    /// One key press, down and up, queued for the application's event loop as a hardware key
    /// is, so it is the current event while menus, the first responder and the key view loop
    /// handle it.
    private static func press(_ name: String) -> Bool {
        var parts = name.split(separator: "+").map(String.init)
        guard let key = parts.popLast(), let window = mainWindow() else { return false }
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: return false
            }
        }
        let named: [String: (UInt16, String)] = [
            "tab": (48, "\t"), "return": (36, "\r"), "enter": (76, "\u{3}"), "escape": (53, "\u{1b}"),
            "delete": (51, "\u{7f}"), "space": (49, " "), "plus": (24, "+"), "minus": (27, "-"),
            "left": (123, "\u{f702}"), "right": (124, "\u{f703}"), "down": (125, "\u{f701}"), "up": (126, "\u{f700}"),
            "home": (115, "\u{f729}"), "end": (119, "\u{f72b}"),
        ]
        let typed: [Character: UInt16] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "=": 24, "z": 6, "a": 0, "f": 3, "h": 4]
        var code: UInt16, text: String
        if let entry = named[key] { (code, text) = entry }
        else if key.count == 1, let character = key.first, let entry = typed[character] { (code, text) = (entry, key) }
        else { return false }
        if key == "plus" { flags.insert(.shift) }
        if (123...126).contains(code) { flags.formUnion([.function, .numericPad]) }
        if code == 115 || code == 119 { flags.insert(.function) }
        // Shift-Tab arrives as the back-tab character.
        if code == 48, flags.contains(.shift) { text = "\u{19}" }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }

    /// A mouse event at `point` in `window`, posted to the app as the window server's are.
    private static func postMouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
                                  flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// The main window's first responder, the curve graph's selection when it has focus, and
    /// the shown frame's point curves.
    private static func focus(_ model: RollModel) -> String {
        guard let window = mainWindow() else { return "no window" }
        let responder = window.firstResponder
        var line = "responder \(responder.map { String(describing: type(of: $0)) } ?? "none")"
        if let view = responder as? NSView, let label = view.accessibilityLabel(), !label.isEmpty { line += " \"\(label)\"" }
        if let graph = responder as? CurveGraphView { line += " channel \(graph.channel.rawValue) selected \(graph.selectedPoint)" }
        if let slider = responder as? AdjustmentSliderControl {
            line += " clipping \(slider.isClipping) view \(model.lightClipping.map { "\($0)" } ?? "none")"
        }
        func graphs(_ view: NSView) -> [CurveGraphView] {
            (view as? CurveGraphView).map { [$0] } ?? view.subviews.flatMap(graphs)
        }
        if let content = window.contentView, let graph = graphs(content).first {
            line += " [graph enabled \(graph.isEnabled) points \(graph.pointMode)\(model.curveGraphFocusRequest != nil ? " focus pending" : "")]"
        }
        if let frame = model.shownFrame {
            let curves = model.manualAdjustments(for: frame).curves
            for channel in ToneCurves.Channel.allCases where !curves.curve(for: channel).isIdentity {
                line += " | \(channel.rawValue) " + curves.curve(for: channel).points.map { "\($0.input):\($0.output)" }.joined(separator: " ")
            }
            line += " | stock \(model.stockIndex) edited \(model.hasManualAdjustments(frame))"
        }
        return line
    }

    /// The previews' work begun during a measurement (`FilmPreviews.observeWork`), counted by kind: "sheet-render 3", from notes
    /// told on any thread.
    final class WorkCount: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func add(_ note: String) {
            guard note.hasSuffix(" +"), let kind = note.split(separator: " ").first else { return }
            lock.withLock { counts[String(kind), default: 0] += 1 }
        }
        var summary: String {
            let counts = lock.withLock { self.counts }
            return counts.isEmpty ? "nothing" : counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
    }

    /// The window's display link as an awaitable clock: each tick's vsync, the presentation
    /// time of the frame being prepared, and when the callback ran.
    @MainActor final class FrameClock: NSObject {
        struct Tick { let timestamp: CFTimeInterval, target: CFTimeInterval, now: CFTimeInterval }
        private var link: CADisplayLink?
        private var waiting: [CheckedContinuation<Tick, Never>] = []
        init(view: NSView) {
            super.init()
            link = view.displayLink(target: self, selector: #selector(fire(_:)))
            link?.add(to: .main, forMode: .common)
        }
        @objc private func fire(_ link: CADisplayLink) {
            let tick = Tick(timestamp: link.timestamp, target: link.targetTimestamp, now: CACurrentMediaTime())
            let resumed = waiting; waiting = []
            resumed.forEach { $0.resume(returning: tick) }
        }
        func next() async -> Tick { await withCheckedContinuation { waiting.append($0) } }
        func stop() { link?.invalidate(); link = nil }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.attachedSheet == nil }
    }

    /// The frame view's film render at the size it is shown, if it is made.
    private static func shownFilm(_ model: RollModel) -> CGImage? {
        guard let frame = model.shownFrame, let layout = model.frameLayout, let films = model.films else { return nil }
        return films.cachedFrameFilm(frame, stock: model.stockIndex(for: frame), settings: model.settings(for: frame, stock: model.stockIndex(for: frame)),
                                     space: model.output.space, pixels: layout.pixels(frame))
    }

    /// One line for the layout and one for each layer at least 200 points on a side: its
    /// frame in the content view's points and in device pixels, and what it draws.
    private static func picture(_ model: RollModel) -> [String] {
        guard let window = mainWindow(), let root = window.contentView?.layer else { return ["no window"] }
        let scale = window.backingScaleFactor
        var lines = ["window \(window.windowNumber), backing \(scale), content \(window.contentView?.bounds.size ?? .zero)"]
        if let frame = model.shownFrame, let layout = model.frameLayout {
            let film = shownFilm(model).map { "\($0.width)x\($0.height)" } ?? "none"
            lines.append("layout area \(layout.area), box \(layout.box(frame)), pixels \(layout.pixels(frame)), film \(film)")
        }
        func describe(_ value: CGFloat) -> String { String(format: "%.4f", value) }
        func walk(_ layer: CALayer, depth: Int) {
            let rect = layer.convert(layer.bounds, to: root)
            if rect.width >= 200, rect.height >= 200 {
                var line = "\(depth) \(type(of: layer)) points (\(describe(rect.minX)), \(describe(rect.minY)), \(describe(rect.width)), \(describe(rect.height)))"
                line += " pixels (\(describe(rect.minX * scale)), \(describe(rect.minY * scale)), \(describe(rect.width * scale)), \(describe(rect.height * scale)))"
                line += " contentsScale \(layer.contentsScale) gravity \(layer.contentsGravity.rawValue)"
                if let contents = layer.contents {
                    if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                        let image = contents as! CGImage
                        line += " image \(image.width)x\(image.height)"
                    } else {
                        line += " contents \(type(of: contents))"
                    }
                }
                if layer.contentsRect != CGRect(x: 0, y: 0, width: 1, height: 1) { line += " contentsRect \(layer.contentsRect)" }
                if !CATransform3DIsIdentity(layer.transform) { line += " transform" }
                if layer.cornerRadius > 0 || layer.mask != nil { line += " corner \(layer.cornerRadius) mask \(layer.mask != nil)" }
                if layer.minificationFilter != .linear || layer.magnificationFilter != .linear {
                    line += " filters \(layer.minificationFilter.rawValue)/\(layer.magnificationFilter.rawValue)"
                }
                lines.append(line)
            }
            layer.sublayers?.forEach { walk($0, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return lines
    }

    /// The frame view's film render written as a PNG, in its own colour space.
    private static func film(_ model: RollModel, name: String) -> String {
        guard let image = shownFilm(model) else { return "no film" }
        return write(image, name: name)
    }

    /// The shown frame through the frame view's own path, its decode and render, at `pixels`:
    /// at a developed file's size, the picture the develop should match.
    private static func film(_ model: RollModel, name: String, pixels: Int) async -> String {
        guard let frame = model.shownFrame, let films = model.films else { return "no frame" }
        guard let image = await films.frameFilm(frame, stock: model.stockIndex(for: frame),
                                                settings: model.settings(for: frame, stock: model.stockIndex(for: frame)),
                                                space: model.output.space, pixels: pixels)
        else { return "no film" }
        return write(image, name: name)
    }

    private static func write(_ image: CGImage, name: String) -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("film-\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return "no file" }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? "\(url.path) \(image.width)x\(image.height)" : "not written"
    }

    /// An 8-bit gray plane, top row first, as a PNG.
    private static func writeGray(_ plane: [UInt8], width: Int, height: Int, to url: URL) -> Bool {
        guard let provider = CGDataProvider(data: Data(plane) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Each visible window drawn into a PNG, titlebar and toolbar included.
    private static func snapshot(_ name: String) -> String {
        var paths: [String] = []
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snap-\(name)-\(index).png")
            if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
                paths.append(url.path)
            }
        }
        return paths.joined(separator: " ")
    }
}

// MARK: - Task Q: measuring Compare's divider and the zoom

extension Automation {
    /// `compare split ...`: the split comparison, and the divider measure.
    fileprivate static func compareSplit(_ argument: String, model: RollModel) {
        let values = argument.split(separator: " ").map(String.init)
        switch values.first {
        case "split":
            if values.count > 1 {
                switch values[1] {
                case "on": model.isSplitComparing = true
                case "off": model.isSplitComparing = false
                case "at" where values.count == 3 && Double(values[2]) != nil: model.splitPosition = CGFloat(Double(values[2])!)
                default: reply("error", "compare split on|off|at F"); return
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                reply("compare", "split \(model.isSplitComparing) at \(model.splitPosition) | \(model.maskEditor.canvas?.geometry?().filmEdge.map { "film edge \($0)" } ?? "no film edge")")
            }
        case "divider-measure":
            guard let window = mainWindow(), let view = window.contentView, let canvas = model.maskEditor.canvas,
                  let geometry = canvas.geometry?(), model.isSplitComparing else {
                reply("error", "compare divider-measure needs a split up over the picture"); return
            }
            let seconds = values.count > 1 ? Double(values[1]) ?? 8 : 8, speed = values.count > 2 ? Double(values[2]) ?? 400 : 400
            let span = values.count > 3 ? Double(values[3]) ?? 240 : 240, drivesModel = values.count > 4 && values[4] == "model"
            let start = CGPoint(x: SplitGeometry(geometry).dividerX(at: model.splitPosition), y: geometry.visiblePicture.midY)
            func windowPoint(_ x: CGFloat) -> NSPoint { canvas.convert(NSPoint(x: x, y: start.y), to: nil) }
            Task {
                let clock = FrameClock(view: view)
                defer { clock.stop() }
                let low = start.x - span / 2
                var stamps: [CFTimeInterval] = []
                var positions = [model.splitPosition]
                _ = await clock.next()
                let cpu = mainThreadCPU()
                if !drivesModel { postMouse(.leftMouseDown, at: windowPoint(start.x), in: window) }
                let began = CACurrentMediaTime()
                var tick = await clock.next()
                while tick.now - began < seconds {
                    stamps.append(tick.timestamp)
                    let travelled = span / 2 + (tick.now - began) * speed, phase = travelled.truncatingRemainder(dividingBy: 2 * span)
                    let x = low + (phase <= span ? phase : 2 * span - phase)
                    if drivesModel {
                        model.splitPosition = SplitGeometry(geometry).position(atX: x)
                    } else {
                        postMouse(.leftMouseDragged, at: windowPoint(x), in: window)
                    }
                    positions.append(model.splitPosition)
                    tick = await clock.next()
                }
                if !drivesModel { postMouse(.leftMouseUp, at: windowPoint(start.x), in: window) }
                let spent = mainThreadCPU() - cpu, elapsed = CACurrentMediaTime() - began
                reply("compare", String(format: "divider-measure %.1f s at %.0f pt/s over %.0f pt, zoom %.2f, %@: ", seconds, speed, span, model.frameZoom.scale, drivesModel ? "model" : "posted")
                      + refreshes(stamps, window: window)
                      + String(format: " | main thread CPU %.0f ms, %.1f%% of the drag | position %.3f to %.3f, ended %.3f", spent * 1000, 100 * spent / max(elapsed, 1e-3),
                               positions.min() ?? 0, positions.max() ?? 0, model.splitPosition))
            }
        default:
            reply("error", "compare split on|off|at F | divider-measure [S] [PT/S] [SPAN]")
        }
    }

    /// `zoom measure pan|pinch [SECONDS] [PT/S]`: a step of the gesture at each display frame through the model's own calls (the ones the window's event monitor makes), then its
    /// end, with the display link's refreshes over it. A pinch is about the area's middle, its scale a sine of amplitude 0.2 around its start; a pan a triangle of 300 points.
    fileprivate static func zoomMeasure(_ values: [String], model: RollModel) {
        guard values.count >= 2, ["pan", "pinch"].contains(values[1]), let window = mainWindow(), let view = window.contentView, model.frameZoomRoom != nil else {
            reply("error", "zoom measure pan|pinch [SECONDS] [PT/S]"); return
        }
        let seconds = values.count > 2 ? Double(values[2]) ?? 8 : 8, speed = values.count > 3 ? Double(values[3]) ?? 400 : 400
        Task {
            let clock = FrameClock(view: view)
            defer { clock.stop() }
            let center = CGPoint(x: model.frameLayout?.area.width ?? 0, y: model.frameLayout?.area.height ?? 0)
            let anchor = CGPoint(x: center.x / 2, y: center.y / 2)
            var stamps: [CFTimeInterval] = []
            var last = CGFloat(0), lastT = 0.0
            _ = await clock.next()
            let cpu = mainThreadCPU(), began = CACurrentMediaTime(), start = model.frameZoom.scale
            var tick = await clock.next()
            while tick.now - began < seconds {
                stamps.append(tick.timestamp)
                let t = tick.now - began
                if values[1] == "pan" {
                    let phase = (t * speed).truncatingRemainder(dividingBy: 600), x = CGFloat(phase <= 300 ? phase : 600 - phase)
                    _ = model.panFrame(by: CGSize(width: x - last, height: 0), ended: false)
                    last = x
                } else {
                    let s = start * (1 + 0.2 * sin(2 * .pi * t / 2.5))
                    model.pinchFrame(by: s / model.frameZoom.scale - 1, at: anchor, ended: false)
                }
                lastT = t
                tick = await clock.next()
            }
            if values[1] == "pan" { _ = model.panFrame(by: .zero, ended: true) } else { model.pinchFrame(by: 0, at: anchor, ended: true) }
            let spent = mainThreadCPU() - cpu, elapsed = CACurrentMediaTime() - began
            for _ in 0..<30 { _ = await clock.next() }
            reply("zoom", String(format: "measure %@ %.1f s, zoom %.2f: ", values[1], lastT, model.frameZoom.scale)
                  + refreshes(stamps, window: window)
                  + String(format: " | main thread CPU %.0f ms, %.1f%% | overlay rasters %d, sharp reads %d, footprint %.0f MB", spent * 1000, 100 * spent / max(elapsed, 1e-3),
                           model.maskEditor.overlay.rasterCount, model.maskEditor.overlay.sharpCount, Double(DevelopBudget.footprint()) / 1048576))
        }
    }
}
#endif
