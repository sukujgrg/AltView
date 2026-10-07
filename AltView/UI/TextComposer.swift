import AppKit
import Network

final class TextComposerViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    private let defaults: UserDefaults
    private let connectLocal: (@escaping (Result<LocalReceiverConnection, Error>) -> Void) -> Void
    private let loadPairing: (String) throws -> Data?
    private let storePairing: (Data, String) throws -> Void
    var showReceiver: (() -> Void)?
    var showDesign: (() -> Void)?
    var onPresentationActivityChange: (() -> Void)?
    var isPresenting: Bool { session.status.ownsOutput || session.pending != nil || session.takingOutput }
    var onDraftChange: ((DisplayContent) -> Void)?
    var prepareLocalPublish: ((DisplayContent) -> Bool)?
    var cancelLocalPublish: (() -> Void)?
    var senderID: UUID { client.senderID }
    var draft: DisplayContent { session.draft }
    private let draftPresentation: CanvasPresentation
    private var designReady = true
    private var designHasChanges = false
    private var appliedTemplate = LowerThirdTemplate()
    private var localTemplatePolicy = TemplatePolicy.sender
    private let titleVisibility = UI.label("", size: 11, color: .secondaryLabelColor)
    private let footerVisibility = UI.label("", size: 11, color: .secondaryLabelColor)
    private let previewNote = UI.label("", size: 12, color: .secondaryLabelColor)
    private var localOwnerID: UUID?
    func updateDesign(template: LowerThirdTemplate, applied: LowerThirdTemplate, style: OutputStyle, artwork: PNGArtwork?, ready: Bool, changed: Bool,
                      policy: TemplatePolicy? = nil) {
        appliedTemplate = applied; designReady = ready; designHasChanges = changed
        localTemplatePolicy = policy ?? template.textTemplate.policy
        var content = session.draft; content.visible = [content.title, content.body, content.footer].contains { !$0.isEmpty }
        draftPresentation.update(content: content, style: style, template: template, artwork: artwork, immediately: true)
        refresh()
    }
    private var client: SenderClient!
    private var session: TextComposerSession!
    private var discovery: ReceiverDiscovery!
    private var discovered: [DiscoveredReceiver] = []
    private var connectionRevision = 0
    private var savedAccount: String?
    private var pairingKey: Data?
    private var connectionNote = ""
    private var activeConnectionID: UUID?
    private var isConnecting = false
    private var connectingID: UUID?
    private var connectedName = ""
    private var memoryPairings: [String: (key: Data, receiverID: UUID)] = [:]
    private var saveWork: DispatchWorkItem?
    private let destinationPicker = NSPopUpButton()
    private var remote: Bool { destinationPicker.indexOfSelectedItem == 1 }
    private let connectionButton = NSButton()
    private let destinationName = UI.label("", size: 12, bold: true)
    private let destinationHint = UI.label("", size: 11, color: .secondaryLabelColor)
    private let titleField = NSTextField(string: "")
    private let bodyEditor = NSTextView()
    private let footerField = NSTextField(string: "")
    private let templatePicker = NSPopUpButton()
    private let templateHint = UI.label("", size: 11, color: .secondaryLabelColor)
    private var templateMenuEntries: [TemplateDescriptor]?
    private var unavailableTemplate: ContentTemplate?
    private lazy var reserveEmptyRegions = NSButton(checkboxWithTitle: "Keep space for empty Title and Footer", target: self, action: #selector(emptyRegionsChanged))
    private let draftLabel = UI.label("Saved automatically on this Mac.", size: 12, color: .secondaryLabelColor)
    private let statusLabel = UI.label("Ready to publish on this Mac", size: 15, bold: true)
    private let statusDetail = UI.label("", size: 12, color: .secondaryLabelColor)
    private let presentationBadge = StatusBadge("NOT PRESENTING")
    private let changesBadge = StatusBadge("UNPUBLISHED CHANGES", color: .systemOrange)
    private var showButton: NSButton!
    private var hideButton: NSButton!
    private var stopButton: NSButton!
    private var localPreview: NSView!
    private var remotePreview: NSView!
    private let remoteHeading = UI.label("", size: 15, bold: true)
    private let remoteBody = UI.label("No text sent yet", size: 22)
    private let remoteFooter = UI.label("", size: 12, color: .secondaryLabelColor)
    private var connectionSheet: NSWindow?
    private let receiverPicker = NSPopUpButton()
    private let hostField = NSTextField(string: "")
    private let portField = NSTextField(string: "")
    private let codeField: NSSecureTextField = {
        let field = NSSecureTextField(string: "")
        field.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        field.setAccessibilityLabel("Pairing code")
        field.setAccessibilityHelp("Type or paste the 8-character code shown on the receiving Mac.")
        field.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return field
    }()
    private let discoveryLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let connectionStatusLabel = UI.label("", size: 12, color: .secondaryLabelColor)
    private let pairingHint = UI.label("", size: 11, color: .secondaryLabelColor)
    private lazy var manualToggle = NSButton(checkboxWithTitle: "Connect using an address instead", target: self, action: #selector(toggleManualAddress))
    private var manualFields: NSView?
    private var connectButton: NSButton?
    private var connectOnlyButton: NSButton?
    private var disconnectButton: NSButton?
    private var refreshButton: NSButton?
    private var connectionProgress: NSProgressIndicator?
    private var localOwnerName: String?
    private var localOutputNotice = ""
    private var localDisplayStatus = "Audience window closed"

    init(defaults: UserDefaults = .standard, localReceiverID: UUID? = nil,
         loadPairing: @escaping (String) throws -> Data? = KeyStore.read,
         storePairing: @escaping (Data, String) throws -> Void = { try KeyStore.save($0, account: $1) },
         layoutCache: CanvasTextLayoutCache = CanvasTextLayoutCache(),
         connectLocal: @escaping (@escaping (Result<LocalReceiverConnection, Error>) -> Void) -> Void) {
        self.defaults = defaults; self.connectLocal = connectLocal
        self.loadPairing = loadPairing; self.storePairing = storePairing
        draftPresentation = CanvasPresentation(layoutCache: layoutCache)
        super.init(nibName: nil, bundle: nil)
        client = SenderClient(name: "AltView Custom Text · \(Host.current().localizedName ?? "This Mac")") { [weak self] in self?.receive($0) }
        let draft = defaults.data(forKey: "customTextDraft").flatMap { try? JSONDecoder().decode(DisplayContent.self, from: $0) } ?? DisplayContent()
        session = TextComposerSession(sender: client, draft: draft)
        session.onChange = { [weak self] in self?.refresh() }
        discovery = ReceiverDiscovery(excludingReceiverID: localReceiverID) { [weak self] receivers, error in
            self?.updateReceivers(receivers, error: error)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 614))
        destinationHint.maximumNumberOfLines = 2
        previewNote.maximumNumberOfLines = 3
        draftLabel.maximumNumberOfLines = 2
        destinationPicker.addItems(withTitles: ["This Mac", "Another Mac"])
        destinationPicker.target = self; destinationPicker.action = #selector(destinationChanged)
        destinationPicker.setAccessibilityLabel("Text destination")
        connectionButton.title = "Connect…"; connectionButton.bezelStyle = .rounded
        connectionButton.target = self; connectionButton.action = #selector(configureConnection)
        destinationName.maximumNumberOfLines = 1; destinationName.lineBreakMode = .byTruncatingMiddle
        destinationName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        destinationName.setAccessibilityIdentifier("textDestinationName")
        let destination = UI.column(
            UI.row(UI.label("Send to", size: 12, bold: true), destinationPicker, destinationName, NSView(), connectionButton),
            destinationHint, spacing: 6)
        destination.setHuggingPriority(.required, for: .vertical)
        titleField.placeholderString = "Optional title or reference"
        titleField.setAccessibilityLabel("Text title"); titleField.delegate = self
        footerField.placeholderString = "Optional credit or footer"
        footerField.setAccessibilityLabel("Text footer"); footerField.delegate = self
        for field in [titleField, footerField] {
            field.font = .systemFont(ofSize: 14)
            field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        reserveEmptyRegions.state = session.draft.emptyRegions == .reserve ? .on : .off
        templatePicker.setAccessibilityLabel("Requested text template")
        templatePicker.target = self; templatePicker.action = #selector(templateChanged)
        templatePicker.autoenablesItems = false
        templatePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        templateHint.maximumNumberOfLines = 2
        reserveEmptyRegions.font = .systemFont(ofSize: 11)
        reserveEmptyRegions.toolTip = "Leave off to let Body use empty Title and Footer space. Rows hidden in the receiver’s Design still give their space to Body. Changes apply when you publish."
        bodyEditor.isRichText = false; bodyEditor.font = .systemFont(ofSize: 19)
        bodyEditor.textContainerInset = NSSize(width: 12, height: 12)
        bodyEditor.isAutomaticQuoteSubstitutionEnabled = false
        bodyEditor.isAutomaticDashSubstitutionEnabled = false
        bodyEditor.isAutomaticSpellingCorrectionEnabled = false
        bodyEditor.isVerticallyResizable = true; bodyEditor.isHorizontallyResizable = false
        bodyEditor.autoresizingMask = [.width]; bodyEditor.textContainer?.widthTracksTextView = true
        bodyEditor.setAccessibilityLabel("Text body"); bodyEditor.delegate = self
        let scroll = NSScrollView(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = bodyEditor
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let fields = UI.column(
            UI.label("Your message", size: 13, bold: true),
            UI.row(UI.label("Template", size: 12, bold: true), templatePicker), templateHint,
            UI.row(UI.label("Title", size: 12, bold: true), titleVisibility, NSView()), titleField,
            UI.label("Body", size: 12, bold: true), scroll,
            UI.row(UI.label("Footer", size: 12, bold: true), footerVisibility, NSView()), footerField,
            reserveEmptyRegions, draftLabel, spacing: 10)
        fields.distribution = .fill
        for field in fields.arrangedSubviews where field !== scroll {
            field.setContentHuggingPriority(.required, for: .vertical)
            (field as? NSStackView)?.setHuggingPriority(.required, for: .vertical)
        }
        let editor = UI.scrolling(fields, fillsHeight: true)
        editor.setAccessibilityLabel("Compose editor")

        showButton = UI.primaryButton("Publish Text", target: self, action: #selector(showText))
        showButton.setAccessibilityIdentifier("showText")
        hideButton = UI.button("Hide Text", target: self, action: #selector(toggleTextVisibility))
        stopButton = UI.button("Stop Presenting", target: self, action: #selector(stopPresenting))
        stopButton.toolTip = "Clear your output and release it to other sources. Your draft is kept."
        let preview = OutputCanvas(presentation: draftPresentation)
        let canvas = UI.canvasStage(preview)
        localPreview = UI.column(
            UI.row(UI.label("MESSAGE PREVIEW", size: 11, color: .secondaryLabelColor, bold: true), NSView(),
                   UI.label("16:9", size: 11, color: .secondaryLabelColor)),
            canvas, previewNote,
            UI.row(UI.button("Edit Audience Design", target: self, action: #selector(openDesign)),
                   UI.button("Open Audience Controls", target: self, action: #selector(openReceiver)), NSView()), spacing: 12)
        let sentText = UI.scrolling(UI.column(remoteHeading, remoteBody, remoteFooter, spacing: 14))
        sentText.setAccessibilityLabel("Last text sent")
        remotePreview = UI.column(UI.label("Last text sent", size: 13, bold: true), sentText,
            UI.label("The receiving Mac controls appearance and its output display. This is a copy of the text sent, not a live picture.", size: 12, color: .secondaryLabelColor), spacing: 12)
        (remotePreview as? NSStackView)?.distribution = .fill
        let right = UI.column(localPreview, remotePreview, spacing: 14)
        right.distribution = .fill
        (localPreview as? NSStackView)?.distribution = .fill
        let body = UI.row(editor, right); body.spacing = 24; body.alignment = .top
        editor.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.5).isActive = true
        right.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.5, constant: -24).isActive = true
        editor.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.maximumNumberOfLines = 1; statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        presentationBadge.setAccessibilityIdentifier("composerPresentationStatus")
        statusLabel.setAccessibilityIdentifier("textPublicationStatus")
        statusDetail.setAccessibilityIdentifier("textPublicationDetail")
        statusDetail.maximumNumberOfLines = 2; statusDetail.lineBreakMode = .byTruncatingTail
        let actions = UI.row(presentationBadge, statusLabel, NSView(), hideButton, stopButton, showButton)
        actions.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        changesBadge.setAccessibilityIdentifier("textDraftStatus")
        let header = UI.row(UI.pageHeading("Text", subtitle: "Write a message, then publish it to your chosen Mac."), changesBadge)
        // Give the heading the remaining width so its subtitle cannot collapse beside a spacer.
        header.distribution = .fill
        let root = UI.column(header, destination, body, UI.separator(), UI.column(actions, statusDetail, spacing: 4), spacing: 16)
        // Expand the editor with the page while keeping publishing actions at the bottom.
        root.distribution = .fill
        UI.fill(root, in: view, padding: 0)
        titleField.stringValue = session.draft.title; bodyEditor.string = session.draft.body; footerField.stringValue = session.draft.footer
        refresh()
    }
    private func receive(_ status: SenderStatus) {
        guard status.connectionID == activeConnectionID else { return }
        let wasConnected = session.status.connected
        let wasOwner = session.status.ownsOutput
        session.receive(status)
        if wasOwner && !status.ownsOutput { cancelLocalPublish?() }
        if !status.connected && status.message.hasPrefix("Disconnected.") { session.cancelPending(); cancelLocalPublish?() }
        if status.connected, !wasConnected {
            connectionNote = ""
            if let id = status.receiverID, let account = savedAccount, let key = pairingKey {
                memoryPairings[account] = (key, id)
                defaults.set(id.uuidString, forKey: "peer.\(account)")
                let revision = connectionRevision
                let storePairing = self.storePairing
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    do { try storePairing(key, account) }
                    catch { DispatchQueue.main.async {
                        guard let self, self.connectionRevision == revision else { return }
                        self.connectionNote = "Pairing is temporary. Enter the receiver’s code again after restarting AltView."
                        self.refresh()
                    } }
                }
            }
        }
        if isConnecting, let connectingID, status.connectionID == connectingID {
            if status.connected {
                isConnecting = false
                codeField.stringValue = ""
                dismissConnectionSheet()
            } else if status.message.hasPrefix("Disconnected") || status.message.hasPrefix("Receiver identity") {
                client.disconnect(); activeConnectionID = nil
                session.resetConnection()
                isConnecting = false
                connectionStatusLabel.stringValue = status.message.hasPrefix("Receiver identity")
                    ? "This receiver’s identity changed. Enter its current code to pair again."
                    : "Couldn’t connect. \(status.failureReason ?? "The receiving Mac didn’t respond.")"
                connectionStatusLabel.textColor = .systemRed
                updateConnectionControls()
                connectionSheet?.makeFirstResponder(codeField)
            } else {
                connectionStatusLabel.stringValue = "\(status.message) If macOS asks, allow Local Network access."
            }
        }
        refresh()
    }
    func updateLocalOutput(owner: String?, ownerID: UUID? = nil, notice: String) {
        localOwnerID = ownerID; localOwnerName = owner; localOutputNotice = notice; refresh()
    }
    func updateLocalReceiverPort(_ port: UInt16) {
        guard !remote, let activeConnectionID else { return }
        client.updateEndpoint(.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                              connectionID: activeConnectionID)
    }
    func updateLocalDisplay(_ status: String) { localDisplayStatus = status; refresh() }
    private func refresh() {
        onPresentationActivityChange?()
        guard isViewLoaded else { return }
        let status = session.status
        refreshTemplatePicker()
        let destination = remote ? (connectedName.isEmpty ? "the receiving Mac" : connectedName) : "this Mac"
        let unpublished = session.hasUnpublishedChanges || (!remote && designHasChanges)
        changesBadge.isHidden = !unpublished
        connectionButton.isHidden = !remote
        connectionButton.title = status.connected ? "Change Receiver…" : "Connect…"
        destinationName.stringValue = remote ? (connectedName.isEmpty ? "No receiver selected" : connectedName) : ""
        destinationName.isHidden = !remote
        destinationName.toolTip = destinationName.stringValue
        destinationHint.stringValue = remote ? (connectionNote.isEmpty ? "Text and your template choice are sent. The receiving Mac controls the final design." : connectionNote)
            : "Publishes your text and Design changes together. Open Audience to choose this Mac’s display."
        showButton.title = session.pending != nil ? "Connecting…" : session.takingOutput ? "Showing…" : (remote && !status.connected ? "Connect & Publish Text…" : session.primaryTitle)
        if !remote {
            showButton.title = session.pending != nil ? "Connecting…" : session.takingOutput ? "Publishing…" : "Publish Text & Design"
        }
        showButton.isEnabled = session.canShow && (remote || designReady)
        func visibility(_ shown: Bool, appliedShown: Bool) -> String {
            if remote { return "" }
            return shown ? (appliedShown ? "Visible" : "Will be shown when published") : "Hidden by Design · text is kept"
        }
        let t = draftPresentation.template.applyingContentTemplate(for: session.draft)
        let applied = appliedTemplate.applyingContentTemplate(for: session.draft)
        titleVisibility.stringValue = visibility(t.showsTitle, appliedShown: applied.showsTitle)
        footerVisibility.stringValue = visibility(t.showsFooter, appliedShown: applied.showsFooter)
        previewNote.stringValue = session.pending != nil || session.takingOutput ? "Publishing the text and design requested by your click. Later text edits remain private."
            : !designReady ? "Design is not ready to publish. Finish or correct the edit in Design."
            : designHasChanges ? "Includes your Design changes. Publish sends this text and design together."
            : "Preview only. Publish updates this Mac’s output."
        hideButton.title = status.ownsOutput && !session.isVisible ? "Show Last Text" : "Hide Text"
        hideButton.toolTip = session.isVisible ? "Hide your published text without sending your edits." : "Show the last published text. Your newer edits stay private."
        hideButton.isEnabled = status.ownsOutput && session.submitted != nil && session.pending == nil && !session.takingOutput
        stopButton.isEnabled = status.ownsOutput || session.pending != nil || session.takingOutput
        localPreview.isHidden = remote; remotePreview.isHidden = !remote
        if let content = session.submitted {
            remoteHeading.stringValue = content.title; remoteBody.stringValue = content.body; remoteFooter.stringValue = content.footer
        } else { remoteHeading.stringValue = ""; remoteBody.stringValue = "No text sent yet"; remoteFooter.stringValue = "" }
        remoteHeading.isHidden = remoteHeading.stringValue.isEmpty
        remoteFooter.isHidden = remoteFooter.stringValue.isEmpty
        if !session.draft.isValid {
            draftLabel.stringValue = "Text is too long. Limits: title 512, body 24,000, footer 1,024 UTF-8 bytes."
            draftLabel.textColor = .systemRed
        } else {
            draftLabel.textColor = .secondaryLabelColor
            draftLabel.stringValue = "Saved automatically on this Mac."
        }
        if session.pending != nil || session.takingOutput {
            statusLabel.stringValue = "Publishing to \(destination)…"
            statusDetail.stringValue = "You can keep editing. Later changes will need another Publish."
        } else if status.ownsOutput {
            statusLabel.stringValue = session.isVisible ? "Published to \(destination)" : "Text hidden on \(destination)"
            statusDetail.stringValue = !session.isVisible ? "Show Last Text restores your last publication. Publish sends your current edits."
                : !remote ? "\(localDisplayStatus).\(localDisplayStatus == "Audience window closed" ? " Open Audience Controls to show it on a display." : "")"
                : unpublished ? "Your new edits have not been sent. The receiving Mac still has your last publication."
                : "Your message matches the last text sent."
        } else if remote && activeConnectionID != nil && !status.connected {
            statusLabel.stringValue = "Connection lost · \(destination)"
            statusDetail.stringValue = status.message
        } else if let owner = status.ownerName ?? (remote ? nil : localOwnerName) {
            statusLabel.stringValue = "\(destination) · controlled by \(owner)"
            statusDetail.stringValue = "Publishing your message will replace this source’s text."
        } else {
            statusLabel.stringValue = status.connected ? "Connected to \(destination)" : !remote ? "Ready to publish on this Mac" : "Choose a receiving Mac"
            statusDetail.stringValue = connectionNote.isEmpty ? "Your message stays private until you publish." : connectionNote
        }
        if session.pending != nil || session.takingOutput { presentationBadge.update("PUBLISHING", color: .systemOrange) }
        else if status.ownsOutput { presentationBadge.update(session.isVisible ? "PUBLISHED" : "HIDDEN", color: session.isVisible ? .systemGreen : .systemOrange) }
        else if remote && activeConnectionID != nil && !status.connected { presentationBadge.update("OFFLINE", color: .systemOrange) }
        else { presentationBadge.update("NOT PRESENTING") }
        statusLabel.toolTip = statusLabel.stringValue
        if remote && status.connected {
            statusDetail.stringValue += "\n" + status.feedback.detail
            if !status.templateDetail.isEmpty { statusDetail.stringValue += " " + status.templateDetail }
        }
        if !remote && !localOutputNotice.isEmpty { statusDetail.stringValue = localOutputNotice }
        statusDetail.toolTip = statusDetail.stringValue
    }
    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === hostField || field === portField || field === codeField {
            updateConnectionControls()
        } else { captureDraft() }
    }
    func textDidChange(_ notification: Notification) { captureDraft() }
    @objc private func emptyRegionsChanged() { captureDraft() }
    @objc private func templateChanged() {
        session.draft.template = (templatePicker.selectedItem?.representedObject as? String).map(ContentTemplate.init(rawValue:))
        captureDraft()
    }
    private func refreshTemplatePicker() {
        let capabilities = remote ? session.status.templateCapabilities
            : TemplateCapabilities(templates: TemplateDescriptor.builtIns, policy: localTemplatePolicy)
        let entries = capabilities.templates ?? []
        let unavailable = session.draft.template.flatMap { capabilities.supports($0) ? nil : $0 }
        // Ordinary feedback and text editing must not rebuild an open menu.
        if templateMenuEntries != entries || unavailableTemplate != unavailable {
            templateMenuEntries = entries; unavailableTemplate = unavailable
            templatePicker.removeAllItems()
            templatePicker.addItem(withTitle: "Receiver’s layout")
            for descriptor in entries {
                templatePicker.menu?.addItem(NSMenuItem(title: descriptor.name, action: nil, keyEquivalent: ""))
                templatePicker.lastItem?.representedObject = descriptor.id.rawValue
            }
            if let unavailable {
                templatePicker.menu?.addItem(NSMenuItem(title: "\(unavailable.rawValue) · Unavailable", action: nil, keyEquivalent: ""))
                templatePicker.lastItem?.representedObject = unavailable.rawValue
                templatePicker.lastItem?.isEnabled = false
            }
        }
        if let requested = session.draft.template,
           let item = templatePicker.itemArray.first(where: { $0.representedObject as? String == requested.rawValue }) {
            templatePicker.select(item)
        } else { templatePicker.selectItem(at: 0) }
        templatePicker.isEnabled = !remote || session.status.connected
        let detail = capabilities.detail(requested: session.draft.template)
        templateHint.stringValue = remote && !session.status.connected ? "Connect to discover the receiver’s templates."
            : !detail.isEmpty ? detail : "Choose a template for this message. Changes apply when you publish."
        templateHint.toolTip = templateHint.stringValue
    }
    private func captureDraft() {
        session.draft = DisplayContent(title: titleField.stringValue, body: bodyEditor.string, footer: footerField.stringValue,
                                       emptyRegions: reserveEmptyRegions.state == .on ? .reserve : .collapse, template: session.draft.template)
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveDraft() }; saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        var previewContent = session.draft; previewContent.visible = session.hasText
        draftPresentation.update(content: previewContent, style: draftPresentation.style, template: draftPresentation.template, artwork: draftPresentation.artwork, immediately: true)
        onDraftChange?(session.draft)
        refresh()
    }
    private func saveDraft() { defaults.set(try? JSONEncoder().encode(session.draft), forKey: "customTextDraft") }
    @objc private func showText() {
        captureDraft()
        guard session.canShow else { return }
        if remote && !session.status.connected { configureConnection(); return }
        if !remote, let prepareLocalPublish, !prepareLocalPublish(session.draft) { return }
        connectionNote = ""
        if session.show() {
            connectionRevision += 1; let revision = connectionRevision
            connectLocal { [weak self] result in
                guard let self, self.connectionRevision == revision, self.session.pending != nil else { return }
                switch result {
                case .success(let info):
                    let id = UUID(); self.activeConnectionID = id
                    self.client.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: info.port)!), key: info.key, connectionID: id)
                case .failure(let error): self.cancelLocalPublish?(); self.session.cancelPending(); self.connectionNote = error.localizedDescription; self.refresh()
                }
            }
        }
    }
    @objc private func toggleTextVisibility() {
        if session.isVisible { cancelLocalPublish?(); session.hide() }
        else { session.showSubmitted() }
    }
    @objc private func stopPresenting() {
        connectionRevision += 1
        cancelLocalPublish?(); session.stop()
    }
    func focusTitle() { view.window?.makeFirstResponder(titleField) }
    @objc private func openDesign() { showDesign?() }
    @objc private func openReceiver() { showReceiver?() }
    @objc private func destinationChanged() {
        cancelLocalPublish?()
        connectionRevision += 1
        activeConnectionID = nil; connectedName = ""
        session.resetConnection(); client.disconnect(); savedAccount = nil; pairingKey = nil; connectionNote = ""
        refresh()
        if remote { configureConnection() }
    }
    private var selectedReceiver: DiscoveredReceiver? {
        let index = receiverPicker.indexOfSelectedItem - 1
        return discovered.indices.contains(index) ? discovered[index] : nil
    }
    func updateReceivers(_ receivers: [DiscoveredReceiver], error: String?) {
        guard !isConnecting else { return }
        let previous = selectedReceiver
        discovered = receivers
        receiverPicker.removeAllItems(); receiverPicker.addItem(withTitle: "Choose a receiving Mac…")
        receiverPicker.addItems(withTitles: receivers.map(\.name))
        if let previous, let index = receivers.firstIndex(where: { $0.endpoint == previous.endpoint }) {
            receiverPicker.selectItem(at: index + 1)
        } else if previous == nil, receivers.count == 1 {
            receiverPicker.selectItem(at: 1)
        }
        if manualToggle.state == .off, previous?.endpoint != selectedReceiver?.endpoint {
            codeField.stringValue = ""
            selectionChanged()
        }
        discoveryLabel.stringValue = error.map { "Discovery unavailable: \($0). You can connect using an address below." }
            ?? (receivers.isEmpty ? "Looking for other Macs… Open AltView on the receiving Mac and use the same network."
                : "\(receivers.count) receiving Mac\(receivers.count == 1 ? "" : "s") found · updates automatically")
        updateConnectionControls()
    }
    @objc private func configureConnection() {
        guard connectionSheet == nil, let parent = view.window else { return }
        captureDraft()
        discovered = []; receiverPicker.removeAllItems(); receiverPicker.addItem(withTitle: "Looking for receiving Macs…")
        receiverPicker.setAccessibilityLabel("Receiving Mac")
        receiverPicker.target = self; receiverPicker.action = #selector(selectReceiver)
        hostField.placeholderString = "e.g. 192.168.1.20 or receiver.local"
        hostField.setAccessibilityLabel("Receiver address"); hostField.delegate = self
        portField.setAccessibilityLabel("Receiver port"); portField.delegate = self
        portField.placeholderString = "Port"
        portField.toolTip = "Use the current port shown in AltView Settings on the receiving Mac."
        if portField.constraints.isEmpty { portField.widthAnchor.constraint(equalToConstant: 75).isActive = true }
        codeField.delegate = self
        codeField.stringValue = ""
        pairingHint.stringValue = "On the other Mac, click the gear in AltView to find its 8-character code in Settings. Leave blank to use a saved pairing."
        connectionStatusLabel.stringValue = session.canShow
            ? "Connect & Publish Text publishes your draft and replaces any current source. Connect Only keeps your draft private."
            : "Connecting keeps the output unchanged. Write your message, then choose Publish Text."
        connectionStatusLabel.textColor = .secondaryLabelColor
        let pairing = UI.column(UI.label("2. Enter that Mac’s pairing code", size: 13, bold: true), codeField, pairingHint, spacing: 6)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Connect to a Receiving Mac"; panel.isReleasedWhenClosed = false
        let manual = UI.column(UI.row(UI.label("Address"), hostField),
            UI.row(UI.label("Port"), portField, UI.label("Shown in the receiving Mac’s AltView Settings.", size: 11, color: .secondaryLabelColor)), spacing: 8)
        manualFields = manual; manual.isHidden = manualToggle.state == .off
        let refresh = UI.button("Refresh", target: self, action: #selector(findReceivers)); refreshButton = refresh
        let connect = UI.button(session.canShow ? "Connect & Publish Text" : "Connect", target: self, action: #selector(connectAndShow))
        connect.keyEquivalent = "\r"; connectButton = connect
        let only = UI.button("Connect Only", target: self, action: #selector(connectRemote))
        only.isHidden = !session.canShow; connectOnlyButton = only
        let cancel = UI.button("Cancel", target: self, action: #selector(closeConnection)); cancel.keyEquivalent = "\u{1b}"
        let disconnect = UI.button("Disconnect", target: self, action: #selector(disconnectRemote))
        disconnect.isHidden = !session.status.connected; disconnectButton = disconnect
        let progress = NSProgressIndicator(); progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false; connectionProgress = progress
        let content = UI.column(UI.label("Send custom text from this Mac", size: 22, bold: true),
            UI.label("The other Mac receives. Just open AltView there — it is ready automatically. Start the connection here.", size: 13, color: .secondaryLabelColor),
            UI.label("1. Choose the receiving Mac", size: 13, bold: true),
            UI.row(receiverPicker, refresh), discoveryLabel, manualToggle, manual, pairing,
            UI.row(progress, connectionStatusLabel),
            UI.row(disconnect, NSView(), cancel, only, connect), spacing: 12)
        UI.fill(content, in: panel.contentView!, padding: 24)
        connectionSheet = panel; parent.beginSheet(panel)
        updateConnectionControls(); findReceivers()
    }
    @objc private func findReceivers() { discovery.start(); discoveryLabel.stringValue = "Looking for other Macs on your network…" }
    @objc private func selectReceiver() { codeField.stringValue = ""; selectionChanged() }
    private func selectionChanged() {
        connectionRevision += 1
        connectionStatusLabel.stringValue = session.canShow
            ? "Connect & Publish Text publishes your draft and replaces any current source. Connect Only keeps your draft private."
            : "Connecting keeps the output unchanged. Write your message, then choose Publish Text."
        connectionStatusLabel.textColor = .secondaryLabelColor
        updateConnectionControls()
        if manualToggle.state == .off, selectedReceiver != nil { connectionSheet?.makeFirstResponder(codeField) }
    }
    @objc private func toggleManualAddress() {
        manualFields?.isHidden = manualToggle.state == .off
        codeField.stringValue = ""
        selectionChanged()
        connectionSheet?.makeFirstResponder(manualToggle.state == .on ? hostField : codeField)
    }
    private func updateConnectionControls() {
        let manual = manualToggle.state == .on
        receiverPicker.isEnabled = !manual && !isConnecting && !discovered.isEmpty
        hostField.isEnabled = !isConnecting; portField.isEnabled = !isConnecting
        manualToggle.isEnabled = !isConnecting; codeField.isEnabled = !isConnecting
        refreshButton?.isEnabled = !isConnecting
        let hasTarget = manual ? !hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : selectedReceiver != nil
        connectButton?.isEnabled = !isConnecting && hasTarget
        connectOnlyButton?.isEnabled = !isConnecting && hasTarget
        disconnectButton?.isEnabled = !isConnecting
        if isConnecting { connectionProgress?.startAnimation(nil) } else { connectionProgress?.stopAnimation(nil) }
    }
    private func dismissConnectionSheet() {
        guard let sheet = connectionSheet else { return }
        sheet.sheetParent?.endSheet(sheet); sheet.orderOut(nil); connectionSheet = nil; discovery.stop()
    }
    @objc private func closeConnection() {
        connectionRevision += 1
        if isConnecting {
            activeConnectionID = nil; client.disconnect(); session.resetConnection(); isConnecting = false
            connectionNote = "Connection cancelled. Your draft is still private."
        }
        codeField.stringValue = ""
        dismissConnectionSheet(); refresh()
    }
    @objc private func disconnectRemote() {
        activeConnectionID = nil; session.resetConnection(); client.disconnect(); connectionNote = ""; connectedName = ""
        closeConnection()
    }
    @objc private func connectAndShow() { beginRemoteConnection(present: session.canShow) }
    @objc private func connectRemote() { beginRemoteConnection(present: false) }
    private func beginRemoteConnection(present: Bool) {
        guard !isConnecting else { return }
        let endpoint: NWEndpoint, account: String, name: String
        if manualToggle.state == .on {
            let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { showConnectionError("Enter the receiving Mac’s address.", field: hostField); return }
            guard let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
                showConnectionError("Enter the current port shown in AltView Settings on the receiving Mac (1–65535).", field: portField); return
            }
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            account = "sender.\(host):\(port)"; name = host
        } else {
            guard let receiver = selectedReceiver else { showConnectionError("Choose a receiving Mac.", field: receiverPicker); return }
            endpoint = receiver.endpoint; account = "sender.service.\(receiver.name)"; name = receiver.name
        }
        let entered = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty && PairingKey.parse(entered) == nil {
            showConnectionError("Use the 8-character code from the receiving Mac. Spaces, hyphens and lowercase are accepted.", field: codeField); return
        }
        let remembered = memoryPairings[account]
        let expected = entered.isEmpty ? (remembered?.receiverID ?? defaults.string(forKey: "peer.\(account)").flatMap(UUID.init(uuidString:))) : nil
        connectionRevision += 1; let revision = connectionRevision
        isConnecting = true; connectingID = nil
        connectionStatusLabel.textColor = .secondaryLabelColor
        connectionStatusLabel.stringValue = "Connecting to \(name)… If macOS asks, allow Local Network access."
        updateConnectionControls()
        let loadPairing = self.loadPairing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> Data in
                if let key = PairingKey.parse(entered) { return key }
                if let key = remembered?.key { return key }
                if let key = try? loadPairing(account) { return key }
                throw ComposerConnectionError(message: "No saved pairing for this Mac. Enter the code in AltView’s Settings (gear icon) on that Mac.")
            }
            DispatchQueue.main.async {
                guard let self, self.connectionRevision == revision, self.connectionSheet != nil else { return }
                switch result {
                case .success(let key):
                    self.session.resetConnection(); self.savedAccount = account; self.pairingKey = key; self.connectedName = name
                    let id = UUID(); self.activeConnectionID = id; self.connectingID = id
                    if present { self.session.show() }
                    self.client.connect(to: endpoint, key: key, expectedReceiverID: expected, connectionID: id)
                case .failure(let error):
                    self.isConnecting = false
                    self.showConnectionError(error.localizedDescription, field: self.codeField)
                    self.updateConnectionControls()
                }
            }
        }
    }
    private func showConnectionError(_ message: String, field: NSView) {
        connectionStatusLabel.stringValue = message; connectionStatusLabel.textColor = .systemRed
        connectionSheet?.makeFirstResponder(field)
    }
    func deactivate() {
        // Invalidate delayed local/Keychain callbacks before clearing the session.
        connectionRevision += 1
        activeConnectionID = nil; connectingID = nil; isConnecting = false
        cancelLocalPublish?()
        if isViewLoaded { captureDraft() }
        saveWork?.cancel(); saveDraft()
        session.resetConnection(); client.disconnect()
        savedAccount = nil; pairingKey = nil; connectedName = ""; connectionNote = ""
        codeField.stringValue = ""
        dismissConnectionSheet(); discovery.stop()
        draftPresentation.stopAnimation()
        refresh()
    }
    func shutdown() {
        cancelLocalPublish?(); draftPresentation.stopAnimation(); saveWork?.cancel(); saveDraft(); connectionRevision += 1; session.cancelPending(); client.disconnect(); discovery.stop(); closeConnection()
    }
}
