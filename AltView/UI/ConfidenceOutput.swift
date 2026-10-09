import AppKit

struct ConfidenceOptions: Codable, Equatable {
    var fontName = "System"
    var fontSize: Double = 100
    var alignment = CanvasAlignment.left
    var twentyFourHourClock = true
    init() {}
    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, alignment, twentyFourHourClock
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        alignment = try values.decodeIfPresent(CanvasAlignment.self, forKey: .alignment) ?? alignment
        twentyFourHourClock = try values.decodeIfPresent(Bool.self, forKey: .twentyFourHourClock) ?? twentyFourHourClock
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(fontName, forKey: .fontName); try values.encode(fontSize, forKey: .fontSize)
        try values.encode(alignment, forKey: .alignment); try values.encode(twentyFourHourClock, forKey: .twentyFourHourClock)
    }
    func clamped() -> Self {
        var result = self
        result.fontSize = fontSize.isFinite ? min(160, max(32, fontSize)) : 100
        return result
    }
    var style: OutputStyle {
        var value = OutputStyle()
        value.fontName = fontName; value.fontSize = fontSize; value.alignment = alignment; value.lineSpacing = 0.08
        return value
    }
}

struct ConfidenceLayout {
    static let clockBand = NSRect(x: 0, y: 0, width: 1920, height: 188)
    static let contentArea = NSRect(x: 48, y: 216, width: 1824, height: 816)
    let main: NSRect
    let title: NSRect
    let body: NSRect
    let footer: NSRect
    let secondaryBody: NSRect?
    let secondaryFooter: NSRect?
    let divider: NSRect?
    let bodySize: CGFloat
    static func make(text: ConfidenceText, options: ConfidenceOptions) -> Self {
        let main = contentArea
        let secondary = text.secondary.flatMap { $0.hasText ? $0 : nil }
        let titleHeight: CGFloat = text.title.isEmpty ? 0 : 72
        let footerHeight: CGFloat = text.footer.isEmpty && (secondary?.footer.isEmpty ?? true) ? 0 : 54
        let gap: CGFloat = secondary == nil ? 0 : 64
        let width = secondary == nil ? main.width : (main.width - gap) / 2
        let bodyBox = NSRect(x: main.minX, y: main.minY + titleHeight, width: width, height: main.height - titleHeight - footerHeight)
        let style = options.style
        func height(_ size: CGFloat) -> CGFloat {
            let primary = CanvasTextLayout.measure(text.body, size: size, width: bodyBox.width, style: style)
            return max(primary, secondary.map { CanvasTextLayout.measure($0.body, size: size, width: bodyBox.width, style: style) } ?? 0)
        }
        var size = CGFloat(options.fontSize)
        if height(size) > bodyBox.height {
            var low: CGFloat = 0.000001, high = size
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if height(mid) <= bodyBox.height { low = mid } else { high = mid }
            }
            size = low
        }
        let bodyHeight = min(bodyBox.height, height(size))
        let body = NSRect(x: bodyBox.minX, y: bodyBox.midY - bodyHeight / 2, width: bodyBox.width, height: bodyHeight)
        let footer = NSRect(x: main.minX, y: main.maxY - footerHeight, width: width, height: footerHeight)
        // Fit both columns at one size and align their first lines, so either
        // translation can be longer without clipping or an uneven text scale.
        let secondaryBody = secondary.map { _ in NSRect(x: body.maxX + gap, y: body.minY, width: width, height: body.height) }
        let secondaryFooter = secondary.map { _ in NSRect(x: footer.maxX + gap, y: footer.minY, width: width, height: footer.height) }
        let divider = secondary.map { _ in NSRect(x: main.midX - 1, y: bodyBox.minY, width: 2, height: main.maxY - bodyBox.minY) }
        return Self(main: main,
                    title: NSRect(x: main.minX, y: main.minY, width: main.width, height: titleHeight), body: body,
                    footer: footer, secondaryBody: secondaryBody, secondaryFooter: secondaryFooter, divider: divider, bodySize: size)
    }
}

/// Receiver snapshots and local operator settings; no audience artwork or visibility dependency.
@MainActor
final class ConfidencePresentation {
    let media: ConfidenceMediaController
    private(set) var text = ConfidenceText.empty
    private(set) var options = ConfidenceOptions()
    private(set) var visible = true
    private var observers: [UUID: () -> Void] = [:]
    private var cachedLayout: ConfidenceLayout?
    init(defaults: UserDefaults? = nil, media: ConfidenceMediaController? = nil) {
        self.media = media ?? ConfidenceMediaController(defaults: defaults)
    }
    var layout: ConfidenceLayout {
        if let cachedLayout { return cachedLayout }
        let value = ConfidenceLayout.make(text: text, options: options)
        cachedLayout = value
        return value
    }
    func update(_ status: ReceiverStatus) {
        let wasMedia = media.isMedia
        media.update(status.confidenceMedia)
        guard text != status.confidenceContent || wasMedia != media.isMedia else { return }
        text = status.confidenceContent; changed()
    }
    func configure(_ options: ConfidenceOptions) {
        let value = options.clamped()
        guard value != self.options else { return }
        self.options = value; changed()
    }
    func setVisible(_ visible: Bool) { guard self.visible != visible else { return }; self.visible = visible; changed() }
    private func changed() { cachedLayout = nil; for observer in observers.values { observer() } }
    func observe(_ change: @escaping () -> Void) -> UUID { let id = UUID(); observers[id] = change; return id }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}

@MainActor
final class ConfidenceCanvas: NSView {
    let presentation: ConfidencePresentation
    private var observation: UUID?
    private var timer: Timer?
    private let clock = DateFormatter()
    private var displayedClock: String?
    private var cachedContent: NSImage?
    private let mediaView = ConfidenceMediaView(frame: .zero)
    init(presentation: ConfidencePresentation) {
        self.presentation = presentation
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(mediaView)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        observation = presentation.observe { [weak self] in
            self?.cachedContent = nil; self?.displayedClock = nil
            self?.needsDisplay = true; self?.layoutMedia()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        if window != nil { presentation.media.attach(mediaView) } else { presentation.media.detach(mediaView) }
        if window != nil {
            let clockTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window?.isVisible == true, self.window?.isMiniaturized == false,
                          self.window?.occlusionState.contains(.visible) == true,
                          self.presentation.visible, !self.isHiddenOrHasHiddenAncestor else { return }
                    self.refreshClock(at: Date())
                }
            }
            clockTimer.tolerance = 0.1; timer = clockTimer
            RunLoop.main.add(clockTimer, forMode: .common)
        }
    }
    /// The clock shows minutes. Keep its liveness check cheap and invalidate
    /// only its strip when the formatted value changes, including time jumps.
    @discardableResult
    func refreshClock(at date: Date) -> Bool {
        let value = clockText(at: date)
        guard value != displayedClock else { return false }
        displayedClock = value
        let scale = min(bounds.width / 1920, bounds.height / 1080)
        setNeedsDisplay(NSRect(x: (bounds.width - 1920 * scale) / 2,
                              y: (bounds.height - 1080 * scale) / 2,
                              width: 1920 * scale, height: ConfidenceLayout.clockBand.height * scale))
        return true
    }
    private func clockText(at date: Date) -> String {
        let locale = Locale.autoupdatingCurrent, timeZone = TimeZone.autoupdatingCurrent
        if clock.locale != locale { clock.locale = locale }
        if clock.timeZone != timeZone { clock.timeZone = timeZone }
        let format = presentation.options.twentyFourHourClock ? "HH:mm" : "h:mm a"
        if clock.dateFormat != format { clock.dateFormat = format }
        return clock.string(from: date)
    }
    override func accessibilityLabel() -> String? {
        guard presentation.visible else { return "Confidence hidden" }
        if presentation.media.isMedia { return "Eucaly projection picture and local clock" }
        var text = [presentation.text.title, presentation.text.body, presentation.text.footer]
        if let secondary = presentation.text.secondary, secondary.hasText { text += [secondary.body, secondary.footer] }
        return text.joined(separator: "\n")
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard presentation.visible else { return }
        let scale = min(bounds.width / 1920, bounds.height / 1080)
        guard scale > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: (bounds.width - 1920 * scale) / 2, yBy: (bounds.height - 1080 * scale) / 2)
        transform.scale(by: scale); transform.concat()
        NSRect(x: 0, y: 0, width: 1920, height: 1080).clip()
        // The once-per-second clock never refits the presented text.
        if !presentation.media.isMedia, cachedContent == nil {
            let image = NSImage(size: NSSize(width: 1920, height: 1080))
            image.lockFocusFlipped(true)
            NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 1920, height: 1080).fill()
            drawContent()
            image.unlockFocus()
            cachedContent = image
        }
        if !presentation.media.isMedia {
            cachedContent?.draw(in: NSRect(x: 0, y: 0, width: 1920, height: 1080), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let clockValue = clockText(at: Date()); displayedClock = clockValue
        drawClock(clockValue)
    }
    override func layout() { super.layout(); layoutMedia() }
    private func layoutMedia() {
        let scale = min(bounds.width / 1920, bounds.height / 1080)
        let area = ConfidenceLayout.contentArea
        mediaView.frame = NSRect(x: (bounds.width - 1920 * scale) / 2 + area.minX * scale,
                                y: (bounds.height - 1080 * scale) / 2 + area.minY * scale,
                                width: area.width * scale, height: area.height * scale)
        mediaView.isHidden = !presentation.visible || !presentation.media.isMedia
        if mediaView.isHidden { mediaView.display(nil) }
    }
    private func drawClock(_ value: String) {
        let band = ConfidenceLayout.clockBand
        let amber = NSColor(srgbRed: 1, green: 0.76, blue: 0.25, alpha: 1)
        NSColor(white: 0.08, alpha: 1).setFill(); band.fill()
        amber.withAlphaComponent(0.5).setFill()
        NSRect(x: band.minX, y: band.maxY - 4, width: band.width, height: 4).fill()

        func centered(_ text: String, font: NSFont, color: NSColor, in rect: NSRect, tracking: CGFloat = 0) {
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: tracking])
            let size = string.size()
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            rect.clip()
            string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
        centered("CURRENT TIME", font: .systemFont(ofSize: 20, weight: .semibold), color: amber.withAlphaComponent(0.8),
                 in: NSRect(x: 48, y: 12, width: 1824, height: 26), tracking: 3)
        // Keep the clock bold and stable regardless of the chosen lyric font.
        centered(value, font: .monospacedDigitSystemFont(ofSize: 128, weight: .bold), color: amber,
                 in: NSRect(x: 48, y: 34, width: 1824, height: 150))
    }
    private func drawContent() {
        guard !presentation.media.isMedia else { return }
        let options = presentation.options, layout = presentation.layout
        draw(presentation.text.title, in: layout.title, size: 44, alignment: options.alignment)
        draw(presentation.text.body, in: layout.body, size: layout.bodySize, alignment: options.alignment)
        draw(presentation.text.footer, in: layout.footer, size: 32, alignment: options.alignment)
        if let secondary = presentation.text.secondary, let body = layout.secondaryBody, let footer = layout.secondaryFooter {
            draw(secondary.body, in: body, size: layout.bodySize, alignment: options.alignment)
            draw(secondary.footer, in: footer, size: 32, alignment: options.alignment)
        }
        if let divider = layout.divider { NSColor(white: 0.25, alpha: 1).setFill(); divider.fill() }
    }
    private func draw(_ text: String, in rect: NSRect, size: CGFloat, alignment: CanvasAlignment = .left) {
        guard !text.isEmpty, rect.height > 0 else { return }
        var style = presentation.options.style; style.alignment = alignment
        var fitted = size
        if CanvasTextLayout.measure(text, size: size, width: rect.width, style: style) > rect.height {
            var low: CGFloat = 0.000001, high = size
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if CanvasTextLayout.measure(text, size: mid, width: rect.width, style: style) <= rect.height { low = mid } else { high = mid }
            }
            fitted = low
        }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        rect.clip()
        NSAttributedString(string: text, attributes: style.attributes(size: fitted)).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
    deinit {
        timer?.invalidate()
        let presentation = presentation, mediaView = mediaView, observation = observation
        Task { @MainActor in
            presentation.media.detach(mediaView)
            if let observation { presentation.removeObserver(observation) }
        }
    }
}

/// This view belongs only to the workspace stage, never to an output canvas.
@MainActor
final class ConfidencePreviewNotice: NSView {
    private let heading = UI.label("", size: 15, color: .white, bold: true)
    private let detail = UI.label("", size: 12, color: NSColor(white: 0.7, alpha: 1))
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("confidencePreviewNotice")
        heading.alignment = .center; detail.alignment = .center
        let text = UI.column(heading, detail, spacing: 8)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        let preferredWidth = text.widthAnchor.constraint(equalTo: widthAnchor, constant: -48)
        preferredWidth.priority = .defaultLow
        // The stage assigns the overlay's frame after initial window layout.
        // Let these margins yield while that frame is temporarily zero.
        let leadingMargin = text.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24)
        let trailingMargin = text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        leadingMargin.priority = .defaultHigh; trailingMargin.priority = .defaultHigh
        NSLayoutConstraint.activate([
            text.centerXAnchor.constraint(equalTo: centerXAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            leadingMargin, trailingMargin,
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 380), preferredWidth
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(title: String, detail: String) {
        heading.stringValue = title; self.detail.stringValue = detail; isHidden = false
    }
}

enum ScreenRecordingSettings {
    static func open() -> Bool {
        let pane: String
        if #available(macOS 13, *) { pane = "com.apple.settings.PrivacySecurity.extension" }
        else { pane = "com.apple.preference.security" }
        let links = ["x-apple.systempreferences:\(pane)?Privacy_ScreenCapture",
                     "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]
        for link in links {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return true }
        }
        return false
    }
}

@MainActor
final class ConfidenceViewController: NSViewController {
    let presentation: ConfidencePresentation
    private let defaults: UserDefaults
    private let monitorAssignments: DisplayAssignments
    private let openScreenRecordingSettings: () -> Bool
    private var settingsOpenFailed = false
    private var previewActive = false
    private var receiverStatus = ReceiverStatus()
    private var options = ConfidenceOptions()
    lazy var output = OutputWindowController(name: "Confidence", makeCanvas: { [presentation] in ConfidenceCanvas(presentation: presentation) },
                                           displays: { [monitorAssignments] in monitorAssignments.currentDisplays() })
    private lazy var monitorControls: MonitorControls = {
        let controls = MonitorControls(role: .confidence, assignments: monitorAssignments, output: output)
        controls.onOpen = { [weak self] in
            self?.presentation.setVisible(true)
            self?.visibilityButton.title = "Hide Confidence"
            self?.refreshCaptureDemand()
            self?.refreshPreviewNotice()
        }
        return controls
    }()
    var onActivityChange: (() -> Void)?
    private let fontPicker = NSPopUpButton()
    private let alignmentPicker = NSPopUpButton()
    private let size = NSSlider(value: 100, minValue: 32, maxValue: 160, target: nil, action: nil)
    private let fontLabel = UI.label("100 pt", size: 11)
    private let clockSwitch = NSButton(checkboxWithTitle: "24-hour clock", target: nil, action: nil)
    private let mediaStatusLabel = UI.label("", size: 11, color: .secondaryLabelColor)
    private let mediaStateLabel = UI.label("", size: 12, bold: true)
    private let mediaEnabledLabel = UI.label("Off", size: 11, color: .secondaryLabelColor)
    private let mediaSwitch = NSSwitch()
    private lazy var mediaActionButton = UI.button("Retry Capture", target: self, action: #selector(mediaAction))
    private let previewNotice = ConfidencePreviewNotice(frame: .zero)
    private let sourceLabel = UI.label("No active text", size: 12)
    private lazy var visibilityButton = UI.button("Hide Confidence", target: self, action: #selector(toggleVisibility))
    init(defaults: UserDefaults, assignments: DisplayAssignments? = nil, media: ConfidenceMediaController? = nil,
         openScreenRecordingSettings: @escaping () -> Bool = ScreenRecordingSettings.open) {
        self.defaults = defaults
        self.openScreenRecordingSettings = openScreenRecordingSettings
        presentation = ConfidencePresentation(defaults: defaults, media: media)
        monitorAssignments = assignments ?? DisplayAssignments(defaults: defaults)
        super.init(nibName: nil, bundle: nil)
        if let data = defaults.data(forKey: "confidenceOptions"), let saved = try? JSONDecoder().decode(ConfidenceOptions.self, from: data) { options = saved.clamped() }
        presentation.configure(options)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        fontPicker.addItems(withTitles: ["System", "Helvetica", "Arial", "Georgia", "Verdana"])
        if !fontPicker.itemTitles.contains(options.fontName) { fontPicker.addItem(withTitle: options.fontName) }
        fontPicker.selectItem(withTitle: options.fontName)
        fontPicker.setAccessibilityLabel("Confidence font")
        alignmentPicker.addItems(withTitles: CanvasAlignment.allCases.map(\.rawValue))
        alignmentPicker.selectItem(withTitle: options.alignment.rawValue)
        alignmentPicker.setAccessibilityLabel("Confidence alignment")
        size.doubleValue = options.fontSize
        size.setAccessibilityLabel("Confidence font size")
        size.isContinuous = false
        for control in [fontPicker, alignmentPicker, size, clockSwitch] as [NSControl] {
            control.target = self; control.action = #selector(optionsChanged)
        }
        clockSwitch.state = options.twentyFourHourClock ? .on : .off
        mediaSwitch.target = self; mediaSwitch.action = #selector(toggleMedia)
        mediaSwitch.setAccessibilityLabel("Show Eucaly media")
        mediaSwitch.setAccessibilityIdentifier("confidenceMediaSwitch")
        mediaStateLabel.setAccessibilityIdentifier("confidenceMediaState")
        mediaActionButton.setAccessibilityIdentifier("confidenceMediaAction")
        fontLabel.stringValue = "\(Int(options.fontSize)) pt"
        let controls = UI.column(
            UI.card("Confidence display", content: monitorControls),
            visibilityButton,
            UI.card("Local Eucaly media", content: UI.column(
                UI.label("Show Eucaly’s projected images, videos and slides. Both apps must run on this Mac, connected using This Mac. Requires Screen Recording access; audio stays in Eucaly.", size: 11, color: .secondaryLabelColor),
                UI.row(UI.label("Show Eucaly media", size: 12), NSView(), mediaEnabledLabel, mediaSwitch),
                mediaStateLabel, mediaStatusLabel, mediaActionButton,
                UI.label("Remembers your choice. When on, capture resumes automatically after launch once Confidence is visible.", size: 11, color: .secondaryLabelColor))),
            UI.card("Readability", content: UI.column(fontPicker, UI.row(size, fontLabel), alignmentPicker, clockSwitch)), spacing: 14)
        let previewCanvas = ConfidenceCanvas(presentation: presentation)
        let stage = UI.canvasStage(previewCanvas, overlay: previewNotice)
        let previewTitle = UI.row(UI.label("CONFIDENCE PREVIEW", size: 11, color: .secondaryLabelColor, bold: true),
                                  NSView(), PreviewAspectRatioPicker(stage: stage, defaults: defaults, role: "Confidence"))
        let previewFooter = UI.column(sourceLabel,
            UI.label("Audience Hide keeps lyrics readable; media follows Eucaly’s projection. Clear/Stop clears content. Close Display closes only Confidence.", size: 11, color: .secondaryLabelColor), spacing: 12)
        let monitor = UI.monitorPreview(heading: previewTitle, stage: stage, footer: previewFooter)
        let body = UI.row(monitor, UI.scrolling(controls)); body.alignment = .top; body.spacing = UI.previewColumnGap
        body.arrangedSubviews[1].widthAnchor.constraint(equalToConstant: UI.previewInspectorWidth).isActive = true
        monitor.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -(UI.previewInspectorWidth + UI.previewColumnGap)).isActive = true
        monitor.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        body.arrangedSubviews[1].heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let root = UI.column(UI.pageHeading("Confidence", subtitle: "Current time, both Bible translations, lyrics and local Eucaly media on a dedicated display."), body, spacing: 20)
        root.distribution = .fill
        UI.fill(root, in: view, padding: 0)
        presentation.media.onChange = { [weak self] in self?.refreshLabels() }
        presentation.media.onVisibilityChange = { [weak self] in self?.refreshCaptureDemand() }
        output.onReadinessChange = { [weak self] _ in self?.refreshCaptureDemand() }
        output.onChange = { [weak self] _ in self?.onActivityChange?() }
        refreshLabels()
    }
    func update(_ status: ReceiverStatus) {
        receiverStatus = status; presentation.update(status); refreshLabels()
    }
    private func refreshLabels() {
        guard isViewLoaded else { return }
        sourceLabel.stringValue = receiverStatus.ownerName.map { "\(presentation.media.isMedia ? "Projection" : "Text") from \($0)" } ?? "No active presentation"
        mediaStatusLabel.stringValue = presentation.media.status
        let media = presentation.media
        mediaSwitch.state = media.enabled ? .on : .off
        mediaEnabledLabel.stringValue = media.enabled ? "On" : "Off"
        mediaStateLabel.stringValue = media.state.title
        mediaStateLabel.textColor = media.state == .live ? .systemGreen : media.state.needsAttention ? .systemOrange : .labelColor
        mediaActionButton.isHidden = media.state.action == nil
        mediaActionButton.isEnabled = media.enabled && media.state.action != nil
        mediaActionButton.title = media.state.action == .settings ? "Open Screen Recording Settings…" : "Retry Capture"
        if settingsOpenFailed && media.state == .permissionNeeded { mediaStatusLabel.stringValue += " Open System Settings manually if it does not open." }
        refreshPreviewNotice()
        if presentation.text.hasText, presentation.layout.bodySize < 32 { sourceLabel.stringValue += " · Text fits below 32 pt" }
    }
    private func refreshPreviewNotice() {
        let media = presentation.media
        if !presentation.visible {
            previewNotice.show(title: "Confidence hidden", detail: "Choose Show Confidence to restore this output.")
        } else if media.isMedia && !media.hasPicture {
            previewNotice.show(title: media.state.title, detail: media.status)
        } else if !media.isMedia && !presentation.text.hasText {
            if media.enabled { previewNotice.show(title: media.state.title, detail: media.status) }
            else { previewNotice.show(title: "No active presentation", detail: "Present lyrics or a verse, or turn on Show Eucaly media.") }
        } else { previewNotice.isHidden = true }
    }
    func setPreviewActive(_ active: Bool) { previewActive = active; refreshCaptureDemand(); if active { presentation.media.redisplay() } }
    private func refreshCaptureDemand() {
        let previewVisible = previewActive && view.window?.isVisible == true && view.window?.isMiniaturized == false
        presentation.media.setDemand(presentation.visible && presentation.media.hasDrawableTarget
            && (previewVisible || output.readiness == .ready || output.readiness == .preview))
    }
    @objc private func toggleMedia() { presentation.media.setEnabled(mediaSwitch.state == .on); refreshCaptureDemand() }
    @objc private func mediaAction() {
        switch presentation.media.state.action {
        case .settings:
            presentation.media.requestAccess()
            settingsOpenFailed = !openScreenRecordingSettings(); refreshLabels()
        case .retry: presentation.media.requestPermission()
        case nil: break
        }
    }
    @objc private func optionsChanged() {
        options.fontName = fontPicker.titleOfSelectedItem ?? "System"; options.fontSize = size.doubleValue
        options.alignment = CanvasAlignment(rawValue: alignmentPicker.titleOfSelectedItem ?? "Left") ?? .left
        options.twentyFourHourClock = clockSwitch.state == .on
        options = options.clamped(); fontLabel.stringValue = "\(Int(options.fontSize)) pt"
        defaults.set(try? JSONEncoder().encode(options), forKey: "confidenceOptions"); presentation.configure(options); refreshLabels()
    }
    @objc func stop() { output.stop() }
    @objc private func toggleVisibility() {
        presentation.setVisible(!presentation.visible)
        visibilityButton.title = presentation.visible ? "Hide Confidence" : "Show Confidence"
        refreshCaptureDemand()
        refreshPreviewNotice()
    }
    func shutdown() { output.stop(); presentation.media.shutdown() }
}
