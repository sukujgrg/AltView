import XCTest
import AppKit
@testable import AltView

final class RendererTests: XCTestCase {
    func testFullCanvasHiddenLabelsReclaimSpaceEvenWhenEmptyRowsAreReserved() {
        var style = OutputStyle(); style.position = .top; style.heightFraction = 0.3
        for behavior in [EmptyRegionBehavior.collapse, .reserve] {
            var content = DisplayContent(title: "Title", body: String(repeating: "Body line\n", count: 12), footer: "Footer")
            content.emptyRegions = behavior
            let allVisible = CanvasTextLayout.make(content: content, style: style)
            for title in [true, false] {
                for footer in [true, false] {
                    var template = LowerThirdTemplate()
                    template.showsTitle = title; template.showsFooter = footer
                    let layout = CanvasTextLayout.make(content: content, style: style, template: template)
                    XCTAssertEqual(layout.title.height > 0, title)
                    XCTAssertEqual(layout.footer.height > 0, footer)
                    if !title { XCTAssertEqual(layout.body.minY, 54, accuracy: 0.01) }
                    if !footer { XCTAssertEqual(layout.footer.minY, layout.body.maxY, accuracy: 0.01) }
                    if !title || !footer { XCTAssertGreaterThan(layout.bodyFontSize, allVisible.bodyFontSize) }
                    XCTAssertLessThanOrEqual(layout.footer.maxY, 54 + 972 * 0.3 + 1)
                }
            }
        }
    }
    func testEmptyFullScreenRowsCollapseOrReserveOneLineAndGap() {
        var style = OutputStyle(); style.position = .top; style.heightFraction = 0.3
        let text = String(repeating: "Body line\n", count: 12)
        for (title, footer) in [("", ""), ("Title", ""), ("", "Footer"), (" \n", "\t")] {
            let content = DisplayContent(title: title, body: text, footer: footer)
            let collapsed = CanvasTextLayout.make(content: content, style: style)
            XCTAssertEqual(collapsed.title.height > 0, content.hasTitle)
            XCTAssertEqual(collapsed.footer.height > 0, content.hasFooter)
            var reserve = content; reserve.emptyRegions = .reserve
            let reserved = CanvasTextLayout.make(content: reserve, style: style)
            XCTAssertGreaterThan(reserved.title.height, 0)
            XCTAssertGreaterThan(reserved.footer.height, 0)
            XCTAssertGreaterThan(reserved.body.minY, reserved.title.maxY)
            XCTAssertGreaterThan(reserved.footer.minY, reserved.body.maxY)
            XCTAssertLessThan(reserved.bodyFontSize, collapsed.bodyFontSize)
            XCTAssertLessThanOrEqual(reserved.footer.maxY, 54 + 972 * 0.3 + 1)
        }
    }
    func testLongMultilingualTextFitsBodyArea() {
        var style = OutputStyle(); style.heightFraction = 0.3; style.position = .bottom
        let content = DisplayContent(title: "LONG CONTENT", body: String(repeating: "Peace സമാധാനം שלום سلام அமைதி शांति\n", count: 16), footer: "Full text must remain visible")
        let layout = CanvasTextLayout.make(content: content, style: style)
        XCTAssertGreaterThan(layout.bodyFontSize, 0)
        XCTAssertGreaterThanOrEqual(layout.title.minY, 0)
        XCTAssertLessThanOrEqual(layout.footer.maxY, 1027)
        XCTAssertLessThan(layout.bodyFontSize, style.fontSize)
    }
    func testBlankCanvasKeepsSelectedKeyColor() throws {
        for background in ["000000", "00FF00", "0000FF"] {
            let canvas = OutputCanvas(frame: NSRect(x: 0, y: 0, width: 192, height: 108))
            var style = OutputStyle(); style.background = background
            canvas.style = style
            var content = DisplayContent.scripture; content.visible = false
            canvas.content = content
            let cg = try XCTUnwrap(CGContext(data: nil, width: 192, height: 108, bitsPerComponent: 8, bytesPerRow: 192 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            canvas.draw(canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
            // Read the explicitly sRGB bitmap directly. NSBitmapImageRep.colorAt
            // returns device-RGB colours on some macOS versions, losing the profile.
            let bytes = try XCTUnwrap(cg.data).assumingMemoryBound(to: UInt8.self)
            let offset = 54 * cg.bytesPerRow + 96 * 4
            let rgb = try XCTUnwrap(UInt32(background, radix: 16))
            XCTAssertEqual(bytes[offset], UInt8((rgb >> 16) & 255), background)
            XCTAssertEqual(bytes[offset + 1], UInt8((rgb >> 8) & 255), background)
            XCTAssertEqual(bytes[offset + 2], UInt8(rgb & 255), background)
            XCTAssertEqual(bytes[offset + 3], 255, background)
        }
    }
    func testLongLabelsAlsoFitInCompactCanvas() {
        var style = OutputStyle(); style.heightFraction = 0.15; style.position = .bottom
        let content = DisplayContent(title: String(repeating: "Heading ", count: 60), body: String(repeating: "Line\n", count: 50), footer: String(repeating: "Credit ", count: 140))
        let layout = CanvasTextLayout.make(content: content, style: style)
        XCTAssertGreaterThanOrEqual(layout.title.minY, 1026 - 972 * 0.15 - 1)
        XCTAssertLessThanOrEqual(layout.footer.maxY, 1027)
    }
}
