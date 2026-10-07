import AppKit

enum UI {
    static let previewInspectorWidth: CGFloat = 300
    static let previewColumnGap: CGFloat = 24
    static func label(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        field.textColor = color
        return field
    }
    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13, weight: .medium)
        return button
    }
    static func primaryButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = self.button(title, target: target, action: action)
        button.bezelColor = .controlAccentColor
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        return button
    }
    static func separator() -> NSBox {
        let line = NSBox(); line.boxType = .separator
        return line
    }
    static func pageHeading(_ title: String, subtitle: String) -> NSView {
        let heading = column(label(title, size: 24, bold: true),
                             label(subtitle, size: 12, color: .secondaryLabelColor), spacing: 5)
        heading.setHuggingPriority(.required, for: .vertical)
        return heading
    }
    static func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 8
        return stack
    }
    static func column(_ views: NSView..., spacing: CGFloat = 10) -> NSStackView { column(views, spacing: spacing) }
    static func column(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    static func card(_ title: String, content: NSView) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 0.5
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor
        box.titlePosition = .noTitle
        box.title = ""
        box.setAccessibilityLabel(title)
        box.contentViewMargins = NSSize(width: 14, height: 14)
        let heading = label(title, size: 13, bold: true)
        let body = column(heading, content, spacing: 10)
        body.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(body)
        if let parent = box.contentView {
            NSLayoutConstraint.activate([
                body.leadingAnchor.constraint(equalTo: parent.leadingAnchor), body.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                body.topAnchor.constraint(equalTo: parent.topAnchor), body.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            ])
        }
        return box
    }
    /// A canvas stage that fits the selected preview shape at any workspace height.
    /// These surroundings belong to the controls only, never to HDMI output.
    static func canvasStage(_ canvas: NSView, overlay: NSView? = nil) -> WorkspaceCanvasStage {
        let stage = WorkspaceCanvasStage(canvas, overlay: overlay)
        // Long preview notes may need a little extra height in a compact window.
        // Let the canvas yield that space instead of enlarging the window.
        let minimumHeight = stage.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        minimumHeight.priority = NSLayoutConstraint.Priority(749)
        minimumHeight.isActive = true
        return stage
    }
    /// Keep both output pages' preview areas identical, including room for status.
    static func monitorPreview(heading: NSView, stage: WorkspaceCanvasStage, footer: NSView) -> NSStackView {
        let notes = scrolling(footer)
        notes.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let monitor = column(heading, stage, notes, spacing: 12)
        monitor.distribution = .fill
        return monitor
    }
    static func scrolling(_ content: NSView, fillsHeight: Bool = false) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let document = WorkspaceDocumentView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        if fillsHeight { document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor).isActive = true }
        fill(content, in: document, padding: 1)
        return scroll
    }
    static func fill(_ view: NSView, in parent: NSView, padding: CGFloat = 20) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -padding),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: padding),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -padding)
        ])
    }
}

/// Fit the monitor inside the allocated space without letting the preview’s
/// preferred aspect ratio impose a minimum size on the surrounding window.
final class WorkspaceCanvasStage: NSView {
    private let canvas: NSView
    private let overlay: NSView?
    var aspectRatio = PreviewAspectRatio.widescreen {
        didSet { needsLayout = true }
    }
    init(_ canvas: NSView, overlay: NSView?) {
        self.canvas = canvas; self.overlay = overlay
        super.init(frame: .zero)
        wantsLayer = true
        // A slate surround makes the monitor's edges visible against black output.
        layer?.backgroundColor = NSColor(srgbRed: 0.20, green: 0.23, blue: 0.27, alpha: 1).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        addSubview(canvas)
        if let overlay { addSubview(overlay) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let width = min(bounds.width, bounds.height * aspectRatio.value)
        let height = width / aspectRatio.value
        let frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        canvas.frame = frame
        overlay?.frame = frame
    }
}

enum PreviewAspectRatio: String, CaseIterable {
    case widescreen = "16:9", computer = "16:10", standard = "4:3"
    var value: CGFloat {
        switch self {
        case .widescreen: return 16.0 / 9
        case .computer: return 16.0 / 10
        case .standard: return 4.0 / 3
        }
    }
}

/// Preview shape is a local workspace preference; output still follows its display.
final class PreviewAspectRatioPicker: NSPopUpButton {
    private let stage: WorkspaceCanvasStage
    private let defaults: UserDefaults
    private let preferenceKey: String
    init(stage: WorkspaceCanvasStage, defaults: UserDefaults, role: String) {
        self.stage = stage; self.defaults = defaults
        preferenceKey = "\(role.lowercased())PreviewAspectRatio"
        super.init(frame: .zero, pullsDown: false)
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        addItems(withTitles: PreviewAspectRatio.allCases.map(\.rawValue))
        let saved = defaults.string(forKey: preferenceKey).flatMap(PreviewAspectRatio.init(rawValue:)) ?? .widescreen
        selectItem(withTitle: saved.rawValue)
        stage.aspectRatio = saved
        setAccessibilityLabel("\(role) preview aspect ratio")
        toolTip = "Preview monitor aspect ratio"
        target = self; action = #selector(selectionChanged)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func selectionChanged() {
        guard let title = titleOfSelectedItem, let ratio = PreviewAspectRatio(rawValue: title) else { return }
        stage.aspectRatio = ratio
        defaults.set(ratio.rawValue, forKey: preferenceKey)
    }
}

private final class WorkspaceDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Text always accompanies colour so broadcast state is readable without colour.
final class StatusBadge: NSView {
    private let label = UI.label("", size: 10, bold: true)
    private var tint = NSColor.secondaryLabelColor
    private(set) var text = ""

    init(_ text: String, color: NSColor = .secondaryLabelColor) {
        super.init(frame: .zero)
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        update(text, color: color)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ text: String, color: NSColor = .secondaryLabelColor) {
        self.text = text; tint = color
        label.stringValue = text; label.textColor = color
        invalidateIntrinsicContentSize(); needsDisplay = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: label.intrinsicContentSize.width + 18, height: 24) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
