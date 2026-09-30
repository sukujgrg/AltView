import AppKit

final class ReceiverWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private let defaults: UserDefaults
    private(set) var customTextEnabled: Bool
    var onCustomTextSettingChange: (() -> Void)?
    private let receiverPort: UInt16
    private var stopped = false
    private(set) var pairingKey: Data?
    private(set) var receiverStatus = ReceiverStatus()
    private var localWaiters: [(Result<LocalReceiverConnection, Error>) -> Void] = []
    private var starting = false
    private var server: ReceiverServer!
    private let presentation = CanvasPresentation()
    private lazy var output = OutputWindowController(presentation: presentation)
    private lazy var preview = OutputCanvas(presentation: presentation)
    private let artworkStore = PNGArtworkStore()
    private var template = LowerThirdTemplate()
    private var artwork: PNGArtwork?
    private var artworkRevision = UUID()
    private var artworkBusy = false
    private var artworkMessage = ""
    private var templateEditor: LowerThirdWindowController?
    private let nameField = NSTextField(string: "")
    private let statusLabel = UI.label("Preparing receiver…", size: 16, bold: true)
    private let ownerLabel = UI.label("No sender controls the output", size: 14, bold: true)
    private let networkLabel = UI.label("Receiving starts automatically when AltView opens.", size: 11, color: .secondaryLabelColor)
    private let pairingLabel = UI.label("Pairing uses an encrypted connection. Share the code with your sender once.", size: 11, color: .secondaryLabelColor)
    private let pairingInstructions = UI.label("On the other Mac, open your app’s AltView connection settings. Choose this receiver and enter the code below.", size: 13)
    private let pairingCodeField = NSTextField(labelWithString: "--------")
    private var copyButton: NSButton!
    private var resetButton: NSButton!
    private var clearButton: NSButton!
    private let outputLabel = UI.label("Output window closed", size: 11, color: .secondaryLabelColor)
    private let fitLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let displayPicker = NSPopUpButton()
    private var receiveButton: NSButton!
    private var style = OutputStyle()
    private var screenObserver: NSObjectProtocol?
    private let sectionPicker = NSSegmentedControl(labels: ["Output", "Design"], trackingMode: .selectOne, target: nil, action: nil)
    private let settingsButton = NSButton()
    private lazy var customTextSwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self; control.action = #selector(customTextSettingChanged)
        control.setAccessibilityLabel("Custom Text")
        control.setAccessibilityIdentifier("enableCustomText")
        return control
    }()
    private lazy var settingsPopover: NSPopover = {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 196))
        let content = UI.column(
            UI.label("Settings", size: 17, bold: true),
            UI.row(UI.label("Custom Text", size: 13, bold: true), NSView(), customTextSwitch),
            UI.label("Compose messages on this Mac or send them to another AltView.", size: 12, color: .secondaryLabelColor),
            UI.label("Turning this off stops Custom Text. Your draft is kept.", size: 11, color: .secondaryLabelColor),
            NSView(), spacing: 12)
        UI.fill(content, in: controller.view, padding: 20)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        return popover
    }()
    private let pages = NSTabView()
    private var composer: TextComposerViewController!
    private var pendingLocalContent: DisplayContent?
    private let contentBadge = StatusBadge("NO TEXT")
    private var updatingDraft = false

    init(defaults: UserDefaults = .standard, pairingKey: Data? = nil, receiverPort: UInt16 = 49721) {
        self.defaults = defaults; self.receiverPort = receiverPort
        customTextEnabled = defaults.bool(forKey: "customTextEnabled")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AltView"
        window.subtitle = "Presentation workspace"
        window.contentMinSize = NSSize(width: 980, height: 650)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.colorSpace = .sRGB
        super.init(window: window)
        let id = defaults.string(forKey: "receiverID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(id.uuidString, forKey: "receiverID")
        if let data = defaults.data(forKey: "outputStyle"), let saved = try? JSONDecoder().decode(OutputStyle.self, from: data) { style = saved }
        if let data = defaults.data(forKey: "lowerThirdTemplate"),
           let saved = try? JSONDecoder().decode(LowerThirdTemplate.self, from: data) { template = saved.clamped() }
        server = ReceiverServer(receiverID: id) { [weak self] status in self?.update(status) }
        output.onChange = { [weak self] text in
            self?.outputLabel.stringValue = text
            self?.composer?.updateLocalDisplay(text)
        }
        composer = TextComposerViewController(defaults: defaults, localReceiverID: id) { [weak self] completion in
            self?.connectLocal(completion)
        }
        composer.showReceiver = { [weak self] in self?.showReceiverPage() }
        composer.showDesign = { [weak self] in self?.showDesignPage() }
        composer.onDraftChange = { [weak self] _ in self?.refreshDraft() }
        composer.prepareLocalPublish = { [weak self] content in
            guard let self, let editor = self.templateEditor else { return false }
            editor.finishEditing()
            guard editor.canPublish else { self.showDesignPage(); return false }
            var snapshot = content; snapshot.visible = true
            self.pendingLocalContent = snapshot
            editor.setPublishing(true)
            return true
        }
        composer.cancelLocalPublish = { [weak self] in self?.cancelLocalPublish() }
        let editor = LowerThirdWindowController(artworkStore: artworkStore)
        templateEditor = editor
        editor.onApplyStyle = { [weak self] value in
            self?.style = value
            self?.defaults.set(try? JSONEncoder().encode(value), forKey: "outputStyle")
        }
        editor.onApply = { [weak self] value, artwork in self?.applyDesign(value, artwork: artwork) }
        editor.onDraftChange = { [weak self] in self?.refreshDraft() }
        editor.onEditText = { [weak self] in self?.showComposerPage(); self?.composer.focusTitle() }
        buildInterface()
        window.delegate = self
        refreshCanvas()
        refreshDisplays()
        nameField.stringValue = defaults.string(forKey: "receiverName") ?? "AltView — \(Host.current().localizedName ?? "This Mac")"
        nameField.delegate = self
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshDisplays() }
        window.center()
        if let pairingKey {
            self.pairingKey = pairingKey
            pairingCodeField.stringValue = PairingKey.text(pairingKey)
            startReceiving()
        } else { preparePairing(reset: false, resume: true) }
        loadArtwork()

    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        receiveButton = UI.button("Preparing…", target: self, action: #selector(toggleReceiving))
        receiveButton.isEnabled = false
        receiveButton.setAccessibilityIdentifier("startReceiving")
        nameField.placeholderString = "Receiver name"
        nameField.setAccessibilityLabel("Receiver name")
        nameField.font = .systemFont(ofSize: 13, weight: .medium)
        copyButton = UI.button("Copy Code", target: self, action: #selector(copyPairingCode))
        copyButton.isEnabled = false
        pairingCodeField.font = .monospacedSystemFont(ofSize: 25, weight: .semibold)
        pairingCodeField.isSelectable = true
        pairingCodeField.setAccessibilityLabel("Pairing code")
        pairingCodeField.setAccessibilityIdentifier("receiverPairingCode")
        copyButton.setAccessibilityLabel("Copy Pairing Code")
        resetButton = UI.button("Reset Code…", target: self, action: #selector(resetPairing))
        resetButton.isEnabled = false
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        pairingInstructions.font = .systemFont(ofSize: 12)
        let receiverCard = UI.card("Receive on this Mac", content: UI.column(
            statusLabel, nameField, UI.separator(), UI.row(pairingCodeField, copyButton, NSView()),
            pairingInstructions, pairingLabel, UI.row(receiveButton, resetButton, NSView()), spacing: 10))

        displayPicker.setAccessibilityLabel("Output display")
        displayPicker.target = self; displayPicker.action = #selector(displayChanged)
        let open = UI.primaryButton("Open Output", target: self, action: #selector(showOutput))
        let close = UI.button("Close Output", target: self, action: #selector(closeOutput))
        let displayCard = UI.card("Output display", content: UI.column(displayPicker,
            UI.row(open, close, NSView()), outputLabel,
            UI.label("Use Preview Window to rehearse, or choose your connected display.", size: 11, color: .secondaryLabelColor), spacing: 10))
        let inspector = UI.column(UI.scrolling(receiverCard), displayCard, spacing: 14)
        inspector.widthAnchor.constraint(equalToConstant: 300).isActive = true
        inspector.setAccessibilityLabel("Output settings")

        clearButton = UI.button("Clear & Release", target: self, action: #selector(clearOutput))
        clearButton.isEnabled = false
        clearButton.toolTip = "Clear the current source and release its control of output."
        let stage = UI.canvasStage(preview)
        let previewTitle = UI.row(UI.label("THIS MAC · OUTPUT PREVIEW", size: 11, color: .secondaryLabelColor, bold: true),
                                 NSView(), UI.label("16:9", size: 11, color: .secondaryLabelColor))
        ownerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        contentBadge.setAccessibilityIdentifier("workspaceContentStatus")
        ownerLabel.maximumNumberOfLines = 1; ownerLabel.lineBreakMode = .byTruncatingTail
        ownerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let monitor = UI.column(previewTitle, stage, UI.row(contentBadge, ownerLabel, NSView()), fitLabel,
            UI.row(UI.button("Edit Design", target: self, action: #selector(showDesignPage)), NSView(), clearButton), spacing: 12)
        monitor.distribution = .fill
        let body = UI.row(monitor, inspector)
        body.alignment = .top; body.spacing = 24
        monitor.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -324).isActive = true
        monitor.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        inspector.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let root = UI.column(UI.pageHeading("Output", subtitle: "Receive from your presentation app and monitor this Mac’s picture."), body, spacing: 20)
        root.distribution = .fill
        // Seed tab geometry before the first layout pass.
        pages.frame = NSRect(x: 0, y: 0, width: 1100, height: 614)
        let receiverPage = NSView(frame: pages.contentRect)
        UI.fill(root, in: receiverPage, padding: 0)
        pages.tabViewType = .noTabsNoBorder
        let receiverItem = NSTabViewItem(identifier: "receiver"); receiverItem.view = receiverPage; receiverItem.label = "Output"
        let designPage = NSView(frame: pages.contentRect)
        UI.fill(templateEditor!.contentView, in: designPage, padding: 0)
        let designItem = NSTabViewItem(identifier: "design"); designItem.view = designPage; designItem.label = "Design"
        pages.addTabViewItem(receiverItem); pages.addTabViewItem(designItem)
        if customTextEnabled { addTextPage() }
        updateNavigation()
        sectionPicker.selectedSegment = 0
        sectionChanged()
        sectionPicker.target = self; sectionPicker.action = #selector(sectionChanged)
        sectionPicker.setAccessibilityLabel("AltView workspace")
        sectionPicker.segmentStyle = .rounded
        sectionPicker.font = .systemFont(ofSize: 13, weight: .medium)
        let icon = NSImageView(image: NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsButton.imagePosition = .imageOnly
        settingsButton.bezelStyle = .rounded
        settingsButton.title = ""
        settingsButton.toolTip = "Settings"
        settingsButton.setAccessibilityLabel("Settings")
        settingsButton.setAccessibilityIdentifier("workspaceSettings")
        settingsButton.target = self; settingsButton.action = #selector(showSettings)
        settingsButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let header = UI.row(icon, UI.label("AltView", size: 20, bold: true), NSView(), sectionPicker, settingsButton)
        header.setCustomSpacing(14, after: sectionPicker)
        header.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let main = UI.column(header, UI.separator(), pages, spacing: 16)
        // Fill the window so extra height belongs to the page, not a trailing gravity area.
        main.distribution = .fill
        UI.fill(main, in: window!.contentView!, padding: 20)
    }
    private func update(_ status: ReceiverStatus) {
        guard !stopped else { return }
        receiverStatus = status
        starting = false
        receiveButton.title = status.listening ? "Pause Receiving" : "Resume Receiving"
        receiveButton.isEnabled = pairingKey != nil
        copyButton.isEnabled = pairingKey != nil
        resetButton.isEnabled = pairingKey != nil
        nameField.isEditable = !status.listening
        nameField.isSelectable = true
        nameField.drawsBackground = !status.listening
        nameField.isBezeled = !status.listening
        nameField.toolTip = status.listening ? "Pause receiving to change this Mac’s receiver name." : nil
        statusLabel.stringValue = status.listening ? (status.ownerName == nil ? "Ready to receive" : "Receiving text") : (status.message.hasPrefix("Could not") ? status.message : "Receiving paused")
        statusLabel.textColor = status.listening ? .systemGreen : .secondaryLabelColor
        pairingInstructions.stringValue = status.listening
            ? "Choose this Mac in your sending app’s AltView settings and enter this code."
            : "Resume receiving, then choose this Mac in your sending app’s AltView settings and enter the code."
        networkLabel.stringValue = status.port.map { "Visible on your local network · Port \($0)\n\(status.connections) connected sender\(status.connections == 1 ? "" : "s")" } ?? "Resume receiving to let another Mac connect."
        statusLabel.toolTip = networkLabel.stringValue
        statusLabel.setAccessibilityHelp(networkLabel.stringValue)
        ownerLabel.stringValue = status.ownerName.map { "From \(status.ownerID == composer.senderID ? "Text on this Mac" : $0)" }
            ?? (status.connections > 0 ? "Sender connected · waiting for text" : "No active sender")
        ownerLabel.toolTip = ownerLabel.stringValue
        clearButton.isEnabled = status.ownerName != nil
        // Commit the frozen design only when the receiver accepts this sender's
        // requested text. A failed connection cannot restyle an external source.
        if let pending = pendingLocalContent, status.ownerID == composer.senderID, status.content == pending {
            pendingLocalContent = nil
            templateEditor?.setPublishing(false)
            templateEditor?.applyChanges()
        }
        refreshCanvas()
        if status.listening, let port = status.port, let key = pairingKey {
            let waiters = localWaiters; localWaiters.removeAll()
            waiters.forEach { $0(.success(LocalReceiverConnection(port: port, key: key))) }
        } else if !status.listening && status.message.hasPrefix("Could not") { failLocalConnections(status.message) }
    }
    func connectLocal(_ completion: @escaping (Result<LocalReceiverConnection, Error>) -> Void) {
        guard !stopped else { return }
        guard let key = pairingKey else { localWaiters.append(completion); return }
        if receiverStatus.listening, let port = receiverStatus.port { completion(.success(LocalReceiverConnection(port: port, key: key))) }
        else { localWaiters.append(completion); if !starting { startReceiving() } }
    }
    private func failLocalConnections(_ message: String) {
        let waiters = localWaiters; localWaiters.removeAll()
        waiters.forEach { $0(.failure(ComposerConnectionError(message: message))) }
    }
    @objc private func sectionChanged() {
        window?.makeFirstResponder(nil)
        pages.selectTabViewItem(at: sectionPicker.selectedSegment)
        refreshDraft()
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    private func addTextPage() {
        let item = NSTabViewItem(identifier: "write")
        // Give the newly revealed page its actual width before AppKit measures
        // wrapping labels and derives the window's minimum content size.
        window?.contentView?.layoutSubtreeIfNeeded()
        composer.view.frame = pages.contentRect
        item.label = "Text"; item.view = composer.view
        pages.addTabViewItem(item)
    }
    private func updateNavigation() {
        sectionPicker.segmentCount = pages.numberOfTabViewItems
        for (index, item) in pages.tabViewItems.enumerated() {
            sectionPicker.setLabel(item.label, forSegment: index)
            sectionPicker.setWidth(88, forSegment: index)
        }
    }
    private func showPage(_ identifier: String) {
        let index = pages.indexOfTabViewItem(withIdentifier: identifier)
        guard index != NSNotFound else { return }
        sectionPicker.selectedSegment = index
        sectionChanged(); showWindow(nil)
    }
    @objc func showComposerPage() {
        guard customTextEnabled else { return }
        showPage("write")
        window?.makeKeyAndOrderFront(nil)
    }
    @objc func showSettings() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if settingsPopover.isShown { settingsPopover.performClose(nil); return }
        window?.makeFirstResponder(nil)
        customTextSwitch.state = customTextEnabled ? .on : .off
        settingsPopover.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .minY)
    }
    @objc private func customTextSettingChanged() {
        setCustomTextEnabled(customTextSwitch.state == .on)
    }
    func setCustomTextEnabled(_ enabled: Bool) {
        guard enabled != customTextEnabled else { return }
        window?.makeFirstResponder(nil)
        let selection = pages.selectedTabViewItem?.identifier as? String ?? "receiver"
        customTextEnabled = enabled
        defaults.set(enabled, forKey: "customTextEnabled")
        customTextSwitch.state = enabled ? .on : .off
        if enabled {
            addTextPage()
        } else {
            composer.deactivate()
            failLocalConnections("Custom Text is turned off.")
            if let item = pages.tabViewItems.first(where: { $0.identifier as? String == "write" }) {
                pages.removeTabViewItem(item)
            }
        }
        updateNavigation()
        let destination = !enabled && selection == "write" ? "receiver" : selection
        sectionPicker.selectedSegment = pages.indexOfTabViewItem(withIdentifier: destination)
        sectionChanged()
        onCustomTextSettingChange?()
    }
    @objc func showReceiverPage() { showPage("receiver") }
    @objc private func toggleReceiving() {
        receiveButton.isEnabled = false
        if receiverStatus.listening { server.stop(); failLocalConnections("Receiving paused.") } else { startReceiving() }
    }
    private func startReceiving() {
        guard let key = pairingKey, !starting, !stopped else { return }
        let enteredName = String(nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
        let name = enteredName.isEmpty ? "AltView — \(Host.current().localizedName ?? "This Mac")" : enteredName
        nameField.stringValue = name
        starting = true
        defaults.set(name, forKey: "receiverName")
        receiveButton.isEnabled = false
        statusLabel.stringValue = "Starting receiver…"
        server.start(name: name, key: key, port: receiverPort)
    }
    @objc private func copyPairingCode() {
        guard let pairingKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PairingKey.text(pairingKey), forType: .string)
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.copyButton.title = "Copy Code" }
    }
    @objc private func resetPairing() {
        let alert = NSAlert()
        alert.messageText = "Reset AltView pairing?"
        alert.informativeText = "Connected senders will disconnect and output will clear. Each sender will need the new pairing code."
        alert.addButton(withTitle: "Reset Pairing"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let resume = self.receiverStatus.listening || self.starting
            self.cancelLocalPublish()
            self.server.stop(); self.starting = false
            self.failLocalConnections("Pairing code changed. Publish again when ready.")
            self.pairingKey = nil; self.receiveButton.isEnabled = false
            self.copyButton.isEnabled = false; self.resetButton.isEnabled = false
            self.pairingCodeField.stringValue = "--------"
            self.preparePairing(reset: true, resume: resume)
        }
    }
    private func preparePairing(reset: Bool, resume: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let key: Data
                var saved = true
                do {
                    // Unreadable or obsolete saved codes are replaced with the current format.
                    let existing = reset ? nil : try? KeyStore.read("receiver")
                    if let existing { key = existing }
                    else {
                        let newKey = try PairingKey.generate()
                        try KeyStore.save(newKey, account: "receiver")
                        key = newKey
                    }
                } catch {
                    // Ad-hoc builds cannot use the data-protection Keychain.
                    // Keep a fresh secret only in memory; never store it in defaults.
                    key = try PairingKey.generate()
                    saved = false
                }
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
                    self.pairingKey = key
                    self.pairingCodeField.stringValue = PairingKey.text(key)
                    self.receiveButton.isEnabled = true
                    self.copyButton.isEnabled = true; self.resetButton.isEnabled = true
                    self.receiveButton.title = "Resume Receiving"
                    self.statusLabel.stringValue = "Receiving paused"
                    self.pairingLabel.stringValue = saved
                        ? "Enter this code on the sending Mac. The connection is encrypted."
                        : "This code changes when AltView restarts. Enter it on the sending Mac."
                    if resume || !self.localWaiters.isEmpty { self.startReceiving() }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
                    self.statusLabel.stringValue = "Could not prepare pairing: \(error.localizedDescription)"
                    self.failLocalConnections(self.statusLabel.stringValue)
                }
            }
        }
    }

    private func refreshDisplays() {
        let saved = defaults.integer(forKey: "outputDisplayID")
        displayPicker.removeAllItems()
        displayPicker.addItem(withTitle: "Preview Window · 16:9")
        displayPicker.lastItem?.tag = 0
        for screen in NSScreen.screens {
            let id = OutputWindowController.displayID(screen)
            let suffix = CGDisplayIsBuiltin(id) != 0 ? " · Built-in" : ""
            displayPicker.addItem(withTitle: "\(screen.localizedName)\(suffix)")
            displayPicker.lastItem?.tag = Int(id)
        }
        if saved != 0, !displayPicker.itemArray.contains(where: { $0.tag == saved }) {
            displayPicker.addItem(withTitle: "Saved display · Disconnected")
            displayPicker.lastItem?.tag = saved
        }
        if !displayPicker.selectItem(withTag: saved) { displayPicker.selectItem(at: 0) }
    }
    @objc private func displayChanged() { defaults.set(displayPicker.selectedItem?.tag ?? 0, forKey: "outputDisplayID") }
    @objc private func showOutput() {
        let id = UInt32(clamping: displayPicker.selectedItem?.tag ?? 0)
        defaults.set(Int(id), forKey: "outputDisplayID")
        if id != 0 && NSScreen.screens.first.map(OutputWindowController.displayID) == id {
            let alert = NSAlert()
            alert.messageText = "Use the main display for output?"
            alert.informativeText = "AltView will cover this display. Press Command-Shift-O to close the output. Preview Window shows output alongside the controls."
            alert.addButton(withTitle: "Open Output"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window!) { [weak self] response in if response == .alertFirstButtonReturn { self?.output.show(displayID: id) } }
        } else { output.show(displayID: id == 0 ? nil : id) }
    }
    @objc func closeOutput() { output.stop() }
    @objc private func clearOutput() { server.clearOutput() }
    private func refreshCanvas() {
        var content = receiverStatus.content
        let unavailable = template.requiresCustomArtwork && artwork == nil
        if unavailable || receiverStatus.ownerName == nil { content = .empty }
        let hasText = [content.title, content.body, content.footer].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if unavailable && receiverStatus.ownerName != nil { contentBadge.update("UNAVAILABLE", color: .systemOrange) }
        else if receiverStatus.ownerName != nil && !content.visible { contentBadge.update("HIDDEN", color: .systemOrange) }
        else if hasText && content.visible { contentBadge.update("TEXT VISIBLE", color: .systemGreen) }
        else { contentBadge.update("NO TEXT") }
        presentation.update(content: content, style: style, template: template, artwork: artwork,
                            immediately: receiverStatus.ownerName == nil || unavailable)
        let size = template.enabled
            ? CanvasTextLayout.lowerThird(content: content, style: style, template: template).bodyFontSize
            : CanvasTextLayout.make(content: content, style: style, template: template).bodyFontSize
        if unavailable {
            fitLabel.stringValue = artworkBusy ? "Loading PNG artwork…" : "Lower third is blank. Open Design to replace the PNG, choose Built-in banner, or untick Artwork in Layout, then Apply."
        } else if content.visible && size < 28 {
            fitLabel.stringValue = "Text fits at \(Int(size)) pt. Use shorter content or enlarge its text area for better readability."
        } else {
            fitLabel.stringValue = "16:9 canvas · White foreground · Key colour #\(style.background)"
        }
        composer?.updateLocalOutput(owner: receiverStatus.ownerName, ownerID: receiverStatus.ownerID, notice: unavailable ? fitLabel.stringValue : "")
        templateEditor?.update(template: template, style: style, artwork: artwork, busy: artworkBusy, message: artworkMessage)
        refreshDraft()
    }
    private func refreshDraft() {
        guard !updatingDraft, let editor = templateEditor, composer != nil else { return }
        updatingDraft = true
        defer { updatingDraft = false }
        editor.updateContent(draft: composer.draft, source: receiverStatus.content,
                             externalSource: receiverStatus.ownerID == composer.senderID ? nil : receiverStatus.ownerName,
                             customTextEnabled: customTextEnabled)
        composer.updateDesign(template: editor.template, applied: template, style: editor.style,
                              artwork: editor.draftArtwork, ready: editor.canPublish, changed: editor.hasChanges)
    }
    private func cancelLocalPublish() {
        pendingLocalContent = nil
        templateEditor?.setPublishing(false)
    }
    @objc func showDesignPage() { showPage("design") }
    private func saveTemplate() {
        template = template.clamped()
        defaults.set(try? JSONEncoder().encode(template), forKey: "lowerThirdTemplate")
        refreshCanvas()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { templateEditor?.windowShouldClose(sender) ?? true }
    func confirmTermination() -> NSApplication.TerminateReply {
        guard let editor = templateEditor, editor.needsCloseConfirmation else { return .terminateNow }
        editor.confirmClose(window!) { NSApp.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }
    private func loadArtwork() {
        guard let id = template.assetID else { return }
        let revision = UUID(); artworkRevision = revision
        artworkBusy = true; artworkMessage = "Loading saved PNG…"
        refreshCanvas()
        artworkStore.load(id: id, name: template.assetName ?? "Imported PNG") { [weak self] result in
            guard let self, self.artworkRevision == revision else { return }
            self.artworkBusy = false
            switch result {
            case .success(let value): self.artwork = value; self.artworkMessage = "PNG saved in AltView. The original file is no longer needed."
            case .failure: self.artworkMessage = "Saved PNG is unavailable. Choose PNG… to import it again."
            }
            self.refreshCanvas()
        }
    }
    private func applyDesign(_ value: LowerThirdTemplate, artwork: PNGArtwork?) {
        let previous = template.assetID
        template = value
        if previous != value.assetID {
            // A draft import supersedes any in-flight load of the old asset.
            artworkRevision = UUID(); artworkBusy = false
        }
        self.artwork = artwork
        artworkMessage = ""
        saveTemplate()
        if let previous, previous != value.assetID { artworkStore.discard(id: previous) }
    }
    func shutdown() {
        stopped = true
        settingsPopover.close()
        failLocalConnections("AltView closed.")
        artworkRevision = UUID()
        composer.shutdown(); server.stop(); output.stop(); presentation.stopAnimation(); templateEditor?.shutdown()
    }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
}
