import AppKit
import Network
import XCTest
@testable import AltView

// Hosted runners can have a screen shorter than the layouts under test. Keep
// AppKit's screen fitting out of these tests while retaining window Auto Layout.
private final class LayoutTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class WindowTests: XCTestCase {
    func testLocalComposerRestoresPublishedSnapshotAfterAutomaticPortChanges() throws {
        let domain = "AltViewTests.LocalPortChange.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let published = DisplayContent(title: "Published title", body: "Published text")
        defaults.set(true, forKey: "customTextEnabled")
        try defaults.set(JSONEncoder().encode(published), forKey: "customTextDraft")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate())
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        controller.showComposerPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        eventually("receiver ready") { controller.receiverStatus.listening }
        let previousPort = try XCTUnwrap(controller.receiverStatus.port)
        try button("Publish Text & Design", in: root).performClick(nil)
        eventually("local snapshot published") { controller.receiverStatus.content == published }
        let owner = try XCTUnwrap(controller.receiverStatus.ownerID)
        let title = try field("Text title", in: root)
        title.stringValue = "Private draft edit"
        title.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: title))
        try button("Hide Text", in: root).performClick(nil)
        var hidden = published; hidden.visible = false
        eventually("published snapshot hidden") { controller.receiverStatus.content == hidden }

        let settings = try settingsContent(in: controller)
        try button("Pause Receiving", in: settings).performClick(nil)
        eventually("receiving paused") { !controller.receiverStatus.listening }
        try button("Resume Receiving", in: settings).performClick(nil)
        eventually("receiving resumed") { controller.receiverStatus.listening }
        XCTAssertNotEqual(controller.receiverStatus.port, previousPort)
        eventually("local sender restores hidden snapshot on the new port", timeout: 10) {
            controller.receiverStatus.ownerID == owner && controller.receiverStatus.content == hidden
        }
        XCTAssertEqual(title.stringValue, "Private draft edit", "Reconnect must preserve the private draft")
        let closed = expectation(forNotification: NSPopover.didCloseNotification, object: nil)
        controller.showSettings(); wait(for: [closed], timeout: 3)

        try button("Stop Presenting", in: root).performClick(nil)
        eventually("local ownership released") { controller.receiverStatus.ownerID == nil }
        let reopened = try settingsContent(in: controller)
        try button("Pause Receiving", in: reopened).performClick(nil)
        eventually("receiving paused after release") { !controller.receiverStatus.listening }
        try button("Resume Receiving", in: reopened).performClick(nil)
        eventually("released sender reconnects without publishing", timeout: 10) {
            controller.receiverStatus.listening && controller.receiverStatus.connections == 1
        }
        XCTAssertNil(controller.receiverStatus.ownerID)
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        let closedAgain = expectation(forNotification: NSPopover.didCloseNotification, object: nil)
        controller.showSettings(); wait(for: [closedAgain], timeout: 3)
    }

    func testDefaultReceiversChooseIndependentPortsAndShowManualConnectionDetails() throws {
        let firstDomain = "AltViewTests.AutomaticPort.\(UUID())", secondDomain = "AltViewTests.AutomaticPort.\(UUID())"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: firstDomain))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondDomain))
        firstDefaults.set("Automatic port one", forKey: "receiverName")
        secondDefaults.set("Automatic port two", forKey: "receiverName")
        let key = try PairingKey.generate()
        // Exercise the real app default, without a test port override.
        let first = ReceiverWindowController(defaults: firstDefaults, pairingKey: key)
        let second = ReceiverWindowController(defaults: secondDefaults, pairingKey: try PairingKey.generate())
        defer {
            first.shutdown(); first.close(); second.shutdown(); second.close()
            firstDefaults.removePersistentDomain(forName: firstDomain); secondDefaults.removePersistentDomain(forName: secondDomain)
        }
        eventually("both defaults start without a port conflict") { first.receiverStatus.listening && second.receiverStatus.listening }
        let firstPort = try XCTUnwrap(first.receiverStatus.port), secondPort = try XCTUnwrap(second.receiverStatus.port)
        XCTAssertGreaterThan(firstPort, 0); XCTAssertGreaterThan(secondPort, 0)
        XCTAssertNotEqual(firstPort, secondPort)
        first.showWindow(nil)
        let settings = try settingsContent(in: first)
        let details = try XCTUnwrap(descendants(settings).compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "receiverManualPort"
        })
        XCTAssertFalse(details.isHidden)
        XCTAssertTrue(details.stringValue.contains(String(firstPort)))
        XCTAssertFalse(details.isEditable, "Receiving ports are automatic, not a user setting")
        settings.layoutSubtreeIfNeeded()
        XCTAssertTrue(settings.bounds.contains(details.convert(details.bounds, to: settings)))
        try button("Pause Receiving", in: settings).performClick(nil)
        eventually("paused port is no longer advertised to the user") { !first.receiverStatus.listening && details.isHidden }
        try button("Resume Receiving", in: settings).performClick(nil)
        eventually("resumed port is shown") { first.receiverStatus.listening && !details.isHidden }
        XCTAssertTrue(details.stringValue.contains(String(try XCTUnwrap(first.receiverStatus.port))))
        var local: LocalReceiverConnection?
        first.connectLocal { local = try? $0.get() }
        eventually("local sender uses assigned port") { local != nil }
        XCTAssertEqual(local?.port, first.receiverStatus.port)
        XCTAssertEqual(local?.key, key)
        // Let the transient popover finish closing before another test opens one.
        let closed = expectation(forNotification: NSPopover.didCloseNotification, object: nil)
        first.showSettings()
        wait(for: [closed], timeout: 3)
    }

    func testReceiverPortRecoveryKeepsLocalPublicationWaiting() throws {
        let occupied = try OccupiedReceiverPort()
        defer { occupied.release() }
        let domain = "AltViewTests.PortRecovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: occupied.port)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        eventually("receiver is recovering") { controller.receiverStatus.starting && controller.receiverStatus.message.contains("retrying") }
        var connection: LocalReceiverConnection?
        controller.connectLocal { result in
            switch result {
            case .success(let value): connection = value
            case .failure(let error): XCTFail("Temporary conflict must keep publication pending: \(error)")
            }
        }
        XCTAssertNil(connection)
        occupied.release()
        eventually("pending local connection continues automatically") { connection != nil && controller.receiverStatus.listening }
        XCTAssertEqual(connection?.port, occupied.port)
        XCTAssertEqual(connection?.key, key)
        XCTAssertFalse(controller.receiverStatus.starting)
        XCTAssertNil(controller.receiverStatus.ownerID, "Starting a receiver alone must not publish text")
    }

    func testPauseReceivingCancelsPortRecoveryAndPendingPublication() throws {
        let occupied = try OccupiedReceiverPort()
        defer { occupied.release() }
        let domain = "AltViewTests.PausePortRecovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: occupied.port)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        controller.showWindow(nil)
        eventually("receiver is recovering") { controller.receiverStatus.starting && controller.receiverStatus.message.contains("retrying") }
        let settings = try settingsContent(in: controller)
        XCTAssertTrue(descendants(settings).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("retrying automatically") })
        let name = try field("Receiver name", in: settings)
        XCTAssertFalse(name.isEditable)
        let cancelled = expectation(description: "pending publication cancelled")
        controller.connectLocal { result in
            if case .success = result { XCTFail("Pause must cancel the pending local connection") }
            cancelled.fulfill()
        }
        try button("Pause Receiving", in: settings).performClick(nil)
        wait(for: [cancelled], timeout: 2)
        eventually("receiving paused") { !controller.receiverStatus.starting && !controller.receiverStatus.listening }
        XCTAssertTrue(name.isEditable)
        occupied.release()
        let settled = expectation(description: "cancelled retry cannot restart receiving")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertFalse(controller.receiverStatus.listening)
        XCTAssertFalse(controller.receiverStatus.starting)
        try button("Resume Receiving", in: settings).performClick(nil)
        eventually("explicit resume still works") { controller.receiverStatus.listening }
        XCTAssertFalse(name.isEditable)
    }

    func testReceiverAdvertisesSavedPolicyAndOnlyBroadcastsAppliedChanges() throws {
        let domain = "AltViewTests.TemplatePolicy.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        var saved = LowerThirdTemplate(); saved.textTemplate = .lyrics
        try defaults.set(JSONEncoder().encode(saved), forKey: "lowerThirdTemplate")
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        var status = SenderStatus()
        let sender = SenderClient(name: "Policy observer") { status = $0 }
        defer { sender.disconnect(); controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        eventually("listener ready") { controller.receiverStatus.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(controller.receiverStatus.port))!), key: key)
        eventually("saved override in handshake") { status.connected && status.templateCapabilities.policy == .fixed(.lyrics) }
        controller.showDesignPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        let selection = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Text template" })
        selection.selectItem(withTitle: "Scripture"); selection.sendAction(selection.action, to: selection.target)
        XCTAssertEqual(status.templateCapabilities.policy, .fixed(.lyrics), "A design draft is private")
        try button("Apply Design to Output", in: root).performClick(nil)
        eventually("applied override broadcast without publishing") { status.templateCapabilities.policy == .fixed(.scripture) }
        XCTAssertNil(controller.receiverStatus.ownerID)
        selection.selectItem(withTitle: "Custom layout"); selection.sendAction(selection.action, to: selection.target)
        try button("Revert Changes", in: root).performClick(nil)
        XCTAssertEqual(status.templateCapabilities.policy, .fixed(.scripture))
    }

    func testComposerDiscoversFutureTemplatesAndKeepsSelectionPrivateAcrossCatalogueChanges() throws {
        let domain = "AltViewTests.TemplateMenu.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Jordan Lee")), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let first = TemplateDescriptor(id: ContentTemplate(rawValue: "intro-one"), name: "Speaker")
        let second = TemplateDescriptor(id: ContentTemplate(rawValue: "intro-two"), name: "Speaker")
        let capabilities = TemplateCapabilities(templates: [first, second], policy: .sender)
        let receiver = try TemplateTestReceiver(key: key, capabilities: capabilities)
        let listening = expectation(description: "template menu receiver ready")
        receiver.start { listening.fulfill() }
        defer { receiver.stop() }
        wait(for: [listening], timeout: 3)
        var received: [DisplayContent] = []
        receiver.onContent = { received.append($0) }
        let controller = TextComposerViewController(defaults: defaults,
            loadPairing: { _ in nil }, storePairing: { _, _ in }) { _ in XCTFail("Must connect remotely") }
        let window = layoutWindow(); window.isReleasedWhenClosed = false; window.contentView = controller.view
        defer { controller.shutdown(); window.close() }
        let root = controller.view
        let destination = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Text destination" })
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Requested text template" })
        destination.selectItem(at: 1); destination.sendAction(destination.action, to: destination.target)
        XCTAssertFalse(picker.isEnabled)
        let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try button("Connect using an address instead", in: sheet).performClick(nil)
        try field("Receiver address", in: sheet).stringValue = "127.0.0.1"
        try field("Receiver port", in: sheet).stringValue = String(try XCTUnwrap(receiver.port).rawValue)
        let code = try field("Pairing code", in: sheet); code.stringValue = PairingKey.text(key)
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: code))
        try button("Connect Only", in: sheet).performClick(nil)
        eventually("discovered choices populated") { window.attachedSheet == nil && picker.isEnabled && picker.numberOfItems == 3 }
        XCTAssertEqual(picker.itemTitles, ["Receiver’s layout", "Speaker", "Speaker"], "IDs, not display names, identify templates")
        picker.selectItem(at: 2); picker.sendAction(picker.action, to: picker.target)
        XCTAssertEqual(controller.draft.template, second.id)
        XCTAssertTrue(received.isEmpty, "Choosing a template never takes output")
        try button("Publish Text", in: root).performClick(nil)
        eventually("chosen opaque ID published") { received.last?.template == second.id }
        let selectedItem = picker.selectedItem
        receiver.updateCapabilities(TemplateCapabilities(templates: [first, second], policy: .custom))
        eventually("override feedback shown") {
            self.descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("AltView overrides sender templates") }
        }
        XCTAssertTrue(picker.selectedItem === selectedItem, "Ordinary status updates must not rebuild the menu")
        receiver.updateCapabilities(TemplateCapabilities(templates: [first], policy: .fixed(first.id)))
        eventually("removed choice retained but unavailable") { picker.titleOfSelectedItem == "intro-two · Unavailable" }
        XCTAssertFalse(try XCTUnwrap(picker.selectedItem).isEnabled)
        XCTAssertEqual(controller.draft.template, second.id)
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("AltView uses Speaker for every message.") })
        try button("Publish Text", in: root).performClick(nil)
        eventually("unavailable request omitted on next publish") { received.count == 2 && received.last?.template == nil }
        receiver.updateCapabilities(capabilities)
        eventually("restored choice becomes selectable again") { picker.selectedItem?.representedObject as? String == second.id.rawValue && picker.selectedItem?.isEnabled == true }
        XCTAssertEqual(controller.draft.template, second.id)
    }

    func testTemplateSamplesFitCompactWorkspaceAndComposerNotesMatchForcedLyrics() throws {
        let domain = "AltViewTests.Templates.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "customTextEnabled")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        let window = try XCTUnwrap(controller.window), root = try XCTUnwrap(window.contentView)
        window.setContentSize(NSSize(width: 980, height: 650))
        controller.showDesignPage()
        let samples = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Design preview content" })
        let selection = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Text template" })
        for name in ["Scripture", "Lyrics"] {
            samples.selectItem(withTitle: "Sample · \(name)"); samples.sendAction(samples.action, to: samples.target)
            root.layoutSubtreeIfNeeded()
            let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
            XCTAssertGreaterThan(preview.bounds.width, 400)
            XCTAssertEqual(preview.bounds.width / preview.bounds.height, 16.0 / 9, accuracy: 0.01)
            XCTAssertTrue(root.bounds.contains(selection.convert(selection.bounds, to: root)))
            XCTAssertTrue(root.bounds.contains(try button("Apply Design to Output", in: root).convert(try button("Apply Design to Output", in: root).bounds, to: root)))
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "Template-\(name)-compact"; attachment.lifetime = .keepAlways
            add(attachment)
        }
        selection.selectItem(withTitle: "Lyrics"); selection.sendAction(selection.action, to: selection.target)
        controller.showComposerPage()
        XCTAssertEqual(descendants(root).compactMap { $0 as? NSTextField }.filter { $0.stringValue == "Hidden by Design · text is kept" }.count, 2)
        controller.showDesignPage()
        try button("Revert Changes", in: root).performClick(nil)
    }

    func testTextTemplatesPreviewApplyRevertAndPreserveCustomSettings() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true; baseline.alignment = .right
        baseline.showsTitle = false
        var style = OutputStyle(); style.alignment = .right
        controller.update(template: baseline, style: style, artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        func picker(_ name: String) throws -> NSPopUpButton {
            try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == name })
        }
        let selection = try picker("Text template")
        let samples = try picker("Design preview content")
        let alignment = try picker("Lower third text alignment")
        let title = try button("Title", in: root), footer = try button("Footer", in: root)
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        var applied: LowerThirdTemplate?
        controller.onApply = { value, _ in applied = value }
        samples.selectItem(withTitle: "Lyrics"); samples.sendAction(samples.action, to: samples.target)
        XCTAssertEqual(alignment.titleOfSelectedItem, "Center")
        XCTAssertFalse(alignment.isEnabled); XCTAssertFalse(title.isEnabled); XCTAssertFalse(footer.isEnabled)
        XCTAssertEqual(title.state, .off); XCTAssertEqual(footer.state, .off)
        XCTAssertEqual(preview.accessibilityLabel(), DisplayContent.lyrics.body)
        XCTAssertFalse(controller.hasChanges, "Selecting a sample cannot edit the design")
        selection.selectItem(withTitle: "Scripture"); selection.sendAction(selection.action, to: selection.target)
        XCTAssertEqual(alignment.titleOfSelectedItem, "Left")
        XCTAssertEqual(title.state, .on); XCTAssertEqual(footer.state, .on)
        XCTAssertNil(applied)
        XCTAssertTrue(controller.hasChanges)
        controller.revertChanges()
        XCTAssertEqual(selection.titleOfSelectedItem, "From sending app")
        XCTAssertEqual(alignment.titleOfSelectedItem, "Center")
        selection.selectItem(withTitle: "Lyrics"); selection.sendAction(selection.action, to: selection.target)
        // Changes to other controls cannot save the preset over the custom rows/alignment.
        try button("Artwork", in: root).performClick(nil)
        controller.applyChanges()
        XCTAssertEqual(applied?.textTemplate, .lyrics)
        XCTAssertEqual(applied?.alignment, .right)
        XCTAssertEqual(applied?.showsTitle, false); XCTAssertEqual(applied?.showsFooter, true)
        selection.selectItem(withTitle: "Custom layout"); selection.sendAction(selection.action, to: selection.target)
        XCTAssertEqual(alignment.titleOfSelectedItem, "Right")
        XCTAssertTrue(alignment.isEnabled); XCTAssertTrue(title.isEnabled); XCTAssertTrue(footer.isEnabled)
        XCTAssertEqual(title.state, .off); XCTAssertEqual(footer.state, .on)
        XCTAssertEqual(controller.style.alignment, .right)
        controller.revertChanges()
        XCTAssertEqual(selection.titleOfSelectedItem, "Lyrics")
        // Source updates must refresh both the preview and the available controls.
        selection.selectItem(withTitle: "From sending app"); selection.sendAction(selection.action, to: selection.target)
        let scripture = DisplayContent(title: "Reference", body: "Verse", footer: "Translation", template: .scripture)
        controller.updateContent(draft: .empty, source: scripture, externalSource: "ViewTheWord", customTextEnabled: false)
        XCTAssertEqual(alignment.titleOfSelectedItem, "Left")
        XCTAssertEqual(preview.accessibilityLabel(), "Reference\nVerse\nTranslation")
        controller.updateContent(draft: .empty, source: DisplayContent(body: "Custom"), externalSource: "ViewTheWord", customTextEnabled: false)
        XCTAssertEqual(alignment.titleOfSelectedItem, "Right")
        XCTAssertTrue(alignment.isEnabled)
    }

    func testOutputReadinessTracksPreviewSleepCloseAndMissingDisplay() throws {
        _ = NSApplication.shared
        let controller = OutputWindowController(presentation: CanvasPresentation())
        var states: [OutputReadiness] = []
        controller.onReadinessChange = { states.append($0) }
        defer { controller.stop() }
        XCTAssertEqual(controller.readiness, .closed)
        controller.show(displayID: nil)
        XCTAssertEqual(controller.readiness, .preview)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(controller.readiness, .asleep)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(controller.readiness, .preview)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "AltView — Preview Output" && $0.isVisible })
        window.close()
        XCTAssertEqual(controller.readiness, .closed)
        controller.show(displayID: UInt32.max)
        XCTAssertEqual(controller.readiness, .displayMissing)
        controller.stop()
        XCTAssertEqual(states, [.preview, .asleep, .preview, .closed, .displayMissing, .closed])
    }
    func testReceiverWindowReportsReadinessOverTheConnection() throws {
        let key = try PairingKey.generate()
        let domain = "AltViewTests.Feedback.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        var status = SenderStatus()
        let sender = SenderClient(name: "Window feedback") { status = $0 }
        defer { sender.disconnect(); controller.shutdown(); controller.close(); defaults.removePersistentDomain(forName: domain) }
        eventually("receiver listening") { controller.receiverStatus.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(controller.receiverStatus.port))!), key: key)
        eventually("closed reported") { status.feedback.output == .closed }
        let root = try XCTUnwrap(controller.window?.contentView)
        try button("Open Output", in: root).performClick(nil)
        eventually("preview reported") { status.feedback.output == .preview }
        controller.closeOutput()
        eventually("close reported") { status.feedback.output == .closed }
    }

    private func layoutWindow() -> NSWindow {
        LayoutTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    }
    private func eventually(_ description: String, timeout: TimeInterval = 10, _ predicate: @escaping () -> Bool) {
        let done = expectation(description: description)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func check() {
            if predicate() { done.fulfill() }
            else if ProcessInfo.processInfo.systemUptime < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check) }
        }
        check(); wait(for: [done], timeout: timeout + 0.5)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }
    private func field(_ label: String, in view: NSView) throws -> NSTextField {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == label })
    }
    private func visibleSettingsContent() -> NSView? {
        NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(descendants)
            .first { $0.accessibilityIdentifier() == "workspaceSettingsContent" }
    }
    private func settingsContent(in controller: ReceiverWindowController) throws -> NSView {
        let root = try XCTUnwrap(controller.window?.contentView)
        let gear = try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "workspaceSettings"
        })
        gear.performClick(nil)
        eventually("gear opens Settings") { self.visibleSettingsContent() != nil }
        return try XCTUnwrap(visibleSettingsContent())
    }
    private func settingsSwitch(in controller: ReceiverWindowController) throws -> NSSwitch {
        let settings = try settingsContent(in: controller)
        return try XCTUnwrap(descendants(settings).compactMap { $0 as? NSSwitch }.first {
            $0.accessibilityIdentifier() == "enableCustomText"
        })
    }
    func testComposerEmptyRowPreferencePreviewsPublishesAndPersists() throws {
        let domain = "AltViewTests.EmptyRows.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Body only")), forKey: "customTextDraft")
        var template = LowerThirdTemplate(); template.enabled = true
        try defaults.set(JSONEncoder().encode(template), forKey: "lowerThirdTemplate")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let keepSpace = try button("Keep space for empty Title and Footer", in: root)
        let publish = try button("Publish Text & Design", in: root)
        XCTAssertTrue(root.bounds.contains(publish.convert(publish.bounds, to: root)))
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(keepSpace.state, .off)
        keepSpace.performClick(nil)
        XCTAssertEqual(preview.content.emptyRegions, .reserve)
        XCTAssertEqual(controller.receiverStatus.content, .empty, "Changing spacing must remain private")
        publish.performClick(nil)
        eventually("spacing sent over the local connection") { controller.receiverStatus.content.emptyRegions == .reserve }
        keepSpace.performClick(nil)
        XCTAssertEqual(controller.receiverStatus.content.emptyRegions, .reserve, "Later edits must stay private")
        publish.performClick(nil)
        eventually("automatic spacing published") { controller.receiverStatus.content.emptyRegions == .collapse }
        let badge = try XCTUnwrap(descendants(root).compactMap { $0 as? StatusBadge }.first {
            $0.accessibilityIdentifier() == "composerPresentationStatus"
        })
        XCTAssertEqual(badge.text, "PUBLISHED")
        XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "workspaceContentStatus" })
        let changes = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "textDraftStatus" })
        XCTAssertTrue(changes.isHidden, "Publishing must clear the change indicator")
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Output window closed") })
        keepSpace.performClick(nil)
        XCTAssertFalse(changes.isHidden)
        try button("Hide Text", in: root).performClick(nil)
        // The composer badge updates immediately; the receiver changes after
        // the snapshot travels over the local connection and returns to the UI.
        eventually("hidden content reflected in the workspace and receiver") {
            badge.text == "HIDDEN" && !controller.receiverStatus.content.visible
        }
        XCTAssertFalse(controller.receiverStatus.content.visible)
        try button("Show Last Text", in: root).performClick(nil)
        eventually("showing last text keeps the new spacing private") {
            badge.text == "PUBLISHED" && controller.receiverStatus.content.visible
        }
        XCTAssertEqual(controller.receiverStatus.content.emptyRegions, .collapse)
        XCTAssertFalse(changes.isHidden)
        try button("Stop Presenting", in: root).performClick(nil)
        eventually("released content reflected in the workspace") { badge.text == "NOT PRESENTING" && controller.receiverStatus.ownerID == nil }
        XCTAssertNil(controller.receiverStatus.ownerID)
        controller.showReceiverPage()
        let outputBadge = try XCTUnwrap(descendants(root).compactMap { $0 as? StatusBadge }.first {
            $0.accessibilityIdentifier() == "workspaceContentStatus"
        })
        XCTAssertEqual(outputBadge.text, "NO TEXT")
        controller.shutdown()
        let saved = try JSONDecoder().decode(DisplayContent.self, from: XCTUnwrap(defaults.data(forKey: "customTextDraft")))
        XCTAssertEqual(saved.emptyRegions, .reserve)
    }
    func testReceiverStartsAutomaticallyAndPauseSurvivesPageChanges() throws {
        let domain = "AltViewTests.Receiver.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let navigation = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(navigation.segmentCount, 2)
        XCTAssertEqual(navigation.label(forSegment: 0), "Output")
        XCTAssertEqual(navigation.label(forSegment: 1), "Design")
        XCTAssertEqual(navigation.selectedSegment, 0)
        eventually("ready without a click") { controller.receiverStatus.listening }
        XCTAssertNil(controller.receiverStatus.ownerName)
        XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "receiverPairingCode" })
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Ready to receive" })
        let pair = try button("Pair a sender…", in: root)
        XCTAssertFalse(pair.isHidden)
        controller.showWindow(nil)
        pair.performClick(nil)
        eventually("pair shortcut opens Settings") { self.visibleSettingsContent() != nil }
        let settings = try XCTUnwrap(visibleSettingsContent())
        settings.layoutSubtreeIfNeeded()
        let code = try field("Pairing code", in: settings)
        XCTAssertEqual(code.stringValue, PairingKey.text(try XCTUnwrap(controller.pairingKey)))
        let controls: [NSView] = [code, try button("Copy Code", in: settings), try button("Reset Code…", in: settings),
                                  try button("Pause Receiving", in: settings)]
        for control in controls {
            XCTAssertTrue(settings.bounds.contains(control.convert(control.bounds, to: settings)))
        }
        try button("Pause Receiving", in: settings).performClick(nil)
        eventually("paused") { !controller.receiverStatus.listening }
        let name = try field("Receiver name", in: settings)
        XCTAssertTrue(name.isEditable)
        name.stringValue = "Presentation Mac"
        let closed = expectation(forNotification: NSPopover.didCloseNotification, object: nil)
        controller.showSettings()
        wait(for: [closed], timeout: 3)
        controller.setCustomTextEnabled(true); controller.showComposerPage(); controller.showReceiverPage()
        XCTAssertFalse(controller.receiverStatus.listening)
        let reopenedSettings = try settingsContent(in: controller)
        try button("Resume Receiving", in: reopenedSettings).performClick(nil)
        eventually("resumed") { controller.receiverStatus.listening }
        XCTAssertFalse(name.isEditable)
        XCTAssertEqual(defaults.string(forKey: "receiverName"), "Presentation Mac")
        XCTAssertEqual(code.stringValue, PairingKey.text(try XCTUnwrap(controller.pairingKey)))
    }
    func testCustomTextOptInPreservesDraftAndRestoresWithoutPublishing() throws {
        let domain = "AltViewTests.CustomTextOptIn.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let draft = DisplayContent(body: "Saved private message")
        try defaults.set(JSONEncoder().encode(draft), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        let navigation = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSegmentedControl }.first)
        eventually("receiver ready with Custom Text disabled") { controller.receiverStatus.listening }
        XCTAssertFalse(controller.customTextEnabled, "An existing saved draft must not opt the user in")
        XCTAssertEqual(navigation.segmentCount, 2)
        XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "receiverPairingCode" })
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.allSatisfy { $0.accessibilityLabel() != "Text title" })

        controller.showDesignPage()
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Design preview content" })
        XCTAssertNil(picker.item(withTitle: "Text draft"))
        XCTAssertEqual(picker.titleOfSelectedItem, "Sample · Speaker")
        XCTAssertTrue(try button("Edit Text…", in: root).isHidden)
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(preview.content.body, "Jordan Lee", "Design stays useful without the hidden text draft")
        picker.selectItem(withTitle: "Sample · Announcement"); picker.sendAction(picker.action, to: picker.target)
        XCTAssertEqual(preview.content.body, "A place to belong")
        XCTAssertEqual(controller.receiverStatus.content, .empty, "Samples must never reach output")

        var enableNotifications = 0
        controller.onCustomTextSettingChange = { enableNotifications += 1 }
        let toggle = try settingsSwitch(in: controller)
        XCTAssertEqual(toggle.state, .off)
        XCTAssertFalse(controller.customTextEnabled, "Opening Settings alone must not enable Custom Text")
        toggle.state = .on; toggle.sendAction(toggle.action, to: toggle.target)
        XCTAssertEqual(navigation.label(forSegment: navigation.selectedSegment), "Design", "Settings keeps the current page in place")
        controller.showSettings() // Dismiss the popover.
        controller.showComposerPage()
        XCTAssertTrue(controller.customTextEnabled)
        XCTAssertTrue(defaults.bool(forKey: "customTextEnabled"))
        XCTAssertEqual(navigation.segmentCount, 3)
        XCTAssertEqual(navigation.label(forSegment: navigation.selectedSegment), "Text")
        let composerPreview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(composerPreview.content, draft)
        XCTAssertEqual(controller.receiverStatus.connections, 0)
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        controller.showDesignPage()
        XCTAssertEqual(picker.titleOfSelectedItem, "Sample · Announcement", "Enabling Custom Text preserves the chosen design preview")
        XCTAssertNotNil(picker.item(withTitle: "Text draft"))
        XCTAssertFalse(try button("Edit Text…", in: root).isHidden)
        try button("Edit Text…", in: root).performClick(nil)
        XCTAssertEqual(enableNotifications, 1)
        XCTAssertEqual(navigation.segmentCount, 3, "Reopening Text must not duplicate its page")
        controller.shutdown(); controller.close()

        let reopened = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        defer { reopened.shutdown(); reopened.close() }
        let reopenedRoot = try XCTUnwrap(reopened.window?.contentView)
        let restoredNavigation = try XCTUnwrap(descendants(reopenedRoot).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertTrue(reopened.customTextEnabled)
        XCTAssertEqual(restoredNavigation.segmentCount, 3)
        XCTAssertEqual(restoredNavigation.label(forSegment: restoredNavigation.selectedSegment), "Output")
        eventually("reopened receiver ready") { reopened.receiverStatus.listening }
        XCTAssertEqual(reopened.receiverStatus.connections, 0)
        XCTAssertNil(reopened.receiverStatus.ownerID)
        XCTAssertEqual(reopened.receiverStatus.content, .empty)
        reopened.showComposerPage()
        XCTAssertEqual(try XCTUnwrap(descendants(reopenedRoot).compactMap { $0 as? OutputCanvas }.first).content, draft)
    }
    func testConnectedSenderIsNamedAndOutputControlsStayCompact() throws {
        let domain = "AltViewTests.PairingStatus.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0, window: layoutWindow())
        defer { controller.shutdown(); controller.close() }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        func label(_ id: String, in view: NSView) throws -> NSTextField {
            try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == id })
        }
        let status = try label("receiverListeningStatus", in: root)
        let connection = try label("receiverConnectionStatus", in: root)
        let pair = try button("Pair a sender…", in: root)
        let display = try XCTUnwrap(descendants(root).first { $0.accessibilityLabel() == "Output display" && $0 is NSBox })
        func checkLayout() {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for size in [NSSize(width: 980, height: 650), NSSize(width: 1280, height: 900)] {
                    window.setContentSize(size)
                    root.layoutSubtreeIfNeeded()
                    let statusFrame = status.convert(status.bounds, to: root)
                    let connectionFrame = connection.convert(connection.bounds, to: root)
                    let pairFrame = pair.convert(pair.bounds, to: root)
                    let displayFrame = display.convert(display.bounds, to: root)
                    XCTAssertLessThanOrEqual(statusFrame.minY - connectionFrame.maxY, 12)
                    XCTAssertLessThanOrEqual(connectionFrame.minY - pairFrame.maxY, 12)
                    XCTAssertGreaterThanOrEqual(pairFrame.minY - displayFrame.maxY, 0)
                    XCTAssertLessThanOrEqual(pairFrame.minY - displayFrame.maxY, 24, "Pairing must not leave a growing gap above display controls")
                    XCTAssertTrue(root.bounds.contains(displayFrame))
                }
            }
        }
        func attachLayout(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
        }
        eventually("receiver ready") { controller.receiverStatus.port != nil }
        XCTAssertEqual(connection.stringValue, "No sender connected")
        checkLayout()
        pair.performClick(nil)
        eventually("pair shortcut opens settings") { self.visibleSettingsContent() != nil }
        let settings = try XCTUnwrap(visibleSettingsContent())
        let pairingStatus = try label("receiverPairingStatus", in: settings)
        XCTAssertEqual(pairingStatus.stringValue, "No sender connected")

        var senderStatus = SenderStatus()
        let sender = SenderClient(name: "Presentation Mac") { senderStatus = $0 }
        defer { sender.disconnect() }
        let endpoint = Network.NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(controller.receiverStatus.port))!)
        sender.connect(to: endpoint, key: key)
        eventually("paired without publishing") { senderStatus.connected && controller.receiverStatus.connections == 1 }
        XCTAssertEqual(status.stringValue, "Sender connected")
        XCTAssertEqual(connection.stringValue, "Connected to Presentation Mac")
        XCTAssertEqual(pairingStatus.stringValue, connection.stringValue, "The open pairing popover confirms a successful connection")
        XCTAssertEqual(pair.title, "Pair another sender…")
        XCTAssertFalse(pair.isHidden)
        XCTAssertNil(controller.receiverStatus.ownerID)
        try attachLayout(settings, name: "Connected sender in Settings")
        let closed = expectation(forNotification: NSPopover.didCloseNotification, object: nil)
        controller.showSettings(); wait(for: [closed], timeout: 3)
        checkLayout()
        try attachLayout(root, name: "Connected sender on Output")

        let second = SenderClient(name: "Second Mac") { _ in }
        defer { second.disconnect() }
        second.connect(to: endpoint, key: key)
        eventually("both paired senders identified") { controller.receiverStatus.connections == 2 }
        XCTAssertEqual(connection.stringValue, "Connected to Presentation Mac, Second Mac")
        sender.submit(.scripture); sender.takeOutput()
        eventually("receiving text") { controller.receiverStatus.content == .scripture }
        XCTAssertEqual(status.stringValue, "Receiving text")
        checkLayout()
        sender.releaseOutput()
        eventually("paired sender remains after release") { controller.receiverStatus.ownerID == nil }
        XCTAssertEqual(status.stringValue, "Sender connected")
        second.disconnect(); sender.disconnect()
        eventually("senders disconnected") { controller.receiverStatus.connections == 0 }
        XCTAssertTrue(controller.receiverStatus.connectedSenders.isEmpty)
        XCTAssertEqual(status.stringValue, "Ready to receive")
        XCTAssertEqual(connection.stringValue, "No sender connected")
        XCTAssertEqual(pair.title, "Pair a sender…")
        checkLayout()
    }
    func testTurningOffCustomTextStopsSendingAndKeepsDraftPrivateOnReenable() throws {
        let domain = "AltViewTests.DisableCustomText.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Currently published")), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.showReceiverPage()
        let pair = try button("Pair a sender…", in: root)
        controller.showComposerPage()
        try button("Publish Text & Design", in: root).performClick(nil)
        eventually("custom text owns output") { controller.receiverStatus.ownerID != nil }
        XCTAssertFalse(pair.isHidden)
        XCTAssertEqual(pair.title, "Pair another sender…")
        let title = try field("Text title", in: root)
        title.stringValue = "Next private title"
        title.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: title))

        let toggle = try settingsSwitch(in: controller)
        XCTAssertEqual(toggle.state, .on)
        toggle.state = .off; toggle.sendAction(toggle.action, to: toggle.target)
        controller.showSettings()
        eventually("turning off disconnects only Custom Text") {
            controller.receiverStatus.ownerID == nil && controller.receiverStatus.connections == 0
        }
        XCTAssertTrue(controller.receiverStatus.listening)
        XCTAssertFalse(pair.isHidden)
        XCTAssertEqual(pair.title, "Pair a sender…")
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        let navigation = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(navigation.segmentCount, 2)
        XCTAssertEqual(navigation.label(forSegment: navigation.selectedSegment), "Output")
        XCTAssertFalse(defaults.bool(forKey: "customTextEnabled"))
        controller.showComposerPage()
        XCTAssertFalse(controller.customTextEnabled, "A stale Text shortcut cannot enable the feature")
        controller.showDesignPage()
        XCTAssertTrue(try button("Edit Text…", in: root).isHidden)
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Design preview content" })
        XCTAssertNil(picker.item(withTitle: "Text draft"))

        controller.setCustomTextEnabled(true); controller.showComposerPage()
        XCTAssertEqual(try field("Text title", in: root).stringValue, "Next private title")
        XCTAssertEqual(controller.receiverStatus.connections, 0)
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        try button("Publish Text & Design", in: root).performClick(nil)
        eventually("explicit publication still works after reenabling") { controller.receiverStatus.content.title == "Next private title" }
        controller.setCustomTextEnabled(false)
        controller.shutdown(); controller.close()

        let reopened = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        defer { reopened.shutdown(); reopened.close() }
        XCTAssertFalse(reopened.customTextEnabled)
        let saved = try JSONDecoder().decode(DisplayContent.self, from: XCTUnwrap(defaults.data(forKey: "customTextDraft")))
        XCTAssertEqual(saved.title, "Next private title")
    }
    func testCompactWorkspaceKeepsCanvasAndActionsVisibleInBothAppearances() throws {
        let domain = "AltViewTests.CompactWorkspace.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent.scripture), forKey: "customTextDraft")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0,
                                                  window: layoutWindow())
        defer { controller.shutdown(); controller.close() }
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        controller.setCustomTextEnabled(true)
        controller.showWindow(nil)
        root.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 980, height: 650))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for (showPage, action) in [
                (controller.showComposerPage, "Publish Text & Design"),
                (controller.showDesignPage, "Apply Design to Output"),
                (controller.showReceiverPage, "Open Output")
            ] {
                showPage()
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(root.bounds.width, 980, accuracy: 1, "Changing pages must not enlarge the window")
                XCTAssertEqual(root.bounds.height, 650, accuracy: 1, "Opening \(action) in \(appearance.rawValue) must not enlarge the window")
                let primary = try button(action, in: root)
                XCTAssertTrue(root.bounds.contains(primary.convert(primary.bounds, to: root)), action)
                XCTAssertFalse(primary.visibleRect.isEmpty, "\(action) must not be clipped by a scroll view")
                let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
                let frame = canvas.convert(canvas.bounds, to: root)
                XCTAssertTrue(root.bounds.contains(frame), "Preview stays inside the compact workspace")
                XCTAssertGreaterThan(frame.width, 300)
                XCTAssertEqual(frame.width / frame.height, 16.0 / 9, accuracy: 0.01)
                let statusID = action == "Publish Text & Design" ? "composerPresentationStatus"
                    : action == "Apply Design to Output" ? "designDraftStatus" : "workspaceContentStatus"
                let status = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == statusID })
                XCTAssertTrue(root.bounds.contains(status.convert(status.bounds, to: root)))
                if action != "Open Output" {
                    XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "workspaceContentStatus" },
                                   "Receiver status belongs only on Output")
                }
            }
        }
        controller.showDesignPage()
        root.layoutSubtreeIfNeeded()
        let inspector = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(try XCTUnwrap(inspector.documentView).frame.height, inspector.contentSize.height)
    }
    func testDesignPreviewKeepsItsSizeWhenSwitchingLayouts() throws {
        let domain = "AltViewTests.DesignPreviewSize.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var template = LowerThirdTemplate(); template.enabled = true
        var style = OutputStyle(); style.background = "0000FF"
        try defaults.set(JSONEncoder().encode(template), forKey: "lowerThirdTemplate")
        try defaults.set(JSONEncoder().encode(style), forKey: "outputStyle")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0,
                                                  window: layoutWindow())
        defer { controller.shutdown(); controller.close() }
        controller.showDesignPage()
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let stage = try XCTUnwrap(canvas.superview)
        let mode = try button("Use lower-third layout", in: root)
        for size in [NSSize(width: 980, height: 650), NSSize(width: 1280, height: 800), NSSize(width: 1520, height: 900)] {
            window.setContentSize(size)
            root.layoutSubtreeIfNeeded()
            let originalStage = stage.convert(stage.bounds, to: root)
            let originalCanvas = canvas.convert(canvas.bounds, to: root)
            for _ in 0..<4 {
                mode.performClick(nil)
                root.layoutSubtreeIfNeeded()
                let currentStage = stage.convert(stage.bounds, to: root)
                let currentCanvas = canvas.convert(canvas.bounds, to: root)
                XCTAssertEqual(root.bounds.width, size.width, accuracy: 1)
                XCTAssertEqual(root.bounds.height, size.height, accuracy: 1)
                XCTAssertEqual(currentStage.minY, originalStage.minY, accuracy: 1)
                XCTAssertEqual(currentStage.height, originalStage.height, accuracy: 1, "Hiding layout controls must not resize the preview stage")
                XCTAssertEqual(currentCanvas.width, originalCanvas.width, accuracy: 1)
                XCTAssertEqual(currentCanvas.height, originalCanvas.height, accuracy: 1)
                XCTAssertEqual(currentCanvas.width / currentCanvas.height, 16.0 / 9, accuracy: 0.01)
                if size.height >= 800 { XCTAssertGreaterThan(currentCanvas.height, 300, "The preview must use the available height") }
                let apply = try button("Apply Design to Output", in: root)
                XCTAssertTrue(root.bounds.contains(apply.convert(apply.bounds, to: root)))
            }
        }
    }
    func testTextWorkspaceUsesAvailableHeightForBothDestinations() throws {
        let domain = "AltViewTests.TextWorkspaceHeight.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "customTextEnabled")
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Test")), forKey: "customTextDraft")
        var remoteStatus = ReceiverStatus()
        let key = try PairingKey.generate()
        let receiver = ReceiverServer(receiverID: UUID()) { remoteStatus = $0 }
        receiver.start(name: "Layout test", key: key, advertise: false)
        defer { receiver.stop() }
        eventually("layout receiver ready") { remoteStatus.port != nil }
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0,
                                                  window: layoutWindow())
        defer { controller.shutdown(); controller.close() }
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        let destination = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Text destination"
        })
        for selection in [0, 1, 0] {
            destination.selectItem(at: selection)
            destination.sendAction(destination.action, to: destination.target)
            if let sheet = window.attachedSheet?.contentView {
                try button("Connect using an address instead", in: sheet).performClick(nil)
                try field("Receiver address", in: sheet).stringValue = "127.0.0.1"
                try field("Receiver port", in: sheet).stringValue = String(try XCTUnwrap(remoteStatus.port))
                let code = try field("Pairing code", in: sheet)
                code.stringValue = PairingKey.text(key)
                code.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: code))
                try button("Connect & Publish Text", in: sheet).performClick(nil)
                eventually("remote text is live") { remoteStatus.content.body == "Test" }
            }
            root.layoutSubtreeIfNeeded()
            XCTAssertFalse(descendants(root).contains { $0.accessibilityIdentifier() == "workspaceContentStatus" })
            for height: CGFloat in [1000, 650, 1000] {
                window.setContentSize(NSSize(width: 1164, height: height))
                let settled = expectation(description: "Window resize and content updates settle")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
                wait(for: [settled], timeout: 1)
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(root.bounds.height, height, accuracy: 1, "The test must exercise the requested window height")
                let status = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "textPublicationDetail" })
                let statusFrame = status.convert(status.bounds, to: root)
                XCTAssertEqual(statusFrame.minY, 20, accuracy: 1, "Publishing status stays at the bottom of the window")
                let publish = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "showText" })
                let publishFrame = publish.convert(publish.bounds, to: root)
                XCTAssertTrue(root.bounds.contains(publishFrame))
                XCTAssertLessThan(publishFrame.minY - statusFrame.maxY, 20, "Publishing actions stay beside their status")
                let editor = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first {
                    $0.accessibilityLabel() == "Compose editor"
                })
                let document = try XCTUnwrap(editor.documentView)
                if height == 1000 {
                    XCTAssertLessThanOrEqual(document.frame.height, editor.contentSize.height + 1,
                                             "All editor fields fit without scrolling when the window is tall")
                    let footer = try field("Text footer", in: root)
                    XCTAssertTrue(editor.documentVisibleRect.contains(footer.convert(footer.bounds, to: document)))
                } else {
                    XCTAssertGreaterThan(document.frame.height, editor.contentSize.height,
                                         "A compact window can scroll the editor while keeping actions visible")
                }
            }
            if selection == 1 {
                let changes = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "textDraftStatus" })
                XCTAssertTrue(changes.isHidden)
                let publication = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
                    $0.accessibilityIdentifier() == "textPublicationStatus"
                })
                XCTAssertTrue(publication.stringValue.contains("127.0.0.1"), "Publication status must name its destination")
                let body = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "Text body" })
                let longText = (1...45).map { "Line \($0): a longer published message." }.joined(separator: "\n")
                body.string = longText
                body.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: body))
                XCTAssertFalse(changes.isHidden)
                XCTAssertEqual(remoteStatus.content.body, "Test", "Editing must not change the receiving Mac")
                try button("Publish Text", in: root).performClick(nil)
                eventually("long text published") { remoteStatus.content.body == longText }
                XCTAssertTrue(changes.isHidden)
                root.layoutSubtreeIfNeeded()
                let sent = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first { $0.accessibilityLabel() == "Last text sent" })
                let sentBody = try XCTUnwrap(descendants(sent).compactMap { $0 as? NSTextField }.first { $0.stringValue == longText })
                XCTAssertEqual(sentBody.maximumNumberOfLines, 0, "Sent text must remain readable in full")
                XCTAssertGreaterThan(try XCTUnwrap(sent.documentView).frame.height, sent.contentSize.height)
                controller.showDesignPage()
                try button("Use lower-third layout", in: root).performClick(nil)
                controller.showComposerPage()
                XCTAssertTrue(changes.isHidden, "Changes to this Mac’s design are not unpublished changes for another Mac")
                XCTAssertTrue(descendants(root).compactMap { $0 as? StatusBadge }.allSatisfy { $0.text != "DRAFT" })
                receiver.stop()
                let publicationBadge = try XCTUnwrap(descendants(root).compactMap { $0 as? StatusBadge }.first {
                    $0.accessibilityIdentifier() == "composerPresentationStatus"
                })
                eventually("disconnection replaces stale ownership with offline status") {
                    publicationBadge.text == "OFFLINE" && publication.stringValue.hasPrefix("Connection lost")
                }
                XCTAssertEqual(sentBody.stringValue, longText, "The last sent text stays available while offline")
            }
        }
    }
    func testLocalPublicationFailureExplainsWhyAndKeepsChangesUnpublished() throws {
        let domain = "AltViewTests.LocalPublicationFailure.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Private message")), forKey: "customTextDraft")
        let composer = TextComposerViewController(defaults: defaults) { completion in
            completion(.failure(ComposerConnectionError(message: "This Mac’s receiver could not start.")))
        }
        defer { composer.shutdown() }
        let root = composer.view
        try button("Publish Text & Design", in: root).performClick(nil)
        let detail = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first {
            $0.accessibilityIdentifier() == "textPublicationDetail"
        })
        XCTAssertEqual(detail.stringValue, "This Mac’s receiver could not start.")
        let changes = try XCTUnwrap(descendants(root).first { $0.accessibilityIdentifier() == "textDraftStatus" })
        XCTAssertFalse(changes.isHidden)
        XCTAssertTrue(try button("Publish Text & Design", in: root).isEnabled)
    }
    func testRemotePairingFailureRetryConnectOnlyAndOneStepPublishing() throws {
        let domain = "AltViewTests.RemoteComposer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent.scripture), forKey: "customTextDraft")
        let key = try XCTUnwrap(PairingKey.parse("ABCD2345"))
        var output = ReceiverStatus()
        let server = ReceiverServer(receiverID: UUID()) { output = $0 }
        server.start(name: "Pairing UX test", key: key, advertise: false)
        defer { server.stop() }
        eventually("receiver ready") { output.port != nil }
        let controller = TextComposerViewController(defaults: defaults,
            loadPairing: { _ in nil }, storePairing: { _, _ in }) { _ in XCTFail("Remote pairing must never connect locally") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1062, height: 714), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = controller.view
        defer { controller.shutdown(); window.close() }
        let destination = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first)
        destination.selectItem(at: 1); destination.sendAction(destination.action, to: destination.target)
        let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try button("Connect using an address instead", in: sheet).performClick(nil)
        try field("Receiver address", in: sheet).stringValue = "127.0.0.1"
        try field("Receiver port", in: sheet).stringValue = String(try XCTUnwrap(output.port))
        let code = try field("Pairing code", in: sheet)
        code.stringValue = "ABCD2346"
        // Bonjour updates must not erase a code typed for a manual address.
        controller.updateReceivers([DiscoveredReceiver(name: "Nearby Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1))], error: nil)
        XCTAssertEqual(code.stringValue, "ABCD2346")
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: code))
        try button("Connect & Publish Text", in: sheet).performClick(nil)
        eventually("wrong code remains editable") {
            code.isEnabled && self.descendants(sheet).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("Couldn’t connect.") }
        }
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertEqual(output.content, .empty)
        XCTAssertNil(output.ownerName)
        code.stringValue = PairingKey.text(key).lowercased()
        try button("Connect Only", in: sheet).performClick(nil)
        eventually("connection confirmed before sheet closes") { window.attachedSheet == nil && output.connections == 1 }
        XCTAssertNil(output.ownerName, "Connect Only must keep the draft private")
        XCTAssertEqual(output.content, .empty)
        try button("Change Receiver…", in: controller.view).performClick(nil)
        let secondSheet = try XCTUnwrap(window.attachedSheet?.contentView)
        XCTAssertEqual(try field("Pairing code", in: secondSheet).stringValue, "")
        try button("Connect & Publish Text", in: secondSheet).performClick(nil)
        eventually("remembered pairing publishes after one action") { window.attachedSheet == nil && output.content == .scripture }
        try button("Stop Presenting", in: controller.view).performClick(nil)
        eventually("stopped") { output.ownerName == nil }
    }
    func testStalledFirstConnectionRetriesAndPublishesWithoutAnotherClick() throws {
        let domain = "AltViewTests.PairingRetry.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent.scripture), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let receiver = try PairingRetryTestReceiver(key: key)
        defer { receiver.stop() }
        let listening = expectation(description: "retry receiver ready")
        receiver.start { listening.fulfill() }
        wait(for: [listening], timeout: 3)
        var published: DisplayContent?
        receiver.onContent = { published = $0 }
        let controller = TextComposerViewController(defaults: defaults,
            loadPairing: { _ in nil }, storePairing: { _, _ in }) { _ in XCTFail("Must connect remotely") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1062, height: 714), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = controller.view
        defer { controller.shutdown(); window.close() }
        let destination = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first)
        destination.selectItem(at: 1); destination.sendAction(destination.action, to: destination.target)
        let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try button("Connect using an address instead", in: sheet).performClick(nil)
        try field("Receiver address", in: sheet).stringValue = "127.0.0.1"
        try field("Receiver port", in: sheet).stringValue = String(try XCTUnwrap(receiver.port).rawValue)
        let code = try field("Pairing code", in: sheet)
        code.stringValue = PairingKey.text(key)
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: code))
        try button("Connect & Publish Text", in: sheet).performClick(nil)
        eventually("retry stays in the connection sheet", timeout: 13) {
            self.descendants(sheet).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Retrying the network") }
        }
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertFalse(code.isEnabled)
        XCTAssertNil(published)
        XCTAssertFalse(descendants(sheet).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("Couldn’t connect.") })
        eventually("original click pairs and publishes", timeout: 5) { window.attachedSheet == nil && published == .scripture }
        XCTAssertEqual(receiver.acceptedConnections, 2)
    }
    func testCancellingPairingLookupCannotConnectOrPublishLater() throws {
        let domain = "AltViewTests.CancelPairing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent.scripture), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let gate = DispatchSemaphore(value: 0)
        let lookup = expectation(description: "pairing lookup started")
        let finished = expectation(description: "cancelled lookup returned")
        let controller = TextComposerViewController(defaults: defaults,
            loadPairing: { _ in lookup.fulfill(); _ = gate.wait(timeout: .now() + 5); finished.fulfill(); return key },
            storePairing: { _, _ in XCTFail("Cancelled pairing must not be saved") }) { _ in XCTFail("Must not connect locally") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1062, height: 714), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = controller.view
        defer { gate.signal(); controller.shutdown(); window.close() }
        let destination = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first)
        destination.selectItem(at: 1); destination.sendAction(destination.action, to: destination.target)
        let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
        try button("Connect using an address instead", in: sheet).performClick(nil)
        let host = try field("Receiver address", in: sheet); host.stringValue = "127.0.0.1"
        XCTAssertEqual(try field("Receiver port", in: sheet).stringValue, "", "Manual connections must not assume the old fixed port")
        try field("Receiver port", in: sheet).stringValue = "1"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: host))
        try button("Connect & Publish Text", in: sheet).performClick(nil)
        wait(for: [lookup], timeout: 3)
        try button("Cancel", in: sheet).performClick(nil)
        gate.signal(); wait(for: [finished], timeout: 3)
        let settled = expectation(description: "late lookup discarded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(try button("Connect & Publish Text…", in: controller.view).isEnabled)
        XCTAssertFalse(try button("Stop Presenting", in: controller.view).isEnabled)
    }
    func testLowerThirdEditorInitializesWithinLaptopScreen() throws {
        let controller = LowerThirdWindowController()
        controller.update(template: LowerThirdTemplate(), style: OutputStyle(), artwork: nil, busy: false, message: "")
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.title, "AltView — Lower Third")
        XCTAssertLessThanOrEqual(window.frame.width, 1440)
        XCTAssertLessThanOrEqual(window.frame.height, 840)
        XCTAssertFalse(window.contentView?.hasAmbiguousLayout ?? true)
        controller.shutdown()
    }
    func testLowerThirdDraftStaysPrivateAcrossReceiverRefreshAndReverts() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var applied = LowerThirdTemplate(); applied.enabled = true
        controller.update(template: applied, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        var published: [LowerThirdTemplate] = []
        controller.onApply = { template, _ in published.append(template) }
        try button("Fit to Canvas", in: root).performClick(nil)
        XCTAssertEqual(controller.template.artworkRegion.width, 100)
        XCTAssertTrue(published.isEmpty, "Editing must never alter receiver output")
        controller.update(template: applied, style: OutputStyle(), artwork: nil, busy: false, message: "")
        XCTAssertEqual(controller.template.artworkRegion.width, 100, "A live status refresh must preserve the draft")
        var editTextRequests = 0
        controller.onEditText = { editTextRequests += 1 }
        try button("Edit Text…", in: root).performClick(nil)
        XCTAssertEqual(editTextRequests, 1)
        XCTAssertTrue(controller.hasChanges, "Opening Compose must preserve the private design draft")
        XCTAssertEqual(controller.template.artworkRegion.width, 100)
        XCTAssertTrue(published.isEmpty, "Opening Compose must not apply a design")
        try button("Show layout guides", in: root).performClick(nil)
        try button("Preview Animation", in: root).performClick(nil)
        XCTAssertTrue(published.isEmpty, "Preview controls are private")
        try button("Apply Design to Output", in: root).performClick(nil)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.artworkRegion.width, 100)
        XCTAssertFalse(controller.hasChanges)
        try button("Reset All Positions", in: root).performClick(nil)
        XCTAssertEqual(controller.template.artworkRegion.width, 90)
        try button("Revert Changes", in: root).performClick(nil)
        XCTAssertEqual(controller.template.artworkRegion.width, 100, "Revert restores the last applied design")
        XCTAssertEqual(published.count, 1)
    }
    func testLowerThirdInvalidInputBlocksApplyAndExplainsClamping() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let height = try field("Body Height percent", in: root)
        var published = 0
        controller.onApply = { _, _ in published += 1 }
        for text in ["oops", "nan", "inf", ""] {
            height.stringValue = text
            controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: height))
            XCTAssertFalse(try button("Apply Design to Output", in: root).isEnabled)
            controller.applyChanges()
            XCTAssertEqual(published, 0)
            XCTAssertEqual(height.stringValue, text, "Keep invalid input visible so it can be corrected")
        }
        height.stringValue = "999"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: height))
        XCTAssertEqual(controller.template.bodyRegion.height, 21)
        XCTAssertEqual(height.stringValue, "21")
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("Position or size adjusted") })
        controller.applyChanges()
        XCTAssertEqual(published, 1)
        let duration = try field("Animation duration in seconds", in: root)
        duration.stringValue = "-1"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: duration))
        XCTAssertEqual(controller.template.duration, 0.1)
        controller.revertChanges()
        XCTAssertEqual(duration.stringValue, "0.45")
    }
    func testLowerThirdNoneAnimationRecoversAnInvalidDuration() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let duration = try field("Animation duration in seconds", in: root)
        duration.stringValue = "bad"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: duration))
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Lower third animation" })
        picker.selectItem(withTitle: "None"); picker.sendAction(picker.action, to: picker.target)
        XCTAssertFalse(duration.isEnabled)
        XCTAssertEqual(duration.stringValue, "0.45")
        XCTAssertTrue(try button("Apply Design to Output", in: root).isEnabled)
        controller.applyChanges()
        XCTAssertFalse(controller.hasChanges)
        XCTAssertEqual(controller.template.animation, .none)
    }
    func testLowerThirdExternalEnableMergesWithoutLosingLayoutDraft() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        let root = try XCTUnwrap(controller.window?.contentView)
        try button("Use lower-third layout", in: root).performClick(nil)
        try button("Fit to Canvas", in: root).performClick(nil)
        try button("Use lower-third layout", in: root).performClick(nil)
        var incoming = LowerThirdTemplate(); incoming.enabled = true
        controller.update(template: incoming, style: OutputStyle(), artwork: nil, busy: false, message: "")
        XCTAssertTrue(controller.template.enabled)
        XCTAssertEqual(controller.template.artworkRegion.width, 100)
        controller.revertChanges()
        XCTAssertTrue(controller.template.enabled)
        XCTAssertEqual(controller.template.artworkRegion.width, 90)
    }
    func testLowerThirdMissingPNGCanRecoverToBuiltInWithoutImport() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var applied = LowerThirdTemplate()
        applied.enabled = true; applied.artwork = .custom; applied.assetID = UUID(); applied.assetName = "missing.png"
        controller.update(template: applied, style: OutputStyle(), artwork: nil, busy: false, message: "Saved PNG unavailable")
        let root = try XCTUnwrap(controller.window?.contentView)
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Lower third artwork" })
        XCTAssertFalse(try button("Apply Design to Output", in: root).isEnabled)
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("PNG unavailable.") })
        picker.selectItem(withTitle: "Built-in banner"); picker.sendAction(picker.action, to: picker.target)
        XCTAssertTrue(try button("Apply Design to Output", in: root).isEnabled)
        var published: LowerThirdTemplate?
        controller.onApply = { value, _ in published = value }
        controller.applyChanges()
        XCTAssertEqual(published?.artwork, .builtIn)
    }
    func testLowerThirdEditorKeepsActionsVisibleAtMinimumWindowSize() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 600))
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let apply = try button("Apply Design to Output", in: root)
        let frame = apply.convert(apply.bounds, to: root)
        XCTAssertTrue(root.bounds.contains(frame), "Apply must remain visible while settings scroll")
        XCTAssertFalse(root.hasAmbiguousLayout)
        let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentSize.height)
    }
    func testLowerThirdOptionalTextUsesDraftApplyRevertAndKeepsPositions() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let titleSwitch = try button("Title", in: root)
        let footerSwitch = try button("Footer", in: root)
        let titleHeight = try field("Title Height percent", in: root)
        let footerY = try field("Footer Y percent", in: root)
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let bodyY = try field("Body Y percent", in: root)
        let bodyHeight = try field("Body Height percent", in: root)
        let grid = try XCTUnwrap(descendants(root).compactMap { $0 as? NSGridView }.first)
        XCTAssertTrue(grid.cell(atColumnIndex: 0, rowIndex: 2).contentView === titleSwitch)
        XCTAssertTrue(grid.cell(atColumnIndex: 0, rowIndex: 4).contentView === footerSwitch)
        var applied: LowerThirdTemplate?
        controller.onApply = { value, _ in applied = value }
        XCTAssertEqual(titleSwitch.state, .on); XCTAssertEqual(footerSwitch.state, .on)
        titleHeight.stringValue = "bad"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: titleHeight))
        titleSwitch.performClick(nil); footerSwitch.performClick(nil)
        XCTAssertFalse(titleHeight.isEnabled); XCTAssertFalse(footerY.isEnabled)
        XCTAssertEqual(titleHeight.stringValue, "4", "Hiding clears invalid input but preserves the saved position")
        XCTAssertEqual(preview.accessibilityLabel(), "Jordan Lee")
        XCTAssertEqual(bodyY.stringValue, "74"); XCTAssertEqual(bodyHeight.stringValue, "20")
        XCTAssertFalse(bodyY.isEnabled); XCTAssertFalse(bodyHeight.isEnabled)
        XCTAssertTrue(try field("Body Width percent", in: root).isEnabled)
        XCTAssertNil(applied, "Visibility changes stay private until Apply")
        XCTAssertTrue(try button("Apply Design to Output", in: root).isEnabled)
        controller.applyChanges()
        XCTAssertEqual(applied?.showsTitle, false); XCTAssertEqual(applied?.showsFooter, false)
        XCTAssertEqual(applied?.bodyRegion, LowerThirdTemplate().bodyRegion)
        XCTAssertEqual(applied?.titleRegion, LowerThirdTemplate().titleRegion)
        titleSwitch.performClick(nil); footerSwitch.performClick(nil)
        XCTAssertTrue(titleHeight.isEnabled); XCTAssertTrue(footerY.isEnabled)
        XCTAssertTrue(bodyY.isEnabled); XCTAssertTrue(bodyHeight.isEnabled)
        XCTAssertEqual(bodyY.stringValue, "79"); XCTAssertEqual(bodyHeight.stringValue, "11")
        XCTAssertTrue(preview.accessibilityLabel()?.contains("GUEST SPEAKER") ?? false)
        controller.revertChanges()
        XCTAssertEqual(titleSwitch.state, .off); XCTAssertEqual(footerSwitch.state, .off)
        XCTAssertEqual(bodyY.stringValue, "74"); XCTAssertEqual(bodyHeight.stringValue, "20")
        XCTAssertEqual(preview.accessibilityLabel(), "Jordan Lee")
    }
    func testFullCanvasTextVisibilityPreviewsPublishesAndSurvivesLayoutChanges() throws {
        let domain = "AltViewTests.FullCanvasVisibility.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let content = DisplayContent(title: "Heading", body: "Main message", footer: "Credit")
        defaults.set(true, forKey: "customTextEnabled")
        try defaults.set(JSONEncoder().encode(content), forKey: "customTextDraft")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        eventually("receiver ready") { controller.receiverStatus.listening }
        controller.showDesignPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        let mode = try button("Use lower-third layout", in: root)
        let title = try button("Title", in: root)
        let footer = try button("Footer", in: root)
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(mode.state, .off)
        XCTAssertFalse(preview.presentation.template.enabled)
        title.performClick(nil)
        XCTAssertEqual(preview.accessibilityLabel(), "Main message\nCredit")
        footer.performClick(nil)
        XCTAssertEqual(preview.accessibilityLabel(), "Main message")
        XCTAssertEqual(preview.content, content, "Hiding a row must preserve its text")
        XCTAssertEqual(controller.receiverStatus.content, .empty, "Visibility edits remain private")
        controller.showComposerPage()
        let textPreview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(textPreview.accessibilityLabel(), "Main message")
        XCTAssertEqual(descendants(root).compactMap { $0 as? NSTextField }.filter { $0.stringValue == "Hidden by Design · text is kept" }.count, 2)
        try button("Publish Text & Design", in: root).performClick(nil)
        eventually("text and visibility published") { controller.receiverStatus.content == content }
        let saved = try JSONDecoder().decode(LowerThirdTemplate.self, from: XCTUnwrap(defaults.data(forKey: "lowerThirdTemplate")))
        XCTAssertFalse(saved.enabled); XCTAssertFalse(saved.showsTitle); XCTAssertFalse(saved.showsFooter)
        controller.showReceiverPage()
        let live = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(live.accessibilityLabel(), "Main message")
        XCTAssertEqual(live.content, content)
        controller.showDesignPage()
        mode.performClick(nil)
        XCTAssertTrue(preview.presentation.template.enabled)
        XCTAssertEqual(preview.accessibilityLabel(), "Main message")
        title.performClick(nil); footer.performClick(nil)
        XCTAssertEqual(preview.accessibilityLabel(), "Heading\nMain message\nCredit")
        mode.performClick(nil)
        XCTAssertFalse(preview.presentation.template.enabled)
        XCTAssertEqual(preview.accessibilityLabel(), "Heading\nMain message\nCredit")
        try button("Revert Changes", in: root).performClick(nil)
        XCTAssertEqual(title.state, .off); XCTAssertEqual(footer.state, .off)
        XCTAssertEqual(preview.accessibilityLabel(), "Main message")
    }
    func testFullCanvasCanApplyAfterHidingInvalidLowerThirdFields() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        for label in ["Body Height percent", "Animation duration in seconds"] {
            let input = try field(label, in: root)
            input.stringValue = "bad"
            controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: input))
        }
        XCTAssertFalse(controller.canPublish)
        try button("Use lower-third layout", in: root).performClick(nil)
        XCTAssertTrue(controller.canPublish, "Hidden lower-third fields must not block full-canvas output")
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertFalse(preview.presentation.template.enabled, "Sample previews must use the selected layout too")
        controller.applyChanges()
        XCTAssertFalse(controller.template.enabled)
        XCTAssertEqual(controller.template.bodyRegion, baseline.bodyRegion)
        XCTAssertEqual(controller.template.duration, baseline.duration)
        try button("Use lower-third layout", in: root).performClick(nil)
        XCTAssertTrue(try field("Body Height percent", in: root).isEnabled)
        XCTAssertEqual(try field("Animation duration in seconds", in: root).stringValue, "0.45")
    }
    func testArtworkToggleKeepsDraftPrivateAndPreservesSavedPlacement() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        baseline.artworkRegion = TemplateRegion(x: 4, y: 68, width: 92, height: 28)
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let toggle = try button("Artwork", in: root)
        let width = try field("Artwork Width percent", in: root)
        let grid = try XCTUnwrap(descendants(root).compactMap { $0 as? NSGridView }.first)
        XCTAssertTrue(grid.cell(atColumnIndex: 0, rowIndex: 1).contentView === toggle)
        XCTAssertEqual(toggle.state, .on)
        var published: LowerThirdTemplate?
        controller.onApply = { value, _ in published = value }
        width.stringValue = "bad"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: width))
        toggle.performClick(nil)
        XCTAssertFalse(width.isEnabled)
        XCTAssertEqual(width.stringValue, "92")
        XCTAssertFalse(try button("Fit to Canvas", in: root).isEnabled)
        XCTAssertTrue(controller.canPublish, "Hidden artwork's disabled fields must not block publication")
        XCTAssertNil(published)
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        XCTAssertFalse(controller.template.showsArtwork, "A receiver refresh must preserve the draft")
        controller.applyChanges()
        XCTAssertEqual(published?.showsArtwork, false)
        XCTAssertEqual(published?.artworkRegion, baseline.artworkRegion)
        XCTAssertEqual(published?.bodyRegion, baseline.bodyRegion)
        toggle.performClick(nil)
        XCTAssertTrue(width.isEnabled)
        XCTAssertTrue(try button("Fit to Canvas", in: root).isEnabled)
        XCTAssertEqual(controller.template.artworkRegion, baseline.artworkRegion)
        controller.revertChanges()
        XCTAssertEqual(toggle.state, .off)
        XCTAssertFalse(controller.hasChanges)
    }
    func testHiddenMissingArtworkCanPublishTextAndPersistTheChoice() throws {
        let domain = "AltViewTests.HiddenArtwork.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let content = DisplayContent(title: "Title", body: "Text without artwork", footer: "Footer")
        defaults.set(true, forKey: "customTextEnabled")
        try defaults.set(JSONEncoder().encode(content), forKey: "customTextDraft")
        var template = LowerThirdTemplate(); template.enabled = true; template.artwork = .custom
        template.assetID = UUID(); template.assetName = "missing.png"
        try defaults.set(JSONEncoder().encode(template), forKey: "lowerThirdTemplate")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        eventually("receiver ready") { controller.receiverStatus.listening }
        controller.showDesignPage()
        eventually("missing PNG reported") {
            self.descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("PNG unavailable.") }
        }
        try button("Artwork", in: root).performClick(nil)
        let draft = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertTrue(draft.content.visible)
        XCTAssertEqual(draft.accessibilityLabel(), "Title\nText without artwork\nFooter")
        XCTAssertTrue(try button("Apply Design to Output", in: root).isEnabled)
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let publish = try button("Publish Text & Design", in: root)
        XCTAssertTrue(publish.isEnabled)
        publish.performClick(nil)
        eventually("text published without the missing PNG") { controller.receiverStatus.content == content }
        let saved = try JSONDecoder().decode(LowerThirdTemplate.self, from: XCTUnwrap(defaults.data(forKey: "lowerThirdTemplate")))
        XCTAssertFalse(saved.showsArtwork)
        XCTAssertEqual(saved.assetID, template.assetID)
        XCTAssertEqual(saved.artwork, .custom)
        controller.showReceiverPage()
        let live = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(live.content, content, "A hidden missing PNG must not blank live output")
        XCTAssertFalse(live.presentation.template.showsArtwork)
        controller.showDesignPage()
        try button("Artwork", in: root).performClick(nil)
        XCTAssertFalse(try button("Apply Design to Output", in: root).isEnabled, "Showing the missing PNG must require recovery again")
    }
    func testAutomaticBodyPlacementClearsErrorsInCalculatedFields() throws {
        let controller = LowerThirdWindowController()
        defer { controller.shutdown() }
        var baseline = LowerThirdTemplate(); baseline.enabled = true
        controller.update(template: baseline, style: OutputStyle(), artwork: nil, busy: false, message: "")
        let root = try XCTUnwrap(controller.window?.contentView)
        let bodyY = try field("Body Y percent", in: root)
        bodyY.stringValue = "bad"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: bodyY))
        XCTAssertFalse(try button("Apply Design to Output", in: root).isEnabled)
        try button("Title", in: root).performClick(nil)
        XCTAssertFalse(bodyY.isEnabled)
        XCTAssertEqual(bodyY.stringValue, "74")
        XCTAssertTrue(try button("Apply Design to Output", in: root).isEnabled)
        controller.applyChanges()
        XCTAssertFalse(controller.hasChanges)
        XCTAssertEqual(controller.template.bodyRegion.y, 79)
    }
    func testComposerEmbedsWithoutConnectingOrOpeningAnotherWindow() throws {
        let domain = "AltViewTests.Composer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var connections = 0
        let controller = TextComposerViewController(defaults: defaults) { _ in connections += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1062, height: 714), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.contentView?.hasAmbiguousLayout ?? true)
        XCTAssertEqual(connections, 0, "Opening the composer must not connect or take output")
        controller.shutdown()
        window.close()
    }
    func testWorkspaceDraftPreviewAndAtomicLocalPublication() throws {
        let domain = "AltViewTests.Workspace.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let original = DisplayContent(title: "Draft title", body: "Private rehearsal", footer: "Draft footer")
        try defaults.set(JSONEncoder().encode(original), forKey: "customTextDraft")
        var base = LowerThirdTemplate(); base.enabled = true
        try defaults.set(JSONEncoder().encode(base), forKey: "lowerThirdTemplate")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        eventually("receiver ready") { controller.receiverStatus.listening }
        controller.showDesignPage()
        root.layoutSubtreeIfNeeded()
        let designScroll = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(designScroll.frame.height, 200, "Embedded Design must keep its settings and preview visible")
        let background = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Draft keying background" })
        background.selectItem(at: 1); background.sendAction(background.action, to: background.target)
        try button("Title", in: root).performClick(nil)
        XCTAssertNil(defaults.data(forKey: "outputStyle"), "Appearance stays private before publishing")
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(preview.style.background, "00FF00")
        XCTAssertEqual(preview.accessibilityLabel(), "Private rehearsal\nDraft footer")
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Hidden by Design · text is kept" })
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        try button("Publish Text & Design", in: root).performClick(nil)
        // A later edit must not enter the snapshot requested by the click.
        let title = try field("Text title", in: root)
        title.stringValue = "Next draft"
        title.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: title))
        eventually("text and design accepted") {
            controller.receiverStatus.content == original && defaults.data(forKey: "outputStyle") != nil
        }
        let saved = try JSONDecoder().decode(OutputStyle.self, from: XCTUnwrap(defaults.data(forKey: "outputStyle")))
        XCTAssertEqual(saved.background, "00FF00")
        let savedLayout = try JSONDecoder().decode(LowerThirdTemplate.self, from: XCTUnwrap(defaults.data(forKey: "lowerThirdTemplate")))
        XCTAssertFalse(savedLayout.showsTitle)
        XCTAssertEqual(title.stringValue, "Next draft")
        controller.showReceiverPage()
        let live = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(live.style.background, "00FF00")
        XCTAssertEqual(live.content, original)
        XCTAssertEqual(live.accessibilityLabel(), "Private rehearsal\nDraft footer")
        controller.showDesignPage()
        let font = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Draft font" })
        font.selectItem(withTitle: "Georgia"); font.sendAction(font.action, to: font.target)
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let republish = try button("Publish Text & Design", in: root)
        republish.sendAction(republish.action, to: republish.target)
        let hide = try button("Hide Text", in: root)
        hide.sendAction(hide.action, to: hide.target)
        eventually("hidden during pending publication") { !controller.receiverStatus.content.visible }
        let stillApplied = try JSONDecoder().decode(OutputStyle.self, from: XCTUnwrap(defaults.data(forKey: "outputStyle")))
        XCTAssertEqual(stillApplied.fontName, "System")
        controller.showDesignPage()
        XCTAssertTrue(try button("Apply Design to Output", in: root).isEnabled, "Hide must release the publishing lock and retain the draft design")
    }

    func testExternalSourcePreviewAndDesignApplyPreserveOwnership() throws {
        let domain = "AltViewTests.ExternalWorkspace.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let draft = DisplayContent(body: "Local private draft")
        try defaults.set(JSONEncoder().encode(draft), forKey: "customTextDraft")
        let key = try PairingKey.generate()
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: key, receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        eventually("receiver ready") { controller.receiverStatus.port != nil }
        var status = SenderStatus()
        let sender = SenderClient(name: "Presentation App") { status = $0 }
        defer { sender.disconnect() }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: controller.receiverStatus.port!)!), key: key)
        eventually("sender connected") { status.connected }
        let text = DisplayContent(title: "External title", body: "External body", footer: "External footer")
        sender.submit(text); sender.takeOutput()
        eventually("external live") { controller.receiverStatus.content == text }
        controller.showDesignPage()
        let root = try XCTUnwrap(controller.window?.contentView)
        let picker = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Design preview content" })
        XCTAssertEqual(picker.titleOfSelectedItem, "Current source")
        XCTAssertNil(picker.item(withTitle: "Text draft"))
        XCTAssertTrue(try button("Open Text Draft…", in: root).isHidden)
        let designPreview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(designPreview.content, text)
        try button("Use lower-third layout", in: root).performClick(nil)
        try button("Footer", in: root).performClick(nil)
        XCTAssertEqual(controller.receiverStatus.content, text)
        try button("Apply Design to Output", in: root).performClick(nil)
        XCTAssertEqual(controller.receiverStatus.ownerID, sender.senderID)
        XCTAssertEqual(controller.receiverStatus.content, text)
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        XCTAssertEqual(controller.receiverStatus.connections, 1, "Enabling Custom Text must not connect another sender")
        controller.showDesignPage()
        XCTAssertEqual(picker.titleOfSelectedItem, "Current source")
        XCTAssertFalse(try button("Open Text Draft…", in: root).isHidden)
        try button("Open Text Draft…", in: root).performClick(nil)
        let localPreview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        XCTAssertEqual(localPreview.content, draft)
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Publishing your message will replace this source’s text") })
        XCTAssertEqual(controller.receiverStatus.ownerID, sender.senderID)
        XCTAssertEqual(controller.receiverStatus.content, text)
        controller.setCustomTextEnabled(false)
        XCTAssertTrue(controller.receiverStatus.listening)
        XCTAssertEqual(controller.receiverStatus.ownerID, sender.senderID)
        XCTAssertEqual(controller.receiverStatus.content, text)
    }

    func testCancelLocalPublishKeepsStagedDesignAndSavedTextPrivate() throws {
        let domain = "AltViewTests.CancelWorkspace.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try defaults.set(JSONEncoder().encode(DisplayContent(body: "Cancel this publication")), forKey: "customTextDraft")
        let controller = ReceiverWindowController(defaults: defaults, pairingKey: try PairingKey.generate(), receiverPort: 0)
        defer { controller.shutdown(); controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.showDesignPage()
        let font = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Draft font" })
        font.selectItem(withTitle: "Georgia"); font.sendAction(font.action, to: font.target)
        controller.setCustomTextEnabled(true); controller.showComposerPage()
        let publish = try button("Publish Text & Design", in: root)
        publish.sendAction(publish.action, to: publish.target)
        let stop = try button("Stop Presenting", in: root)
        stop.sendAction(stop.action, to: stop.target)
        eventually("receiver ready after cancellation") { controller.receiverStatus.listening }
        XCTAssertNil(controller.receiverStatus.ownerID)
        XCTAssertEqual(controller.receiverStatus.content, .empty)
        XCTAssertNil(defaults.data(forKey: "outputStyle"))
        controller.showDesignPage()
        XCTAssertTrue(try button("Apply Design to Output", in: root).isEnabled)
        XCTAssertEqual(font.titleOfSelectedItem, "Georgia")
        try button("Revert Changes", in: root).performClick(nil)
        XCTAssertEqual(font.titleOfSelectedItem, "System")
    }

    func testDesignAppearanceRevertAndInvalidLayoutBlockPublication() throws {
        let editor = LowerThirdWindowController()
        defer { editor.shutdown() }
        var applied = LowerThirdTemplate(); applied.enabled = true
        editor.update(template: applied, style: OutputStyle(), artwork: nil, busy: false, message: "")
        editor.updateContent(draft: DisplayContent(body: "My draft"), source: .empty, externalSource: nil)
        let root = editor.contentView
        let preview = try XCTUnwrap(descendants(root).compactMap { $0 as? OutputCanvas }.first)
        let font = try XCTUnwrap(descendants(root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Draft font" })
        font.selectItem(withTitle: "Georgia"); font.sendAction(font.action, to: font.target)
        editor.update(template: applied, style: OutputStyle(), artwork: nil, busy: false, message: "")
        XCTAssertEqual(preview.style.fontName, "Georgia")
        XCTAssertEqual(preview.accessibilityLabel(), "My draft")
        let height = try field("Body Height percent", in: root)
        height.stringValue = "oops"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: height))
        XCTAssertFalse(editor.canPublish)
        editor.revertChanges()
        XCTAssertTrue(editor.canPublish)
        XCTAssertEqual(preview.style.fontName, "System")
        XCTAssertFalse(editor.hasChanges)
    }

}
