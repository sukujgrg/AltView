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
    let main: NSRect
    let title: NSRect
    let body: NSRect
    let footer: NSRect
    let bodySize: CGFloat
    static func make(text: ConfidenceText, options: ConfidenceOptions) -> Self {
        let main = NSRect(x: 48, y: 136, width: 1824, height: 896)
        let titleHeight: CGFloat = text.title.isEmpty ? 0 : 72
        let footerHeight: CGFloat = text.footer.isEmpty ? 0 : 54
        let bodyBox = NSRect(x: main.minX, y: main.minY + titleHeight, width: main.width, height: main.height - titleHeight - footerHeight)
        let style = options.style
        func height(_ size: CGFloat) -> CGFloat {
            CanvasTextLayout.measure(text.body, size: size, width: bodyBox.width, style: style)
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
        return Self(main: main,
                    title: NSRect(x: main.minX, y: main.minY, width: main.width, height: titleHeight), body: body,
                    footer: NSRect(x: main.minX, y: main.maxY - footerHeight, width: main.width, height: footerHeight), bodySize: size)
    }
}

/// Receiver snapshots and local operator settings; no audience artwork or visibility dependency.
final class ConfidencePresentation {
    private(set) var text = ConfidenceText.empty
    private(set) var options = ConfidenceOptions()
    private(set) var visible = true
    private var observers: [UUID: () -> Void] = [:]
    private var cachedLayout: ConfidenceLayout?
    var layout: ConfidenceLayout {
        if let cachedLayout { return cachedLayout }
        let value = ConfidenceLayout.make(text: text, options: options)
        cachedLayout = value
        return value
    }
    func update(_ status: ReceiverStatus) {
        guard text != status.confidenceContent else { return }
        text = status.confidenceContent; changed()
    }
    func configure(_ options: ConfidenceOptions) {
        let value = options.clamped()
        guard value != self.options else { return }
        self.options = value; changed()
    }
    func setVisible(_ visible: Bool) { self.visible = visible; changed() }
    private func changed() { cachedLayout = nil; for observer in observers.values { observer() } }
    func observe(_ change: @escaping () -> Void) -> UUID { let id = UUID(); observers[id] = change; return id }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
}

final class ConfidenceCanvas: NSView {
    let presentation: ConfidencePresentation
    private var observation: UUID?
    private var timer: Timer?
    private let clock = DateFormatter()
    private var cachedContent: NSImage?
    init(presentation: ConfidencePresentation) {
        self.presentation = presentation
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        observation = presentation.observe { [weak self] in self?.cachedContent = nil; self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        if window != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, self.window?.isVisible == true, !self.isHiddenOrHasHiddenAncestor else { return }
                self.needsDisplay = true
            }
        }
    }
    override func accessibilityLabel() -> String? {
        guard presentation.visible else { return "Confidence hidden" }
        return [presentation.text.title, presentation.text.body, presentation.text.footer].joined(separator: "\n")
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
        let options = presentation.options
        // The once-per-second clock never refits the presented text.
        if cachedContent == nil {
            let image = NSImage(size: NSSize(width: 1920, height: 1080))
            image.lockFocusFlipped(true)
            NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 1920, height: 1080).fill()
            drawContent()
            image.unlockFocus()
            cachedContent = image
        }
        cachedContent?.draw(in: NSRect(x: 0, y: 0, width: 1920, height: 1080), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1920, height: 108).fill()
        clock.locale = .autoupdatingCurrent; clock.timeZone = .autoupdatingCurrent
        clock.dateFormat = options.twentyFourHourClock ? "HH:mm" : "h:mm a"
        draw(clock.string(from: Date()), in: NSRect(x: 48, y: 16, width: 500, height: 80), size: 60)
    }
    private func drawContent() {
        let options = presentation.options, layout = presentation.layout
        draw(presentation.text.title, in: layout.title, size: 44, alignment: options.alignment)
        draw(presentation.text.body, in: layout.body, size: layout.bodySize, alignment: options.alignment)
        draw(presentation.text.footer, in: layout.footer, size: 32, alignment: options.alignment)
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
    deinit { timer?.invalidate(); if let observation { presentation.removeObserver(observation) } }
}

final class ConfidenceViewController: NSViewController {
    let presentation = ConfidencePresentation()
    private let defaults: UserDefaults
    private let monitorAssignments: DisplayAssignments
    private var receiverStatus = ReceiverStatus()
    private var options = ConfidenceOptions()
    lazy var output = OutputWindowController(name: "Confidence", makeCanvas: { [presentation] in ConfidenceCanvas(presentation: presentation) },
                                           displays: { [monitorAssignments] in monitorAssignments.currentDisplays() })
    private lazy var monitorControls: MonitorControls = {
        let controls = MonitorControls(role: .confidence, assignments: monitorAssignments, output: output)
        controls.onOpen = { [weak self] in
            self?.presentation.setVisible(true)
            self?.visibilityButton.title = "Hide Confidence"
        }
        return controls
    }()
    var onActivityChange: (() -> Void)?
    private let fontPicker = NSPopUpButton()
    private let alignmentPicker = NSPopUpButton()
    private let size = NSSlider(value: 100, minValue: 32, maxValue: 160, target: nil, action: nil)
    private let fontLabel = UI.label("100 pt", size: 11)
    private let clockSwitch = NSButton(checkboxWithTitle: "24-hour clock", target: nil, action: nil)
    private let sourceLabel = UI.label("No active text", size: 12)
    private lazy var visibilityButton = UI.button("Hide Confidence", target: self, action: #selector(toggleVisibility))
    init(defaults: UserDefaults, assignments: DisplayAssignments? = nil) {
        self.defaults = defaults
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
        fontLabel.stringValue = "\(Int(options.fontSize)) pt"
        let controls = UI.column(
            UI.card("Confidence display", content: monitorControls),
            visibilityButton,
            UI.card("Readability", content: UI.column(fontPicker, UI.row(size, fontLabel), alignmentPicker, clockSwitch)), spacing: 14)
        let stage = UI.canvasStage(ConfidenceCanvas(presentation: presentation))
        let previewTitle = UI.row(UI.label("CONFIDENCE PREVIEW", size: 11, color: .secondaryLabelColor, bold: true),
                                  NSView(), PreviewAspectRatioPicker(stage: stage, defaults: defaults, role: "Confidence"))
        let previewFooter = UI.column(sourceLabel,
            UI.label("Audience Hide/Blank keeps this text readable. Clear/Stop releases text. Close Confidence Display closes only this display.", size: 11, color: .secondaryLabelColor), spacing: 12)
        let monitor = UI.monitorPreview(heading: previewTitle, stage: stage, footer: previewFooter)
        let body = UI.row(monitor, UI.scrolling(controls)); body.alignment = .top; body.spacing = UI.previewColumnGap
        body.arrangedSubviews[1].widthAnchor.constraint(equalToConstant: UI.previewInspectorWidth).isActive = true
        monitor.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -(UI.previewInspectorWidth + UI.previewColumnGap)).isActive = true
        monitor.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        body.arrangedSubviews[1].heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let root = UI.column(UI.pageHeading("Confidence", subtitle: "Current time and presented text on a dedicated display."), body, spacing: 20)
        root.distribution = .fill
        UI.fill(root, in: view, padding: 0)
        output.onChange = { [weak self] _ in self?.onActivityChange?() }
        refreshLabels()
    }
    func update(_ status: ReceiverStatus) {
        receiverStatus = status; presentation.update(status); refreshLabels()
    }
    private func refreshLabels() {
        guard isViewLoaded else { return }
        sourceLabel.stringValue = receiverStatus.ownerName.map { "Text from \($0)" } ?? "No active text"
        if presentation.text.hasText, presentation.layout.bodySize < 32 { sourceLabel.stringValue += " · Text fits below 32 pt" }
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
    }
    func shutdown() { output.stop() }
}
