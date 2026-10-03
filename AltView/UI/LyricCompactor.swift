import AppKit

/// A display-only transformation using the fitted font on the fixed output
/// canvas. Joined rows remain constrained to one line during the final fit.
enum LyricCompactor {
    struct Plan {
        let text: String
        let joinedLines: [String]
        func fits(style: OutputStyle, size: CGFloat, width: CGFloat) -> Bool {
            joinedLines.allSatisfy { fitsOneLine($0, style: style, size: size, width: safeWidth(width)) }
        }
    }

    private static func safeWidth(_ width: CGFloat) -> CGFloat { max(0, width - max(2, width * 0.01)) }

    static func displayText(_ text: String, template: LowerThirdTemplate, content: DisplayContent,
                            style: OutputStyle, width: CGFloat, size: CGFloat) -> String {
        plan(text, template: template, content: content, style: style, width: width, size: size).text
    }

    static func plan(_ text: String, template: LowerThirdTemplate, content: DisplayContent,
                     style: OutputStyle, width: CGFloat, size: CGFloat) -> Plan {
        guard template.lyricLineLayout == .compact,
              template.selectedContentTemplate(for: content) == .lyrics else { return Plan(text: text, joinedLines: []) }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var result: [String] = [], joinedLines: [String] = [], index = 0
        var measured: [String: Bool] = [:]
        let width = safeWidth(width)
        while index < lines.count {
            let first = lines[index]
            if index + 1 < lines.count {
                let second = lines[index + 1]
                let a = first.trimmingCharacters(in: .whitespaces)
                let b = second.trimmingCharacters(in: .whitespaces)
                // Tabs and manual indentation may encode deliberate positioning.
                if !a.isEmpty, !b.isEmpty, !first.contains("\t"), !second.contains("\t"),
                   first == a, second == b {
                    // Avoid adding a second punctuation mark after an existing one.
                    let punctuation = CharacterSet.punctuationCharacters
                    let separator = template.lyricJoiner == .comma && a.unicodeScalars.last.map(punctuation.contains) == true
                        ? " " : template.lyricJoiner.separator
                    let candidate = a + separator + b
                    let fits = measured[candidate] ?? fitsOneLine(candidate, style: style, size: size, width: width)
                    measured[candidate] = fits
                    if fits {
                        result.append(candidate); joinedLines.append(candidate); index += 2; continue
                    }
                }
            }
            result.append(first); index += 1
        }
        return Plan(text: result.joined(separator: "\n"), joinedLines: joinedLines)
    }

    static func fitsOneLine(_ text: String, style: OutputStyle, size: CGFloat, width: CGFloat) -> Bool {
        guard width > 0, size > 0 else { return false }
        let storage = NSTextStorage(string: text, attributes: style.attributes(size: size))
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: width, height: 100_000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(for: container)
        guard glyphs.length == manager.numberOfGlyphs else { return false }
        var count = 0, fits = true
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            count += 1
            if used.width > width { fits = false }
        }
        // Also check unwrapped advance: long unbreakable words must not pass
        // just because a text container clips them to its available width.
        let advance = NSAttributedString(string: text, attributes: style.attributes(size: size)).size().width
        return count == 1 && fits && advance <= width
    }
}
