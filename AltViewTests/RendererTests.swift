import XCTest
import AppKit
@testable import AltView

final class RendererTests: XCTestCase {
    func testLayoutsAreSharedAcrossDrawingPreviewsAccessibilityAndStatus() throws {
        for lowerThird in [false, true] {
            var fits = 0
            let cache = CanvasTextLayoutCache { content, style, template in
                fits += 1
                return template.enabled ? .lowerThird(content: content, style: style, template: template)
                    : .make(content: content, style: style, template: template)
            }
            let scene = CanvasPresentation(layoutCache: cache), draft = CanvasPresentation(layoutCache: cache)
            let output = OutputCanvas(presentation: scene), preview = OutputCanvas(presentation: scene)
            let draftPreview = OutputCanvas(presentation: draft)
            var template = LowerThirdTemplate(); template.enabled = lowerThird; template.lyricLineLayout = .compact
            let content = DisplayContent(title: "Ignored title", body: "First line\nSecond line", template: .lyrics)
            scene.update(content: content, style: OutputStyle(), template: template, artwork: nil, immediately: true)
            draft.update(content: content, style: OutputStyle(), template: template, artwork: nil, immediately: true)
            XCTAssertEqual(fits, 0, "Offscreen scenes must not fit text until requested")
            let statusLayout = scene.textLayout
            XCTAssertEqual(fits, 1)
            for canvas in [output, preview, draftPreview] {
                XCTAssertEqual(canvas.accessibilityLabel(), statusLayout.bodyText)
                try draw(canvas, size: NSSize(width: 192, height: 108))
                try draw(canvas, size: NSSize(width: 384, height: 216))
            }
            XCTAssertEqual(draft.textLayout, statusLayout)
            XCTAssertEqual(fits, 1, "All consumers and canvas sizes reuse the same fitted layout")
        }
    }

    func testLayoutCacheInvalidatesTextTypographyGeometryAndLyricSettings() {
        var fits = 0
        let cache = CanvasTextLayoutCache { content, style, template in
            fits += 1
            return template.enabled ? .lowerThird(content: content, style: style, template: template)
                : .make(content: content, style: style, template: template)
        }
        let content = DisplayContent(title: "Title", body: "First line\nSecond line", footer: "Footer", template: .lyrics)
        let style = OutputStyle(), template = LowerThirdTemplate()
        var changes: [(DisplayContent, OutputStyle, LowerThirdTemplate)] = []
        for key in [\DisplayContent.title, \.body, \.footer] {
            var next = content; next[keyPath: key] += " changed"; changes.append((next, style, template))
        }
        var nextContent = content; nextContent.emptyRegions = .reserve; changes.append((nextContent, style, template))
        nextContent = content; nextContent.template = .scripture; changes.append((nextContent, style, template))
        var nextStyle = style; nextStyle.fontName = "Georgia"; changes.append((content, nextStyle, template))
        nextStyle = style; nextStyle.fontSize = 120; changes.append((content, nextStyle, template))
        nextStyle = style; nextStyle.lineSpacing = 0.3; changes.append((content, nextStyle, template))
        nextStyle = style; nextStyle.heightFraction = 0.3; changes.append((content, nextStyle, template))
        nextStyle = style; nextStyle.position = .top; changes.append((content, nextStyle, template))
        nextStyle = style; nextStyle.alignment = .right; changes.append((content, nextStyle, template))
        var nextTemplate = template; nextTemplate.enabled = true; changes.append((content, style, nextTemplate))
        for key in [\LowerThirdTemplate.titleRegion, \.bodyRegion, \.footerRegion] {
            var next = nextTemplate; next[keyPath: key].height = 2; changes.append((content, style, next))
        }
        for key in [\LowerThirdTemplate.showsTitle, \.showsFooter, \.customized] {
            var next = template; next[keyPath: key].toggle(); changes.append((content, style, next))
        }
        nextTemplate = template; nextTemplate.alignment = .right; changes.append((content, style, nextTemplate))
        nextTemplate = template; nextTemplate.textTemplate = .scripture; changes.append((content, style, nextTemplate))
        nextTemplate = template; nextTemplate.lyricLineLayout = .compact; changes.append((content, style, nextTemplate))
        nextTemplate.lyricJoiner = .dot; changes.append((content, style, nextTemplate))
        for (content, style, template) in changes {
            let before = fits
            let actual = cache.layout(content: content, style: style, template: template)
            let expected = template.enabled ? CanvasTextLayout.lowerThird(content: content, style: style, template: template)
                : CanvasTextLayout.make(content: content, style: style, template: template)
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(fits, before + 1, "A changed fitting input needs a new calculation")
        }
    }

    func testLayoutCacheReusesExitLayoutAndIgnoresCompositingChanges() {
        var fits = 0, now: TimeInterval = 10
        let cache = CanvasTextLayoutCache { content, style, template in
            fits += 1
            return .lowerThird(content: content, style: style, template: template)
        }
        let scene = CanvasPresentation(clock: { now }, reduceMotion: { false }, layoutCache: cache)
        defer { scene.stopAnimation() }
        let canvas = OutputCanvas(presentation: scene)
        var template = LowerThirdTemplate(); template.enabled = true
        var style = OutputStyle()
        scene.update(content: .lyrics, style: style, template: template, artwork: nil, immediately: true)
        let layout = scene.textLayout
        style.background = "00FF00"; template.animation = .reveal; template.duration = 1
        template.artwork = .custom; template.assetID = UUID(); template.assetName = "Artwork"
        template.showsArtwork = false; template.artworkRegion.height = 20
        scene.update(content: .lyrics, style: style, template: template, artwork: nil)
        XCTAssertEqual(scene.textLayout, layout)
        scene.update(content: .empty, style: style, template: template, artwork: nil)
        XCTAssertEqual(scene.displayedTextLayout, layout)
        XCTAssertEqual(canvas.accessibilityLabel(), "Output blank — keying background")
        now += 0.5
        XCTAssertGreaterThan(scene.progress, 0)
        XCTAssertEqual(scene.displayedTextLayout, layout)
        XCTAssertEqual(fits, 1, "Background, artwork and exit animation do not refit text")
    }

    func testLayoutCacheEvictsLeastRecentlyUsedContent() {
        var fits = 0
        let cache = CanvasTextLayoutCache(capacity: 2) { content, style, template in
            fits += 1; return .make(content: content, style: style, template: template)
        }
        for body in ["A", "B", "A", "C", "A", "B"] {
            _ = cache.layout(content: DisplayContent(body: body), style: OutputStyle(), template: LowerThirdTemplate())
        }
        XCTAssertEqual(fits, 4, "Only the least recently used layout is discarded")
    }

    @discardableResult
    private func draw(_ canvas: OutputCanvas, size: NSSize) throws -> Data {
        canvas.frame.size = size
        let cg = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        canvas.draw(canvas.bounds)
        return Data(bytes: try XCTUnwrap(cg.data), count: cg.bytesPerRow * cg.height)
    }

    func testSwitchingPreviewPresentationInvalidatesEqualRevisionRasterAndAccessibility() throws {
        let live = CanvasPresentation(), pending = CanvasPresentation()
        var template = LowerThirdTemplate(); template.enabled = true; template.animation = .none
        let content = DisplayContent(title: "Heading", body: "Body text", footer: "Credit")
        live.update(content: content, style: OutputStyle(), template: template, artwork: nil, immediately: true)
        template.showsTitle = false; template.showsFooter = false
        pending.update(content: content, style: OutputStyle(), template: template, artwork: nil, immediately: true)
        XCTAssertEqual(live.revision, pending.revision)
        let canvas = OutputCanvas(presentation: live)
        let size = NSSize(width: 384, height: 216)
        let original = try draw(canvas, size: size)
        XCTAssertEqual(canvas.accessibilityLabel(), "Heading\nBody text\nCredit")
        canvas.setPresentation(pending)
        XCTAssertEqual(canvas.accessibilityLabel(), "Body text")
        let candidate = try draw(canvas, size: size)
        XCTAssertNotEqual(candidate, original, "Independent scenes can share a revision number but require different cached images")
        canvas.setPresentation(live)
        XCTAssertEqual(try draw(canvas, size: size), original)
        XCTAssertEqual(canvas.accessibilityLabel(), "Heading\nBody text\nCredit")
    }

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
