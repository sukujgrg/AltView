import AppKit
import XCTest
@testable import AltView

final class TemplateDesignTests: XCTestCase {
    func testMigrationPreservesEveryExistingDesignAndSharedArtwork() throws {
        var old = LowerThirdTemplate()
        old.enabled = true; old.artwork = .custom; old.assetID = UUID(); old.assetName = "saved.png"
        old.alignment = .right; old.showsTitle = false
        old.bodyRegion = TemplateRegion(x: 7, y: 76, width: 86, height: 17)
        var style = OutputStyle(); style.fontName = "Georgia"; style.background = "00FF00"
        let library = TemplateDesignLibrary(template: old, style: style)
        XCTAssertEqual(library.assetIDs, Set([try XCTUnwrap(old.assetID)]))
        for id in DesignProfileID.allCases {
            let design = library.design(id)
            let content = DisplayContent(title: "Reference", body: "Body", footer: "Footer")
            var legacy = old; legacy.textTemplate = id.selection
            let expected = legacy.applyingContentTemplate(for: content)
            XCTAssertEqual(design.template.alignment, expected.alignment)
            XCTAssertEqual(design.template.showsTitle, expected.showsTitle)
            XCTAssertEqual(design.template.showsFooter, expected.showsFooter)
            XCTAssertEqual(design.template.bodyRegion, old.bodyRegion)
            XCTAssertEqual(design.template.assetID, old.assetID)
            XCTAssertEqual(design.style.fontName, "Georgia")
            XCTAssertEqual(design.style.background, "00FF00")
            XCTAssertEqual(design.template.lyricLineLayout, .preserve)
        }
        XCTAssertEqual(try JSONDecoder().decode(TemplateDesignLibrary.self, from: JSONEncoder().encode(library)), library)
    }

    func testIndependentDesignsResolveSenderAndOverrideRequests() throws {
        var library = TemplateDesignLibrary()
        var lyrics = library[.lyrics]
        lyrics.template.assetID = UUID(); lyrics.template.alignment = .right
        lyrics.template.showsFooter = true; lyrics.template.lyricLineLayout = .compact
        lyrics.style.fontName = "Georgia"; lyrics.style.fontSize = 72; lyrics.style.lineSpacing = 0.05
        library[.lyrics] = lyrics
        library.background = "0000FF"
        library = try JSONDecoder().decode(TemplateDesignLibrary.self, from: JSONEncoder().encode(library))
        let content = DisplayContent(body: "Lyrics", template: .lyrics)
        let resolved = library.design(for: content)
        XCTAssertEqual(resolved.template.applyingContentTemplate(for: content).alignment, .right)
        XCTAssertTrue(resolved.template.contentForDisplay(DisplayContent(footer: "Credit", template: .lyrics)).hasFooter)
        XCTAssertEqual(resolved.style.fontName, "Georgia")
        XCTAssertEqual(resolved.style.background, "0000FF")
        XCTAssertNil(library.scripture.template.assetID)
        XCTAssertEqual(library.scripture.style.fontName, "System")
        XCTAssertEqual(library.design(for: DisplayContent(template: ContentTemplate(rawValue: "unknown"))), library.design(.custom))
        library.selection = .scripture
        XCTAssertEqual(library.design(for: content), library.design(.scripture))
        library.selection = .custom
        XCTAssertEqual(library.design(for: content), library.design(.custom))
    }

    func testOlderPreferencesDefaultToPreservedLinesAndExistingSpacing() throws {
        var template = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LowerThirdTemplate())) as? [String: Any])
        for key in ["customized", "lyricLineLayout", "lyricJoiner"] { template.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(LowerThirdTemplate.self, from: JSONSerialization.data(withJSONObject: template))
        XCTAssertFalse(restored.customized)
        XCTAssertEqual(restored.lyricLineLayout, .preserve)
        XCTAssertEqual(restored.lyricJoiner, .space)
        var style = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(OutputStyle())) as? [String: Any])
        style.removeValue(forKey: "lineSpacing")
        XCTAssertEqual(try JSONDecoder().decode(OutputStyle.self, from: JSONSerialization.data(withJSONObject: style)).lineSpacing, 0.12)
    }

    func testPublicationChecksTheRequestedProfilesArtwork() {
        let editor = LowerThirdWindowController()
        defer { editor.shutdown() }
        var library = TemplateDesignLibrary()
        library.lyrics.template.enabled = true; library.lyrics.template.artwork = .custom
        library.lyrics.template.assetID = UUID()
        editor.update(library: library, artworks: [:], busy: false, message: "")
        XCTAssertTrue(editor.canPublish(content: DisplayContent(body: "Message")))
        XCTAssertFalse(editor.canPublish(content: DisplayContent(body: "Song", template: .lyrics)),
                       "Editing Custom cannot bypass missing artwork in the requested Lyrics profile")
        editor.selectProfile(.lyrics)
        XCTAssertTrue(editor.canPublish(content: DisplayContent(body: "Message")),
                      "Opening an unrelated profile with missing artwork must not block healthy output")
        XCTAssertFalse(editor.canPublish(content: DisplayContent(body: "Song", template: .lyrics)))
    }

    func testRevertingSeveralProfileImportsRemovesOnlyDraftCopies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AltViewTemplateDrafts-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PNGArtworkStore(directory: directory.appendingPathComponent("Stored"))
        let editor = LowerThirdWindowController(artworkStore: store)
        defer { editor.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        editor.update(library: TemplateDesignLibrary(template: baseline), artworks: [:], busy: false, message: "")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let original = directory.appendingPathComponent("original.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: original)
        var ids: [UUID] = []
        for profile in [DesignProfileID.lyrics, .scripture] {
            editor.selectProfile(profile)
            editor.importArtwork(from: original)
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                editor.canPublish && editor.template.assetID != nil
            }, object: nil)
            wait(for: [ready], timeout: 3)
            ids.append(try XCTUnwrap(editor.template.assetID))
        }
        editor.revertChanges()
        XCTAssertFalse(editor.hasChanges)
        XCTAssertTrue(try XCTUnwrap(editor.draftLibrary).assetIDs.isEmpty)
        XCTAssertTrue(editor.allDraftArtworks.isEmpty)
        let discarded = expectation(description: "both unused imports discarded"); discarded.expectedFulfillmentCount = ids.count
        for id in ids {
            store.load(id: id, name: "draft") { result in
                if case .success = result { XCTFail("Revert retained an unused profile import") }
                discarded.fulfill()
            }
        }
        wait(for: [discarded], timeout: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    private func compact(_ text: String, width: CGFloat = 1728, size: CGFloat = 60,
                         joiner: LyricJoiner = .space, font: String = "System") -> String {
        var template = LowerThirdTemplate(); template.textTemplate = .lyrics; template.lyricLineLayout = .compact
        template.lyricJoiner = joiner
        var style = OutputStyle(); style.fontName = font
        return LyricCompactor.displayText(text, template: template, content: DisplayContent(body: text), style: style, width: width, size: size)
    }

    func testCompactPairsKeepStanzasPunctuationOddLinesAndExplicitSpacing() {
        XCTAssertEqual(compact("You are the light\nthat guides me home\nYou are the hope\nthat makes me whole\nOne last line"),
                       "You are the light that guides me home\nYou are the hope that makes me whole\nOne last line")
        XCTAssertEqual(compact("One\r\nTwo\r\n\r\nThree\r\nFour\r\n"), "One Two\n\nThree Four\n")
        XCTAssertEqual(compact("One\n \nTwo"), "One\n \nTwo")
        XCTAssertEqual(compact("Peace,\njoy!", joiner: .comma), "Peace, joy!")
        XCTAssertEqual(compact("Peace\njoy", joiner: .comma), "Peace, joy")
        XCTAssertEqual(compact("Peace\njoy", joiner: .dot), "Peace · joy")
        XCTAssertEqual(compact("  One\nTwo\n\tThree"), "  One\nTwo\n\tThree")
    }

    func testPreferredFontAndActualGlyphWidthsDetermineJoining() {
        for font in ["System", "Georgia", "Helvetica", "AvenirNext-Regular"] {
            for pair in [("Amazing grace,", "how sweet the sound"), ("സമാധാനം", "സന്തോഷം"), ("שלום", "עולם")] {
                var style = OutputStyle(); style.fontName = font
                let candidate = pair.0 + " " + pair.1
                let advance = NSAttributedString(string: candidate, attributes: style.attributes(size: 60)).size().width
                let threshold = max(advance + 2, advance / 0.99)
                let original = pair.0 + "\n" + pair.1
                XCTAssertEqual(compact(original, width: threshold - 1, font: font), original, font)
                XCTAssertEqual(compact(original, width: threshold + 2, font: font), candidate, font)
            }
        }
        XCTAssertEqual(compact("Supercalifragilisticexpialidocious\nSupercalifragilisticexpialidocious", width: 200),
                       "Supercalifragilisticexpialidocious\nSupercalifragilisticexpialidocious")
        let original = "Amazing grace\nhow sweet the sound"
        XCTAssertEqual(compact(original, width: 500, size: 100), original)
        XCTAssertEqual(compact(original, width: 500, size: 24), "Amazing grace how sweet the sound")
    }

    func testLongStanzasCompactAtTheirFittedSizeWithoutMakingTextSmaller() {
        // Original test text with the long lines and 8/8/9-line stanza sizes
        // that exposed checking the preferred font before the height fit.
        let lines = [
            "Across the fields a quiet morning opens",
            "The distant hills are softly lit in gold",
            "Along the path the little river wanders",
            "And over stones its silver waters flow",
            "The trees beside the road are gently swaying",
            "A painted gate stands open to the lane",
            "The clouds above the valley slowly gather",
            "And evening brings a cooling summer rain"
        ]
        var style = OutputStyle(); style.fontName = "Georgia"; style.fontSize = 93
        style.heightFraction = 0.15
        var template = LowerThirdTemplate(); template.textTemplate = .lyrics
        template.lyricLineLayout = .compact; template.enabled = true
        for count in [8, 8, 9] {
            let stanza = Array((lines + [lines.last!]).prefix(count))
            let content = DisplayContent(body: stanza.joined(separator: "\n"), template: .lyrics)
            let expected = stride(from: 0, to: count, by: 2).map { index in
                stanza[index..<min(index + 2, count)].joined(separator: " ")
            }.joined(separator: "\n")
            for lowerThird in [true, false] {
                template.enabled = lowerThird
                let make = { (template: LowerThirdTemplate) in
                    lowerThird ? CanvasTextLayout.lowerThird(content: content, style: style, template: template)
                        : CanvasTextLayout.make(content: content, style: style, template: template)
                }
                var preserve = template; preserve.lyricLineLayout = .preserve
                let baseline = make(preserve), layout = make(template)
                XCTAssertEqual(layout.bodyText, expected)
                XCTAssertGreaterThan(layout.bodyFontSize, baseline.bodyFontSize)
                XCTAssertLessThanOrEqual(layout.bodyFontSize, CGFloat(style.fontSize))
                XCTAssertLessThanOrEqual(CanvasTextLayout.measure(layout.bodyText, size: layout.bodyFontSize,
                    width: layout.body.width, style: style), layout.body.height + 0.01)
                for line in layout.bodyText.components(separatedBy: "\n") {
                    XCTAssertTrue(LyricCompactor.fitsOneLine(line, style: style, size: layout.bodyFontSize,
                        width: layout.body.width - max(2, layout.body.width * 0.01)))
                }
                XCTAssertEqual(content.body, stanza.joined(separator: "\n"))
            }
        }
    }

    func testCompactionDoesNotShrinkTextJustToForceAJoin() {
        let content = DisplayContent(body: "Across the fields a quiet morning opens\nThe distant hills are softly lit in gold", template: .lyrics)
        var style = OutputStyle(); style.fontName = "Georgia"; style.fontSize = 93
        var template = LowerThirdTemplate(); template.textTemplate = .lyrics
        let baseline = CanvasTextLayout.make(content: content, style: style, template: template)
        template.lyricLineLayout = .compact
        let layout = CanvasTextLayout.make(content: content, style: style, template: template)
        XCTAssertEqual(layout.bodyText, content.body)
        XCTAssertEqual(layout.bodyFontSize, baseline.bodyFontSize)
    }

    func testCompactingIsLyricsOnlyAndKeepsMeasuredRenderedAndAccessibleTextTogether() throws {
        let source = DisplayContent(body: "You are the light\nthat guides me home", template: .lyrics)
        var template = LowerThirdTemplate(); template.lyricLineLayout = .compact; template.animation = .none
        var style = OutputStyle(); style.background = "00FF00"; style.fontSize = 60
        for lowerThird in [false, true] {
            template.enabled = lowerThird
            let scene = CanvasPresentation(), reference = CanvasPresentation()
            let canvas = OutputCanvas(presentation: scene), expectedCanvas = OutputCanvas(presentation: reference)
            canvas.setFrameSize(NSSize(width: 192, height: 108)); expectedCanvas.setFrameSize(canvas.frame.size)
            defer { scene.stopAnimation(); reference.stopAnimation() }
            scene.update(content: source, style: style, template: template, artwork: nil, immediately: true)
            let layout = lowerThird ? CanvasTextLayout.lowerThird(content: source, style: style, template: template)
                : CanvasTextLayout.make(content: source, style: style, template: template)
            XCTAssertEqual(layout.bodyText, "You are the light that guides me home")
            XCTAssertEqual(scene.content, source, "Network content and the sender's original phrasing stay intact")
            XCTAssertEqual(canvas.accessibilityLabel(), layout.bodyText)
            var expected = source; expected.body = layout.bodyText
            var preserve = template; preserve.lyricLineLayout = .preserve
            reference.update(content: expected, style: style, template: preserve, artwork: nil, immediately: true)
            XCTAssertEqual(try render(canvas), try render(expectedCanvas), "Measurement and drawing must use the same joined text")
            for width: CGFloat in [384, 960, 1920] {
                canvas.setFrameSize(NSSize(width: width, height: width * 9 / 16))
                XCTAssertEqual(canvas.accessibilityLabel(), layout.bodyText, "Preview size cannot change joining")
            }
        }
        XCTAssertEqual(CanvasTextLayout.make(content: DisplayContent(body: source.body, template: .scripture), style: style, template: template).bodyText, source.body)
        template.lyricLineLayout = .preserve
        XCTAssertEqual(CanvasTextLayout.make(content: source, style: style, template: template).bodyText, source.body)
    }

    private func render(_ canvas: OutputCanvas) throws -> Data {
        let cg = try XCTUnwrap(CGContext(data: nil, width: 192, height: 108, bitsPerComponent: 8, bytesPerRow: 192 * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: try XCTUnwrap(cg.data), count: 192 * 108 * 4)
    }
}
