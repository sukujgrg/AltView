import Foundation

enum DesignProfileID: String, Codable, CaseIterable {
    case custom = "Custom", scripture = "Scripture", lyrics = "Lyrics"
    var selection: TextTemplateSelection {
        switch self { case .custom: return .custom; case .scripture: return .scripture; case .lyrics: return .lyrics }
    }
}

struct TemplateDesign: Codable, Equatable {
    var template: LowerThirdTemplate
    var style: OutputStyle
}

/// Three independent saved designs; the HDMI key background and selection
/// policy belong to the receiver. Artwork IDs may be shared after migration.
struct TemplateDesignLibrary: Codable, Equatable {
    var selection: TextTemplateSelection
    var background: String
    var custom: TemplateDesign
    var scripture: TemplateDesign
    var lyrics: TemplateDesign

    init(template: LowerThirdTemplate = LowerThirdTemplate(), style: OutputStyle = OutputStyle()) {
        selection = template.textTemplate
        background = style.clamped().background
        var storedStyle = style.clamped(); storedStyle.background = "000000"
        var base = template; base.customized = true; base.textTemplate = .custom
        custom = TemplateDesign(template: base, style: storedStyle)
        var scriptureTemplate = base
        scriptureTemplate.textTemplate = .scripture; scriptureTemplate.alignment = .left
        scriptureTemplate.showsTitle = true; scriptureTemplate.showsFooter = true
        scripture = TemplateDesign(template: scriptureTemplate, style: storedStyle)
        var lyricsTemplate = base
        lyricsTemplate.textTemplate = .lyrics; lyricsTemplate.alignment = .center
        lyricsTemplate.showsTitle = false; lyricsTemplate.showsFooter = false
        lyrics = TemplateDesign(template: lyricsTemplate, style: storedStyle)
    }

    subscript(_ id: DesignProfileID) -> TemplateDesign {
        get { switch id { case .custom: return custom; case .scripture: return scripture; case .lyrics: return lyrics } }
        set {
            var value = newValue
            value.template = value.template.clamped()
            value.template.customized = true; value.template.textTemplate = id.selection
            value.style = value.style.clamped()
            value.style.background = "000000"
            switch id { case .custom: custom = value; case .scripture: scripture = value; case .lyrics: lyrics = value }
        }
    }

    func profileID(for content: DisplayContent) -> DesignProfileID {
        switch selection {
        case .custom: return .custom
        case .scripture: return .scripture
        case .lyrics: return .lyrics
        case .sender:
            switch content.template { case .scripture: return .scripture; case .lyrics: return .lyrics; default: return .custom }
        }
    }

    func design(for content: DisplayContent) -> TemplateDesign { design(profileID(for: content)) }
    func design(_ id: DesignProfileID) -> TemplateDesign {
        var result = self[id]; result.style.background = background
        return result
    }
    var assetIDs: Set<UUID> { Set(DesignProfileID.allCases.compactMap { self[$0].template.assetID }) }
    func clamped() -> Self {
        var result = self
        var keyStyle = OutputStyle(); keyStyle.background = background
        result.background = keyStyle.clamped().background
        for id in DesignProfileID.allCases { result[id] = self[id] }
        return result
    }
}
