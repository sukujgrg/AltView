import AppKit

final class ReceiverWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private let defaults: UserDefaults
    private let loadPairing: (String) throws -> Data?
    private let storePairing: (Data, String) throws -> Void
    private(set) var customTextEnabled: Bool
    var onPresentationActivityChange: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var isPresenting: Bool {
        output.isActive || confidence.output.isActive || receiverStatus.ownerID != nil || composer?.isPresenting == true
    }
    private lazy var updateButton: NSButton = {
        let button = UI.button("Update Available", target: self, action: #selector(checkForUpdates))
        button.isHidden = true
        button.setAccessibilityIdentifier("updateAvailable")
        return button
    }()
    func showUpdateState(_ state: AppUpdateState, canCheck: Bool, disabledReason: String?) {
        updateButton.isHidden = state.availableVersion == nil
        updateButton.isEnabled = canCheck
        updateButton.toolTip = disabledReason ?? state.availableVersion.map { "Update to AltView \($0)" }
    }
    @objc private func checkForUpdates() { onCheckForUpdates?() }
    var onCustomTextSettingChange: (() -> Void)?
    private let advertiseReceiver: Bool
    private let receiverPort: UInt16
    private var stopped = false
    private(set) var pairingKey: Data?
    private(set) var receiverStatus = ReceiverStatus()
    private var localWaiters: [(Result<LocalReceiverConnection, Error>) -> Void] = []
    private var starting = false
    private var server: ReceiverServer!
    private let presentation: CanvasPresentation
    private let templatePreviewPresentation: CanvasPresentation
    private let audiencePreviewHeading = UI.label("THIS MAC · AUDIENCE PREVIEW", size: 11, color: .secondaryLabelColor, bold: true)
    private let monitorAssignments: DisplayAssignments
    private lazy var output = OutputWindowController(presentation: presentation, displays: { [monitorAssignments] in monitorAssignments.currentDisplays() })
    private lazy var monitorControls = MonitorControls(role: .audience, assignments: monitorAssignments, output: output)
    private lazy var confidence = ConfidenceViewController(defaults: defaults, assignments: monitorAssignments)
    private lazy var preview: OutputCanvas = {
        let canvas = OutputCanvas(presentation: presentation)
        canvas.onVisible = { [weak self] in self?.refreshFitStatus() }
        return canvas
    }()
    private let artworkStore: PNGArtworkStore
    private var template = LowerThirdTemplate()
    private var designs = TemplateDesignLibrary()
    private var pendingAudienceTemplate = TextTemplateSelection.sender
    private let audienceTemplatePicker = NSPopUpButton()
    private let audienceTemplateHint = UI.label("", size: 11, color: .secondaryLabelColor)
    private let audienceTemplateStatus = UI.label("", size: 11, color: .secondaryLabelColor)
    private var applyTemplateButton: NSButton!
    private var artworks: [UUID: PNGArtwork] = [:]
    private var artwork: PNGArtwork?
    private var artworkRevision = UUID()
    private var artworkBusy = false
    private var artworkMessage = ""
    private var templateEditor: LowerThirdWindowController?
    private let nameField = NSTextField(string: "")
    private let statusLabel = UI.label("Preparing receiver…", size: 16, bold: true)
    private let pairingStatusLabel = UI.label("No sender connected", size: 12, color: .secondaryLabelColor)
    private let ownerLabel = UI.label("No sender controls the output", size: 14, bold: true)
    private let networkLabel = UI.label("Receiving starts automatically when AltView opens.", size: 11, color: .secondaryLabelColor)
    private let pairingLabel = UI.label("Pairing uses an encrypted connection. Share the code with your sender once.", size: 11, color: .secondaryLabelColor)
    private let pairingInstructions = UI.label("On the other Mac, open your app’s AltView connection settings. Choose this receiver and enter the code below.", size: 13)
    private let pairingCodeField = NSTextField(labelWithString: "--------")
    private var copyButton: NSButton!
    private var resetButton: NSButton!
    private var clearButton: NSButton!
    private let fitLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private var receiveButton: NSButton!
    private var style = OutputStyle()
    private let sidebar = NSOutlineView()
    private let senderList = NSTableView()
    private let senderListEmpty = UI.label("No senders connected", size: 12, color: .secondaryLabelColor)
    private var senderRows: [ReceiverConnection] = []
    private var navigationGroups: [WorkspaceDestination] = []
    private var splitController: NSSplitViewController?
    private lazy var customTextSwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self; control.action = #selector(customTextSettingChanged)
        control.setAccessibilityLabel("Custom Text")
        control.setAccessibilityIdentifier("enableCustomText")
        return control
    }()
    private lazy var settingsWindow: NSWindowController = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentView!.setAccessibilityIdentifier("workspaceSettingsContent")
        let content = UI.column(
            UI.row(UI.label("Custom Text", size: 13, bold: true), NSView(), customTextSwitch),
            UI.label("Compose messages on this Mac or send them to another AltView.", size: 12, color: .secondaryLabelColor),
            UI.label("Turning this off stops Custom Text. Your draft is kept.", size: 11, color: .secondaryLabelColor), NSView(), spacing: 12)
        content.distribution = .fill
        UI.fill(content, in: window.contentView!, padding: 24)
        window.center()
        return NSWindowController(window: window)
    }()
    private let pages = NSTabView()
    private var composer: TextComposerViewController!
    private var pendingLocalContent: DisplayContent?
    private let contentBadge = StatusBadge("NO TEXT")
    private var updatingDraft = false

    init(defaults: UserDefaults = .standard, pairingKey: Data? = nil,
         loadPairing: @escaping (String) throws -> Data? = KeyStore.read,
         storePairing: @escaping (Data, String) throws -> Void = { try KeyStore.save($0, account: $1) },
         advertiseReceiver: Bool = true, receiverPort: UInt16 = 0,
         window: NSWindow? = nil, artworkStore: PNGArtworkStore = PNGArtworkStore(),
         displays: @escaping () -> [OutputDisplay] = { OutputDisplay.current },
         presentation: CanvasPresentation = CanvasPresentation()) {
        self.defaults = defaults; self.receiverPort = receiverPort
        self.loadPairing = loadPairing; self.storePairing = storePairing
        self.advertiseReceiver = advertiseReceiver
        monitorAssignments = DisplayAssignments(defaults: defaults, displays: displays)
        self.artworkStore = artworkStore; self.presentation = presentation
        templatePreviewPresentation = CanvasPresentation(layoutCache: presentation.layoutCache)
        customTextEnabled = defaults.bool(forKey: "customTextEnabled")
        let window = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AltView"
        window.subtitle = "Presentation workspace"
        window.contentMinSize = NSSize(width: 1160, height: 650)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.colorSpace = .sRGB
        super.init(window: window)
        let id = defaults.string(forKey: "receiverID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(id.uuidString, forKey: "receiverID")
        if let data = defaults.data(forKey: "outputStyle"), let saved = try? JSONDecoder().decode(OutputStyle.self, from: data) { style = saved }
        if let data = defaults.data(forKey: "lowerThirdTemplate"),
           let saved = try? JSONDecoder().decode(LowerThirdTemplate.self, from: data) { template = saved.clamped() }
        if let data = defaults.data(forKey: "templateDesignLibrary"),
           let saved = try? JSONDecoder().decode(TemplateDesignLibrary.self, from: data) { designs = saved.clamped() }
        else { designs = TemplateDesignLibrary(template: template, style: style) }
        server = ReceiverServer(receiverID: id) { [weak self] status in self?.update(status) }
        output.onReadinessChange = { [weak self] _ in self?.refreshOutputReadiness() }
        output.onChange = { [weak self] text in
            self?.composer?.updateLocalDisplay(text)
            self?.onPresentationActivityChange?()
        }
        confidence.onActivityChange = { [weak self] in self?.onPresentationActivityChange?() }
        composer = TextComposerViewController(defaults: defaults, localReceiverID: id, layoutCache: presentation.layoutCache) { [weak self] completion in
            self?.connectLocal(completion)
        }
        composer.onPresentationActivityChange = { [weak self] in self?.onPresentationActivityChange?() }
        composer.showReceiver = { [weak self] in self?.showReceiverPage() }
        composer.showDesign = { [weak self] in self?.showDesignPage() }
        composer.onDraftChange = { [weak self] _ in self?.refreshDraft() }
        composer.prepareLocalPublish = { [weak self] content in
            guard let self, let editor = self.templateEditor else { return false }
            editor.finishEditing()
            guard editor.canPublish(content: content) else { self.showDesignPage(); return false }
            var snapshot = content; snapshot.visible = true
            snapshot = TemplateCapabilities(templates: TemplateDescriptor.builtIns).contentForSending(snapshot)
            self.pendingLocalContent = snapshot
            editor.setPublishing(true)
            self.refreshAudienceTemplate()
            return true
        }
        composer.cancelLocalPublish = { [weak self] in self?.cancelLocalPublish() }
        let editor = LowerThirdWindowController(artworkStore: artworkStore, layoutCache: presentation.layoutCache, defaults: defaults)
        templateEditor = editor
        editor.onApplyLibrary = { [weak self] value, assets in self?.applyDesigns(value, artworks: assets) }
        editor.onDraftChange = { [weak self] in self?.refreshDraft() }
        editor.onEditText = { [weak self] in self?.showComposerPage(); self?.composer.focusTitle() }
        buildInterface()
        window.delegate = self
        refreshCanvas()
        nameField.stringValue = defaults.string(forKey: "receiverName") ?? "AltView — \(Host.current().localizedName ?? "This Mac")"
        nameField.delegate = self
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
        pairingLabel.setAccessibilityIdentifier("receiverPairingPersistence")
        pairingLabel.maximumNumberOfLines = 4
        copyButton.setAccessibilityLabel("Copy Pairing Code")
        resetButton = UI.button("Reset Code…", target: self, action: #selector(resetPairing))
        resetButton.isEnabled = false
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.setAccessibilityIdentifier("receiverListeningStatus")
        pairingStatusLabel.setAccessibilityIdentifier("receiverPairingStatus")
        pairingStatusLabel.maximumNumberOfLines = 2
        pairingStatusLabel.lineBreakMode = .byTruncatingTail
        pairingInstructions.font = .systemFont(ofSize: 12)
        networkLabel.setAccessibilityIdentifier("receiverManualPort")
        networkLabel.isSelectable = true
        networkLabel.isHidden = true
        networkLabel.toolTip = "This port is chosen automatically and may change when receiving restarts."
        let displayCard = UI.card("Audience display", content: monitorControls)
        audienceTemplatePicker.addItems(withTitles: TextTemplateSelection.allCases.map(\.rawValue))
        audienceTemplatePicker.setAccessibilityLabel("Audience template")
        audienceTemplatePicker.setAccessibilityIdentifier("audienceTemplate")
        audienceTemplatePicker.target = self; audienceTemplatePicker.action = #selector(audienceTemplateChanged)
        pendingAudienceTemplate = designs.selection
        audienceTemplateHint.maximumNumberOfLines = 3
        audienceTemplateStatus.maximumNumberOfLines = 2
        audienceTemplateStatus.setAccessibilityIdentifier("audienceTemplateStatus")
        applyTemplateButton = UI.button("Apply Template", target: self, action: #selector(applyAudienceTemplate))
        applyTemplateButton.setAccessibilityIdentifier("applyAudienceTemplate")
        applyTemplateButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        let templateAction = UI.row(NSView(), applyTemplateButton)
        templateAction.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let templateContent = UI.column(audienceTemplatePicker, audienceTemplateHint, audienceTemplateStatus, templateAction, spacing: 8)
        templateContent.setHuggingPriority(.required, for: .vertical)
        let templateCard = UI.card("Template", content: templateContent)
        // Keep the groups at their natural height; spare workspace belongs below them.
        let inspectorContent = UI.column(displayCard, templateCard, spacing: 14)
        inspectorContent.setHuggingPriority(.required, for: .vertical)
        let inspector = NSView()
        inspector.addSubview(inspectorContent)
        inspectorContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inspectorContent.leadingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspectorContent.trailingAnchor.constraint(equalTo: inspector.trailingAnchor),
            inspectorContent.topAnchor.constraint(equalTo: inspector.topAnchor),
            inspectorContent.bottomAnchor.constraint(lessThanOrEqualTo: inspector.bottomAnchor)
        ])
        inspector.widthAnchor.constraint(equalToConstant: UI.previewInspectorWidth).isActive = true
        inspector.setAccessibilityLabel("Audience settings")

        clearButton = UI.button("Clear & Release", target: self, action: #selector(clearOutput))
        clearButton.isEnabled = false
        clearButton.toolTip = "Clear the current source and release its control of output."
        let stage = UI.canvasStage(preview)
        audiencePreviewHeading.setAccessibilityIdentifier("audiencePreviewHeading")
        let previewTitle = UI.row(audiencePreviewHeading,
                                 NSView(), PreviewAspectRatioPicker(stage: stage, defaults: defaults, role: "Audience"))
        ownerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        contentBadge.setAccessibilityIdentifier("workspaceContentStatus")
        ownerLabel.maximumNumberOfLines = 1; ownerLabel.lineBreakMode = .byTruncatingTail
        ownerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let previewFooter = UI.column(UI.row(contentBadge, ownerLabel, NSView()), fitLabel,
            UI.row(UI.button("Edit Audience Design", target: self, action: #selector(showDesignPage)), NSView(), clearButton), spacing: 12)
        let monitor = UI.monitorPreview(heading: previewTitle, stage: stage, footer: previewFooter)
        let body = UI.row(monitor, inspector)
        body.alignment = .top; body.spacing = UI.previewColumnGap
        monitor.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -(UI.previewInspectorWidth + UI.previewColumnGap)).isActive = true
        monitor.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        inspector.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let root = UI.column(UI.pageHeading("Audience", subtitle: "Receive from your presentation app and monitor this Mac’s picture."), body, spacing: 20)
        root.distribution = .fill
        // Seed tab geometry before the first layout pass.
        pages.frame = NSRect(x: 0, y: 0, width: 1100, height: 614)
        let receiverPage = NSView(frame: pages.contentRect)
        UI.fill(root, in: receiverPage, padding: 0)
        pages.tabViewType = .noTabsNoBorder
        let receiverItem = NSTabViewItem(identifier: "receiver"); receiverItem.view = receiverPage; receiverItem.label = "Audience"
        let designPage = NSView(frame: pages.contentRect)
        let backToAudience = UI.button("Back to Audience", target: self, action: #selector(showReceiverPage))
        backToAudience.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)
        backToAudience.imagePosition = .imageLeading
        let designContent = UI.column(
            UI.row(backToAudience, NSView()),
            templateEditor!.contentView, spacing: 12)
        designContent.distribution = .fill
        UI.fill(designContent, in: designPage, padding: 0)
        let designItem = NSTabViewItem(identifier: "design"); designItem.view = designPage; designItem.label = "Audience Design"
        pages.addTabViewItem(receiverItem); pages.addTabViewItem(designItem)
        let confidenceItem = NSTabViewItem(identifier: "confidence"); confidenceItem.label = "Confidence"
        confidence.view.frame = pages.contentRect
        confidenceItem.view = confidence.view; pages.addTabViewItem(confidenceItem)
        let connectionsPage = NSView(frame: pages.contentRect)
        connectionsPage.setAccessibilityIdentifier("workspaceConnectionsContent")
        let receiverControls = UI.column(
            statusLabel, pairingStatusLabel,
            UI.column(UI.label("Receiver name", size: 11, color: .secondaryLabelColor), nameField, spacing: 4),
            UI.row(pairingCodeField, copyButton, NSView()),
            pairingInstructions, pairingLabel,
            UI.row(receiveButton, resetButton, NSView()), networkLabel, spacing: 12)
        let connectionCard = UI.card("Receive on this Mac", content: receiverControls)
        connectionCard.widthAnchor.constraint(equalToConstant: 460).isActive = true
        let senderColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sender"))
        senderColumn.title = "Sender"; senderColumn.minWidth = 180
        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("connectionAction"))
        actionColumn.width = 145; actionColumn.minWidth = 145; actionColumn.maxWidth = 145
        senderList.addTableColumn(senderColumn); senderList.addTableColumn(actionColumn)
        senderList.headerView = nil; senderList.style = .fullWidth
        senderList.rowHeight = 58; senderList.intercellSpacing = NSSize(width: 8, height: 4)
        senderList.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        senderList.usesAlternatingRowBackgroundColors = true
        senderList.dataSource = self; senderList.delegate = self
        senderList.setAccessibilityLabel("Senders")
        senderList.setAccessibilityIdentifier("receiverSenderList")
        let senderScroll = NSScrollView()
        senderScroll.hasVerticalScroller = true; senderScroll.autohidesScrollers = true
        senderScroll.borderType = .bezelBorder; senderScroll.documentView = senderList
        senderScroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        let senderControls = UI.column(senderListEmpty, senderScroll,
            UI.label("Disconnect pauses reconnection until you allow it again or restart AltView.", size: 11, color: .secondaryLabelColor), spacing: 10)
        let senderCard = UI.card("Senders", content: senderControls)
        let connectionBody = UI.row(connectionCard, senderCard)
        connectionBody.alignment = .top; connectionBody.spacing = 20
        senderCard.widthAnchor.constraint(equalTo: connectionBody.widthAnchor, constant: -480).isActive = true
        let connections = UI.column(
            UI.pageHeading("Connections", subtitle: "Connect your sending apps once for Audience and Confidence."),
            connectionBody, NSView(), spacing: 20)
        connections.distribution = .fill
        UI.fill(connections, in: connectionsPage, padding: 0)
        let connectionsItem = NSTabViewItem(identifier: "connections")
        connectionsItem.label = "Connections"; connectionsItem.view = connectionsPage
        pages.addTabViewItem(connectionsItem)
        if customTextEnabled { addTextPage() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("destination"))
        sidebar.addTableColumn(column); sidebar.outlineTableColumn = column
        sidebar.headerView = nil; sidebar.style = .sourceList
        sidebar.rowSizeStyle = .medium
        sidebar.floatsGroupRows = false
        sidebar.dataSource = self; sidebar.delegate = self
        sidebar.target = self; sidebar.action = #selector(sidebarClicked)
        sidebar.setAccessibilityLabel("AltView sidebar")
        sidebar.setAccessibilityIdentifier("workspaceSidebar")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.documentView = sidebar
        let sidebarController = NSViewController()
        let backdrop = NSVisualEffectView()
        backdrop.material = .sidebar; backdrop.blendingMode = .behindWindow
        sidebarController.view = backdrop
        let navigation = UI.column(scroll, updateButton, spacing: 8)
        navigation.distribution = .fill
        UI.fill(navigation, in: backdrop, padding: 10)
        let detail = NSViewController()
        detail.view = NSView()
        UI.fill(pages, in: detail.view, padding: 20)
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 160; sidebarItem.maximumThickness = 220
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        splitController = split
        window!.contentViewController = split
        updateNavigation()
        pages.selectTabViewItem(withIdentifier: "receiver")
        syncSidebarSelection()
    }
    private func update(_ status: ReceiverStatus) {
        guard !stopped else { return }
        receiverStatus = status
        if senderRows != status.senderConnections {
            let selectedID = senderList.selectedRow >= 0 && senderList.selectedRow < senderRows.count ? senderRows[senderList.selectedRow].id : nil
            senderRows = status.senderConnections
            senderList.reloadData()
            if let selectedID, let row = senderRows.firstIndex(where: { $0.id == selectedID }) {
                senderList.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let disconnectedCount = senderRows.filter(\.isDisconnected).count
            senderListEmpty.stringValue = senderRows.isEmpty ? "No senders connected"
                : "\(status.connections) connected" + (disconnectedCount > 0 ? " · \(disconnectedCount) disconnected" : "")
        }
        confidence.update(status)
        onPresentationActivityChange?()
        starting = status.starting
        let receiving = status.listening || status.starting
        receiveButton.title = receiving ? "Pause Receiving" : "Resume Receiving"
        receiveButton.isEnabled = pairingKey != nil
        copyButton.isEnabled = pairingKey != nil
        resetButton.isEnabled = pairingKey != nil
        nameField.isEditable = !receiving
        nameField.isSelectable = true
        nameField.drawsBackground = !receiving
        nameField.isBezeled = !receiving
        nameField.toolTip = receiving ? "Pause receiving to change this Mac’s receiver name." : nil
        statusLabel.stringValue = status.listening
            ? (status.ownerName != nil ? "Receiving text" : status.connections > 0 ? "Sender connected" : "Ready to receive")
            : (status.starting || status.message.hasPrefix("Could not") ? status.message : "Receiving paused")
        statusLabel.textColor = status.listening ? .systemGreen : status.starting ? .systemOrange : .secondaryLabelColor
        let connectionText = status.connections > 0 ? "\(status.connections) sender\(status.connections == 1 ? "" : "s") connected" : "No sender connected"
        pairingStatusLabel.stringValue = status.starting || status.message.hasPrefix("Could not") ? status.message : connectionText
        pairingStatusLabel.toolTip = pairingStatusLabel.stringValue
        pairingStatusLabel.textColor = status.connections > 0 ? .systemGreen : status.starting ? .systemOrange : .secondaryLabelColor
        pairingInstructions.stringValue = status.connections > 0
            ? "Already connected. Use this code only to pair another sender."
            : status.listening
            ? "In your sending app’s AltView settings, connect to this Mac. Enter this code only if asked."
            : status.starting
            ? "Wait for receiving to start, then connect from your sending app."
            : "Resume receiving, then choose this Mac in your sending app’s AltView settings and enter the code."
        networkLabel.stringValue = status.port.map { "For manual connections: port \($0)" } ?? ""
        networkLabel.isHidden = !status.listening
        let networkDetail = status.port.map { "Visible on your local network · Port \($0)\n\(status.connections) connected sender\(status.connections == 1 ? "" : "s")" }
            ?? (status.starting ? "Keep AltView open while receiving starts." : "Resume receiving to let another Mac connect.")
        statusLabel.toolTip = networkDetail
        statusLabel.setAccessibilityHelp(networkDetail)
        ownerLabel.stringValue = status.ownerName.map { "From \(status.ownerID == composer.senderID ? "Text on this Mac" : $0)" }
            ?? (status.connections > 0 ? "Sender connected · waiting for text" : "No active sender")
        ownerLabel.toolTip = ownerLabel.stringValue
        clearButton.isEnabled = status.ownerName != nil
        // Commit the frozen design only when the receiver accepts this sender's
        // requested text. A failed connection cannot restyle an external source.
        if let pending = pendingLocalContent, status.ownerID == composer.senderID, status.content == pending {
            pendingLocalContent = nil
            templateEditor?.setPublishing(false)
            templateEditor?.applyDraft(for: pending)
        }
        refreshCanvas()
        if status.listening, let port = status.port, let key = pairingKey {
            composer.updateLocalReceiverPort(port)
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
        navigationGroups = [WorkspaceDestination("Outputs", children: [
            WorkspaceDestination("Audience", id: "receiver", symbol: "tv"),
            WorkspaceDestination("Confidence", id: "confidence", symbol: "text.below.photo")])]
        if customTextEnabled {
            navigationGroups.append(WorkspaceDestination("Content", children: [
                WorkspaceDestination("Text", id: "write", symbol: "text.alignleft")]))
        }
        navigationGroups.append(WorkspaceDestination("Setup", children: [
            WorkspaceDestination("Connections", id: "connections", symbol: "network")]))
        sidebar.reloadData(); sidebar.expandItem(nil, expandChildren: true)
        syncSidebarSelection()
    }
    private func syncSidebarSelection() {
        let selected = pages.selectedTabViewItem?.identifier as? String
        // Design belongs to Audience and keeps that sidebar item selected.
        let destination = selected == "design" ? "receiver" : selected
        for row in 0..<sidebar.numberOfRows {
            if let item = sidebar.item(atRow: row) as? WorkspaceDestination, item.id == destination {
                sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                break
            }
        }
    }
    private func showPage(_ identifier: String, revealWindow: Bool = true) {
        let index = pages.indexOfTabViewItem(withIdentifier: identifier)
        guard index != NSNotFound else { return }
        window?.makeFirstResponder(nil)
        if identifier == "design", pages.selectedTabViewItem?.identifier as? String != "design" {
            templateEditor?.selectProfile(designs.profileID(for: outputDesignContent), preservingPreviewContent: true)
        }
        pages.selectTabViewItem(at: index)
        confidence.setPreviewActive(identifier == "confidence")
        syncSidebarSelection()
        refreshDraft()
        window?.contentView?.layoutSubtreeIfNeeded()
        if revealWindow { showWindow(nil) }
    }
    @objc private func sidebarClicked() {
        guard let item = sidebar.item(atRow: sidebar.clickedRow) as? WorkspaceDestination, let id = item.id else { return }
        showPage(id)
    }
    @objc func showConnectionsPage() { showPage("connections") }
    @objc func showComposerPage() {
        guard customTextEnabled else { return }
        showPage("write")
        window?.makeKeyAndOrderFront(nil)
    }
    @objc func showSettings() {
        window?.makeFirstResponder(nil)
        customTextSwitch.state = customTextEnabled ? .on : .off
        settingsWindow.showWindow(nil)
        settingsWindow.window?.makeKeyAndOrderFront(nil)
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
        showPage(destination, revealWindow: false)
        onCustomTextSettingChange?()
    }
    @objc func showReceiverPage() { showPage("receiver") }
    @objc func showConfidencePage() { showPage("confidence") }
    @objc func closeConfidence() { confidence.stop() }
    @objc private func toggleReceiving() {
        receiveButton.isEnabled = false
        if receiverStatus.listening || starting { server.stop(); failLocalConnections("Receiving paused.") } else { startReceiving() }
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
        server.start(name: name, key: key, port: receiverPort, advertise: advertiseReceiver)
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
        let loadPairing = self.loadPairing, storePairing = self.storePairing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var existing: Data?
                var notice: String?
                if !reset {
                    do { existing = try loadPairing("receiver") }
                    catch {
                        // Preserve the saved item for recovery or an explicit Reset Code.
                        notice = "Saved pairing could not be read from Keychain. This code is temporary and changes after restarting. Unlock Keychain and restart AltView to recover the saved code, or use Reset Code. \(error.localizedDescription)"
                    }
                }
                let key = try existing ?? PairingKey.generate()
                if existing == nil, notice == nil {
                    do { try storePairing(key, "receiver") }
                    catch {
                        notice = "Keychain could not save this pairing. This code is temporary and changes after restarting AltView. Enter it again on the sending Mac after restarting. \(error.localizedDescription)"
                    }
                }
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
                    self.pairingKey = key
                    self.pairingCodeField.stringValue = PairingKey.text(key)
                    self.receiveButton.isEnabled = true
                    self.copyButton.isEnabled = true; self.resetButton.isEnabled = true
                    self.receiveButton.title = "Resume Receiving"
                    self.statusLabel.stringValue = "Receiving paused"
                    self.pairingLabel.stringValue = notice ?? "Enter this code on the sending Mac. The connection is encrypted."
                    self.pairingLabel.toolTip = self.pairingLabel.stringValue
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

    @objc func closeOutput() { output.stop() }
    @objc private func clearOutput() { server.clearOutput() }
    private func refreshOutputReadiness() {
        let unavailable = template.requiresCustomArtwork && artwork == nil
        let readiness = unavailable && (output.readiness == .ready || output.readiness == .preview)
            ? OutputReadiness.unavailable : output.readiness
        server.updateOutputReadiness(readiness)
    }
    private var outputDesignContent: DisplayContent {
        let content = receiverStatus.content
        // A sender may hide with an empty snapshot. Keep the last visible
        // profile's artwork and typography while that composition exits.
        return !content.visible && receiverStatus.ownerName != nil && presentation.displayedContent.visible
            ? presentation.displayedContent : content
    }
    private var audienceDesignUsage: String {
        let profile = designs.profileID(for: outputDesignContent).rawValue
        if let owner = receiverStatus.ownerName { return "Audience uses \(profile) · From \(owner)" }
        return "Audience template: \(designs.selection.rawValue) · No active sender"
    }
    @objc private func audienceTemplateChanged() {
        pendingAudienceTemplate = TextTemplateSelection(rawValue: audienceTemplatePicker.titleOfSelectedItem ?? "") ?? .sender
        refreshAudienceTemplate()
    }
    private func refreshAudienceTemplate() {
        audienceTemplatePicker.selectItem(withTitle: pendingAudienceTemplate.rawValue)
        var candidate = designs; candidate.selection = pendingAudienceTemplate
        let design = candidate.design(for: outputDesignContent)
        let missingArtwork = design.template.requiresCustomArtwork && design.template.assetID.flatMap { artworks[$0] } == nil
        let publishing = pendingLocalContent != nil
        audienceTemplatePicker.isEnabled = !publishing
        applyTemplateButton.isEnabled = pendingAudienceTemplate != designs.selection && !artworkBusy && !missingArtwork && !publishing
        audienceTemplateHint.stringValue = missingArtwork
            ? "\(candidate.profileID(for: outputDesignContent).rawValue) PNG unavailable. Open Audience Design to replace it or hide Artwork."
            : pendingAudienceTemplate == .sender
            ? "Follow the sending app’s template. Text without a template uses Custom."
            : "Use \(candidate.profileID(for: outputDesignContent).rawValue) for all incoming text."
        audienceTemplateStatus.stringValue = pendingAudienceTemplate == designs.selection
            ? audienceDesignUsage : "Previewing \(candidate.profileID(for: outputDesignContent).rawValue) · Apply Template to update the audience."
        refreshAudiencePreview()
    }
    private func refreshAudiencePreview() {
        let pending = pendingAudienceTemplate != designs.selection
        if pending {
            var candidate = designs; candidate.selection = pendingAudienceTemplate
            let design = candidate.design(for: outputDesignContent)
            let artwork = design.template.assetID.flatMap { artworks[$0] }
            var content = receiverStatus.content
            if receiverStatus.ownerName == nil || (design.template.requiresCustomArtwork && artwork == nil) { content = .empty }
            templatePreviewPresentation.update(content: content, style: design.style, template: design.template,
                                               artwork: artwork, immediately: true)
            preview.setPresentation(templatePreviewPresentation)
        } else {
            if preview.presentation !== presentation { templatePreviewPresentation.stopAnimation() }
            preview.setPresentation(presentation)
        }
        audiencePreviewHeading.stringValue = pending ? "TEMPLATE PREVIEW · NOT APPLIED" : "THIS MAC · AUDIENCE PREVIEW"
        let scene = preview.presentation
        let displayed = scene.template.contentForDisplay(scene.content)
        let hasText = [displayed.title, displayed.body, displayed.footer].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if scene.template.requiresCustomArtwork && scene.artwork == nil && (pending || receiverStatus.ownerName != nil) {
            contentBadge.update("UNAVAILABLE", color: .systemOrange)
        } else if receiverStatus.ownerName != nil && !scene.content.visible { contentBadge.update("HIDDEN", color: .systemOrange) }
        else if hasText && scene.content.visible { contentBadge.update("TEXT VISIBLE", color: .systemGreen) }
        else { contentBadge.update("NO TEXT") }
        refreshFitStatus()
    }
    @objc private func applyAudienceTemplate() {
        refreshAudienceTemplate()
        guard applyTemplateButton.isEnabled else { return }
        designs.selection = pendingAudienceTemplate
        saveDesignPreferences()
        refreshCanvas()
    }
    private func refreshCanvas() {
        server.updateTemplatePolicy(designs.selection.policy)
        var content = receiverStatus.content
        let design = designs.design(for: outputDesignContent)
        template = design.template; style = design.style
        artwork = template.assetID.flatMap { artworks[$0] }
        let unavailable = template.requiresCustomArtwork && artwork == nil
        if unavailable || receiverStatus.ownerName == nil { content = .empty }
        presentation.update(content: content, style: style, template: template, artwork: artwork,
                            immediately: receiverStatus.ownerName == nil || unavailable)
        refreshAudienceTemplate()
        composer?.updateLocalOutput(owner: receiverStatus.ownerName, ownerID: receiverStatus.ownerID, notice: unavailable ? artworkNotice : "")
        templateEditor?.update(library: designs, artworks: artworks, busy: artworkBusy, message: artworkMessage)
        refreshOutputReadiness()
        refreshDraft()
    }
    private var artworkNotice: String {
        artworkBusy ? "Loading PNG artwork…" : "Lower third is blank. Open Design to replace the PNG, choose Built-in banner, or untick Artwork in Layout, then Apply."
    }
    private func refreshFitStatus() {
        guard preview.isVisibleForUpdates else { return }
        let scene = preview.presentation
        let content = scene.content
        let template = scene.template, style = scene.style
        let unavailable = template.requiresCustomArtwork && scene.artwork == nil
        if unavailable {
            fitLabel.stringValue = pendingAudienceTemplate != designs.selection ? audienceTemplateHint.stringValue : artworkNotice
        } else if content.visible && scene.textLayout.bodyFontSize < 28 {
            fitLabel.stringValue = "Text fits at \(Int(scene.textLayout.bodyFontSize)) pt. Use shorter content or enlarge its text area for better readability."
        } else {
            let preset = template.selectedContentTemplate(for: content).map { "\($0.name) template · " } ?? ""
            fitLabel.stringValue = "\(preset)16:9 canvas · White foreground · Key colour #\(style.background)"
        }
    }
    private func refreshDraft() {
        guard !updatingDraft, let editor = templateEditor, composer != nil else { return }
        updatingDraft = true
        defer { updatingDraft = false }
        editor.updateContent(draft: composer.draft, source: receiverStatus.content,
                             externalSource: receiverStatus.ownerID == composer.senderID ? nil : receiverStatus.ownerName,
                             customTextEnabled: customTextEnabled, outputContent: outputDesignContent,
                             audienceStatus: audienceDesignUsage)
        let draft = editor.draftLibrary ?? designs
        let design = draft.design(for: composer.draft)
        composer.updateDesign(template: design.template, applied: designs.design(for: composer.draft).template, style: design.style,
                              artwork: design.template.assetID.flatMap { editor.allDraftArtworks[$0] },
                              ready: editor.canPublish(content: composer.draft), changed: editor.hasChanges,
                              policy: draft.selection.policy)
    }
    private func cancelLocalPublish() {
        pendingLocalContent = nil
        templateEditor?.setPublishing(false)
        refreshAudienceTemplate()
    }
    @objc func showDesignPage() { showPage("design") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { templateEditor?.windowShouldClose(sender) ?? true }
    func confirmTermination() -> NSApplication.TerminateReply {
        guard let editor = templateEditor, editor.needsCloseConfirmation else { return .terminateNow }
        editor.confirmClose(window!) { NSApp.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }
    private func loadArtwork() {
        let ids = designs.assetIDs
        guard !ids.isEmpty else { return }
        let revision = UUID(); artworkRevision = revision
        artworkBusy = true; artworkMessage = "Loading saved PNG…"
        refreshCanvas()
        var remaining = ids
        for id in ids {
            let name = DesignProfileID.allCases.compactMap { profile -> String? in
                let value = designs[profile].template
                return value.assetID == id ? value.assetName : nil
            }.first ?? "Imported PNG"
            artworkStore.load(id: id, name: name) { [weak self] result in
                guard let self, self.artworkRevision == revision else { return }
                remaining.remove(id)
                if case .success(let value) = result { self.artworks[id] = value }
                self.artworkBusy = !remaining.isEmpty
                self.artworkMessage = ""
                self.refreshCanvas()
            }
        }
    }
    private func applyDesigns(_ value: TemplateDesignLibrary, artworks: [UUID: PNGArtwork]) {
        let previous = designs.assetIDs
        let selection = designs.selection
        designs = value.clamped(); designs.selection = selection
        artworkRevision = UUID(); artworkBusy = false
        self.artworks = artworks
        artworkMessage = ""
        saveDesignPreferences()
        refreshCanvas()
        // A migrated PNG can belong to several templates. Delete only when
        // no saved profile references it anymore.
        for id in previous.subtracting(designs.assetIDs) { artworkStore.discard(id: id) }
    }
    private func saveDesignPreferences() {
        defaults.set(try? JSONEncoder().encode(designs), forKey: "templateDesignLibrary")
        // Keep the previous preference keys readable for older builds.
        let custom = designs.design(.custom)
        var legacy = custom.template; legacy.textTemplate = designs.selection
        defaults.set(try? JSONEncoder().encode(legacy), forKey: "lowerThirdTemplate")
        defaults.set(try? JSONEncoder().encode(custom.style), forKey: "outputStyle")
    }
    func shutdown() {
        stopped = true
        settingsWindow.close()
        failLocalConnections("AltView closed.")
        artworkRevision = UUID()
        composer.shutdown(); server.stop(); output.stop(); confidence.shutdown(); presentation.stopAnimation(); templatePreviewPresentation.stopAnimation(); templateEditor?.shutdown()
    }
}

private final class WorkspaceDestination {
    let title: String
    let id: String?
    let symbol: String?
    let children: [WorkspaceDestination]
    init(_ title: String, id: String? = nil, symbol: String? = nil, children: [WorkspaceDestination] = []) {
        self.title = title; self.id = id; self.symbol = symbol; self.children = children
    }
}

extension ReceiverWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? WorkspaceDestination)?.children.count ?? navigationGroups.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? WorkspaceDestination)?.children ?? navigationGroups)[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !(item as! WorkspaceDestination).children.isEmpty
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as! WorkspaceDestination).id == nil
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as! WorkspaceDestination).id != nil
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let destination = item as! WorkspaceDestination
        let cell = WorkspaceSidebarCell()
        let label = NSTextField(labelWithString: destination.title)
        label.font = .systemFont(ofSize: destination.id == nil ? 11 : 13, weight: destination.id == nil ? .semibold : .regular)
        cell.isGroup = destination.id == nil
        label.textColor = cell.isGroup ? .secondaryLabelColor : .controlTextColor
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        var leading = cell.leadingAnchor
        if let symbol = destination.symbol {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            icon.contentTintColor = .controlAccentColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = icon; cell.addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18)])
            leading = icon.trailingAnchor
        }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leading, constant: destination.symbol == nil ? 0 : 7),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)])
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let destination = sidebar.item(atRow: sidebar.selectedRow) as? WorkspaceDestination,
              let id = destination.id else { return }
        let current = pages.selectedTabViewItem?.identifier as? String
        guard current != id, !(current == "design" && id == "receiver") else { return }
        showPage(id)
    }
}

private final class WorkspaceSidebarCell: NSTableCellView {
    var isGroup = false
    override var allowsVibrancy: Bool { false }
    override func viewWillDraw() {
        super.viewWillDraw()
        let selected = (superview as? NSTableRowView)?.isSelected == true
        textField?.textColor = isGroup ? .secondaryLabelColor
            : selected ? .alternateSelectedControlTextColor : .controlTextColor
    }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            textField?.textColor = isGroup ? .secondaryLabelColor
                : backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .controlTextColor
        }
    }
}

extension ReceiverWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { senderRows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard senderRows.indices.contains(row) else { return nil }
        let connection = senderRows[row]
        let name = connection.senderID == composer.senderID ? "Text on this Mac" : connection.name
        if tableColumn?.identifier.rawValue == "connectionAction" {
            let button = ConnectionActionButton(title: connection.isDisconnected ? "Allow Reconnect" : "Disconnect", target: nil, action: nil)
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 12)
            button.setAccessibilityLabel("\(button.title) \(name)")
            button.setAccessibilityIdentifier("senderAction-\(connection.id.uuidString)")
            button.toolTip = connection.isDisconnected ? "Let this sender connect again."
                : connection.isPresenting ? "Disconnect this sender and clear its presented text." : "Disconnect this sender. The current presentation keeps running."
            button.onClick = { [weak self] in
                guard let self else { return }
                if connection.isDisconnected {
                    self.server.allowReconnect(senderID: connection.senderID)
                } else {
                    // Validate the session again on the server queue; a stale row
                    // must never disconnect a replacement connection.
                    self.server.disconnectConnection(connection.id)
                }
            }
            button.target = button; button.action = #selector(ConnectionActionButton.performConnectionAction)
            let cell = NSView()
            button.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(button)
            NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let title = UI.label(name, size: 13, bold: true)
        title.maximumNumberOfLines = 1; title.lineBreakMode = .byTruncatingTail
        title.toolTip = name
        let subtitle = connection.isDisconnected ? "Disconnected by you"
            : connection.isPresenting ? "Presenting to outputs" : "Connected · idle"
        let detail = UI.label(subtitle, size: 11, color: connection.isPresenting ? .systemGreen : .secondaryLabelColor)
        let cell = NSTableCellView(); cell.textField = title
        UI.fill(UI.column(title, detail, spacing: 3), in: cell, padding: 8)
        cell.setAccessibilityLabel("\(name), \(subtitle)")
        return cell
    }
}

private final class ConnectionActionButton: NSButton {
    var onClick: (() -> Void)?
    @objc func performConnectionAction() { onClick?() }
}
