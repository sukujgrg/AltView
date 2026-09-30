import Foundation
import CoreGraphics

enum LowerThirdArtwork: String, Codable, CaseIterable { case builtIn = "Built-in banner", custom = "Imported PNG" }
enum LowerThirdAnimation: String, Codable, CaseIterable { case none = "None", slide = "Slide", reveal = "Reveal" }

/// Coordinates are percentages of a 1920 × 1080 canvas, measured from the top left.
struct TemplateRegion: Codable, Equatable {
    var x: Double, y: Double, width: Double, height: Double
    var rect: CGRect { CGRect(x: x * 19.2, y: y * 10.8, width: width * 19.2, height: height * 10.8) }
    func clamped() -> Self {
        func finite(_ value: Double, fallback: Double) -> Double { value.isFinite ? value : fallback }
        let x = min(99, max(0, finite(x, fallback: 5)))
        let y = min(99, max(0, finite(y, fallback: 72)))
        return Self(x: x, y: y, width: min(100 - x, max(1, finite(width, fallback: 90))), height: min(100 - y, max(1, finite(height, fallback: 23))))
    }
}

struct LowerThirdTemplate: Codable, Equatable {
    var enabled = false
    var artwork = LowerThirdArtwork.builtIn
    var assetID: UUID?
    var assetName: String?
    var animation = LowerThirdAnimation.slide
    var duration = 0.45
    var alignment = CanvasAlignment.left
    var showsArtwork = true
    var showsTitle = true
    var showsFooter = true
    var artworkRegion = TemplateRegion(x: 5, y: 72, width: 90, height: 23)
    var titleRegion = TemplateRegion(x: 10, y: 74, width: 80, height: 4)
    var bodyRegion = TemplateRegion(x: 10, y: 79, width: 80, height: 11)
    var footerRegion = TemplateRegion(x: 10, y: 91, width: 80, height: 3)

    init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled, artwork, assetID, assetName, animation, duration, alignment
        case showsArtwork, showsTitle, showsFooter, artworkRegion, titleRegion, bodyRegion, footerRegion
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        artwork = try values.decode(LowerThirdArtwork.self, forKey: .artwork)
        assetID = try values.decodeIfPresent(UUID.self, forKey: .assetID)
        assetName = try values.decodeIfPresent(String.self, forKey: .assetName)
        animation = try values.decode(LowerThirdAnimation.self, forKey: .animation)
        duration = try values.decode(Double.self, forKey: .duration)
        alignment = try values.decode(CanvasAlignment.self, forKey: .alignment)
        // Designs saved before these switches existed keep all areas on.
        showsArtwork = try values.decodeIfPresent(Bool.self, forKey: .showsArtwork) ?? true
        showsTitle = try values.decodeIfPresent(Bool.self, forKey: .showsTitle) ?? true
        showsFooter = try values.decodeIfPresent(Bool.self, forKey: .showsFooter) ?? true
        artworkRegion = try values.decode(TemplateRegion.self, forKey: .artworkRegion)
        titleRegion = try values.decode(TemplateRegion.self, forKey: .titleRegion)
        bodyRegion = try values.decode(TemplateRegion.self, forKey: .bodyRegion)
        footerRegion = try values.decode(TemplateRegion.self, forKey: .footerRegion)
    }

    /// Filter for display without altering the sender's snapshot or saved boxes.
    func contentForDisplay(_ content: DisplayContent) -> DisplayContent {
        var result = content
        if !showsTitle { result.title = "" }
        if !showsFooter { result.footer = "" }
        return result
    }

    func clamped() -> Self {
        var result = self
        result.duration = duration.isFinite ? min(2, max(0.1, duration)) : 0.45
        result.artworkRegion = artworkRegion.clamped()
        result.titleRegion = titleRegion.clamped()
        result.bodyRegion = bodyRegion.clamped()
        result.footerRegion = footerRegion.clamped()
        return result
    }
    var requiresCustomArtwork: Bool { enabled && showsArtwork && artwork == .custom }
    var bodyExpandsAutomatically: Bool { !showsTitle || !showsFooter }

    /// Resolve the sender's empty-row preference without changing the saved design.
    /// Receiver-hidden rows still reclaim space even when empty rows are reserved.
    func resolved(for content: DisplayContent) -> Self {
        guard content.emptyRegions == .collapse else { return self }
        var result = self
        result.showsTitle = showsTitle && content.hasTitle
        result.showsFooter = showsFooter && content.hasFooter
        return result
    }

    /// Reclaim hidden text rows vertically, retaining the body's horizontal
    /// alignment and saved base rectangle so switching rows on is reversible.
    var effectiveBodyRegion: TemplateRegion {
        let body = bodyRegion.clamped()
        var top = body.y, bottom = body.y + body.height
        for region in [showsTitle ? nil : titleRegion, showsFooter ? nil : footerRegion].compactMap({ $0 }) {
            let region = region.clamped()
            top = min(top, region.y)
            bottom = max(bottom, region.y + region.height)
        }
        return TemplateRegion(x: body.x, y: top, width: body.width, height: bottom - top)
    }

    /// Enclose the expanded body and the remaining visible areas for animation.
    var bounds: CGRect {
        var result = effectiveBodyRegion.rect
        if showsArtwork { result = result.union(artworkRegion.rect) }
        if showsTitle { result = result.union(titleRegion.rect) }
        if showsFooter { result = result.union(footerRegion.rect) }
        return result
    }
}

/// A reversible timeline. Content updates never restart an in-progress transition.
struct LowerThirdMotion {
    private(set) var from: Double = 0
    private(set) var target: Double = 0
    private(set) var started: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    func progress(at time: TimeInterval) -> Double {
        guard duration > 0 else { return target }
        let t = min(1, max(0, (time - started) / duration))
        let eased = t * t * (3 - 2 * t)
        return from + (target - from) * eased
    }
    func isRunning(at time: TimeInterval) -> Bool { duration > 0 && time < started + duration }
    mutating func set(visible: Bool, at time: TimeInterval, duration requestedDuration: TimeInterval, animated: Bool) {
        let next: Double = visible ? 1 : 0
        if !animated { from = next; target = next; duration = 0; started = time; return }
        guard next != target else { return }
        from = progress(at: time)
        target = next
        duration = requestedDuration * abs(target - from)
        started = time
    }
}
