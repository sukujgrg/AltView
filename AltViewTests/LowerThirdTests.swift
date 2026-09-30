import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AltView

final class LowerThirdTests: XCTestCase {
    func testMotionReversesFromCurrentPositionAndDoesNotReplay() {
        var motion = LowerThirdMotion()
        motion.set(visible: true, at: 10, duration: 1, animated: true)
        XCTAssertEqual(motion.progress(at: 10.5), 0.5, accuracy: 0.0001)
        motion.set(visible: true, at: 10.5, duration: 1, animated: true)
        XCTAssertEqual(motion.started, 10)
        motion.set(visible: false, at: 10.5, duration: 1, animated: true)
        XCTAssertEqual(motion.progress(at: 10.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(motion.progress(at: 11), 0)
        XCTAssertFalse(motion.isRunning(at: 11))
    }
    func testTextUpdatesKeepClockAndBlankRetainsSceneUntilHidden() {
        var now: TimeInterval = 10
        let scene = CanvasPresentation(clock: { now }, reduceMotion: { false })
        defer { scene.stopAnimation() }
        var template = LowerThirdTemplate(); template.enabled = true; template.duration = 1
        scene.update(content: .empty, style: OutputStyle(), template: template, artwork: nil)
        scene.update(content: .scripture, style: OutputStyle(), template: template, artwork: nil)
        now = 10.5
        scene.update(content: .lyrics, style: OutputStyle(), template: template, artwork: nil)
        XCTAssertEqual(scene.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(scene.motion.started, 10)
        XCTAssertEqual(scene.displayedContent, .lyrics)
        now = 11
        let revision = scene.revision
        scene.update(content: .lyrics, style: OutputStyle(), template: template, artwork: nil)
        XCTAssertEqual(scene.progress, 1)
        XCTAssertEqual(scene.revision, revision, "Identical updates must not rerasterize")
        scene.update(content: .empty, style: OutputStyle(), template: template, artwork: nil)
        XCTAssertEqual(scene.displayedContent, .lyrics, "An exit uses the last visible scene")
        now = 11.5
        XCTAssertEqual(scene.progress, 0.5, accuracy: 0.0001)
        scene.update(content: .scripture, style: OutputStyle(), template: template, artwork: nil)
        XCTAssertEqual(scene.progress, 0.5, accuracy: 0.0001, "Rapid Show reverses without jumping")
        scene.update(content: .empty, style: OutputStyle(), template: template, artwork: nil, immediately: true)
        XCTAssertEqual(scene.progress, 0, "Losing ownership must clear immediately")
        XCTAssertEqual(scene.displayedContent, .empty)
        XCTAssertFalse(scene.motion.isRunning(at: now))
    }
    func testCompletedExitClearsSceneAndReduceMotionIsImmediate() {
        var now: TimeInterval = 1
        var reduce = false
        let scene = CanvasPresentation(clock: { now }, reduceMotion: { reduce })
        defer { scene.stopAnimation() }
        var template = LowerThirdTemplate(); template.enabled = true
        scene.update(content: .scripture, style: OutputStyle(), template: template, artwork: nil)
        scene.update(content: .empty, style: OutputStyle(), template: template, artwork: nil)
        now = 2
        scene.update(content: .empty, style: OutputStyle(), template: template, artwork: nil)
        XCTAssertEqual(scene.displayedContent, .empty)
        reduce = true
        scene.update(content: .scripture, style: OutputStyle(), template: template, artwork: nil)
        XCTAssertEqual(scene.progress, 1)
        scene.update(content: .empty, style: OutputStyle(), template: template, artwork: nil)
        XCTAssertEqual(scene.progress, 0)
        XCTAssertEqual(scene.displayedContent, .empty)
    }
    func testRegionsAndLongTextStayWithinCanvas() {
        var template = LowerThirdTemplate()
        template.bodyRegion = TemplateRegion(x: .infinity, y: -40, width: 900, height: .nan)
        template.footerRegion = TemplateRegion(x: 99, y: 99, width: -20, height: 100)
        template.duration = .nan
        template = template.clamped()
        for region in [template.artworkRegion, template.titleRegion, template.bodyRegion, template.footerRegion] {
            XCTAssertGreaterThanOrEqual(region.rect.minX, 0)
            XCTAssertGreaterThanOrEqual(region.rect.minY, 0)
            XCTAssertLessThanOrEqual(region.rect.maxX, 1920.001)
            XCTAssertLessThanOrEqual(region.rect.maxY, 1080.001)
        }
        XCTAssertEqual(template.duration, 0.45)
        let content = DisplayContent(title: String(repeating: "Title ", count: 40), body: String(repeating: "Peace സമാധാനം שלום\n", count: 40), footer: String(repeating: "Credit ", count: 90))
        template = LowerThirdTemplate()
        var style = OutputStyle(); style.alignment = template.alignment
        let layout = CanvasTextLayout.lowerThird(content: content, style: style, template: template)
        XCTAssertLessThanOrEqual(CanvasTextLayout.measure(content.body, size: layout.bodyFontSize, width: layout.body.width, style: style), layout.body.height)
        XCTAssertLessThanOrEqual(CanvasTextLayout.measure(content.title, size: layout.titleFontSize, width: layout.title.width, style: style), layout.title.height)
        XCTAssertLessThanOrEqual(CanvasTextLayout.measure(content.footer, size: layout.footerFontSize, width: layout.footer.width, style: style, bold: false), layout.footer.height)
    }
    func testMaximumLineCountFitsSmallestTextRegion() {
        var template = LowerThirdTemplate()
        template.bodyRegion = TemplateRegion(x: 10, y: 79, width: 80, height: 1)
        let content = DisplayContent(body: String(repeating: "x\n", count: 12_000))
        var style = OutputStyle(); style.alignment = template.alignment
        let layout = CanvasTextLayout.lowerThird(content: content, style: style, template: template)
        XCTAssertGreaterThan(layout.bodyFontSize, 0)
        XCTAssertLessThanOrEqual(CanvasTextLayout.measure(content.body, size: layout.bodyFontSize, width: layout.body.width, style: style), layout.body.height)
    }
    func testTransparentPNGOrientationAndBlankAcrossKeyColors() throws {
        let image = try PNGArtworkStore.decode(pngFixture())
        let art = PNGArtwork(id: UUID(), name: "fixture.png", image: image)
        var template = LowerThirdTemplate(); template.enabled = true; template.artwork = .custom; template.animation = .none
        template.artworkRegion = TemplateRegion(x: 0, y: 0, width: 100, height: 100)
        for key in ["00FF00", "0000FF", "000000"] {
            let scene = CanvasPresentation()
            var style = OutputStyle(); style.background = key
            scene.update(content: DisplayContent(), style: style, template: template, artwork: art)
            let visible = try render(scene)
            assertPixel(visible, x: 30, y: 20, equals: [255, 0, 0, 255])
            assertPixel(visible, x: 150, y: 85, equals: [0, 0, 255, 255])
            let rgb = UInt32(key, radix: 16)!
            let background: [UInt8] = [UInt8((rgb >> 16) & 255), UInt8((rgb >> 8) & 255), UInt8(rgb & 255), 255]
            assertPixel(visible, x: 100, y: 50, equals: background)
            scene.update(content: .scripture, style: style, template: template, artwork: art)
            scene.update(content: .empty, style: style, template: template, artwork: art)
            let blank = try render(scene)
            for offset in stride(from: 0, to: blank.count, by: 4) {
                if Array(blank[offset..<offset + 4]) != background { XCTFail("Blank must remove all artwork and text"); break }
            }
        }
    }
    func testSlideAndRevealHideTheEntireComposition() throws {
        var now: TimeInterval = 1
        let scene = CanvasPresentation(clock: { now }, reduceMotion: { false })
        defer { scene.stopAnimation() }
        var style = OutputStyle(); style.background = "00FF00"
        for animation in [LowerThirdAnimation.slide, .reveal] {
            var template = LowerThirdTemplate(); template.enabled = true; template.animation = animation; template.duration = 1
            scene.update(content: .scripture, style: style, template: template, artwork: nil, immediately: true)
            let complete = try render(scene)
            scene.update(content: .empty, style: style, template: template, artwork: nil)
            XCTAssertEqual(try render(scene), complete)
            now += 0.5
            XCTAssertNotEqual(try render(scene), complete)
            now += 0.5
            let hidden = try render(scene)
            XCTAssertTrue(stride(from: 0, to: hidden.count, by: 4).allSatisfy { Array(hidden[$0..<$0+4]) == [0, 255, 0, 255] })
        }
    }
    func testPNGRejectsWrongTypeOversizedDataAndDimensions() throws {
        XCTAssertThrowsError(try PNGArtworkStore.decode(Data("not a PNG".utf8)))
        XCTAssertThrowsError(try PNGArtworkStore.decode(Data(count: PNGArtworkStore.maximumBytes + 1))) { XCTAssertEqual($0 as? ArtworkFailure, .tooLarge) }
        let image = try fixtureImage(width: 16_385, height: 1)
        XCTAssertThrowsError(try PNGArtworkStore.decode(encode(image))) { XCTAssertEqual($0 as? ArtworkFailure, .tooLarge) }
    }
    func testPNGImportCopiesAndReloadsWithoutOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        let data = try pngFixture(); try data.write(to: original)
        let store = PNGArtworkStore(directory: root.appendingPathComponent("stored"))
        let imported = expectation(description: "PNG imported off main and delivered on main")
        var asset: PNGArtwork?
        store.importPNG(from: original) { result in
            XCTAssertTrue(Thread.isMainThread)
            switch result { case .success(let value): asset = value; case .failure(let error): XCTFail("\(error)") }
            imported.fulfill()
        }
        wait(for: [imported], timeout: 5)
        let artwork = try XCTUnwrap(asset)
        try FileManager.default.removeItem(at: original)
        let reloaded = expectation(description: "saved PNG loaded independently")
        store.load(id: artwork.id, name: artwork.name) { result in
            XCTAssertTrue(Thread.isMainThread)
            switch result {
            case .success(let value): XCTAssertEqual(value.image.width, 192); XCTAssertEqual(value.id, artwork.id)
            case .failure(let error): XCTFail("\(error)")
            }
            reloaded.fulfill()
        }
        wait(for: [reloaded], timeout: 5)
    }
    func testNewOutputViewDescribesAnAlreadyVisibleScene() {
        let scene = CanvasPresentation()
        scene.update(content: .scripture, style: OutputStyle(), template: LowerThirdTemplate(), artwork: nil)
        let canvas = OutputCanvas(presentation: scene)
        XCTAssertEqual(canvas.accessibilityLabel(), [DisplayContent.scripture.title, DisplayContent.scripture.body, DisplayContent.scripture.footer].joined(separator: "\n"))
        scene.update(content: .empty, style: OutputStyle(), template: LowerThirdTemplate(), artwork: nil)
        XCTAssertEqual(canvas.accessibilityLabel(), "Output blank — keying background")
    }
    func testOldOutputStyleDecodesWithoutTemplateSettings() throws {
        let data = Data(#"{"background":"00FF00","fontName":"System","fontSize":88,"heightFraction":0.74,"position":"Center","alignment":"Center"}"#.utf8)
        let style = try JSONDecoder().decode(OutputStyle.self, from: data)
        XCTAssertEqual(style.heightFraction, 0.74)
        XCTAssertFalse(LowerThirdTemplate().enabled)
    }

    func testDraftPNGImportApplyRevertAndCancellationPreserveAppliedAsset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("draft.png")
        try pngFixture().write(to: source)
        let store = PNGArtworkStore(directory: root.appendingPathComponent("stored"))
        let controller = LowerThirdWindowController(artworkStore: store)
        defer { controller.shutdown() }
        var applied: PNGArtwork?
        var appliedTemplate: LowerThirdTemplate?
        controller.onApply = { template, asset in appliedTemplate = template; applied = asset }
        func waitUntil(_ description: String, _ predicate: @escaping () -> Bool) {
            let ready = expectation(description: description)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            func check() {
                if predicate() { ready.fulfill() }
                else if ProcessInfo.processInfo.systemUptime < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: check) }
            }
            check(); wait(for: [ready], timeout: 5.5)
        }
        controller.importArtwork(from: source)
        waitUntil("draft imported") { controller.template.assetID != nil }
        XCTAssertNil(applied, "Importing must not publish or replace the applied asset")
        controller.applyChanges()
        let original = try XCTUnwrap(applied)
        let baseline = try XCTUnwrap(appliedTemplate)
        controller.update(template: baseline, style: OutputStyle(), artwork: original, busy: false, message: "")
        controller.importArtwork(from: source)
        waitUntil("replacement preview ready") { controller.template.assetID != original.id }
        let discarded = try XCTUnwrap(controller.template.assetID)
        XCTAssertEqual(applied?.id, original.id)
        controller.revertChanges()
        XCTAssertEqual(controller.template.assetID, original.id)
        let checked = expectation(description: "revert removes only the draft file")
        store.load(id: discarded, name: "discarded") { result in
            if case .success = result { XCTFail("Reverted draft should be removed") }
            store.load(id: original.id, name: original.name) { result in
                if case .failure = result { XCTFail("Applied artwork must remain available") }
                checked.fulfill()
            }
        }
        wait(for: [checked], timeout: 5)
        // Cancellation before decoding returns must not resurrect a draft or leak its copy.
        controller.importArtwork(from: source)
        controller.revertChanges()
        let drained = expectation(description: "import callback and discard queue drained")
        store.load(id: original.id, name: original.name) { _ in
            store.load(id: original.id, name: original.name) { _ in drained.fulfill() }
        }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(controller.template.assetID, original.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("stored").path).count, 1)
        // Bad data must preserve the previous design and applied copy.
        try Data("not png".utf8).write(to: source)
        controller.importArtwork(from: source)
        let failed = expectation(description: "invalid import completed")
        store.load(id: original.id, name: original.name) { _ in failed.fulfill() }
        wait(for: [failed], timeout: 5)
        XCTAssertEqual(controller.template, baseline)
        XCTAssertEqual(applied?.id, original.id)
    }

    func testGuideLabelsDoNotOverlapForCrowdedOrEdgeAlignedRegions() {
        var screenshot = LowerThirdTemplate()
        screenshot.bodyRegion = TemplateRegion(x: 10, y: 70, width: 80, height: 1)
        var top = LowerThirdTemplate()
        var bottom = LowerThirdTemplate()
        for key in [\LowerThirdTemplate.artworkRegion, \.titleRegion, \.bodyRegion, \.footerRegion] {
            top[keyPath: key] = TemplateRegion(x: 0, y: 0, width: 100, height: 1)
            bottom[keyPath: key] = TemplateRegion(x: 99, y: 99, width: 1, height: 1)
        }
        for template in [LowerThirdTemplate(), screenshot, top, bottom] {
            for bounds in [NSRect(x: 0, y: 0, width: 540, height: 303.75),
                           NSRect(x: 0, y: 0, width: 480, height: 270),
                           NSRect(x: 10, y: 20, width: 600, height: 400)] {
                let guides = LowerThirdGuideLayout.make(template: template, in: bounds)
                XCTAssertEqual(Set(guides.map(\.index)), Set(0..<4))
                for (index, guide) in guides.enumerated() {
                    XCTAssertTrue(bounds.contains(guide.badge), "Every guide name must stay inside the preview")
                    XCTAssertEqual(guide.anchor.x, guide.rect.minX)
                    XCTAssertGreaterThanOrEqual(guide.anchor.y, guide.rect.minY)
                    XCTAssertLessThanOrEqual(guide.anchor.y, guide.rect.maxY)
                    for other in guides.dropFirst(index + 1) {
                        XCTAssertFalse(guide.badge.insetBy(dx: -1, dy: -1).intersects(other.badge),
                                       "Guide labels need a readable gap even when boxes overlap")
                    }
                }
            }
        }
    }

    func testVisibilityDefaultsForOldDesignsAndPersistsForNewOnes() throws {
        var template = LowerThirdTemplate()
        template.enabled = true; template.artwork = .custom
        template.assetID = UUID(); template.assetName = "kept.png"
        template.titleRegion = TemplateRegion(x: 12, y: 65, width: 70, height: 8)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any])
        legacy.removeValue(forKey: "showsArtwork"); legacy.removeValue(forKey: "showsTitle"); legacy.removeValue(forKey: "showsFooter")
        let restored = try JSONDecoder().decode(LowerThirdTemplate.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored, template, "Existing artwork and layout must survive migration with all areas on")
        template.showsArtwork = false; template.showsTitle = false; template.showsFooter = false
        let saved = try JSONDecoder().decode(LowerThirdTemplate.self, from: JSONEncoder().encode(template))
        XCTAssertEqual(saved, template)
        XCTAssertEqual(saved.clamped(), saved)
    }
    func testHiddenArtworkRendersOnlyTextAndRestoresBothArtworkSources() throws {
        let artwork = PNGArtwork(id: UUID(), name: "fixture.png", image: try fixtureImage())
        let content = DisplayContent(title: "HEADING", body: "Main message", footer: "Credit")
        var style = OutputStyle(); style.background = "00FF00"
        var template = LowerThirdTemplate(); template.enabled = true; template.animation = .none
        template.artworkRegion = TemplateRegion(x: 0, y: 0, width: 100, height: 100)
        template.artwork = .custom
        let reference = CanvasPresentation()
        reference.update(content: content, style: style, template: template, artwork: nil)
        let textOnly = try render(reference)
        XCTAssertTrue(stride(from: 0, to: textOnly.count, by: 4).contains { textOnly[$0] > 0 }, "Text must remain visible")
        let scene = CanvasPresentation()
        let canvas = OutputCanvas(presentation: scene)
        for source in LowerThirdArtwork.allCases {
            template.artwork = source; template.showsArtwork = true
            scene.update(content: content, style: style, template: template, artwork: artwork)
            let withArtwork = try render(scene)
            XCTAssertNotEqual(withArtwork, textOnly)
            template.showsArtwork = false
            scene.update(content: content, style: style, template: template, artwork: artwork)
            XCTAssertEqual(try render(scene), textOnly, "Hiding either artwork source must preserve every text pixel")
            XCTAssertEqual(scene.content, content)
            XCTAssertEqual(scene.artwork?.id, artwork.id)
            XCTAssertEqual(canvas.accessibilityLabel(), "HEADING\nMain message\nCredit")
            XCTAssertEqual(template.effectiveBodyRegion, template.bodyRegion)
            XCTAssertEqual(template.bounds, template.titleRegion.rect.union(template.bodyRegion.rect).union(template.footerRegion.rect))
            XCTAssertEqual(Set(LowerThirdGuideLayout.make(template: template, in: NSRect(x: 0, y: 0, width: 540, height: 304)).map(\.index)), Set([1, 2, 3]))
            template.showsArtwork = true
            scene.update(content: content, style: style, template: template, artwork: artwork)
            XCTAssertEqual(try render(scene), withArtwork, "Re-enabling must restore the saved artwork")
        }
    }
    func testOptionalTitleAndFooterMatchBlankTextPixelsWithoutChangingSource() throws {
        let content = DisplayContent(title: "HEADING", body: "Main message", footer: "Credit")
        let scene = CanvasPresentation()
        let canvas = OutputCanvas(presentation: scene)
        var template = LowerThirdTemplate(); template.enabled = true; template.animation = .none
        var style = OutputStyle(); style.background = "00FF00"
        let reference = CanvasPresentation()
        defer { scene.stopAnimation(); reference.stopAnimation() }
        for enabled in [true, false] {
            template.enabled = enabled
            for title in [true, false] {
                for footer in [true, false] {
                    template.showsTitle = title; template.showsFooter = footer
                    scene.update(content: content, style: style, template: template, artwork: nil)
                    var expected = content
                    if !title { expected.title = "" }
                    if !footer { expected.footer = "" }
                    var referenceTemplate = template
                    referenceTemplate.bodyRegion = template.effectiveBodyRegion
                    referenceTemplate.showsTitle = true; referenceTemplate.showsFooter = true
                    reference.update(content: expected, style: style, template: referenceTemplate, artwork: nil)
                    XCTAssertEqual(try render(scene), try render(reference), "Disabled areas must produce no text pixels")
                    XCTAssertEqual(scene.content, content, "The original sender snapshot must be retained")
                    XCTAssertEqual(canvas.accessibilityLabel(), [expected.title, expected.body, expected.footer].filter { !$0.isEmpty }.joined(separator: "\n"))
                }
            }
        }
        template.enabled = false
        scene.update(content: content, style: style, template: template, artwork: nil)
        XCTAssertEqual(canvas.accessibilityLabel(), "Main message", "Full-canvas mode keeps the same text visibility choices")
        template.enabled = true; template.showsTitle = true; template.showsFooter = true
        scene.update(content: scene.content, style: style, template: template, artwork: nil)
        XCTAssertEqual(canvas.accessibilityLabel(), "HEADING\nMain message\nCredit", "Re-enabling restores the original text without a new snapshot")
    }
    func testHiddenTextGuidesAreReplacedByExpandedBodyBounds() {
        var template = LowerThirdTemplate()
        template.titleRegion = TemplateRegion(x: 0, y: 0, width: 100, height: 10)
        template.footerRegion = TemplateRegion(x: 0, y: 99, width: 100, height: 1)
        template.showsTitle = false; template.showsFooter = false
        XCTAssertEqual(template.bounds, template.artworkRegion.rect.union(template.effectiveBodyRegion.rect))
        let bounds = NSRect(x: 0, y: 0, width: 540, height: 303.75)
        XCTAssertEqual(Set(LowerThirdGuideLayout.make(template: template, in: bounds).map(\.index)), Set([0, 2]))
        template.showsTitle = true
        XCTAssertEqual(Set(LowerThirdGuideLayout.make(template: template, in: bounds).map(\.index)), Set([0, 1, 2]))
        XCTAssertEqual(template.bounds.minY, 0)
        template.showsFooter = true
        XCTAssertEqual(template.bounds.maxY, 1080, accuracy: 0.001)
    }

    func testBodyReclaimsHiddenRowsAndRestoresItsSavedGeometry() throws {
        var template = LowerThirdTemplate()
        let base = template.bodyRegion
        for (title, footer, y, height) in [(true, true, 79.0, 11.0), (false, true, 74.0, 16.0),
                                         (true, false, 79.0, 15.0), (false, false, 74.0, 20.0)] {
            template.showsTitle = title; template.showsFooter = footer
            let body = template.effectiveBodyRegion
            XCTAssertEqual(body, TemplateRegion(x: 10, y: y, width: 80, height: height))
            let layout = CanvasTextLayout.lowerThird(content: .scripture, style: OutputStyle(), template: template)
            XCTAssertEqual(layout.body, body.rect, "Rendering must use the expanded box")
            let guides = LowerThirdGuideLayout.make(template: template, in: NSRect(x: 0, y: 0, width: 1920, height: 1080))
            XCTAssertEqual(try XCTUnwrap(guides.first { $0.index == 2 }).rect, body.rect, "Guides must match rendering")
            XCTAssertEqual(template.bodyRegion, base, "Visibility must not rewrite the saved body rectangle")
            let restored = try JSONDecoder().decode(LowerThirdTemplate.self, from: JSONEncoder().encode(template))
            XCTAssertEqual(restored.effectiveBodyRegion, body)
            XCTAssertEqual(restored.bodyRegion, base)
        }
        template.showsTitle = true; template.showsFooter = true
        XCTAssertEqual(template.effectiveBodyRegion, base)
        template.bodyRegion = TemplateRegion(x: 20, y: 40, width: 60, height: 10)
        template.titleRegion = TemplateRegion(x: 5, y: 20, width: 90, height: 5)
        template.footerRegion = TemplateRegion(x: 0, y: 80, width: 100, height: 10)
        template.showsTitle = false; template.showsFooter = false
        XCTAssertEqual(template.effectiveBodyRegion, TemplateRegion(x: 20, y: 20, width: 60, height: 70),
                       "Custom layouts reclaim vertical space without changing body alignment or width")
    }

    func testEmptySenderRowsReclaimSpaceUnlessReserved() throws {
        var template = LowerThirdTemplate(); template.enabled = true
        let saved = template
        let bounds = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        for (title, footer, y, height) in [("Title", "Footer", 79.0, 11.0), ("", "Footer", 74.0, 16.0),
                                         ("Title", "", 79.0, 15.0), ("", "", 74.0, 20.0), (" \n", "\t", 74.0, 20.0)] {
            var content = DisplayContent(title: title, body: String(repeating: "Body line\n", count: 8), footer: footer)
            let layout = CanvasTextLayout.lowerThird(content: content, style: OutputStyle(), template: template)
            XCTAssertEqual(layout.body, TemplateRegion(x: 10, y: y, width: 80, height: height).rect)
            let resolved = template.resolved(for: content)
            let guides = LowerThirdGuideLayout.make(template: resolved, in: bounds)
            XCTAssertEqual(try XCTUnwrap(guides.first { $0.index == 2 }).rect, layout.body)
            XCTAssertEqual(guides.contains { $0.index == 1 }, content.hasTitle)
            XCTAssertEqual(guides.contains { $0.index == 3 }, content.hasFooter)
            XCTAssertTrue(resolved.bounds.contains(layout.body))
            content.emptyRegions = .reserve
            let reserved = CanvasTextLayout.lowerThird(content: content, style: OutputStyle(), template: template)
            XCTAssertEqual(reserved.body, template.bodyRegion.rect)
            XCTAssertGreaterThanOrEqual(layout.bodyFontSize, reserved.bodyFontSize)
            XCTAssertEqual(template, saved, "Resolving content must not rewrite the receiver’s saved design")
        }
        template.showsTitle = false
        let content = DisplayContent(body: "Body", emptyRegions: .reserve)
        XCTAssertEqual(template.resolved(for: content).effectiveBodyRegion,
                       TemplateRegion(x: 10, y: 74, width: 80, height: 16), "Receiver-hidden rows still reclaim space")
    }

    func testBodyOnlyRenderingMatchesExplicitExpandedDesignAndRestoresLabels() throws {
        var template = LowerThirdTemplate(); template.enabled = true; template.animation = .none
        let scene = CanvasPresentation(), reference = CanvasPresentation()
        defer { scene.stopAnimation(); reference.stopAnimation() }
        let content = DisplayContent(body: "Body only")
        scene.update(content: content, style: OutputStyle(), template: template, artwork: nil)
        var expanded = template
        expanded.bodyRegion = TemplateRegion(x: 10, y: 74, width: 80, height: 20)
        var reserved = content; reserved.emptyRegions = .reserve
        reference.update(content: reserved, style: OutputStyle(), template: expanded, artwork: nil)
        XCTAssertEqual(try render(scene), try render(reference))
        scene.update(content: .scripture, style: OutputStyle(), template: template, artwork: nil)
        reference.update(content: .scripture, style: OutputStyle(), template: template, artwork: nil)
        XCTAssertEqual(try render(scene), try render(reference), "Labels returning must restore the saved body box")
    }

    private func fixtureImage(width: Int = 192, height: Int = 108) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        if width == 192 && height == 108 {
            for y in 10..<40 { for x in 20..<60 { let i = (y * width + x) * 4; bytes[i] = 255; bytes[i+3] = 255 } }
            for y in 70..<100 { for x in 130..<170 { let i = (y * width + x) * 4; bytes[i+2] = 255; bytes[i+3] = 255 } }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }
    private func pngFixture() throws -> Data { try encode(fixtureImage()) }
    private func render(_ scene: CanvasPresentation) throws -> [UInt8] {
        let canvas = OutputCanvas(presentation: scene); canvas.frame = NSRect(x: 0, y: 0, width: 192, height: 108)
        let cg = try XCTUnwrap(CGContext(data: nil, width: 192, height: 108, bitsPerComponent: 8, bytesPerRow: 192 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.translateBy(x: 0, y: 108); cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let bytes = try XCTUnwrap(cg.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: 192 * 108 * 4))
    }
    private func assertPixel(_ bytes: [UInt8], x: Int, y: Int, equals expected: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        let i = (y * 192 + x) * 4
        XCTAssertEqual(Array(bytes[i..<i+4]), expected, "Pixel \(x),\(y)", file: file, line: line)
    }
}
