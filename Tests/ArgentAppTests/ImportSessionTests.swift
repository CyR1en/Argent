import ArgentCore
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import ArgentApp
@testable import ArgentRoll

@MainActor @Suite(.serialized) struct ImportSessionTests {
    @Test func aScanMovesFromIdleThroughScanningToReviewing() async throws {
        try await Self.withCard(frames: 4) { model, card in
            #expect(model.importSession == .idle)
            #expect(model.cards == [card])
            model.startImport(card)
            #expect(model.importSession == .scanning(card: card, done: 0, of: 4))
            #expect(model.workspacePage == .importReview)
            #expect(model.cards.isEmpty)

            await model.importTask?.value
            guard case .reviewing(let review) = model.importSession else {
                Issue.record("not reviewing: \(model.importSession)")
                return
            }
            #expect(review.frames.map(\.name) == ["DSC00001", "DSC00002", "DSC00003", "DSC00004"])
            #expect(review.frames.allSatisfy { $0.frame?.url.lastPathComponent == $0.name + ".ARW" })
            #expect(review.count(.all) == 4)
        }
    }

    @Test func anOverrideFlipsOneVerdictAndTheCounts() {
        var review = Self.review()
        #expect(review.summary == "3 to import, 3 left on the card")
        #expect(review.badge("DSC1.ARW") == .reason(.failed))

        review.toggle("DSC1.ARW")
        #expect(review.isKept("DSC1.ARW"))
        #expect(review.isChanged("DSC1.ARW"))
        #expect(review.badge("DSC1.ARW") == .changedToImport)
        #expect(review.summary == "4 to import, 2 left on the card")

        review.toggle("DSC1.ARW")
        #expect(!review.isChanged("DSC1.ARW"))
        #expect(review.summary == "3 to import, 3 left on the card")
    }

    /// Several frames selected in the review: a Command-click and a Shift-click select without changing where a frame
    /// goes; a click on one of several, and Space, send them all the way that frame goes; an arrow leaves one selected.
    @Test func severalFramesAreSelectedAndSentTogether() {
        var review = Self.review()
        let ids = review.frames.map(\.id)
        review.click(ids[1], .toggle)
        #expect(review.selection == ids[1] && review.selected == [ids[1]] && review.isKept(ids[1]), "nothing selected yet: it alone, not toggled")
        review.click(ids[4], .range)
        #expect(review.selection == ids[4] && review.selectedFrames == Array(ids[1...4]))
        review.click(ids[0], .toggle)
        #expect(review.selectedFrames == Array(ids[0...4]) && review.selection == ids[0])
        review.click(ids[2], .toggle)
        #expect(review.selectedFrames == [ids[0], ids[1], ids[3], ids[4]])
        #expect(review.summary == "3 to import, 3 left on the card", "selecting sends no frame anywhere")

        // A click on one of them: DSC2 was to import, so all four are left; again, and all four are to import.
        review.click(ids[1], .alone)
        #expect([ids[0], ids[1], ids[3], ids[4]].allSatisfy { !review.isKept($0) } && review.selected.count == 4)
        #expect(review.summary == "1 to import, 5 left on the card")
        review.click(ids[1], .alone)
        #expect(review.summary == "5 to import, 1 left on the card" && review.selection == ids[1])
        // Space: the way the lead goes.
        review.toggleSelected()
        #expect(review.summary == "1 to import, 5 left on the card")
        // A click on a frame that is not one of them: it alone, sent the other way.
        review.click(ids[5], .alone)
        #expect(review.selected == [ids[5]] && !review.isKept(ids[5]))
        review.toggleSelected()
        #expect(review.isKept(ids[5]))

        // Shift with an arrow extends from where it started; an arrow alone leaves one frame.
        review.selection = ids[2]
        review.moveSelection(by: 2, extending: true)
        #expect(review.selectedFrames == Array(ids[2...4]) && review.selection == ids[4])
        review.moveSelection(by: -3, extending: true)
        #expect(review.selectedFrames == Array(ids[1...2]))
        review.selectEnd(last: true, extending: true)
        #expect(review.selectedFrames == Array(ids[2...5]))
        review.moveSelection(by: -1)
        #expect(review.selected == [ids[4]])
        review.selectAll()
        #expect(review.selected.count == 6 && review.selection == ids[4])
        #expect(review.framesActedOn(from: ids[0]).count == 6 && review.framesActedOn(from: ids[4]).count == 6)
        review.selection = ids[0]
        #expect(review.framesActedOn(from: ids[3]) == [ids[3]])
    }

    /// The frames selected that a filter leaves out leave the selection, and the review's menu sends the frames it is
    /// opened on, selecting a frame that is not one of several first.
    @Test func theFilterKeepsShownFramesSelectedAndTheMenuSendsThem() async throws {
        try await Self.withCard(frames: 4) { model, card in
            model.startImport(card)
            await model.importTask?.value
            guard case .reviewing(let first) = model.importSession else {
                Issue.record("not reviewing: \(model.importSession)")
                return
            }
            let ids = first.frames.map(\.id)
            @MainActor func review() -> ImportReview {
                if case .reviewing(let review) = model.importSession { return review }
                return first
            }
            // Every frame to import but the second, whatever the cull made of them.
            model.reviewImport { $0.setKept(true, for: ids) }
            model.reviewImport { $0.setKept(false, for: [ids[1]]) }
            model.reviewImport { $0.selection = ids[0] }
            model.reviewImport { $0.selectAll() }
            model.reviewImport { $0.show(.toImport) }
            #expect(review().selectedFrames == [ids[0], ids[2], ids[3]] && review().selection == ids[0])

            // The menu on one of the three: theirs.
            let several = ImportMenu.entries(on: ids[2], model: model)
            #expect(several.titles == ["Import 3 Frames", "Leave 3 Frames on the Card", "—", "Select All"])
            #expect(several.entry("import.take")?.isEnabled == false && several.entry("import.leave")?.isEnabled == true)
            several.entry("import.leave")?.choose()
            #expect(review().importCount == 0 && review().selected.count == 3)
            #expect(ImportMenu.entries(on: ids[2], model: model).entry("import.take")?.isEnabled == true)

            // On a frame that is not one of several: it is selected, and nothing of where it goes changes.
            model.reviewImport { $0.show(.all) }
            model.reviewImport { $0.selection = ids[0] }
            let one = ImportMenu.entries(on: ids[3], model: model)
            #expect(one.titles == ["Import", "Leave on the Card", "—", "Select All"])
            #expect(review().selection == ids[3] && review().selected == [ids[3]] && review().importCount == 0)
            one.entry("import.take")?.choose()
            #expect(review().isKept(ids[3]) && review().importCount == 1)
            // The ground: Select All alone.
            let ground = ImportMenu.entries(on: nil, model: model)
            #expect(ground.titles == ["Select All"])
            ground.entry("import.selectAll")?.choose()
            #expect(review().selected.count == 4)
        }
    }

    @Test func aFrameChangedUnderAFilterKeepsItsPlaceUntilTheFilterIsChosenAgain() {
        var review = Self.review()
        review.show(.left)
        #expect(review.shown.map(\.id) == ["DSC1.ARW", "DSC3.ARW", "DSC5.ARW"])

        review.toggle("DSC3.ARW")
        #expect(review.shown.map(\.id) == ["DSC1.ARW", "DSC3.ARW", "DSC5.ARW"])
        #expect(review.count(.left) == 2)

        review.show(.left)
        #expect(review.shown.map(\.id) == ["DSC1.ARW", "DSC5.ARW"])
        #expect(review.selection == nil)
    }

    @Test func leavingAKeeperOnTheCardLeavesItsSameMomentFramesAsTheyWere() {
        var review = Self.review()
        #expect(review.badge("DSC5.ARW") == .reason(.sameMoment(keeper: "DSC4.ARW")))

        review.toggle("DSC4.ARW")
        #expect(!review.isKept("DSC4.ARW"))
        #expect(!review.isKept("DSC5.ARW"))
        #expect(review.badge("DSC5.ARW")?.text == "Same moment as DSC4")
    }

    @Test func aChangeInSettingsJudgesTheFramesAgainAndKeepsThePhotographersChanges() {
        var review = Self.review()
        review.toggle("DSC1.ARW")
        review.toggle("DSC3.ARW")
        #expect(review.badge("DSC3.ARW") == .changedToImport)

        var loose = CullSettings()
        SoftFocusChoice.loose.apply(to: &loose)
        review.judge(with: loose)
        #expect(review.badge("DSC1.ARW") == .changedToImport)
        #expect(review.isKept("DSC3.ARW"))
        #expect(!review.isChanged("DSC3.ARW"))
        #expect(review.badge("DSC3.ARW") == nil)
        #expect(review.summary == "5 to import, 1 left on the card")

        review.judge(with: CullSettings())
        #expect(review.isKept("DSC3.ARW"))
        #expect(review.badge("DSC3.ARW") == .changedToImport)
        #expect(review.summary == "5 to import, 1 left on the card")
    }

    @Test func aFrameSentBackAndForthKeepsItsLastPlaceThroughAChangeInSettings() {
        var review = Self.review()
        var loose = CullSettings()
        SoftFocusChoice.loose.apply(to: &loose)
        review.judge(with: loose)
        review.toggle("DSC3.ARW")
        review.toggle("DSC3.ARW")
        #expect(review.isKept("DSC3.ARW"))
        #expect(!review.isChanged("DSC3.ARW"))

        review.judge(with: CullSettings())
        #expect(review.isKept("DSC3.ARW"))
        #expect(review.badge("DSC3.ARW") == .changedToImport)
    }

    @Test func aSettingChangedWhileTheCardIsReadJudgesTheReview() async throws {
        try await Self.withCard(frames: 2) { model, card in
            let saved = model.importSettings
            defer { model.importSettings = saved }
            model.importSettings.cull.failedBelow = -2
            model.startImport(card)
            model.importSettings.cull.failedBelow = 2
            await model.importTask?.value
            guard case .reviewing(let review) = model.importSession else {
                Issue.record("not reviewing: \(model.importSession)")
                return
            }
            #expect(review.summary == "0 to import, 2 left on the card")
            #expect(review.frames.map { review.badge($0.id)?.text } == ["Failed frame", "Failed frame"])
        }
    }

    @Test func readingCountsTheFramesUp() async throws {
        let frames = 2 * CardCull.lanes + 2
        try await Self.withCard(frames: frames) { model, card in
            model.startImport(card)
            #expect(ImportTopBar.subtitle(model.importSession) == "Reading \(frames) frames")
            var counts: [Int] = []
            while case .scanning(_, let done, let total) = model.importSession, total == frames {
                if counts.last != done { counts.append(done) }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(counts.first == 0)
            #expect(counts == counts.sorted())
            #expect(counts.count >= 2)
        }
    }

    @Test func eachReasonReadsOnItsBadgeAndToVoiceOver() {
        var review = Self.review()
        #expect(review.badge("DSC1.ARW")?.text == "Failed frame")
        #expect(review.badge("DSC3.ARW")?.text == "Soft focus")
        #expect(review.badge("DSC5.ARW")?.text == "Same moment as DSC4")
        #expect(Self.cellText("DSC5.ARW", in: review) == "DSC5, left on the card, Same moment as DSC4")
        #expect(Self.cellText("DSC2.ARW", in: review) == "DSC2, to import")

        review.judge(with: CullSettings(softFocusBelow: 0.2, eyesClosedBelow: 0.3))
        #expect(review.badge("DSC3.ARW")?.text == "Eyes closed")
        #expect(Self.cellText("DSC3.ARW", in: review) == "DSC3, left on the card, Eyes closed")

        review.toggle("DSC1.ARW")
        #expect(review.badge("DSC1.ARW")?.text == "To import")
        #expect(Self.cellText("DSC1.ARW", in: review) == "DSC1, to import, changed")
        review.toggle("DSC2.ARW")
        #expect(review.badge("DSC2.ARW")?.text == "Left on the card")
        #expect(Self.cellText("DSC2.ARW", in: review) == "DSC2, left on the card, changed")

        let keeper = ImportBadge.reason(.sameMoment(keeper: "DCIM/100MSDCF/DSC04433.ARW"))
        #expect(keeper.text == "Same moment as DSC04433")
    }

    @Test(arguments: [false, true]) func frameWordingMatchesTheImportSource(isFolder: Bool) throws {
        var review = Self.review(isFolder: isFolder)
        let place = isFolder ? "in the folder" : "on the card"
        let kept = try #require(Self.cellInputs("DSC2.ARW", in: review))
        #expect(kept.badge == nil)
        #expect(ImportCell.helpText(kept) == "To import. Click to leave it \(place).")
        #expect(ImportCell.accessibilityText(kept) == "DSC2, to import")

        review.toggle("DSC2.ARW")
        let left = try #require(Self.cellInputs("DSC2.ARW", in: review))
        #expect(left.badge?.text == "Left \(place)")
        #expect(ImportCell.helpText(left) == "Left \(place). Click to import it.")
        #expect(ImportCell.accessibilityText(left) == "DSC2, left \(place), changed")

        let culled = try #require(Self.cellInputs("DSC5.ARW", in: review))
        #expect(culled.badge?.text == "Same moment as DSC4")
        #expect(ImportCell.helpText(culled) == "Same moment as DSC4. Click to import it.")
        #expect(ImportCell.accessibilityText(culled) == "DSC5, left \(place), Same moment as DSC4")
    }

    @Test func theTopBarAndTheFilterSayWhatTheSpecSays() {
        let review = Self.review()
        #expect(ImportTopBar.subtitle(.scanning(card: review.card, done: 0, of: 24)) == "Reading 24 frames")
        #expect(ImportTopBar.subtitle(.scanning(card: review.card, done: 0, of: 1)) == "Reading 1 frame")
        #expect(ImportTopBar.subtitle(.reviewing(review)) == "3 to import, 3 left on the card")
        #expect(ImportTopBar.importTitle(.reviewing(review)) == "Import 3 frames")
        #expect(ImportFilter.allCases.map(\.title) == ["All", "To import", "Left on the card"])
    }

    @Test func openingARollDuringAReviewEndsTheImportAndShowsTheRoll() async throws {
        try await Self.withCard(frames: 2) { model, card in
            model.startImport(card)
            await model.importTask?.value
            await model.open(card.volume)
            #expect(model.importSession == .idle)
            #expect(model.workspacePage == .roll)
            #expect(model.roll?.frames.count == 2)
            #expect(model.cards.isEmpty)
        }
    }

    @Test func anOpenThatFailsDuringAReviewSaysWhyOnTheRollsPage() async throws {
        try await Self.withCard(frames: 2) { model, card in
            let empty = card.volume.deletingLastPathComponent().appendingPathComponent("Empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            model.startImport(card)
            await model.importTask?.value
            await model.open(empty)
            #expect(model.importSession == .idle)
            #expect(model.workspacePage == .rolls)
            #expect(model.message == "No ARW files in Empty")
            #expect(model.cards == [card])
        }
    }

    @Test func aHeaderScanThatIsCancelledReadsNoMoreHeaders() async throws {
        try await Self.withCard(frames: 4) { _, card in
            let scan = Task { () -> Roll in
                withUnsafeCurrentTask { $0?.cancel() }
                return await RollScanner.scan(card.volume)
            }
            #expect(await scan.value.frames.isEmpty)
        }
    }

    @Test func closingAScanReturnsToIdleAndOffersTheCardAgain() async throws {
        try await Self.withCard(frames: 2 * CardCull.lanes + 2) { model, card in
            model.startImport(card)
            model.closeImport()
            #expect(model.importSession == .idle)
            #expect(model.workspacePage == .rolls)
            #expect(model.cards == [card])

            await model.importTask?.value
            #expect(model.importSession == .idle)
        }
    }

    @Test func aScanClosedAndBegunAgainEndsAsTheSecondOne() async throws {
        try await Self.withCard(frames: 2 * CardCull.lanes + 2) { model, card in
            model.startImport(card)
            let first = model.importTask
            model.closeImport()
            model.startImport(card)
            await first?.value
            #expect(model.importSession.card == card)
            #expect(model.importSession != .idle)

            await model.importTask?.value
            guard case .reviewing(let review) = model.importSession else {
                Issue.record("not reviewing: \(model.importSession)")
                return
            }
            #expect(review.count(.all) == 2 * CardCull.lanes + 2)
        }
    }

    @Test func aCardEjectedDuringAScanEndsInFailedWithTheCardsName() async throws {
        try await Self.withCard(frames: 2 * CardCull.lanes + 2) { model, card in
            model.startImport(card)
            model.importCardRemoved(card.volume)
            #expect(model.importSession == .failed(card: card, message: "Card Untitled was removed"))
            #expect(model.workspacePage == .importReview)

            model.closeImport()
            try FileManager.default.removeItem(at: card.volume)
            model.startImport(card)
            await model.importTask?.value
            #expect(model.importSession == .failed(card: card, message: "Card Untitled was removed"))
            model.closeImport()
            #expect(model.cards.isEmpty)
        }
    }

    @Test func aCardThatCannotBeReadEndsInFailedWithTheConsentHint() async throws {
        try await Self.withCard(frames: 2) { model, card in
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: card.volume.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: card.volume.path) }
            model.startImport(card)
            await model.importTask?.value
            #expect(model.importSession == .failed(card: card, message: RollModel.mayNotReadText("Untitled")))
        }
    }

    @Test func aCardThatIsNotAFolderEndsInFailedWithItsName() async throws {
        try await Self.withCard(frames: 1) { model, card in
            try FileManager.default.removeItem(at: card.volume)
            try Data().write(to: card.volume)
            model.startImport(card)
            await model.importTask?.value
            #expect(model.importSession == .failed(card: card, message: "Argent could not read Untitled"))
        }
    }

    @Test func aCardWhoseFoldersCannotBeListedIsNotImportedAndSaysWhy() async throws {
        try await Self.withCard(frames: 1) { model, card in
            let unlisted = Card(volume: card.volume, name: "Untitled", rawCount: nil)
            #expect(!model.canImport(unlisted))
            #expect(model.importHelp(unlisted) == RollModel.mayNotReadText("Untitled"))
            model.startImport(unlisted)
            #expect(model.importSession == .idle)
        }
    }

    @Test func aCopyMovesFromReviewingThroughCopyingAndFinishedToTheRoll() async throws {
        try await Self.withCopy(frames: 4) { model, card, folder in
            let review = try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            let states = await Self.follow(model)
            #expect(states.first == .copying(review, folder: folder, done: 0, of: 4))
            #expect(states.dropLast(2).last == .copying(review, folder: folder, done: 4, of: 4))
            #expect(states.suffix(2) == [.finished(card: card, folder: folder, new: 4, of: 4), .idle])
            let counts = states.compactMap { state -> Int? in if case .copying(_, _, let done, _) = state { done } else { nil } }
            #expect(counts == counts.sorted())

            // The copy went on behind the Rolls page; the roll joins the library as imported, and is not opened over it.
            #expect(model.workspacePage == .rolls)
            #expect(model.roll == nil)
            let entry = try #require(model.library.first)
            #expect(model.library.count == 1 && entry.path == folder.canonicalPath && entry.name == "2026-11-11")
            #expect(entry.origin == .imported && entry.source == "Untitled" && entry.frameCount == 4)
            let notice = try #require(model.importNotice)
            #expect(notice.roll == entry.id && notice.folder.canonicalPath == folder.canonicalPath)
            #expect(notice.copied == 4 && notice.left == 0 && !notice.isFolder && notice.ejectable == nil)
            #expect(notice.text == "4 frames imported into 2026-11-11")

            // Open roll on the notice opens it.
            model.importNotice = nil
            model.openLibraryRoll(id: entry.id)
            for _ in 0..<500 where model.roll == nil || model.isScanning { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.workspacePage == .roll)
            #expect(model.roll?.folder.canonicalPath == folder.canonicalPath)
            #expect(model.roll?.frames.map(\.url.lastPathComponent) == ["DSC00001.ARW", "DSC00002.ARW", "DSC00003.ARW", "DSC00004.ARW"])
            for number in 1...4 {
                let name = String(format: "DCIM/100MSDCF/DSC%05d.ARW", number)
                #expect(try Data(contentsOf: folder.appendingPathComponent((name as NSString).lastPathComponent))
                        == Data(contentsOf: card.volume.appendingPathComponent(name)))
            }
        }
    }

    @Test func aSecondImportOfTheCardFindsEveryFrameThereAndKeepsOneRoll() async throws {
        try await Self.withCopy(frames: 3) { model, card, folder in
            try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            await model.importTask?.value

            try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            let states = await Self.follow(model)
            #expect(states.suffix(2) == [.finished(card: card, folder: folder, new: 0, of: 3), .idle])
            #expect(model.library.count == 1 && model.library.first?.frameCount == 3)
            #expect(model.importNotice?.copied == 3)
        }
    }

    @Test(arguments: [false, true])
    func aConflictComesBackToTheReviewNamingTheFrameAndKeepsTheOthersCopied(sameSize: Bool) async throws {
        try await Self.withCopy(frames: 4) { model, card, folder in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let other = folder.appendingPathComponent("DSC00002.ARW")
            var conflict = Data("another frame".utf8)
            if sameSize {
                let raw = card.volume.appendingPathComponent("DCIM/100MSDCF/DSC00002.ARW")
                conflict = try Data(contentsOf: raw)
                conflict[conflict.startIndex] ^= 1
                let verified = card.volume.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
                try FileManager.default.copyItem(at: verified, to: folder.appendingPathComponent(verified.lastPathComponent))
            }
            try conflict.write(to: other)
            let chosen = try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            await model.importTask?.value

            let review = try #require(model.importSession.review, "not reviewing: \(model.importSession)")
            #expect(review.keepers == chosen.keepers)
            let message = "\(DevelopStatusText.abbreviated(folder)) already holds a different DSC00002.ARW: move it away, then import again"
            #expect(review.stop?.failure == message)
            #expect(review.stop?.text == message + ". 3 frames are in 2026-11-11 already, and Import copies only the rest")
            #expect(review.stop?.imported == ImportedFrames(count: 3, folder: folder))
            #expect(model.workspacePage == .importReview)
            #expect(try Data(contentsOf: other) == conflict)
            #expect(model.roll == nil)

            try FileManager.default.removeItem(at: other)
            model.startCopy()
            let states = await Self.follow(model)
            #expect(states.suffix(2) == [.finished(card: card, folder: folder, new: 1, of: 4), .idle])
        }
    }

    @Test func aSameSizeConflictAloneDoesNotClaimAnyFramesAlreadyImported() async throws {
        try await Self.withCopy(frames: 1) { model, card, folder in
            let raw = card.volume.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW")
            var conflict = try Data(contentsOf: raw)
            conflict[conflict.startIndex] ^= 1
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let other = folder.appendingPathComponent(raw.lastPathComponent)
            try conflict.write(to: other)
            try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            await model.importTask?.value

            let stop = try #require(model.importSession.review?.stop)
            #expect(stop.text == "\(DevelopStatusText.abbreviated(folder)) already holds a different DSC00001.ARW: move it away, then import again")
            #expect(stop.imported == nil)
            #expect(try Data(contentsOf: other) == conflict)
        }
    }

    @Test func aCancelledCopyComesBackToTheReviewAsItWasAndImportCopiesTheRest() async throws {
        try await Self.withCopy(frames: 10) { model, card, folder in
            model.importSettings.cull.failedBelow = 2
            let copy = model.keeperCopy
            model.keeperCopy = Self.holding(at: "DSC00002.ARW", copy)
            let chosen = try await Self.reviewKeepingEveryFrame(card, on: model)
            #expect(chosen.importCount == 10)
            #expect(chosen.frames.allSatisfy { chosen.isChanged($0.id) })
            model.startCopy()
            let task = model.importTask
            await Self.copied(atLeast: 1, by: model)
            model.cancelCopy()
            await task?.value

            let review = try #require(model.importSession.review, "not reviewing: \(model.importSession)")
            #expect(review.importCount == 10)
            #expect(review.frames.allSatisfy { review.isChanged($0.id) })
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(!names.contains { $0.contains(".partial-") })
            #expect((1..<10).contains(names.count))
            #expect(review.stop?.imported == ImportedFrames(count: names.count, folder: folder))
            #expect(review.stop?.text == "\(RollModel.framesText(names.count)) \(names.count == 1 ? "is" : "are") in 2026-11-11 already, "
                    + "and Import copies only the rest")
            #expect(model.cards.isEmpty)

            model.keeperCopy = copy
            model.startCopy()
            let states = await Self.follow(model)
            #expect(states.suffix(2) == [.finished(card: card, folder: folder, new: 10 - names.count, of: 10), .idle])
            #expect(model.library.first?.frameCount == 10)
        }
    }

    @Test func aCardEjectedWhileCopyingEndsInFailedAndSaysWhatIsInTheFolder() async throws {
        try await Self.withCopy(frames: 10) { model, card, folder in
            model.keeperCopy = Self.holding(at: "DSC00002.ARW", model.keeperCopy)
            try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            let task = model.importTask
            await Self.copied(atLeast: 1, by: model)
            try FileManager.default.removeItem(at: card.volume)
            model.importCardRemoved(card.volume)
            await task?.value
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(!names.contains { $0.contains(".partial-") })
            #expect(model.importSession == .failed(card: card, message: "Card Untitled was removed",
                                                   imported: ImportedFrames(count: names.count, folder: folder)))
        }
    }

    @Test func aFrameThatLandsAsTheCardIsEjectedIsCounted() async throws {
        try await Self.withCopy(frames: 1) { model, card, folder in
            let copy = model.keeperCopy
            model.keeperCopy = { raws, destination, progress in
                try await copy(raws, destination) { raw, outcome in
                    await MainActor.run {
                        try? FileManager.default.removeItem(at: card.volume)
                        model.importCardRemoved(card.volume)
                    }
                    await progress(raw, outcome)
                }
            }
            try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            await model.importTask?.value
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["DSC00001.ARW"])
            #expect(model.importSession == .failed(card: card, message: "Card Untitled was removed",
                                                   imported: ImportedFrames(count: 1, folder: folder)))
        }
    }

    @Test func aCardPulledMidCopyIsRemovedAtOnceThoughItsMountPointStays() async throws {
        try await Self.withCopy(frames: 2) { model, card, folder in
            model.keeperCopy = { raws, _, _ in
                try FileManager.default.moveItem(at: card.volume, to: card.volume.deletingLastPathComponent().appendingPathComponent("Pulled"))
                try FileManager.default.createDirectory(at: card.volume, withIntermediateDirectories: false)
                throw KeeperCopy.Stopped(raw: raws[0], outcome: .failed(.unreadable("Device not configured")))
            }
            try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            await model.importTask?.value
            #expect(model.importSession == .failed(card: card, message: "Card Untitled was removed"))
        }
    }

    enum CopyStop: CaseIterable {
        case unreadable, changedWhileRead, readBackMismatch, unwritable, unreadableBeforeAnyCopy, unwritableBeforeAnyCopy, folderOnCard
    }

    @Test(arguments: CopyStop.allCases)
    func aCopyThatStopsSaysWhyInTheSpecsWords(_ stop: CopyStop) async throws {
        try await Self.withCopy(frames: 2) { model, card, folder in
            let raw = card.volume.appendingPathComponent("DCIM/100MSDCF/DSC00002.ARW"), place = DevelopStatusText.abbreviated(folder)
            let (error, expected): (any Error, String) = switch stop {
            case .unreadable:
                (KeeperCopy.Stopped(raw: raw, outcome: .failed(.unreadable("Input/output error"))), "Argent could not read DSC00002 on Untitled")
            case .changedWhileRead:
                (KeeperCopy.Stopped(raw: raw, outcome: .failed(.changedWhileRead)), "DSC00002 changed on Untitled while Argent copied it: import again")
            case .readBackMismatch:
                (KeeperCopy.Stopped(raw: raw, outcome: .failed(.readBackMismatch)),
                 "The copy of DSC00002 in \(place) does not match the frame on Untitled: import again")
            case .unwritable:
                (KeeperCopy.Stopped(raw: raw, outcome: .failed(.unwritable("No space left on device"))),
                 "Argent could not write to \(place): No space left on device")
            case .unreadableBeforeAnyCopy:
                (KeeperCopy.Failure.unreadable("DSC00002.ARW: Operation not permitted"), "Argent could not read Untitled")
            case .unwritableBeforeAnyCopy:
                (KeeperCopy.Failure.unwritable("The volume is read only."), "Argent could not write to \(place): The volume is read only.")
            case .folderOnCard:
                (KeeperCopy.Failure.folderOnCard(folder.path), "Argent never writes to the card: choose another folder in Copy to")
            }
            model.keeperCopy = { _, _, _ in throw error }
            try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            await model.importTask?.value
            #expect(model.importSession.review?.stop?.failure == expected)
        }
    }

    @Test func aFinishedImportLeavesItsCardToFileImportCardButOffersItNotOverTheRoll() async throws {
        try await Self.withCopy(frames: 2) { model, card, folder in
            try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            _ = await Self.follow(model)
            #expect(model.library.first?.path == folder.canonicalPath)
            #expect(model.offeredCard == nil)
            #expect(model.menuState.card == "Untitled")
            #expect(model.menuState.canImportCard)
        }
    }

    /// An import leaves the roll open now as it was: its copy goes on behind the Rolls page, and the roll is one click back.
    @Test func anImportLeavesTheRollOpenNowAsItWas() async throws {
        try await Self.withCopy(frames: 2) { model, card, folder in
            let other = card.volume.deletingLastPathComponent().appendingPathComponent("Other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: card.volume.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW"),
                                             to: other.appendingPathComponent("DSC00001.ARW"))
            await model.open(other)
            if let restore = model.manualRestoreTask { await restore.value }

            try await Self.reviewKeepingEveryFrame(card, on: model)
            #expect(model.workspacePage == .importReview)
            model.startCopy()
            #expect(model.workspacePage == .rolls)
            // The roll open now can be shown while the copy goes on; Close on a copy does nothing.
            model.showRoll()
            #expect(model.workspacePage == .roll)
            model.closeImport()
            #expect(model.importSession.isCopying)
            _ = await Self.follow(model)
            #expect(model.importSession == .idle)
            #expect(model.roll?.folder.canonicalPath == other.canonicalPath)
            #expect(model.importNotice?.folder.canonicalPath == folder.canonicalPath)
            #expect(Set(model.library.map(\.name)) == ["Other", "2026-11-11"])
        }
    }

    /// A folder without raws gives no import, as it gives no roll.
    @Test func aFolderWithoutRawsGivesNoReview() async throws {
        try await Self.withCard(frames: 1) { model, card in
            let empty = card.volume.deletingLastPathComponent().appendingPathComponent("Empty")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            model.startImport(folder: empty)
            await model.importTask?.value
            #expect(model.importSession == .idle)
            #expect(model.workspacePage == .rolls)
            #expect(model.message == "No ARW files in Empty")
            #expect(!model.importsFolder)
        }
    }

    /// An import into the roll open now leaves it as it was: the frame open and its selection stay, and the roll is not read again.
    @Test func anImportIntoTheRollOpenNowLeavesItAsItWas() async throws {
        try await Self.withCopy(frames: 2) { model, card, folder in
            try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            _ = await Self.follow(model)
            model.openLibraryRoll(id: try #require(model.library.first?.id))
            for _ in 0..<500 where model.roll == nil || model.isScanning { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.roll != nil && !model.isScanning)
            model.openFrame()
            let selection = model.selection

            try await Self.reviewKeepingEveryFrame(card, on: model)
            model.startCopy()
            _ = await Self.follow(model)
            #expect(model.isFrameOpen)
            #expect(model.selection == selection)
            #expect(model.roll?.folder.canonicalPath == folder.canonicalPath)
        }
    }

    /// A roll is dated by the first of the frames imported, not the first on the card.
    @Test func anImportedRollIsDatedByTheFramesImported() async throws {
        try await Self.withCopy(frames: 3) { model, card, _ in
            let review = try await Self.reviewKeepingEveryFrame(card, on: model)
            let first = try #require(review.firstCaptureDate)
            model.reviewImport { $0.toggle(review.frames[0].id) }
            model.startCopy()
            _ = await Self.follow(model)
            #expect(try #require(model.library.first?.firstCapture) > first)
        }
    }

    /// Cull off: every frame is to import and none has a reason; on again, the frames are judged as before, and the
    /// photographer's own changes stay throughout. Kept for the next import.
    @Test func cullOffImportsEveryFrameAndOnAgainJudgesThemAsBefore() throws {
        let saved = UserDefaults.standard.data(forKey: ImportSettings.key)
        defer { UserDefaults.standard.set(saved, forKey: ImportSettings.key) }
        var review = Self.review()
        let judged = review.importCount
        #expect(judged < review.frames.count)
        review.toggle("DSC4.ARW")
        let mine = review.isKept("DSC4.ARW")
        review.judge(with: CullSettings(), culling: false)
        #expect(review.frames.allSatisfy { review.isKept($0.id) || $0.id == "DSC4.ARW" })
        #expect(review.isKept("DSC4.ARW") == mine)
        #expect(review.frames.allSatisfy { review.badge($0.id) == nil || review.isChanged($0.id) })
        review.judge(with: CullSettings(), culling: true)
        #expect(review.isKept("DSC4.ARW") == mine)

        var settings = ImportSettings()
        #expect(settings.isCulling)
        settings.isCulling = false
        let defaults = ScratchDefaults()
        settings.save(to: defaults)
        #expect(!ImportSettings(defaults: defaults).isCulling)
    }

    @Test func theRollIsNamedForItsFirstDayUntilRenamedAndItsFolderTakesTheName() {
        var review = Self.review()
        let day = ImportReview.defaultName(firstCapture: review.firstCaptureDate)
        #expect(review.name == day && review.folderName == day)
        review.name = "  Saturday market "
        #expect(review.folderName == "Saturday market")
        review.name = "a/b:c"
        #expect(review.folderName == "a-b-c")
        review.name = " .hidden"
        #expect(review.folderName == "hidden")
        review.name = "   "
        #expect(review.folderName == day)
        #expect(ImportReview.defaultName(firstCapture: Date(timeIntervalSince1970: 1_800_000_000)) == "2027-01-15")
    }

    enum SourceMount: CaseIterable {
        case unchanged, unmountedDuringEject, missing, replaced, reportedUnmount, unidentified
    }

    @Test(arguments: SourceMount.allCases) func importNoticeOnlyEjectsItsSource(_ mount: SourceMount) async throws {
        try await Self.withCopy(frames: 1) { model, card, _ in
            model.importSettings.isCulling = false
            let source = card.volume.appendingPathComponent("DCIM/100MSDCF")
            let identity = Mutex<String?>(mount == .unidentified ? nil : "source")
            let ejected = Mutex<[URL]>([])
            let release = DispatchSemaphore(value: 0)
            let (started, signal) = AsyncStream<Void>.makeStream()
            model.importSourceVolume = { $0 == source ? card.volume : nil }
            model.importVolumeID = { url in url == card.volume ? identity.withLock { $0 } : nil }
            model.ejectVolume = { volume in
                ejected.withLock { $0.append(volume) }
                if mount == .unmountedDuringEject {
                    signal.yield(())
                    release.wait()
                }
            }
            model.startImport(folder: source)
            await model.importTask?.value
            try #require(model.importSession.review?.canCopy == true)
            model.startCopy()
            await model.importTask?.value
            let notice = try #require(model.importNotice)
            let roll = try #require(notice.roll)
            #expect((notice.ejectable != nil) == (mount != .unidentified))

            switch mount {
            case .unchanged, .unmountedDuringEject, .unidentified: break
            case .missing: identity.withLock { $0 = nil }
            case .replaced: identity.withLock { $0 = "replacement" }
            case .reportedUnmount:
                model.importCardRemoved(card.volume)
                #expect(model.importNotice?.ejectable == nil)
                // Even if the same disk has already come back, its old action is gone.
            }
            let work = model.ejectImportSource()
            if mount == .unmountedDuringEject {
                Task {
                    await work?.value
                    signal.finish()
                }
                for await _ in started {
                    model.importCardRemoved(card.volume)
                    #expect(model.importNotice?.ejectable == nil)
                    release.signal()
                    break
                }
            }
            await work?.value
            let succeeded = mount == .unchanged || mount == .unmountedDuringEject
            #expect(ejected.withLock { $0 } == (succeeded ? [card.volume] : []))
            if succeeded {
                #expect(model.importNotice == nil)
            } else {
                #expect(model.importNotice?.ejectable == nil)
                #expect(model.importNotice?.text == notice.text)
                #expect(model.importNotice?.roll == roll)
            }
        }
    }

    /// A folder chosen in the panel is imported as a card is: its frames are "left in the folder", its roll may be on its
    /// own disk, and the notice offers no eject for a folder on the startup disk.
    @Test func aFolderIsImportedAsACardIsIntoANewRoll() async throws {
        let saved = UserDefaults.standard.data(forKey: ImportSettings.key)
        defer { UserDefaults.standard.set(saved, forKey: ImportSettings.key) }
        try await Self.withCard(frames: 3) { model, card in
            let source = card.volume.appendingPathComponent("DCIM/100MSDCF")
            let parent = card.volume.deletingLastPathComponent().appendingPathComponent("Rolls", isDirectory: true)
            model.importSettings.destination = .folder(parent)
            model.importSettings.isCulling = false
            model.startImport(folder: source)
            await model.importTask?.value
            let review = try #require(model.importSession.review, "not reviewing: \(model.importSession)")
            #expect(review.isFolder && review.card.name == "100MSDCF" && review.importCount == 3)
            #expect(review.summary == "All 3 to import")
            #expect(ImportFilter.left.title(isFolder: true) == "Left in the folder")
            model.reviewImport { $0.toggle($0.frames[0].id) }
            #expect(model.importSession.review?.summary == "2 to import, 1 left in the folder")
            model.reviewImport { $0.name = "Market" }
            model.startCopy()
            _ = await Self.follow(model)
            let roll = parent.appendingPathComponent("Market", isDirectory: true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: roll.path).sorted() == ["DSC00002.ARW", "DSC00003.ARW"])
            let entry = try #require(model.library.first)
            #expect(entry.name == "Market" && entry.origin == .imported && entry.source == "100MSDCF" && entry.frameCount == 2)
            let notice = try #require(model.importNotice)
            #expect(notice.isFolder && notice.ejectable == nil)
            #expect(notice.text == "2 frames imported into Market · 1 left in the folder")
            // A folder is not a card: nothing is offered for it, and the card's offer is as it was.
            #expect(!model.importsFolder && model.importedCards.isEmpty)
        }
    }

    /// The roll's folder may not be the folder the frames are in.
    @Test func aRollIsNeverMadeInTheFolderItsFramesAreIn() async throws {
        try await Self.withCard(frames: 1) { model, card in
            let source = card.volume.appendingPathComponent("DCIM/100MSDCF")
            let saved = UserDefaults.standard.data(forKey: ImportSettings.key)
            defer { UserDefaults.standard.set(saved, forKey: ImportSettings.key) }
            model.importSettings.destination = .folder(source.deletingLastPathComponent())
            model.importSettings.isCulling = false
            model.startImport(folder: source)
            await model.importTask?.value
            model.reviewImport { $0.name = "100MSDCF" }
            model.startCopy()
            #expect(model.importSession.review?.stop?.failure == "100MSDCF is the folder the frames are in: name the roll otherwise")
        }
    }

    @Test func theCopyAndItsEndsSayWhatTheSpecSays() {
        let folder = RollModel.argentPictures.appendingPathComponent("2026-10-24", isDirectory: true)
        #expect(ImportTopBar.copyingText(0, of: 15) == "Copying 1 of 15")
        #expect(ImportTopBar.copyingText(14, of: 15) == "Copying 15 of 15")
        #expect(ImportTopBar.copyingText(15, of: 15) == "Copying 15 of 15")
        #expect(ImportTopBar.openingText(folder) == "Opening 2026-10-24…")
        #expect(ImportTopBar.newText(15, of: 15) == "15 frames copied")
        #expect(ImportTopBar.newText(1, of: 1) == "1 frame copied")
        #expect(ImportTopBar.newText(11, of: 15) == "11 frames copied, 4 there already")
        #expect(ImportTopBar.newText(0, of: 15) == "All 15 frames were there already")
        #expect(ImportTopBar.newText(0, of: 1) == "The frame was there already")
        #expect(ImportTopBar.keptText(ImportedFrames(count: 1, folder: folder))
                == "1 frame is in ~/Pictures/Argent/2026-10-24 and stays there. Nothing on the card was changed.")
        #expect(ImportTopBar.keptText(ImportedFrames(count: 13, folder: folder))
                == "13 frames are in ~/Pictures/Argent/2026-10-24 and stay there. Nothing on the card was changed.")
        #expect(ImportTopBar.keptText(nil) == "Nothing was imported, and nothing on the card was changed.")
        let card = Card(volume: URL(fileURLWithPath: "/Volumes/Untitled"), name: "Untitled", rawCount: 24)
        #expect(RollModel.removedText(card) == "Card Untitled was removed")
        #expect(RollModel.removedText(card, isFolder: true) == "Untitled was removed")
        #expect(ImportTopBar.subtitle(.failed(card: card, message: "Card Untitled was removed")) == "Nothing imported")
        #expect(ImportTopBar.subtitle(.failed(card: card, message: "Card Untitled was removed", imported: ImportedFrames(count: 13, folder: folder)))
                == "13 frames in 2026-10-24")
    }

    #if DEBUG
    @Test func theDriveHookTimesACopyThatStops() {
        let review = Self.review()
        for end in [ImportSession.failed(card: review.card, message: "Card Untitled was removed"), .reviewing(review), .idle] {
            let trail = Automation.ImportTrail()
            #expect(!trail.keepsFollowing(end))
            #expect(trail.copySeconds != nil, "\(end)")
        }
    }
    #endif

    @Test func importCopiesToADayInPicturesAsTheCamerasClockReadIt() throws {
        let late = try #require(ISO8601DateFormatter().date(from: "2026-11-11T23:30:00Z"))
        let review = Self.review(dates: [late.addingTimeInterval(3600), late])
        #expect(RollModel.picturesFolder(for: review) == RollModel.argentPictures.appendingPathComponent("2026-11-11", isDirectory: true))
        let home = try #require(getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) })
        #expect(RollModel.argentPictures.path == home + "/Pictures/Argent")
    }

    @Test func twoFramesToImportUnderOneNameAreNotCopied() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let inputs = ["DCIM/100MSDCF/DSC00001.ARW", "DCIM/101MSDCF/DSC00001.ARW"].enumerated().map { index, path in
            CullInput(path: path, captureDate: date.addingTimeInterval(Double(index)),
                      scores: PreviewScores(faceQuality: 0.5, aesthetics: 0.5, featurePrint: index == 0 ? [1, 0] : [0, 1]))
        }
        let card = Card(volume: URL(fileURLWithPath: "/Volumes/Untitled"), name: "Untitled", rawCount: 2)
        var review = ImportReview(card: card, frames: inputs, headers: [], settings: CullSettings())
        #expect(review.importCount == 2)
        #expect(review.clash == "DSC00001")
        #expect(!review.canCopy)
        #expect(ImportTopBar.subtitle(.reviewing(review)) == "Two frames to import are named DSC00001: leave one out")

        review.toggle("DCIM/101MSDCF/DSC00001.ARW")
        #expect(review.clash == nil)
        #expect(review.canCopy)
    }

    @Test func aChosenFolderRenamedSinceIsFoundUnderItsNewName() async throws {
        try await Self.withCopy(frames: 1) { model, card, folder in
            let parent = folder.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            model.setImportDestination(.folder(parent))
            let renamed = parent.deletingLastPathComponent().appendingPathComponent("Renamed")
            try FileManager.default.moveItem(at: parent, to: renamed)
            for run in ["found through its bookmark", "found again under the path Copy to took"] {
                try await Self.reviewKeepingEveryFrame(card, on: model)
                model.startCopy()
                _ = await Self.follow(model)
                #expect(model.library.first?.path == renamed.appendingPathComponent("2026-11-11").canonicalPath, "\(run)")
                let chosen: URL? = if case .folder(let chosen) = model.importSettings.destination { chosen } else { nil }
                #expect(chosen?.canonicalPath == renamed.canonicalPath, "\(run)")
            }
        }
    }

    @discardableResult
    private static func reviewKeepingEveryFrame(_ card: Card, on model: RollModel) async throws -> ImportReview {
        model.startImport(card)
        await model.importTask?.value
        let review = try #require(model.importSession.review, "not reviewing: \(model.importSession)")
        for frame in review.frames where !review.isKept(frame.id) { model.reviewImport { $0.toggle(frame.id) } }
        return try #require(model.importSession.review)
    }

    private static func follow(_ model: RollModel) async -> [ImportSession] {
        var states = [model.importSession]
        let limit = ContinuousClock.now + .seconds(60)
        following: while ContinuousClock.now < limit {
            await Task.yield()
            let state = model.importSession
            if states.last != state { states.append(state) }
            switch state {
            case .scanning, .copying, .finished: continue
            case .idle, .reviewing, .failed: break following
            }
        }
        if let restore = model.manualRestoreTask { await restore.value }
        return states
    }

    private static func copied(atLeast count: Int, by model: RollModel) async {
        let limit = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < limit {
            if case .copying(_, _, let done, _) = model.importSession, done >= count { return }
            await Task.yield()
        }
    }

    private static func holding(at name: String, _ copy: @escaping CopyKeepers) -> CopyKeepers {
        { raws, folder, progress in
            try await copy(raws, folder) { raw, outcome in
                await progress(raw, outcome)
                if raw.lastPathComponent == name { try? await Task.sleep(for: .seconds(60)) }
            }
        }
    }

    private static func withCopy(frames: Int, _ body: (RollModel, Card, URL) async throws -> Void) async throws {
        let saved = UserDefaults.standard.data(forKey: ImportSettings.key)
        defer { UserDefaults.standard.set(saved, forKey: ImportSettings.key) }
        try await withCard(frames: frames) { model, card in
            // Import makes the roll's folder, named for its first frame's day, in the folder chosen.
            let parent = card.volume.deletingLastPathComponent().appendingPathComponent("Imported", isDirectory: true)
            model.importSettings.destination = .folder(parent)
            model.importSettings.isCulling = true
            model.keeperCopy = { try await KeeperCopy.run($0, to: $1, refusing: [], progress: $2) }
            try await body(model, card, parent.appendingPathComponent("2026-11-11", isDirectory: true))
        }
    }

    private static func review(isFolder: Bool = false) -> ImportReview {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func input(_ number: Int, seconds: Double, face: Double?, aesthetics: Double = 0.5, print: [Float]) -> CullInput {
            CullInput(path: "DSC\(number).ARW", captureDate: start.addingTimeInterval(seconds),
                      scores: PreviewScores(faceQuality: face, aesthetics: aesthetics, featurePrint: print))
        }
        let inputs = [
            input(1, seconds: 0, face: 0.5, aesthetics: -0.1, print: [1, 0, 0, 0]),
            input(2, seconds: 10, face: 0.5, print: [0, 1, 0, 0]),
            input(3, seconds: 20, face: 0.25, print: [0, 0, 1, 0]),
            input(4, seconds: 30, face: 0.6, print: [0, 0, 0, 1]),
            input(5, seconds: 30.1, face: 0.5, print: [0, 0, 0.1, 1]),
            input(6, seconds: 40, face: nil, print: [1, 1, 0, 0]),
        ]
        let card = Card(volume: URL(fileURLWithPath: "/Volumes/Untitled"), name: "Untitled", rawCount: inputs.count)
        return ImportReview(card: card, frames: inputs, headers: [], settings: CullSettings(), isFolder: isFolder)
    }

    private static func cellText(_ id: ImportFrame.ID, in review: ImportReview) -> String? {
        cellInputs(id, in: review).map(ImportCell.accessibilityText)
    }

    private static func cellInputs(_ id: ImportFrame.ID, in review: ImportReview) -> ImportCellInputs? {
        review.frames.first { $0.id == id }.map { ImportCellInputs(frame: $0, review: review, width: 160) }
    }

    private static func review(dates: [Date]) -> ImportReview {
        let inputs = dates.enumerated().map { index, date in
            CullInput(path: "DSC\(index).ARW", captureDate: date, scores: PreviewScores(faceQuality: 0.5, aesthetics: 0.5, featurePrint: [1]))
        }
        let card = Card(volume: URL(fileURLWithPath: "/Volumes/Untitled"), name: "Untitled", rawCount: inputs.count)
        return ImportReview(card: card, frames: inputs, headers: [], settings: CullSettings())
    }

    private static func withCard(frames: Int, _ body: (RollModel, Card) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("argent-import-\(UUID().uuidString)")
        let volume = folder.appendingPathComponent("Untitled"), library = folder.appendingPathComponent("Library")
        let dcim = volume.appendingPathComponent("DCIM/100MSDCF")
        for directory in [dcim, library] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: folder) }
        for number in 1...frames {
            try Data(previewARW(captured: String(format: "2026:11:11 10:%02d:%02d", number / 60, number % 60),
                                shade: Double(number) / Double(frames)))
                .write(to: dcim.appendingPathComponent(String(format: "DSC%05d.ARW", number)))
        }
        let model = RollModel(bookmarks: BookmarkStore(file: folder.appendingPathComponent("bookmarks.json"), securityScoped: false),
                              stocksDirectory: library, decisions: AutoDecisionStore(library: library), flagStore: FlagStore(library: library),
                              recipeLibrary: library, previewCache: folder.appendingPathComponent("Linear Previews"), digestsFile: nil)
        let card = Card(volume: volume, name: "Untitled", rawCount: frames)
        model.offer(card, announce: false)
        try await body(model, card)
        model.closeImport()
        await model.flagSave?.value
    }

    private static func previewARW(captured: String, shade: Double) -> [UInt8] {
        let width = 160, height = 120
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let jpegData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpegData, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        let jpeg = [UInt8](jpegData as Data)

        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) } }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: [UInt8]) -> [UInt8] {
            u16(tag) + u16(type) + u32(count) + value + [UInt8](repeating: 0, count: 4 - value.count)
        }
        let ifd0 = 8, exif = ifd0 + 2 + 3 * 12 + 4
        let date = Array(captured.utf8) + [0]
        let dateOffset = exif + 2 + 12 + 4
        let jpegOffset = dateOffset + date.count + date.count % 2
        return [0x49, 0x49] + u16(42) + u32(ifd0)
            + u16(3) + entry(0x0201, 4, 1, u32(jpegOffset)) + entry(0x0202, 4, 1, u32(jpeg.count)) + entry(0x8769, 4, 1, u32(exif)) + u32(0)
            + u16(1) + entry(0x9003, 2, date.count, u32(dateOffset)) + u32(0)
            + date + (date.count % 2 == 1 ? [0] : []) + jpeg
    }
}

private extension ImportSession {
    var review: ImportReview? {
        if case .reviewing(let review) = self { review } else { nil }
    }
}
