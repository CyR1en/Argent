import AppKit
import SwiftUI
import Testing
@testable import ArgentApp

/// The contact sheet's arithmetic, which puts any cell of any roll without walking the others, and its
/// file names, drawn once and kept.
@MainActor @Suite struct SheetGridTests {
    private typealias Spacing = ContactSheet.Spacing
    private let geometry = SheetGeometry(width: 1000, targetCell: 168)

    @Test func columnsShareTheRoomOnWholePoints() {
        #expect(geometry.columns == Spacing.columns(fitting: 1000 - 2 * Spacing.margin, cell: 168))
        #expect(geometry.cell >= 168)
        #expect(geometry.cell == geometry.cell.rounded())
        let last = geometry.frame(ofItem: geometry.columns - 1)
        #expect(geometry.frame(ofItem: 0).minX >= Spacing.margin)
        #expect(last.maxX <= 1000 - Spacing.margin)
        // What whole points leave over is shared either side.
        #expect(abs(geometry.frame(ofItem: 0).minX - (1000 - last.maxX)) <= 1)
    }

    @Test func aNarrowWindowStillHasOneColumnOfTheSmallestCell() {
        let narrow = SheetGeometry(width: 60, targetCell: 336)
        #expect(narrow.columns == 1)
        #expect(narrow.cell == Metrics.thumbnailWidths[0])
    }

    @Test func cellsRunInRowsOfTheColumnsCount() {
        let first = geometry.frame(ofItem: 0), next = geometry.frame(ofItem: geometry.columns)
        #expect(first.minY == Spacing.topFade)
        #expect(next.minX == first.minX)
        #expect(next.minY == first.maxY + Spacing.rowGap)
        #expect(first.height >= geometry.cell * 2 / 3 + SheetGeometry.labelGap + SheetGeometry.labelHeight)
        #expect(first.height == first.height.rounded())
    }

    @Test func theContentHoldsItsRowsBetweenTheFades() {
        #expect(geometry.contentHeight(count: 0) == Spacing.topFade + Spacing.bottomFade)
        #expect(geometry.contentHeight(count: 1) == geometry.frame(ofItem: 0).maxY + Spacing.bottomFade)
        // A part row is a row.
        let partRow = geometry.columns + 1
        #expect(geometry.contentHeight(count: partRow) == geometry.frame(ofItem: partRow - 1).maxY + Spacing.bottomFade)
    }

    @Test func aRectFindsEveryCellItTouchesAndNoRowsItDoesNot() {
        let count = 300
        for rect in [CGRect(x: 0, y: 0, width: 1000, height: 400),
                     CGRect(x: 0, y: 733, width: 1000, height: 1),
                     CGRect(x: 0, y: 2000, width: 1000, height: 900),
                     CGRect(x: 0, y: 90000, width: 1000, height: 900)] {
            let found = geometry.items(in: rect, count: count)
            let touching = (0..<count).filter { geometry.frame(ofItem: $0).intersects(rect) }
            #expect(touching.allSatisfy(found.contains), "\(rect)")
            #expect(found.upperBound <= count)
            // Whole rows, at most one more each way than those it touches.
            #expect(found.count <= touching.count + 2 * geometry.columns, "\(rect)")
        }
        #expect(geometry.items(in: .zero, count: count).isEmpty)
        #expect(geometry.items(in: CGRect(x: 0, y: 0, width: 10, height: 10), count: 0).isEmpty)
    }

    @Test func revealingMovesOnlyAsFarAsItTakesToClearTheFades() {
        let count = 300, viewport: CGFloat = 600, row = geometry.columns * 10
        let item = geometry.frame(ofItem: row)
        // Already clear of both fades: stays.
        let within = item.minY - 100
        #expect(geometry.offset(revealing: row, count: count, current: within, viewport: viewport, centered: false) == within)
        // Below: its foot clear of the lower fade.
        let above = geometry.offset(revealing: row, count: count, current: 0, viewport: viewport, centered: false)
        #expect(above == item.maxY + Spacing.bottomFade - viewport)
        // Above: its head clear of the upper one.
        let below = geometry.offset(revealing: row, count: count, current: item.minY + 500, viewport: viewport, centered: false)
        #expect(below == item.minY - Spacing.topFade)
    }

    @Test func revealingCentresWithinTheContent() {
        let count = 300, viewport: CGFloat = 600, row = geometry.columns * 10
        #expect(geometry.offset(revealing: row, count: count, current: 0, viewport: viewport, centered: true)
                == geometry.frame(ofItem: row).midY - viewport / 2)
        #expect(geometry.offset(revealing: 0, count: count, current: 500, viewport: viewport, centered: true) == 0)
        #expect(geometry.offset(revealing: count - 1, count: count, current: 0, viewport: viewport, centered: true)
                == geometry.contentHeight(count: count) - viewport)
        // A sheet shorter than the view does not scroll.
        #expect(geometry.offset(revealing: 2, count: 3, current: 0, viewport: viewport, centered: true) == 0)
    }

    @Test func aFileNameIsDrawnOnceForEachNameColourAndWidth() throws {
        let image = try #require(SheetFileName.image("DSC04050", color: .white, limit: 160, scale: 2))
        #expect(SheetFileName.image("DSC04050", color: .white, limit: 160, scale: 2) === image)
        #expect(SheetFileName.image("DSC04051", color: .white, limit: 160, scale: 2) !== image)
        #expect(SheetFileName.image("DSC04050", color: .black, limit: 160, scale: 2) !== image)
        #expect(SheetFileName.image("DSC04050", color: .white, limit: 120, scale: 2) !== image)
        #expect(image.height == Int(SheetGeometry.labelHeight * 2))
    }

    @Test func aFileNameFitsItsLimit() throws {
        let long = String(repeating: "ILCE-7M4_DSC06673_", count: 6)
        let image = try #require(SheetFileName.image(long, color: .white, limit: 120, scale: 2))
        #expect(image.width <= 240)
        #expect(SheetFileName.image("", color: .white, limit: 120, scale: 2) == nil)
        #expect(SheetFileName.image("DSC04050", color: .white, limit: 0, scale: 2) == nil)
    }
}
