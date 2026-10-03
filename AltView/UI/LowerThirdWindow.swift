import AppKit
import UniformTypeIdentifiers

/// A private design draft. Only Apply hands the template and its artwork to the
/// receiver; draft content, samples and guides never enter the output scene.
final class LowerThirdWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    var onApply: ((LowerThirdTemplate, PNGArtwork?) -> Void)?
    var onApplyLibrary: ((TemplateDesignLibrary, [UUID: PNGArtwork]) -> Void)?
    var onEditText: (() -> Void)?
    var onApplyStyle: ((OutputStyle) -> Void)?
    var onDraftChange: (() -> Void)?
    private(set) var style = OutputStyle()
    private var appliedStyle = OutputStyle()
    private var draftContent = DisplayContent.empty
    private var sourceContent = DisplayContent.empty
    private var outputContent = DisplayContent.empty
    private var sourceName: String?
    private var usesRealContent = false
    private var customTextEnabled = true
    private var publishing = false
    private let previewHeading = UI.label("Design preview · not live", size: 13, bold: true)
    private let sourceHint = UI.label("", size: 12, color: .secondaryLabelColor)
    private let editTextButton = NSButton()
    private let backgroundPicker = NSPopUpButton()
    private let backgroundScope = UI.label("Shared key colour · all templates", size: 11, color: .secondaryLabelColor)
    private var customBackgroundSelected = false
    private let colorWell = NSColorWell()
    private let fontPicker = NSPopUpButton()
    private let sizeSlider = NSSlider(value: 88, minValue: 24, maxValue: 160, target: nil, action: nil)
    private let sizeLabel = UI.label("88 pt", size: 11)
    private let heightSlider = NSSlider(value: 80, minValue: 15, maxValue: 90, target: nil, action: nil)
    private let positionPicker = NSPopUpButton()
    private let fullAlignmentPicker = NSPopUpButton()
    private let textTemplatePicker = NSPopUpButton()
    private let textTemplateHint = UI.label("", size: 11, color: .secondaryLabelColor)
    private let profilePicker = NSPopUpButton()
    private var profileControls: NSView!
    private let lineLayoutPicker = NSPopUpButton()
    private let joinerPicker = NSPopUpButton()
    private var lyricControls: NSView!
    private let spacingSlider = NSSlider(value: 12, minValue: 0, maxValue: 40, target: nil, action: nil)
    private let spacingLabel = UI.label("12%", size: 11)
    private var library: TemplateDesignLibrary?
    private var appliedLibrary: TemplateDesignLibrary?
    private(set) var editingProfile = DesignProfileID.custom
    private var appliedAssets: [UUID: PNGArtwork] = [:]
    private var draftAssets: [UUID: PNGArtwork] = [:]
    var draftLibrary: TemplateDesignLibrary? {
        guard var result = library else { return nil }
        result[editingProfile] = TemplateDesign(template: template, style: style)
        result.background = style.background
        return result
    }
    var allDraftArtworks: [UUID: PNGArtwork] {
        var result = appliedAssets.merging(draftAssets) { _, draft in draft }
        if let pendingArtwork { result[pendingArtwork.id] = pendingArtwork }
        return result
    }
    private var fullLayout: NSView!
    private var lowerAlignment: NSView!
    private var artworkSection: NSView!
    private var artworkSizing: NSView!
    private var animationSection: NSView!
    private var resetLayoutRow: NSView!
    private var regionGrid: NSGridView!
    private let layoutModeHint = UI.label("", size: 11, color: .secondaryLabelColor)
    private var editorRoot: NSView!
    var contentView: NSView { editorRoot }
    private var hostWindow: NSWindow? { editorRoot?.window ?? window }
    var draftArtwork: PNGArtwork? { artwork }
    private var canCommitDraft: Bool { invalidFields.isEmpty && !importing && !loading && !publishing }
    var canPublish: Bool { canCommitDraft && !hasUnfinishedEdit && (!template.requiresCustomArtwork || artwork != nil) }
    private func artworkIsAvailable(for content: DisplayContent) -> Bool {
        guard let library = draftLibrary else { return !template.requiresCustomArtwork || artwork != nil }
        let design = library.design(for: content)
        return !design.template.requiresCustomArtwork || design.template.assetID.flatMap { allDraftArtworks[$0] } != nil
    }
    func canPublish(content: DisplayContent) -> Bool {
        canCommitDraft && !hasUnfinishedEdit && artworkIsAvailable(for: content)
    }
    private var outputArtworkWarning: String? {
        guard !loading, let library = draftLibrary, !artworkIsAvailable(for: outputContent) else { return nil }
        let name = library.profileID(for: outputContent).rawValue
        return "\(name) PNG unavailable. Select \(name) in Edit template to replace the PNG, use Built-in banner, or hide Artwork."
    }
    func finishEditing() { hostWindow?.makeFirstResponder(nil) }
    func setPublishing(_ value: Bool) { publishing = value; if value { colorWell.deactivate() }; refresh() }
    func updateContent(draft: DisplayContent, source: DisplayContent, externalSource: String?, customTextEnabled: Bool = true,
                       outputContent: DisplayContent? = nil) {
        let previousSource = sourceName
        let rebuildChoices = !usesRealContent || self.customTextEnabled != customTextEnabled
        self.customTextEnabled = customTextEnabled
        draftContent = draft; sourceContent = source; sourceName = externalSource
        self.outputContent = outputContent ?? source
        let fallback = customTextEnabled ? "Text draft" : "Sample · Speaker"
        if rebuildChoices {
            let selection = samplePicker.titleOfSelectedItem
            usesRealContent = true
            samplePicker.removeAllItems()
            samplePicker.addItems(withTitles: (customTextEnabled ? ["Text draft"] : [])
                + ["Current source", "Sample · Speaker", "Sample · Announcement", "Sample · Long message", "Sample · Scripture", "Sample · Lyrics"])
            samplePicker.selectItem(withTitle: selection.flatMap { samplePicker.item(withTitle: $0)?.title }
                ?? (externalSource == nil ? fallback : "Current source"))
        }
        if previousSource != externalSource, externalSource != nil { samplePicker.selectItem(withTitle: "Current source") }
        samplePicker.item(withTitle: "Current source")?.isEnabled = externalSource != nil
        if externalSource == nil && samplePicker.titleOfSelectedItem == "Current source" { samplePicker.selectItem(withTitle: fallback) }
        editTextButton.isHidden = !customTextEnabled
        editTextButton.title = externalSource == nil ? "Edit Text…" : "Open Text Draft…"
        refresh()
    }
    private(set) var template = LowerThirdTemplate()
    private var appliedTemplate = LowerThirdTemplate()
    private var appliedArtwork: PNGArtwork?
    private var pendingArtwork: PNGArtwork?
    private var artwork: PNGArtwork? { pendingArtwork ?? appliedArtwork }
    private let artworkStore: PNGArtworkStore
    private var importRevision = UUID()
    private var importing = false
    private var loading = false
    private var artworkMessage = ""
    private var validationMessage = ""
    private var invalidFields: Set<ObjectIdentifier> = []
    private let presentation = CanvasPresentation()
    private lazy var preview = OutputCanvas(presentation: presentation)
    private let guides = LowerThirdGuidesView()
    private lazy var enabled = NSButton(checkboxWithTitle: "Use lower-third layout", target: self, action: #selector(controlsChanged))
    private lazy var showArtwork = NSButton(checkboxWithTitle: "Artwork", target: self, action: #selector(controlsChanged))
    private lazy var showTitle = NSButton(checkboxWithTitle: "Title", target: self, action: #selector(controlsChanged))
    private lazy var showFooter = NSButton(checkboxWithTitle: "Footer", target: self, action: #selector(controlsChanged))
    private lazy var showGuides = NSButton(checkboxWithTitle: "Show layout guides", target: self, action: #selector(previewChanged))
    private let artworkPicker = NSPopUpButton()
    private let animationPicker = NSPopUpButton()
    private let alignmentPicker = NSPopUpButton()
    private let samplePicker = NSPopUpButton()
    private let duration = NSTextField(string: "0.45")
    private let filename = UI.label("", size: 12)
    private let status = UI.label("", size: 12, color: .secondaryLabelColor)
    private let bodyLayoutHint = UI.label("", size: 11, color: .secondaryLabelColor)
    private let feedback = UI.label("", size: 12, color: .secondaryLabelColor)
    private let draftStatus = UI.label("", size: 12, color: .secondaryLabelColor)
    private let draftBadge = StatusBadge("APPLIED")
    private var chooseButton: NSButton!
    private var applyButton: NSButton!
    private var revertButton: NSButton!
    private var replayButton: NSButton!
    private lazy var bannerButton = UI.button("Fit to Banner", target: self, action: #selector(bannerArea))
    private lazy var canvasButton = UI.button("Fit to Canvas", target: self, action: #selector(fullCanvas))
    private var regionFields: [[NSTextField]] = []
    private let regions: [WritableKeyPath<LowerThirdTemplate, TemplateRegion>] = [\.artworkRegion, \.titleRegion, \.bodyRegion, \.footerRegion]
    private let regionNames = ["Artwork", "Title", "Body", "Footer"]
    var hasChanges: Bool {
        if let draftLibrary { return draftLibrary != appliedLibrary }
        return template != appliedTemplate || style != appliedStyle
    }

    init(artworkStore: PNGArtworkStore = PNGArtworkStore()) {
        self.artworkStore = artworkStore
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AltView — Lower Third"
        window.minSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.colorSpace = .sRGB
        super.init(window: window)
        window.delegate = self
        buildInterface()
        refresh()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        enabled.setAccessibilityIdentifier("lowerThirdEnabled")
        enabled.toolTip = "On: use the lower-third text boxes and optional artwork. Off: arrange text across the full canvas."
        layoutModeHint.maximumNumberOfLines = 0
        showArtwork.setAccessibilityIdentifier("lowerThirdShowArtwork")
        showTitle.setAccessibilityIdentifier("lowerThirdShowTitle")
        showFooter.setAccessibilityIdentifier("lowerThirdShowFooter")
        showArtwork.setAccessibilityLabel("Show artwork")
        showTitle.setAccessibilityLabel("Show title")
        showFooter.setAccessibilityLabel("Show footer")
        for toggle in [showArtwork, showTitle, showFooter] { toggle.font = .systemFont(ofSize: 11) }
        showArtwork.toolTip = "Untick to show text without artwork. Your image and saved positions are kept."
        showTitle.toolTip = "Show or hide the title in either layout. Hidden text is kept, and Body uses the freed space."
        showFooter.toolTip = "Show or hide the footer in either layout. Hidden text is kept, and Body uses the freed space."
        artworkPicker.addItems(withTitles: LowerThirdArtwork.allCases.map(\.rawValue))
        artworkPicker.autoenablesItems = false
        animationPicker.addItems(withTitles: LowerThirdAnimation.allCases.map(\.rawValue))
        alignmentPicker.addItems(withTitles: CanvasAlignment.allCases.map(\.rawValue))
        for picker in [artworkPicker, animationPicker, alignmentPicker] {
            picker.target = self; picker.action = #selector(controlsChanged)
        }
        artworkPicker.setAccessibilityLabel("Lower third artwork")
        animationPicker.setAccessibilityLabel("Lower third animation")
        alignmentPicker.setAccessibilityLabel("Lower third text alignment")
        duration.setAccessibilityLabel("Animation duration in seconds")
        duration.toolTip = "0.1 to 2 seconds for a complete entrance or exit."
        duration.widthAnchor.constraint(equalToConstant: 50).isActive = true
        duration.delegate = self
        chooseButton = UI.button("Choose PNG…", target: self, action: #selector(choosePNG))
        filename.maximumNumberOfLines = 2
        filename.lineBreakMode = .byTruncatingMiddle
        status.maximumNumberOfLines = 0
        artworkSection = UI.card("Artwork", content: UI.column(
            artworkPicker, UI.row(chooseButton, NSView()), filename, status, spacing: 10))
        animationSection = UI.card("Animation", content: UI.column(
            UI.row(animationPicker, duration, UI.label("sec", size: 11), NSView()),
            UI.label("0.1–2 seconds. Respects Reduce Motion.", size: 11, color: .secondaryLabelColor), spacing: 8))

        backgroundPicker.addItems(withTitles: ["Black · Luma key", "Green · Chroma key", "Blue · Chroma key", "Custom colour"])
        backgroundPicker.setAccessibilityLabel("Draft keying background")
        backgroundPicker.toolTip = "Key colour is shared by Custom, Scripture and Lyrics. Changes stay private until Apply."
        colorWell.toolTip = backgroundPicker.toolTip
        fontPicker.addItems(withTitles: ["System", "Helvetica", "Georgia", "Avenir Next"])
        fontPicker.setAccessibilityLabel("Draft font")
        positionPicker.addItems(withTitles: CanvasPosition.allCases.map(\.rawValue))
        positionPicker.setAccessibilityLabel("Draft vertical position")
        fullAlignmentPicker.addItems(withTitles: CanvasAlignment.allCases.map(\.rawValue))
        fullAlignmentPicker.setAccessibilityLabel("Draft text alignment")
        textTemplatePicker.addItems(withTitles: TextTemplateSelection.allCases.map(\.rawValue))
        textTemplatePicker.setAccessibilityLabel("Text template")
        textTemplatePicker.target = self; textTemplatePicker.action = #selector(textTemplateChanged)
        textTemplateHint.maximumNumberOfLines = 0
        profilePicker.addItems(withTitles: DesignProfileID.allCases.map(\.rawValue))
        profilePicker.setAccessibilityLabel("Edit template")
        profilePicker.target = self; profilePicker.action = #selector(profileChanged)
        profileControls = UI.column(UI.label("Edit template", size: 11, bold: true), profilePicker,
            UI.label("Each template remembers its own artwork and design. Key colour is shared. Editing stays private until Apply.", size: 11, color: .secondaryLabelColor), spacing: 6)
        lineLayoutPicker.addItems(withTitles: LyricLineLayout.allCases.map(\.rawValue))
        lineLayoutPicker.setAccessibilityLabel("Lyrics line layout")
        joinerPicker.addItems(withTitles: LyricJoiner.allCases.map(\.rawValue))
        joinerPicker.setAccessibilityLabel("Lyrics line joiner")
        for picker in [lineLayoutPicker, joinerPicker] { picker.target = self; picker.action = #selector(lyricLayoutChanged) }
        lyricControls = UI.column(UI.label("Lyrics lines", size: 11, bold: true), lineLayoutPicker,
            UI.row(UI.label("Join with", size: 11), joinerPicker),
            UI.label("Compact pairs joins adjacent lines at the fitted text size, then uses the freed space for larger text. Stanza breaks are kept.", size: 11, color: .secondaryLabelColor), spacing: 6)
        spacingSlider.setAccessibilityLabel("Draft line spacing")
        spacingSlider.target = self; spacingSlider.action = #selector(appearanceChanged)
        sizeSlider.setAccessibilityLabel("Draft font size")
        heightSlider.setAccessibilityLabel("Draft maximum content height")
        for control: NSControl in [backgroundPicker, colorWell, fontPicker, sizeSlider, heightSlider, positionPicker, fullAlignmentPicker] {
            control.target = self; control.action = #selector(appearanceChanged)
        }
        colorWell.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 25).isActive = true
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        fullLayout = UI.column(UI.row(positionPicker, fullAlignmentPicker),
            UI.label("Maximum content height", size: 11, color: .secondaryLabelColor), heightSlider, spacing: 8)
        lowerAlignment = UI.row(UI.label("Alignment", size: 12), alignmentPicker, NSView())
        let typography = UI.card("Typography", content: UI.column(fontPicker,
            UI.row(sizeSlider, sizeLabel), UI.label("Extra line spacing", size: 11, color: .secondaryLabelColor),
            UI.row(spacingSlider, spacingLabel), lowerAlignment, lyricControls, spacing: 10))
        let composition = UI.card("Canvas", content: UI.column(enabled, layoutModeHint,
            backgroundScope, UI.row(backgroundPicker, colorWell), fullLayout, spacing: 12))

        var gridRows: [[NSView]] = [[UI.label("Area", size: 11, bold: true)] + ["X %", "Y %", "W %", "H %"].map { UI.label($0, size: 10, color: .secondaryLabelColor, bold: true) }]
        for name in regionNames {
            var fields: [NSTextField] = []
            for component in ["X", "Y", "Width", "Height"] {
                let field = NSTextField(string: "0")
                field.delegate = self
                field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                field.alignment = .right
                field.setAccessibilityLabel("\(name) \(component) percent")
                field.toolTip = "\(name) \(component.lowercased()), as a percentage of the full canvas."
                field.widthAnchor.constraint(equalToConstant: 44).isActive = true
                fields.append(field)
            }
            regionFields.append(fields)
            let label: NSView = name == "Artwork" ? showArtwork : name == "Title" ? showTitle : name == "Footer" ? showFooter : UI.label(name, size: 11)
            label.widthAnchor.constraint(equalToConstant: 78).isActive = true
            gridRows.append([label] + fields)
        }
        let grid = NSGridView(views: gridRows)
        regionGrid = grid
        grid.columnSpacing = 6; grid.rowSpacing = 8
        grid.xPlacement = .leading; grid.yPlacement = .center
        bannerButton.controlSize = .small; canvasButton.controlSize = .small
        bannerButton.font = .systemFont(ofSize: 11); canvasButton.font = .systemFont(ofSize: 11)
        let reset = UI.button("Reset All Positions", target: self, action: #selector(resetLayout))
        reset.controlSize = .small; reset.font = .systemFont(ofSize: 11)
        artworkSizing = UI.column(UI.separator(), UI.label("Artwork size", size: 11, color: .secondaryLabelColor),
            UI.row(bannerButton, canvasButton, NSView()), spacing: 10)
        resetLayoutRow = UI.row(reset, NSView())
        let layout = UI.card("Layout", content: UI.column(grid, bodyLayoutHint,
            artworkSizing, resetLayoutRow, spacing: 10))
        let textTemplates = UI.card("Text template", content: UI.column(
            UI.label("Use on output", size: 11, bold: true), textTemplatePicker, textTemplateHint, profileControls, spacing: 8))
        let inspector = UI.scrolling(UI.column(textTemplates, composition, typography, artworkSection, animationSection, layout, spacing: 12))
        inspector.widthAnchor.constraint(equalToConstant: 340).isActive = true
        inspector.setAccessibilityLabel("Design inspector")

        samplePicker.addItems(withTitles: ["Speaker", "Announcement", "Long message", "Scripture", "Lyrics"])
        samplePicker.target = self; samplePicker.action = #selector(previewChanged)
        samplePicker.setAccessibilityLabel("Design preview content"); samplePicker.autoenablesItems = false
        samplePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        replayButton = UI.button("Preview Animation", target: self, action: #selector(replay))
        previewHeading.font = .systemFont(ofSize: 11, weight: .semibold)
        previewHeading.textColor = .secondaryLabelColor
        let stage = UI.canvasStage(preview, overlay: guides)
        feedback.maximumNumberOfLines = 3
        editTextButton.title = "Edit Text…"; editTextButton.bezelStyle = .rounded
        editTextButton.target = self; editTextButton.action = #selector(editText)
        editTextButton.toolTip = "Open the local Text draft. This does not edit text in another app or take output."
        sourceHint.font = .systemFont(ofSize: 11)
        sourceHint.maximumNumberOfLines = 2
        sourceHint.lineBreakMode = .byTruncatingTail
        sourceHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let previewHeader = UI.row(previewHeading, NSView(), samplePicker)
        previewHeader.setHuggingPriority(.required, for: .vertical)
        let previewControls = UI.row(showGuides, NSView(), replayButton)
        // Keep this row's space when its controls are hidden; an unconstrained
        // spacer would otherwise grow and squeeze the canvas to its minimum.
        previewControls.heightAnchor.constraint(equalToConstant: 28).isActive = true
        // Mode-specific guidance can wrap to three lines without resizing the canvas.
        feedback.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let previewSource = UI.row(sourceHint, NSView(), editTextButton)
        previewSource.setHuggingPriority(.required, for: .vertical)
        let sample = UI.column(previewHeader, stage, previewControls, feedback, previewSource, spacing: 10)
        sample.distribution = .fill
        let body = UI.row(sample, inspector); body.alignment = .top; body.spacing = 24
        sample.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -364).isActive = true
        sample.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        inspector.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true

        applyButton = UI.primaryButton("Apply Design to Output", target: self, action: #selector(applyChanges))
        applyButton.setAccessibilityIdentifier("applyLowerThird")
        applyButton.keyEquivalent = "s"; applyButton.keyEquivalentModifierMask = [.command]
        revertButton = UI.button("Revert Changes", target: self, action: #selector(revertChanges))
        draftBadge.setAccessibilityIdentifier("designDraftStatus")
        draftStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = UI.row(draftBadge, draftStatus, NSView(), revertButton, applyButton)
        actions.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        let heading = UI.pageHeading("Design", subtitle: "Set the appearance of this Mac’s output. Apply when you’re ready.")
        let root = UI.column(heading, body, UI.separator(), actions, spacing: 16)
        root.distribution = .fill
        editorRoot = NSView()
        UI.fill(root, in: editorRoot, padding: 0)
        UI.fill(editorRoot, in: window!.contentView!, padding: 16)
    }

    /// Receiver status can refresh at any time, including during an unfinished edit.
    func update(library incoming: TemplateDesignLibrary, artworks: [UUID: PNGArtwork], busy: Bool, message: String) {
        let incoming = incoming.clamped()
        let dirty = hasChanges
        if library == nil || !dirty {
            library = incoming
            let design = incoming.design(editingProfile)
            template = design.template; style = design.style
        }
        appliedLibrary = incoming; appliedAssets = artworks
        let applied = incoming.design(editingProfile)
        appliedTemplate = applied.template; appliedStyle = applied.style
        appliedArtwork = appliedTemplate.assetID.flatMap { artworks[$0] }
        loading = busy
        customBackgroundSelected = !["000000", "00FF00", "0000FF"].contains(style.background)
        if !importing && pendingArtwork == nil { artworkMessage = message }
        refresh()
    }

    func update(template incoming: LowerThirdTemplate, style: OutputStyle, artwork: PNGArtwork?, busy: Bool, message: String) {
        let incoming = incoming.clamped()
        if !hasChanges {
            template = incoming
        } else if template.enabled == appliedTemplate.enabled {
            // Merge an applied enable change only when the draft did not edit it.
            template.enabled = incoming.enabled
        }
        appliedTemplate = incoming
        appliedArtwork = artwork
        if self.style == appliedStyle && self.style != style {
            self.style = style
            customBackgroundSelected = !["000000", "00FF00", "0000FF"].contains(style.background)
        }
        appliedStyle = style; loading = busy
        if !importing && pendingArtwork == nil { artworkMessage = message }
        refresh()
    }

    @objc private func appearanceChanged(_ sender: NSControl) {
        guard !publishing else { return }
        if sender === backgroundPicker {
            customBackgroundSelected = backgroundPicker.indexOfSelectedItem == 3
            let colors = ["000000", "00FF00", "0000FF"]
            if colors.indices.contains(backgroundPicker.indexOfSelectedItem) { style.background = colors[backgroundPicker.indexOfSelectedItem] }
        } else if sender === colorWell, let color = colorWell.color.usingColorSpace(.sRGB) {
            style.background = String(format: "%02X%02X%02X", Int(round(color.redComponent * 255)), Int(round(color.greenComponent * 255)), Int(round(color.blueComponent * 255)))
        } else if sender === spacingSlider {
            style.lineSpacing = spacingSlider.doubleValue.rounded() / 100
        } else if sender === fontPicker {
            style.fontName = fontPicker.titleOfSelectedItem == "Avenir Next" ? "AvenirNext-Regular" : (fontPicker.titleOfSelectedItem ?? "System")
        } else if sender === sizeSlider {
            style.fontSize = sizeSlider.doubleValue.rounded()
        } else if sender === heightSlider {
            style.heightFraction = heightSlider.doubleValue.rounded() / 100
        } else if sender === positionPicker {
            style.position = CanvasPosition(rawValue: positionPicker.titleOfSelectedItem ?? "") ?? .center
        } else if sender === fullAlignmentPicker {
            if template.customized || template.selectedContentTemplate(for: previewContent) == nil {
                style.alignment = CanvasAlignment(rawValue: fullAlignmentPicker.titleOfSelectedItem ?? "") ?? .center
                if template.customized { template.alignment = style.alignment }
            }
        }
        refresh()
    }
    private func refresh() {
        // Restore control availability before applying context-specific restrictions.
        func enable(_ view: NSView) {
            if let control = view as? NSControl { control.isEnabled = true }
            view.subviews.forEach(enable)
        }
        if let editorRoot { enable(editorRoot) }
        let layoutTemplate = template.applyingContentTemplate(for: previewContent)
        let preset = template.selectedContentTemplate(for: previewContent)
        textTemplatePicker.selectItem(withTitle: (library?.selection ?? template.textTemplate).rawValue)
        textTemplateHint.stringValue = preset.map {
            ($0 == .scripture ? "Scripture: left aligned, with reference above and translation below."
                : "Lyrics: centred body text, with no title or footer.")
            + " Choose Custom layout to edit alignment and title/footer visibility."
        } ?? (template.textTemplate == .sender
            ? "Sending apps can request Scripture or Lyrics for each message. Text without a request uses your custom layout."
            : "Use your alignment and title/footer settings for every message.")
        profileControls.isHidden = library == nil
        backgroundScope.isHidden = library == nil
        if let library {
            textTemplateHint.stringValue = library.selection == .sender
                ? "Incoming text selects its saved template. Messages without a template use Custom."
                : "Incoming text uses the selected template. Apply to change output."
            profilePicker.selectItem(withTitle: editingProfile.rawValue)
            profilePicker.isEnabled = !importing && !loading
        }
        lyricControls.isHidden = preset != .lyrics
        lineLayoutPicker.selectItem(withTitle: template.lyricLineLayout.rawValue)
        joinerPicker.selectItem(withTitle: template.lyricJoiner.rawValue)
        joinerPicker.isEnabled = template.lyricLineLayout == .compact
        spacingSlider.doubleValue = style.lineSpacing * 100
        spacingLabel.stringValue = "\(Int(style.lineSpacing * 100))%"
        backgroundPicker.selectItem(at: customBackgroundSelected ? 3 : (["000000", "00FF00", "0000FF"].firstIndex(of: style.background) ?? 3))
        colorWell.color = style.backgroundColor; colorWell.isEnabled = backgroundPicker.indexOfSelectedItem == 3
        fontPicker.selectItem(withTitle: style.fontName == "AvenirNext-Regular" ? "Avenir Next" : style.fontName)
        sizeSlider.doubleValue = style.fontSize; sizeLabel.stringValue = "\(Int(style.fontSize)) pt"
        heightSlider.doubleValue = style.heightFraction * 100
        positionPicker.selectItem(withTitle: style.position.rawValue)
        fullAlignmentPicker.selectItem(withTitle: (preset == nil ? style.alignment : layoutTemplate.alignment).rawValue)
        fullAlignmentPicker.isEnabled = template.customized || preset == nil
        fullLayout?.isHidden = template.enabled
        lowerAlignment?.isHidden = !template.enabled
        artworkSection.isHidden = !template.enabled
        artworkSizing.isHidden = !template.enabled
        animationSection.isHidden = !template.enabled
        resetLayoutRow.isHidden = !template.enabled
        for row in [0, 1, 3] { regionGrid.row(at: row).isHidden = !template.enabled }
        for column in 1..<regionGrid.numberOfColumns { regionGrid.column(at: column).isHidden = !template.enabled }
        showGuides.isHidden = !template.enabled
        replayButton.isHidden = !template.enabled
        layoutModeHint.stringValue = template.enabled
            ? "Text uses the lower-third boxes near the bottom. Artwork is optional."
            : "Text uses the full canvas. Enable this to place it in the lower-third area."
        enabled.state = template.enabled ? .on : .off
        showArtwork.state = template.showsArtwork ? .on : .off
        showTitle.state = layoutTemplate.showsTitle ? .on : .off
        showFooter.state = layoutTemplate.showsFooter ? .on : .off
        showTitle.isEnabled = template.customized || preset == nil; showFooter.isEnabled = template.customized || preset == nil
        artworkPicker.selectItem(withTitle: template.artwork.rawValue)
        artworkPicker.item(withTitle: LowerThirdArtwork.custom.rawValue)?.isEnabled = artwork != nil || template.artwork == .custom
        chooseButton.isEnabled = !importing && !loading
        bannerButton.isEnabled = template.showsArtwork
        canvasButton.isEnabled = template.showsArtwork
        if template.artwork == .builtIn {
            filename.stringValue = preset == .lyrics
                ? "Navy lyric panel with gold accents" : "Navy banner with a gold accent"
        } else { filename.stringValue = template.assetName ?? "No imported PNG" }
        filename.toolTip = template.artwork == .custom ? template.assetName : nil
        let unavailable = template.showsArtwork && template.artwork == .custom && artwork == nil
        if importing { status.stringValue = "Importing PNG… Your current output is unchanged." }
        else if unavailable { status.stringValue = loading ? "Loading saved PNG…" : "PNG unavailable. Choose PNG… to replace it, select Built-in banner, or untick Artwork in Layout for text only." }
        else if artworkMessage.hasPrefix("Import failed") { status.stringValue = artworkMessage }
        else if !template.showsArtwork { status.stringValue = "Artwork hidden. Text keeps its layout. Tick Artwork in Layout to show the selected image again." }
        else if template.artwork == .builtIn, let name = template.assetName { status.stringValue = "Saved PNG: \(name). Select Imported PNG to use it again." }
        else if template.artwork == .custom { status.stringValue = pendingArtwork == nil ? "PNG saved in AltView. The original file is no longer needed." : artworkMessage }
        else { status.stringValue = "Import a transparent PNG up to 20 MB. AltView saves its own copy." }
        status.textColor = unavailable && !loading || artworkMessage.hasPrefix("Import failed") ? .systemOrange : .secondaryLabelColor
        animationPicker.selectItem(withTitle: template.animation.rawValue)
        alignmentPicker.selectItem(withTitle: layoutTemplate.alignment.rawValue)
        alignmentPicker.isEnabled = template.customized || preset == nil
        let hadInvalidFields = !invalidFields.isEmpty
        duration.isEnabled = template.enabled && template.animation != .none
        if !duration.isEnabled {
            invalidFields.remove(ObjectIdentifier(duration)); duration.textColor = .labelColor
        }
        if !isEditing(duration) && !invalidFields.contains(ObjectIdentifier(duration)) { duration.stringValue = String(format: "%.2f", template.duration) }
        for (index, key) in regions.enumerated() {
            let region = index == 2 ? layoutTemplate.effectiveBodyRegion : template[keyPath: key]
            let values = [region.x, region.y, region.width, region.height]
            let active = template.enabled && (index != 0 || template.showsArtwork) && (index != 1 || layoutTemplate.showsTitle) && (index != 3 || layoutTemplate.showsFooter)
            for (component, field) in regionFields[index].enumerated() {
                let automatic = index == 2 && layoutTemplate.bodyExpandsAutomatically && (component == 1 || component == 3)
                field.isEnabled = active && !automatic
                if !field.isEnabled {
                    invalidFields.remove(ObjectIdentifier(field)); field.textColor = .labelColor
                }
                if !isEditing(field) && !invalidFields.contains(ObjectIdentifier(field)) {
                    field.stringValue = String(format: "%g", values[component])
                }
                if index == 2 && (component == 1 || component == 3) {
                    field.toolTip = automatic
                        ? "Calculated from the space freed by hidden title/footer rows. Enable both rows to edit the base body position and height."
                        : "Body \(component == 1 ? "y" : "height"), as a percentage of the full canvas."
                }
            }
        }
        if hadInvalidFields && invalidFields.isEmpty { validationMessage = "" }
        bodyLayoutHint.stringValue = preset != nil && !template.customized
            ? "The text template controls alignment and visible rows. Choose Custom layout to change these."
            : !template.enabled
            ? "Show or hide Title and Footer. Body uses the available space; set its position in Canvas."
            : layoutTemplate.bodyExpandsAutomatically
            ? "Body fills the hidden rows. Its Y and height are automatic; enable Title and Footer to edit the base values."
            : "These are the saved boxes. Body also uses empty Title/Footer space unless the sender keeps it reserved; guides show the preview’s actual boxes."
        refreshPreview()
        refreshActions()
        if publishing {
            func disable(_ view: NSView) {
                if let control = view as? NSControl { control.isEnabled = false }
                view.subviews.forEach(disable)
            }
            disable(editorRoot)
            draftStatus.stringValue = "Publishing this design… Cancel from Text to keep editing."
        }
        onDraftChange?()
    }
    private var previewContent: DisplayContent {
        let samples = [
            DisplayContent(title: "GUEST SPEAKER", body: "Jordan Lee", footer: "Community coordinator"),
            DisplayContent(title: "WELCOME", body: "A place to belong", footer: "Sundays · 10 am"),
            DisplayContent(title: "COMING UP", body: "Join us after the service for morning tea and a chance to meet the community.", footer: "Everyone is welcome · Main hall"),
            DisplayContent(title: DisplayContent.scripture.title, body: DisplayContent.scripture.body,
                           footer: DisplayContent.scripture.footer, template: .scripture),
            DisplayContent(title: DisplayContent.lyrics.title, body: DisplayContent.lyrics.body,
                           footer: DisplayContent.lyrics.footer, template: .lyrics)
        ]
        let selection = samplePicker.titleOfSelectedItem
        if !usesRealContent { return samples[min(samples.count - 1, max(0, samplePicker.indexOfSelectedItem))] }
        switch selection {
        case "Text draft": return draftContent
        case "Current source": return sourceContent
        case "Sample · Announcement": return samples[1]
        case "Sample · Long message": return samples[2]
        case "Sample · Scripture": return samples[3]
        case "Sample · Lyrics": return samples[4]
        default: return samples[0]
        }
    }
    private func refreshPreview() {
        let selection = samplePicker.titleOfSelectedItem
        sourceHint.stringValue = sourceName.map {
            "Source: \($0). Edit its text in that app." + (customTextEnabled ? " Text has its own separate draft." : "")
        } ?? (selection == "Text draft" ? "Previewing your Text draft. Edit in Text, then publish when ready."
            : "Use sample text to preview your design. Live text comes from your sending app.")
        sourceHint.toolTip = sourceHint.stringValue
        var sample = previewContent
        let previewTemplate = template
        sample.visible = (!previewTemplate.requiresCustomArtwork || artwork != nil) && [sample.title, sample.body, sample.footer].contains { !$0.isEmpty }
        previewHeading.stringValue = usesRealContent && (selection == "Text draft" || selection == "Current source")
            ? "Design preview · not live" : "Sample preview · not live"
        if library != nil { previewHeading.stringValue = "\(editingProfile.rawValue) preview · not live" }
        presentation.update(content: sample, style: style, template: previewTemplate, artwork: artwork, immediately: true)
        guides.template = template.resolved(for: sample)
        guides.isHidden = showGuides.state != .on || !previewTemplate.enabled
        replayButton.isEnabled = sample.visible && previewTemplate.enabled && template.animation != .none && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        replayButton.toolTip = replayButton.isEnabled ? "Replay this preview without changing output." : "Choose Slide or Reveal and turn off macOS Reduce Motion to preview animation."
        let textSize = previewTemplate.enabled
            ? CanvasTextLayout.lowerThird(content: sample, style: style, template: template).bodyFontSize
            : CanvasTextLayout.make(content: sample, style: style, template: template).bodyFontSize
        if !validationMessage.isEmpty { feedback.stringValue = validationMessage; feedback.textColor = .systemOrange }
        else if let warning = outputArtworkWarning { feedback.stringValue = warning; feedback.textColor = .systemOrange }
        else if sample.visible && textSize < 28 {
            let adjustment = template.enabled ? "Enlarge the Body box" : "Increase Maximum content height in Canvas"
            feedback.stringValue = "Body text shrinks to \(Int(textSize)) pt. \(adjustment) or use shorter content for better readability."
            feedback.textColor = .systemOrange
        } else if !previewTemplate.enabled || !template.showsArtwork {
            feedback.stringValue = "Text appears directly on the selected key colour."
            feedback.textColor = .secondaryLabelColor
        } else if style.background.uppercased() == "000000" {
            feedback.stringValue = "Black luma key can remove dark parts of this artwork. For coloured graphics, choose green or blue chroma key in Design."
            feedback.textColor = .secondaryLabelColor
        } else {
            feedback.stringValue = "Transparent PNG pixels show the receiver’s key colour. Fit to Canvas suits a full-frame PNG; Fit to Banner suits a cropped strip."
            feedback.textColor = .secondaryLabelColor
        }
    }
    private var hasUnfinishedEdit: Bool {
        ([duration] + regionFields.flatMap { $0 }).contains { field in
            guard let editor = field.currentEditor() else { return false }
            return editor.string != formattedValue(for: field)
        }
    }
    private func refreshActions() {
        let dirty = hasChanges || hasUnfinishedEdit || !invalidFields.isEmpty
        applyButton.isEnabled = dirty && canCommitDraft && artworkIsAvailable(for: outputContent)
        revertButton.isEnabled = dirty || importing
        draftBadge.update(publishing ? "PUBLISHING" : importing ? "IMPORTING" : dirty ? "UNAPPLIED CHANGES" : "APPLIED",
                          color: dirty || importing || publishing ? .systemOrange : .secondaryLabelColor)
        draftStatus.stringValue = importing ? "Preparing artwork…" : dirty ? "This Mac’s output is unchanged" : "Design saved on this Mac"
    }
    private func isEditing(_ field: NSTextField) -> Bool { field.currentEditor() != nil }
    private func commit(_ next: LowerThirdTemplate) { template = next.clamped(); refresh() }
    @objc private func controlsChanged() {
        guard !publishing else { return }
        // Ending a field edit refreshes controls. Capture the new choice first.
        let useLowerThird = enabled.state == .on
        let artworkVisible = showArtwork.state == .on
        let titleVisible = showTitle.state == .on
        let footerVisible = showFooter.state == .on
        let artworkChoice = LowerThirdArtwork(rawValue: artworkPicker.titleOfSelectedItem ?? "") ?? .builtIn
        let motionChoice = LowerThirdAnimation(rawValue: animationPicker.titleOfSelectedItem ?? "") ?? .slide
        let alignmentChoice = CanvasAlignment(rawValue: alignmentPicker.titleOfSelectedItem ?? "") ?? .left
        let usesCustomLayout = template.customized || template.selectedContentTemplate(for: previewContent) == nil
        hostWindow?.makeFirstResponder(nil)
        var next = template
        next.enabled = useLowerThird; next.artwork = artworkChoice
        next.showsArtwork = artworkVisible
        if usesCustomLayout {
            next.showsTitle = titleVisible; next.showsFooter = footerVisible
            next.alignment = alignmentChoice
        }
        // A hidden area's disabled fields must not keep Apply blocked.
        for (index, visible) in [(0, artworkVisible), (1, titleVisible), (3, footerVisible)] where !visible {
            for field in regionFields[index] {
                invalidFields.remove(ObjectIdentifier(field)); field.textColor = .labelColor
                field.stringValue = formattedValue(for: field)
            }
        }
        if invalidFields.isEmpty { validationMessage = "" }
        next.animation = motionChoice
        if motionChoice == .none {
            // An unused duration must not leave Apply blocked by a disabled field.
            invalidFields.remove(ObjectIdentifier(duration)); duration.textColor = .labelColor
            duration.stringValue = String(format: "%.2f", next.duration)
            if invalidFields.isEmpty { validationMessage = "" }
        }
        commit(next)
    }
    @objc private func textTemplateChanged() {
        guard !publishing else { return }
        let selection = TextTemplateSelection(rawValue: textTemplatePicker.titleOfSelectedItem ?? "") ?? .sender
        hostWindow?.makeFirstResponder(nil)
        if var library = draftLibrary {
            library.selection = selection; self.library = library
            refresh(); return
        }
        var next = template; next.textTemplate = selection
        commit(next)
    }
    @objc private func profileChanged() {
        let id = DesignProfileID(rawValue: profilePicker.titleOfSelectedItem ?? "") ?? .custom
        selectProfile(id)
    }
    func selectProfile(_ id: DesignProfileID) {
        guard library != nil, !publishing, !importing, !loading else { return }
        hostWindow?.makeFirstResponder(nil)
        guard invalidFields.isEmpty else { refresh(); return }
        library = draftLibrary
        if let pendingArtwork { draftAssets[pendingArtwork.id] = pendingArtwork }
        editingProfile = id
        let design = library!.design(id), applied = appliedLibrary!.design(id)
        template = design.template; style = design.style
        appliedTemplate = applied.template; appliedStyle = applied.style
        appliedArtwork = applied.template.assetID.flatMap { appliedAssets[$0] }
        pendingArtwork = template.assetID.flatMap { draftAssets[$0] }
        artworkMessage = ""; validationMessage = ""
        let sampleName = id == .lyrics ? "Lyrics" : id == .scripture ? "Scripture" : "Speaker"
        samplePicker.selectItem(withTitle: usesRealContent ? "Sample · \(sampleName)" : sampleName)
        customBackgroundSelected = !["000000", "00FF00", "0000FF"].contains(style.background)
        refresh()
    }
    @objc private func lyricLayoutChanged() {
        guard !publishing else { return }
        let layout = LyricLineLayout(rawValue: lineLayoutPicker.titleOfSelectedItem ?? "") ?? .preserve
        let joiner = LyricJoiner(rawValue: joinerPicker.titleOfSelectedItem ?? "") ?? .space
        hostWindow?.makeFirstResponder(nil)
        var next = template; next.lyricLineLayout = layout; next.lyricJoiner = joiner
        commit(next)
    }
    @objc private func previewChanged() { refresh() }
    @objc private func editText() {
        guard customTextEnabled else { return }
        hostWindow?.makeFirstResponder(nil)
        onEditText?()
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        guides.selectedRegion = regionFields.firstIndex { $0.contains { $0 === field } }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if number(in: field) != nil {
            invalidFields.remove(ObjectIdentifier(field)); field.textColor = .labelColor
            if invalidFields.isEmpty { validationMessage = ""; refreshPreview() }
        }
        refreshActions(); onDraftChange?()
    }
    private func number(in field: NSTextField) -> Double? {
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let value = Double(string), value.isFinite else { return nil }
        return value
    }
    private func formattedValue(for field: NSTextField) -> String {
        if field === duration { return String(format: "%.2f", template.duration) }
        for (index, fields) in regionFields.enumerated() {
            if let component = fields.firstIndex(where: { $0 === field }) {
                let r = index == 2 ? template.applyingContentTemplate(for: previewContent).effectiveBodyRegion : template[keyPath: regions[index]]
                return String(format: "%g", [r.x, r.y, r.width, r.height][component])
            }
        }
        return field.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        guard let value = number(in: field) else {
            invalidFields.insert(ObjectIdentifier(field)); field.textColor = .systemRed
            validationMessage = "Enter a number for \(field.accessibilityLabel() ?? "this value"), or Revert Changes."
            refreshPreview(); refreshActions(); return
        }
        invalidFields.remove(ObjectIdentifier(field)); field.textColor = .labelColor
        var next = template
        if field === duration { next.duration = value }
        else {
            for (index, fields) in regionFields.enumerated() {
                guard let component = fields.firstIndex(where: { $0 === field }) else { continue }
                var region = next[keyPath: regions[index]]
                switch component { case 0: region.x = value; case 1: region.y = value; case 2: region.width = value; default: region.height = value }
                next[keyPath: regions[index]] = region
            }
        }
        let clamped = next.clamped()
        if invalidFields.isEmpty {
            validationMessage = next == clamped ? "" : field === duration ? "Duration adjusted to the supported range: 0.1–2 seconds." : "Position or size adjusted to keep the entire box inside the canvas (minimum size: 1%)."
        }
        template = clamped
        field.stringValue = formattedValue(for: field)
        refresh()
    }

    @objc private func choosePNG() {
        hostWindow?.makeFirstResponder(nil)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Choose PNG artwork to preview. Apply Design to Output when ready. AltView saves its own copy."
        panel.beginSheetModal(for: hostWindow!) { [weak self] response in
            if response == .OK, let url = panel.url { self?.importArtwork(from: url) }
        }
    }
    func importArtwork(from url: URL) {
        guard !importing && !loading && !publishing else { return }
        importing = true
        let revision = UUID(); importRevision = revision
        refresh()
        let store = artworkStore
        store.importPNG(from: url) { [weak self] result in
            guard let self, self.importRevision == revision else {
                if case .success(let asset) = result { store.discard(id: asset.id) }
                return
            }
            self.importing = false
            switch result {
            case .success(let asset):
                if let previous = self.pendingArtwork {
                    self.draftAssets.removeValue(forKey: previous.id)
                    store.discard(id: previous.id)
                }
                self.pendingArtwork = asset
                if self.library != nil { self.draftAssets[asset.id] = asset }
                self.template.assetID = asset.id; self.template.assetName = asset.name; self.template.artwork = .custom
                self.artworkMessage = "PNG ready to preview. Apply Design to Output to use this design. The original file can be moved or removed."
            case .failure(let error): self.artworkMessage = "Import failed: \(error.localizedDescription)"
            }
            self.refresh()
        }
    }
    @objc func applyChanges() {
        applyDraft(for: outputContent)
    }
    func applyDraft(for content: DisplayContent) {
        hostWindow?.makeFirstResponder(nil)
        guard canPublish(content: content), hasChanges else { return }
        if let draft = draftLibrary {
            let assets = allDraftArtworks.filter { draft.assetIDs.contains($0.key) }
            library = draft; appliedLibrary = draft; appliedAssets = assets
            draftAssets.removeAll(); pendingArtwork = nil
            appliedTemplate = template; appliedStyle = style
            appliedArtwork = template.assetID.flatMap { assets[$0] }
            artworkMessage = ""
            onApplyLibrary?(draft, assets)
            refresh(); return
        }
        appliedTemplate = template; appliedArtwork = artwork; pendingArtwork = nil
        appliedStyle = style
        artworkMessage = ""
        onApplyStyle?(style)
        onApply?(template, appliedArtwork)
        refresh()
    }
    @objc func revertChanges() {
        guard !publishing else { return }
        hostWindow?.makeFirstResponder(nil)
        importRevision = UUID(); importing = false
        if let appliedLibrary {
            var unused = Set(draftAssets.keys)
            if let pendingArtwork { unused.insert(pendingArtwork.id) }
            for id in unused.subtracting(appliedLibrary.assetIDs) { artworkStore.discard(id: id) }
            draftAssets.removeAll(); library = appliedLibrary
            let design = appliedLibrary.design(editingProfile)
            appliedTemplate = design.template; appliedStyle = design.style
            appliedArtwork = design.template.assetID.flatMap { appliedAssets[$0] }
        } else if let pendingArtwork { artworkStore.discard(id: pendingArtwork.id) }
        pendingArtwork = nil; template = appliedTemplate; style = appliedStyle
        customBackgroundSelected = !["000000", "00FF00", "0000FF"].contains(style.background)
        invalidFields.removeAll(); validationMessage = ""; artworkMessage = ""
        for field in [duration] + regionFields.flatMap({ $0 }) { field.textColor = .labelColor }
        refresh()
    }
    @objc private func bannerArea() {
        hostWindow?.makeFirstResponder(nil)
        var next = template; next.artworkRegion = LowerThirdTemplate().artworkRegion; commit(next)
    }
    @objc private func fullCanvas() {
        hostWindow?.makeFirstResponder(nil)
        var next = template; next.artworkRegion = TemplateRegion(x: 0, y: 0, width: 100, height: 100); commit(next)
    }
    @objc private func resetLayout() {
        hostWindow?.makeFirstResponder(nil)
        var next = template
        for key in regions { next[keyPath: key] = LowerThirdTemplate()[keyPath: key] }
        for field in regionFields.flatMap({ $0 }) { invalidFields.remove(ObjectIdentifier(field)); field.textColor = .labelColor }
        if invalidFields.isEmpty { validationMessage = "" }
        commit(next)
    }
    @objc private func replay() { hostWindow?.makeFirstResponder(nil); presentation.replay() }
    var needsCloseConfirmation: Bool { hasChanges || !invalidFields.isEmpty || importing || publishing || hasUnfinishedEdit }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finishEditing()
        guard needsCloseConfirmation else { return true }
        confirmClose(sender) { if $0 { sender.close() } }
        return false
    }
    func confirmClose(_ sender: NSWindow, completion: @escaping (Bool) -> Void) {
        finishEditing()
        let alert = NSAlert()
        alert.messageText = publishing ? "Text and design are being published" : "Apply design changes?"
        alert.informativeText = publishing ? "Keep this window open until publishing finishes, or cancel publishing from Text."
            : "Design changes have only appeared in draft previews. Apply updates this Mac’s current output source."
                + (customTextEnabled ? " Your text draft stays saved." : "")
        alert.addButton(withTitle: "Keep Editing")
        if !publishing {
            alert.addButton(withTitle: "Discard Design Changes")
            alert.addButton(withTitle: "Apply Design to Output").isEnabled = applyButton.isEnabled
        }
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { completion(false); return }
            if response == .alertSecondButtonReturn { self.revertChanges(); completion(true) }
            else if response == .alertThirdButtonReturn { self.applyChanges(); completion(true) }
            else { completion(false) }
        }
    }
    func windowWillClose(_ notification: Notification) { presentation.stopAnimation() }
    func shutdown() { publishing = false; onDraftChange = nil; revertChanges(); presentation.stopAnimation(); close() }
}

/// Label placement is shared across all four guides so nearby or overlapping
/// boxes cannot hide one another's names. Coordinates are in preview points.
struct LowerThirdGuideLayout {
    let index: Int
    let rect: NSRect
    let anchor: NSPoint
    let label: NSAttributedString
    var badge: NSRect

    static func make(template: LowerThirdTemplate, in bounds: NSRect) -> [Self] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let template = template.clamped()
        let scale = min(bounds.width / 1920, bounds.height / 1080)
        let origin = NSPoint(x: bounds.midX - 1920 * scale / 2, y: bounds.midY - 1080 * scale / 2)
        let regions = [template.artworkRegion, template.titleRegion, template.effectiveBodyRegion, template.footerRegion]
        let names = ["Artwork", "Title", "Body", "Footer"]
        let labels = names.map { NSAttributedString(string: $0, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white
        ]) }
        let height = ceil(labels.map { $0.size().height }.max() ?? 12) + 4
        let margin: CGFloat = 2, gap: CGFloat = 3
        var guides = regions.enumerated().compactMap { index, region -> Self? in
            guard (index != 0 || template.showsArtwork) && (index != 1 || template.showsTitle) && (index != 3 || template.showsFooter) else { return nil }
            let r = region.rect
            let rect = NSRect(x: origin.x + r.minX * scale, y: origin.y + r.minY * scale,
                              width: r.width * scale, height: r.height * scale)
            let label = labels[index]
            let width = ceil(label.size().width) + 8
            let fitsBeside = rect.minX - bounds.minX >= width + 6
            let anchor = NSPoint(x: rect.minX, y: fitsBeside ? rect.midY : rect.minY)
            let x = fitsBeside ? rect.minX - width - 4 : rect.minX
            let y = fitsBeside ? anchor.y - height / 2 : anchor.y - height - 4
            return Self(index: index, rect: rect, anchor: anchor, label: label,
                        badge: NSRect(x: max(bounds.minX + margin, min(x, bounds.maxX - width - margin)),
                                      y: y, width: width, height: height))
        }
        guides.sort { $0.badge.minY == $1.badge.minY ? $0.index < $1.index : $0.badge.minY < $1.badge.minY }

        // Pack overlapping labels as a group, sharing the displacement above
        // and below their preferred positions instead of pushing all names down.
        let separation = height + gap
        var groups: [(indices: [Int], sum: CGFloat)] = []
        for index in guides.indices {
            groups.append(([index], guides[index].badge.minY - CGFloat(index) * separation))
            while groups.count > 1 {
                let last = groups[groups.count - 1], previous = groups[groups.count - 2]
                guard previous.sum / CGFloat(previous.indices.count) > last.sum / CGFloat(last.indices.count) else { break }
                groups.removeLast(2)
                groups.append((previous.indices + last.indices, previous.sum + last.sum))
            }
        }
        let maximumOrigin = bounds.maxY - margin - height - CGFloat(guides.count - 1) * separation
        for group in groups {
            let origin = max(bounds.minY + margin, min(group.sum / CGFloat(group.indices.count), maximumOrigin))
            for index in group.indices { guides[index].badge.origin.y = origin + CGFloat(index) * separation }
        }
        return guides
    }
}

/// An editor-only overlay, deliberately separate from the HDMI renderer.
private final class LowerThirdGuidesView: NSView {
    var template = LowerThirdTemplate() { didSet { needsDisplay = true } }
    var selectedRegion: Int? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let guides = LowerThirdGuideLayout.make(template: template, in: bounds)
        for guide in guides {
            let path = NSBezierPath(rect: guide.rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor.black.withAlphaComponent(0.85).setStroke(); path.lineWidth = 3; path.stroke()
            NSColor.white.setStroke(); path.lineWidth = selectedRegion == guide.index ? 2 : 1
            if selectedRegion != guide.index { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()
        }
        for guide in guides {
            // A short leader retains the association when a label has to move.
            let start = NSPoint(x: max(guide.badge.minX, min(guide.anchor.x, guide.badge.maxX)),
                                y: max(guide.badge.minY, min(guide.anchor.y, guide.badge.maxY)))
            let line = NSBezierPath(); line.move(to: start); line.line(to: guide.anchor)
            NSColor.black.setStroke(); line.lineWidth = 3; line.stroke()
            NSColor.white.setStroke(); line.lineWidth = 1; line.stroke()
        }
        // Draw every badge last so another region's outline or leader can never
        // paint through its text. The opaque background keeps names legible.
        for guide in guides {
            NSColor.black.setFill(); NSBezierPath(roundedRect: guide.badge, xRadius: 2, yRadius: 2).fill()
            guide.label.draw(at: NSPoint(x: guide.badge.minX + 4, y: guide.badge.minY + 2))
        }
    }
}
