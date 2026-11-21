# The Lightroom mask session: the owner's script

You open Lightroom, choose one menu command and wait. About an hour is set aside; the plan below uses about 35 minutes
and the rest is for a retry. You do not draw anything and you do not use Lightroom's masking panel. The plug-in writes
mask tables into photos in a **throwaway catalog**, Lightroom exports them, and a program reads the exports afterwards.
Your own catalog (`~/Pictures/Lightroom`) is never opened, and the plug-in refuses to run in any catalog whose name does
not contain `argent-masks-session`.

What it settles, for the plan's masking arithmetic: whether a partly covered area gets a *smaller slider* or a *smaller
gain* (up to 13 L* apart for Whites), how two masks combine and whether their order matters, what Amount scales, the
shape of a feather, how Add, Subtract, Intersect and Invert combine, whether a mask reads the same base as the global
sliders, whether a mask over everything equals the global slider, and the range of local Exposure.

## Before you start

- Mac on power, the lid open, and at least **15 GB free**. The exports take about 7.5 GB.
- Open a terminal at the root of the Argent checkout containing `references/` and `samples/`.
  Run every command below from there. The session's research data is not included in the public checkout.
- Nothing heavy running (no Argent develop, no model run).

## The steps, with time

| # | Step | Minutes |
| --- | --- | ---: |
| 1 | Quit Lightroom | 1 |
| 2 | `session-masks.sh prepare` | 3 |
| 3 | Open Lightroom with a new throwaway catalog | 8 |
| 4 | Check the plug-in loaded | 3 |
| 5 | Choose the menu command | 1 |
| 6 | Wait (the run itself; planned, probably half of it) | 7 |
| 7 | Quit Lightroom | 1 |
| 8 | `check`, `analyze`, `finish` | 6 |
| 9 | Delete the throwaway catalog and the clones | 5 |
| | **Total planned** | **about 35** |

Steps 1 to 4 are the setup (15 minutes), steps 5 and 6 the run (8), steps 7 to 9 the wrap-up (12). The run is planned from the only
throughput on record (the 175 or more renders of 2026-10-29 took at most 4 minutes), at two to four times that cost per item.

### 1. Quit Lightroom

Lightroom Classic menu, **Quit Lightroom Classic** (⌘Q). If it asks to back up the catalog, choose **Skip Now**. Check the
Dock: no dot under its icon. The next step refuses to go on while it runs.

### 2. Prepare (terminal)

```sh
scripts/lightroom-probe/session-masks.sh plan       # optional: the jobs and the time, nothing written
scripts/lightroom-probe/session-masks.sh prepare
```

`prepare` makes the test charts, backs up the plug-in that is installed now (version 1.1.0) and installs 1.2.0, creates
the `READY` file the plug-in waits for, and writes six job files, a small table file for each mask, and about 350 clones of the
test charts (clones cost no disk space). It takes a couple of
minutes and ends with `READY. Now follow SESSION.md`. If it stops with a message, the message says what is missing (the
sample raw, Python); nothing is half-installed that `finish` cannot undo.

### 3. Open Lightroom with a throwaway catalog

1. Start Lightroom Classic **while holding the Option key (⌥)** until a window called *Select Catalog* appears.
2. Click **Create New Catalog…**
3. Name it exactly **`Argent-masks-session`**, save it on the **Desktop**, click **Create**. (The name matters: the plug-in
   looks for `argent-masks-session` in the catalog's file name, ignoring capitals, and refuses to run anywhere else.)
4. Lightroom opens, empty. In the menu **Lightroom Classic ▸ Catalog Settings… ▸ Metadata** make sure **Automatically write
   changes into XMP** is **not** ticked (it is off in a new catalog). Close the window. Change nothing else.

### 4. Check the plug-in loaded

**File ▸ Plug-in Manager…** Find **Argent Probe** in the list on the left. The right side must say it is **Enabled** and
**Version 1.2.0**. If it is missing or says 1.1.0, quit, run `prepare` again, and start over from 3. If it is listed but
disabled, click **Enable**. Click **Done**.

### 5. Choose the menu command

Make sure you are in the **Library** module (press **G**, grid view). Then:

**Library ▸ Plug-in Extras ▸ Argent Probe: run pending jobs**

Nothing else needs choosing. The plug-in works through the six jobs in order of their names.

### 6. Wait

What you see: a progress bar at the top left of the window, *Argent probe: m00-smoke.job*, with captions
*writing 3 of 9*, then *exporting 9*. The first job is the smoke test and takes **under half a minute**. If Lightroom
takes the tables, the run goes on by itself to `m01-partial` and the rest. If it does not, it stops and says so (see *If
Lightroom refuses a table*); that costs you a minute, not the hour.

**How to tell it is done:** the progress bar goes away and a short grey message, *Argent Probe: all jobs done*, appears in the
middle of the window. In the terminal, `scripts/lightroom-probe/session-masks.sh status` then shows `marker: ALLDONE` and
`353 of 353 exports in all`. While it runs the same command shows how far along it is. The jobs, in the order they run:

| job | items | planned | what it settles |
| --- | ---: | ---: | --- |
| `m00-smoke` | 9 | 0.3 min | does Lightroom take a table at all (it stops the run if not) |
| `m01-partial` | 120 | 2.2 min | partial coverage, Amount, mask over everything |
| `m02-overlap` | 96 | 1.8 min | how two masks combine, local with global |
| `m03-feather` | 80 | 1.2 min | feather profile, component algebra, local Exposure's range |
| `m04-base` | 36 | 1.6 min | the base, and a real picture |
| `m05-extra` | 12 | 0.4 min | the other ways to cover the whole frame |

The most important questions are in the first two jobs, so if time runs out those are the ones you have.

**While it runs, do not:**

- click in the photo grid, select, rename, move, rate, or delete photos;
- open the Develop module, the Masking panel, or any other module (the plug-in needs the Library module);
- import anything, open another catalog, or change a Lightroom preference;
- quit Lightroom, force quit it, or let the Mac sleep (if it might, run `caffeinate -dims` in another terminal tab);
- run `prepare` again, or touch the `jobs` folder by hand.

You may watch, and you may use `status` or `stop` in the terminal.

**To stop safely:** `scripts/lightroom-probe/session-masks.sh stop`, or click the small **×** beside the progress bar. The
plug-in finishes the item or render it is on (a second or two), skips the rest, and removes its tables from the photos. Wait until the progress bar has
gone. Never force quit while it is exporting. Jobs that did not finish stay as `.job` files and run next time.

### 7. Quit Lightroom

⌘Q. If it asks to back up the catalog, **Skip Now**.

### 8. Check, analyse, finish (terminal)

```sh
scripts/lightroom-probe/session-masks.sh check      # are all the exports there and clean
scripts/lightroom-probe/session-masks.sh analyze    # a minute or two; writes references/lightroom-probe/masks-report/REPORT.md
scripts/lightroom-probe/session-masks.sh finish     # takes READY away and puts the old plug-in back (needs Lightroom quit)
```

`analyze` prints a one-page table: for each of the eight questions what Lightroom does, what Argent's candidate rule
assumed, KEEP or CHANGE, and what keeping the current rule would cost in L*. The full report, with the numbers behind every
row, is `references/lightroom-probe/masks-report/REPORT.md`.

### 9. Delete the throwaway catalog

In Finder, put the folder **`Argent-masks-session`** from the Desktop in the Trash (it holds the catalog and Lightroom's
previews). Then in the terminal:

```sh
scripts/lightroom-probe/session-masks.sh clean      # removes the 350 cloned inputs; the exports, the plan and the report stay
```

The next time you start Lightroom it will say it cannot find the last catalog, because that was the throwaway one. Pick your
usual catalog from the list. That is expected. `~/Pictures/Lightroom` was never touched.

Hand the coordinator `references/lightroom-probe/masks-report/REPORT.md` and tell them where `exports-m0*` are.

## What Lightroom might say, and what to do

| What you see | What it means | What to do |
| --- | --- | --- |
| Dialog *Argent Probe: These jobs run only in the throwaway catalog…* | The open catalog is not `Argent-masks-session` | **OK**; File ▸ Open Recent ▸ Argent-masks-session; run the command again. Nothing was changed |
| *Argent Probe: stopped* (grey message) | The smoke job failed, or you pressed stop or ×, or a `STOP` file exists | `session-masks.sh status`, then `check`. If the smoke job failed see *If Lightroom refuses a table* |
| Plug-in Manager does not list Argent Probe, or says 1.1.0 | The install did not take | Quit; `prepare` again; step 3 again |
| macOS asks whether Lightroom may access a folder (Desktop, Documents, Developer) | It reads the cloned charts | **Allow** |
| *Back Up Catalog* when quitting | Lightroom's usual prompt | **Skip Now** |
| An update for Lightroom is offered | Adobe | **Not now** |
| Spinning wheel for more than a minute or two | A 33 MP export or the first import | Wait. Judge by `status`: if the export count has not moved for 5 minutes, use `stop` and wait |
| *Disk is full* or an export error | Not enough space | Free space; the unfinished jobs are still `.job` files; choose the command again |
| Any dialog about AI, *Update AI Settings*, *AI process is running*, *No subject detected* | Should never appear: no AI mask is involved | Click the safe choice (Cancel or OK), note the time, tell the coordinator, `stop` |
| **Lightroom crashes** (*quit unexpectedly*) | A table it did not like | Do **not** reopen that catalog. Start Lightroom holding ⌥, create a new catalog named `Argent-masks-session-2`, run the command again. Finished jobs are `.processed` and are skipped; the rest run again. Trash the crashed catalog folder. Tell the coordinator which job was running |

## If Lightroom refuses a table

Signs: the first job ends with *Argent Probe: stopped*; `status`/`check` show lines like
`WARN mask-readback ... wrote 1 components, read back 0`; or the smoke exports look exactly like the base picture.

1. Quit Lightroom. Run `scripts/lightroom-probe/install-plugin.sh --sdk 13` (the plug-in then declares SDK 13.0; the one
   third-party plug-in known to have written tables on Lightroom 15.6 declared 13.0, the old probe declared 10.0, and whether the
   declared version matters is not known).
2. Put the finished-or-stopped jobs back, and remove the stop marker:
   `cd references/lightroom-probe/jobs && for f in m0*.processed; do mv $f ${f%.processed}.job; done; rm -f STOPPED ALLDONE`
3. Start Lightroom with the same throwaway catalog, check the plug-in is Enabled, choose the command again.
4. Still refused: **stop here, the hour is better spent on this than on more attempts.** In the same catalog, import
   nothing; instead select `m00-smoke_R-base` in the grid, switch to Develop (D), press ⇧W, make a *Linear Gradient* by
   hand with Exposure +1, and a *Radial Gradient*, then go back to Library (G). In the terminal hold the other jobs back, so the
   menu command runs only the capture, and write it:
   `cd references/lightroom-probe/jobs && for f in m0*.job; do mv $f $f.held; done; cd ../../..`
   `.venv/bin/python -I scripts/lightroom-probe/jobs.py dump capture references/lightroom-probe/inputs/m00-smoke/m00-smoke_R-base.dng`
   and choose the menu command once more. (To release the other jobs later:
   `cd references/lightroom-probe/jobs && for f in m0*.job.held; do mv $f ${f%.held}; done`.) The plug-in writes Lightroom's own table for that photo to
   `references/lightroom-probe/exports-capture/dump/`. Hand that file to the coordinator: comparing it with
   `references/lightroom-probe/mask-tables/m00-smoke/R-smoke-G1-E+1.json` shows which field Lightroom wants that the
   planner does not write. This is the one place the kit asks for a gesture, and only as a fallback.

## Running it for the owner, with no one at the keyboard

On 2026-11-06 the coordinator ran this session at the owner's request, by UI scripting from a shell that has Accessibility and Screen
Recording. It took 8 minutes of Lightroom and worked, after one mistake worth not repeating: **setting
`recentLibraryBehavior20` in `~/Library/Preferences/com.adobe.LightroomClassicCC7.plist` does nothing.** Lightroom reads its startup choice from
`~/Library/Application Support/Adobe/Lightroom/Preferences/Lightroom Classic CC 7 Startup Preferences.agprefs` and rewrites the plist from it on quit. So
that first launch opened the owner's real catalog for about two minutes. It was closed cleanly with no edits, but it broke this script's promise. The steps that held:

1. With Lightroom quit, run `prepare`, and back up both the plist (`defaults export`) and the `.agprefs` file. In the `.agprefs` file set
   `recentLibraryBehavior20 = "AlwaysPromptForLibrary"`. Do not use the plist, and do not simulate a held Option key: a missed key opens the owner's catalog.
2. Launch the binary inside a rule that makes that catalog physically unreachable, so a failed preference cannot touch it:
   `sandbox-exec -p '(version 1)(allow default)(deny file* (subpath "$HOME/Pictures/Lightroom") (subpath "/System/Volumes/Data$HOME/Pictures/Lightroom"))' "/Applications/Adobe Lightroom Classic/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic"`,
   with `$HOME` written out, since the rule is not expanded by the shell inside single quotes.
3. Check with `lsof -c 'Adobe Lightroom' | grep lrcat` which catalog is open **before** any screenshot. Capture only Lightroom's own windows (`screencapture -l <window id>`), never the screen, and never while the owner's catalog might show.
4. **Create a New Catalog…** Name it `Argent-masks-session`. The session used `references/lightroom-probe/session-catalog/` rather than the Desktop: that needs no permission prompt and stays out of Git.
5. Wait until the window's title carries the catalog's name, then choose the menu command by walking it: click **Library**, then **Plug-in Extras**, then the item. The first choice was lost in all three runs, whether it was a direct accessibility press on the nested item (run 1) or a walk (runs 2 and 3, the third with the title already changed), and the reason is not known; a second walk worked each time. So expect to choose it twice, and confirm it started by the catalog's photo count: choosing it again is harmless, since the plug-in ignores the command while it is busy.
6. Keep the Mac awake with `caffeinate -dims -w <pid>`, and watch `ALLDONE`, `STOPPED` and the export count.
7. Quit from the menu, then, before anything else, restore the `.agprefs` file and `defaults import` the plist, so the owner's next launch opens their catalog as before. Then `check`, `analyze`, `finish`.

## After the first run

The session ran on 2026-11-06: 353 items, then `m06-confirm` (88) and `m07-law` (29), all without an error. Three things changed because of it:

- **Do not trust the automatic report's one-page table.** It judges masks by the panel's curves, and Lightroom's local Whites, Blacks and Contrast are different functions, so several of its labels are wrong. The audit (`P0-L1b-audit`, in the research folder named by `docs/masking-plan.md`, section 14) lists eleven bugs with their fixes; `analyze_masks.py` still has them. `P0-L1c-arithmetic` has the final table.
- `prepare` now writes all eight jobs (470 items, about 12 minutes of Lightroom, about 20 GB of exports). To run one job: with Lightroom quit, run `install-plugin.sh`, create the `READY` file, then `.venv/bin/python -I scripts/lightroom-probe/jobs.py masks --only m07-law`.
- `m06-confirm` and `m07-law` are read by the audit's scripts and `check_m07.py`, not by `analyze_masks.py`, whose `Q` tags they avoid on purpose.

## L2: Lightroom's AI masks, for the blind A/B (run 2026-11-08)

L2 needs no one at the keyboard and it is run as the section above says, with these additions (**measured**, Lightroom Classic 15.6, on this Mac):

- The job is `MODE masks-ai` (`ArgentProbe.lrplugin/Probe.lua`, plug-in 1.3.0; `ai_masks.py job` writes it into a jobs folder of its own, `references/lightroom-probe/l2-session/jobs`, with `ARGENT_PROBE_ROOT` set for `install-plugin.sh`). The catalog is `Argent-masks-session-l2`, in `references/lightroom-probe/l2-session/catalog/`.
- **Nothing leaves the Mac, and Lightroom made its masks that way.** The `sandbox-exec` rule also has `(deny network-outbound (remote tcp "*:*") (remote udp "*:*"))(allow network-outbound (remote tcp "localhost:*") (remote udp "localhost:*"))(deny network-outbound (literal "/private/var/run/mDNSResponder"))`. On macOS 27.2, an `(allow … (remote ip "localhost:*"))` after a deny of `(remote ip "*:*")` does not let local connections through; the `tcp`/`udp` form does, tried with connect and `getaddrinfo` inside the rule before Lightroom was started. Lightroom started, showed no sign-in or network dialog, and `lsof -i` showed only `127.0.0.1` sockets at each check during the job. A helper Lightroom only talks to over local sockets is outside the rule (Creative Cloud's own processes were running, as they do on this Mac), so the rule binds Lightroom's process and its children, not the Mac.
- The plug-in's menu item is listed as "   Argent Probe: run pending jobs" with leading spaces under the plug-in's name: choose **item 2** of Plug-in Extras by index, not by name. The first choice was lost again and the second took, as in the earlier runs.
- The job asks for 17 AI masks (10 Sky, 7 Subject) on the owner's frames and adds 2 known gradients; each of the 19 is then exported in 15 states (a masked render and a full-coverage series at each of two Exposures, and the base), 285 full-size renders.
- **Two Exposures, because one cannot read both ends of the tone range.** At local -1 EV a bright sky sits in the highlight shoulder of Lightroom's rendering and moves by less than 0.15 stops, so up to about 9 % of a frame could not be measured and came out blotchy. At local -4 EV, the end of the local range, the toe clips deep shadows to exact black within a stop or two, so a dark pixel cannot be told from a deeper one (rms 0.13 of coverage below luminance 0.005, against 0.0096 at -1 EV). The job exports a series at each, and `ai_masks.py` blends them by the pixel's base luminance, -1 EV below 0.02 and -4 EV above 0.045. Two earlier runs, at one Exposure each, were discarded.
- **`defaults import` merges, it does not replace.** Keys Lightroom added during the session stay after it (here three of the Masking panel's: `AgDevelop_localizedMaskExpanded`, `AgDevelop_maskingLandscapeWalkthroughPlayed`, `maskingSS_Walkthroughs_Closed`). After the import, compare the plist with the backup (`defaults export`, then compare as plists) and `defaults delete` what is not in the backup.
- `ai_masks.py recover` inverts each pixel's full-coverage series in log luminance; `ai_masks.py validate` checks it against the Linear profile's law on known gradients on two real frames. The figures and what the blind A/B found are in Phase 4's report P, in the research folder named by `docs/masking-plan.md` section 14.

## Where things are

- `references/lightroom-probe/jobs/`: the job files and, as it goes, `.done` logs (every item, and `NOTE` lines for any
  field Lightroom changed or dropped when it read a table back), `READY`, and the markers `ALLDONE`, `STOPPED`, `STOP`.
- `references/lightroom-probe/exports-m0*/`: Lightroom's exports (16-bit ProPhoto TIFFs), plus `readback/` (what
  Lightroom kept of every table, as JSON) and `timing.tsv` (seconds per phase and per render).
- `references/lightroom-probe/masks-plan.json`: which item answers which question; `masks-report/`: the analysis.
- `references/lightroom-probe/plugin-backups/`: the plug-in that was installed before. `finish` puts it back.
