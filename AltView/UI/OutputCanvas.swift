import AppKit

enum CanvasPosition: String, Codable, CaseIterable { case top = "Top", center = "Center", bottom = "Bottom" }
enum CanvasAlignment: String, Codable, CaseIterable { case left = "Left", center = "Center", right = "Right" }

struct OutputStyle: Codable, Equatable {
    var background = "000000"
    var fontName = "System"
    var fontSize: Double = 88
    var heightFraction: Double = 0.8
    var position = CanvasPosition.center
    var alignment = CanvasAlignment.center
    var backgroundColor: NSColor {
        let rgb = UInt32(background, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    func font(size: CGFloat, bold: Bool = true) -> NSFont {
        if fontName == "System" { return .systemFont(ofSize: size, weight: bold ? .semibold : .regular) }
        return NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }
    var textAlignment: NSTextAlignment {
        switch alignment { case .left: return .left; case .center: return .center; case .right: return .right }
    }
    func attributes(size: CGFloat, bold: Bool = true) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment
        paragraph.baseWritingDirection = .natural
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = size * 0.12
        return [.font: font(size: size, bold: bold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
    }
}

struct CanvasTextLayout {
    let bodyFontSize: CGFloat
    let titleFontSize: CGFloat
    let footerFontSize: CGFloat
    let title: NSRect
    let body: NSRect
    let footer: NSRect
    static func measure(_ text: String, size: CGFloat, width: CGFloat, style: OutputStyle, bold: Bool = true) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let string = NSAttributedString(string: text, attributes: style.attributes(size: size, bold: bold))
        return ceil(string.boundingRect(with: NSSize(width: width, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
    }
    static func make(content: DisplayContent, style: OutputStyle, template: LowerThirdTemplate = LowerThirdTemplate()) -> CanvasTextLayout {
        let content = template.contentForDisplay(content)
        let width: CGFloat = 1728
        let maximumHeight = 972 * CGFloat(min(0.9, max(0.15, style.heightFraction)))
        let preferred = CGFloat(min(160, max(12, style.fontSize)))
        let reserve = content.emptyRegions == .reserve
        // Full-screen layout has no fixed label boxes. Reserve one line plus
        // its normal gap for an empty label; the placeholder is never drawn.
        let title = content.hasTitle ? content.title : (reserve && template.showsTitle ? "Ag" : "")
        let footer = content.hasFooter ? content.footer : (reserve && template.showsFooter ? "Ag" : "")
        func metrics(scale: CGFloat) -> (title: CGFloat, body: CGFloat, footer: CGFloat, titleGap: CGFloat, footerGap: CGFloat) {
            (measure(title, size: 34 * scale, width: width, style: style),
             measure(content.body, size: preferred * scale, width: width, style: style),
             measure(footer, size: 28 * scale, width: width, style: style, bold: false),
             title.isEmpty ? 0 : 22 * scale, footer.isEmpty ? 0 : 22 * scale)
        }
        var low: CGFloat = 0.001
        var high: CGFloat = 1
        for _ in 0..<16 {
            let mid = (low + high) / 2
            let m = metrics(scale: mid)
            if m.title + m.body + m.footer + m.titleGap + m.footerGap <= maximumHeight { low = mid } else { high = mid }
        }
        let m = metrics(scale: low)
        let titleHeight = m.title, bodyHeight = m.body, footerHeight = m.footer
        let titleGap = m.titleGap, footerGap = m.footerGap
        let total = titleHeight + titleGap + bodyHeight + footerGap + footerHeight
        let y: CGFloat
        switch style.position {
        case .top: y = 54
        case .center: y = (1080 - total) / 2
        case .bottom: y = 1026 - total
        }
        return CanvasTextLayout(bodyFontSize: preferred * low, titleFontSize: 34 * low, footerFontSize: 28 * low,
            title: NSRect(x: 96, y: y, width: width, height: titleHeight),
            body: NSRect(x: 96, y: y + titleHeight + titleGap, width: width, height: bodyHeight),
            footer: NSRect(x: 96, y: y + titleHeight + titleGap + bodyHeight + footerGap, width: width, height: footerHeight))
    }
}

extension CanvasTextLayout {
    static func lowerThird(content: DisplayContent, style: OutputStyle, template: LowerThirdTemplate) -> CanvasTextLayout {
        let template = template.resolved(for: content)
        let content = template.contentForDisplay(content)
        var textStyle = style; textStyle.alignment = template.alignment
        func fit(_ text: String, in region: TemplateRegion, preferred: CGFloat, bold: Bool = true) -> CGFloat {
            let rect = region.rect
            // Tiny boxes and valid snapshots with many explicit newlines may
            // need sub-point text. Do not impose a floor that lets it overflow.
            var low: CGFloat = 0.000001, high = preferred
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if measure(text, size: mid, width: rect.width, style: textStyle, bold: bold) <= rect.height { low = mid } else { high = mid }
            }
            return low
        }
        return CanvasTextLayout(bodyFontSize: fit(content.body, in: template.effectiveBodyRegion, preferred: CGFloat(min(160, max(12, style.fontSize)))),
            titleFontSize: fit(content.title, in: template.titleRegion, preferred: 34),
            footerFontSize: fit(content.footer, in: template.footerRegion, preferred: 28, bold: false),
            title: template.titleRegion.rect, body: template.effectiveBodyRegion.rect, footer: template.footerRegion.rect)
    }
}

final class OutputCanvas: NSView {
    let presentation: CanvasPresentation
    private var observation: UUID?
    private var cachedRevision: UInt64?
    private var cachedImage: NSImage?
    private var accessibleContent: DisplayContent?
    // Convenience accessors for standalone rendering and tests.
    var content: DisplayContent {
        get { presentation.content }
        set { presentation.update(content: newValue, style: presentation.style, template: presentation.template, artwork: presentation.artwork) }
    }
    var style: OutputStyle {
        get { presentation.style }
        set { presentation.update(content: presentation.content, style: newValue, template: presentation.template, artwork: presentation.artwork) }
    }
    override init(frame: NSRect) {
        presentation = CanvasPresentation()
        super.init(frame: frame)
        observePresentation()
    }
    init(presentation: CanvasPresentation) {
        self.presentation = presentation
        super.init(frame: .zero)
        observePresentation()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func observePresentation() {
        setAccessibilityElement(true); setAccessibilityRole(.image)
        observation = presentation.observe { [weak self] in self?.presentationDidChange() }
        presentationDidChange()
    }
    private func presentationDidChange() {
        needsDisplay = true
        let content = presentation.template.contentForDisplay(self.content)
        if accessibleContent != content {
            accessibleContent = content
            setAccessibilityLabel(content.visible ? [content.title, content.body, content.footer].filter { !$0.isEmpty }.joined(separator: "\n") : "Output blank — keying background")
        }
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        style.backgroundColor.setFill(); bounds.fill()
        let progress = presentation.progress
        guard progress > 0 else { return }
        let scale = min(bounds.width / 1920, bounds.height / 1080)
        guard scale > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: (bounds.width - 1920 * scale) / 2, yBy: (bounds.height - 1080 * scale) / 2)
        transform.scale(by: scale); transform.concat()
        NSRect(x: 0, y: 0, width: 1920, height: 1080).clip()
        if presentation.template.enabled {
            if cachedRevision != presentation.revision {
                cachedImage = makeLowerThirdImage()
                cachedRevision = presentation.revision
            }
            let region = presentation.template.resolved(for: presentation.displayedContent).bounds
            switch presentation.template.animation {
            case .slide:
                let move = NSAffineTransform()
                move.translateX(by: -(1 - progress) * (region.maxX + 2), yBy: 0); move.concat()
            case .reveal:
                NSRect(x: region.minX, y: region.minY, width: region.width * progress, height: region.height).clip()
            case .none: break
            }
            cachedImage?.draw(in: NSRect(x: 0, y: 0, width: 1920, height: 1080), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let content = presentation.template.contentForDisplay(presentation.displayedContent)
            drawText(content, layout: CanvasTextLayout.make(content: content, style: style, template: presentation.template), style: style)
        }
    }
    /// Rasterize only when content/design changes. Animation frames move or clip
    /// this cached transparent layer; they never decode images or refit text.
    private func makeLowerThirdImage() -> NSImage? {
        guard let cg = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 1920 * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: 1080); cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let template = presentation.template
        if template.showsArtwork && template.artwork == .builtIn {
            Self.drawBuiltInBanner(in: template.artworkRegion.rect)
        } else if template.showsArtwork, let artwork = presentation.artwork {
            let bounds = template.artworkRegion.rect
            let factor = min(bounds.width / CGFloat(artwork.image.width), bounds.height / CGFloat(artwork.image.height))
            let size = NSSize(width: CGFloat(artwork.image.width) * factor, height: CGFloat(artwork.image.height) * factor)
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            NSImage(cgImage: artwork.image, size: .zero).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        var textStyle = style; textStyle.alignment = template.alignment
        let content = template.contentForDisplay(presentation.displayedContent)
        drawText(content, layout: .lowerThird(content: content, style: style, template: template), style: textStyle)
        NSGraphicsContext.restoreGraphicsState()
        return cg.makeImage().map { NSImage(cgImage: $0, size: NSSize(width: 1920, height: 1080)) }
    }
    static func drawBuiltInBanner(in rect: NSRect) {
        NSColor(srgbRed: 0.04, green: 0.08, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        NSColor(srgbRed: 0.10, green: 0.22, blue: 0.39, alpha: 1).setFill()
        NSRect(x: rect.minX + 14, y: rect.minY, width: rect.width - 24, height: rect.height * 0.28).fill()
        NSColor(srgbRed: 1, green: 0.65, blue: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: 14, height: rect.height), xRadius: 5, yRadius: 5).fill()
    }
    private func drawText(_ content: DisplayContent, layout: CanvasTextLayout, style: OutputStyle) {
        func draw(_ text: String, rect: NSRect, size: CGFloat, bold: Bool = true) {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            rect.clip()
            NSAttributedString(string: text, attributes: style.attributes(size: size, bold: bold))
                .draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        draw(content.title, rect: layout.title, size: layout.titleFontSize)
        draw(content.body, rect: layout.body, size: layout.bodyFontSize)
        draw(content.footer, rect: layout.footer, size: layout.footerFontSize, bold: false)
    }
    deinit { if let observation { presentation.removeObserver(observation) } }
}
