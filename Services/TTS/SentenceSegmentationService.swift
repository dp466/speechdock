import Foundation
import NaturalLanguage

/// Splits text into synthesis-sized chunks at natural sentence boundaries, without breaking
/// abbreviations, decimals, URLs, emails, or initials. Paragraph boundaries are preserved (chunks
/// never span a blank-line paragraph break). Long sentences are split at clause then word boundaries
/// to respect a configurable maximum length. Pure and deterministic — see SentenceSegmentationTests.
struct SentenceSegmentationService {
    /// Soft maximum characters per chunk; sentences longer than this are sub-split.
    var maxChunkLength: Int = 300

    /// The opening chunk is kept deliberately short so the very first audio arrives fast — it is the
    /// only chunk on the critical path (everything after it is generated while this one plays).
    var firstChunkMaxLength: Int = 45

    /// Abbreviations after which a period should NOT end a sentence (safety net over NLTokenizer).
    private static let abbreviations: Set<String> = [
        "m", "mr", "mrs", "ms", "dr", "dre", "prof", "st", "ste", "mme", "mlle",
        "etc", "eg", "ie", "vs", "inc", "ltd", "co", "jr", "sr", "no", "vol",
        "cf", "al", "p", "pp", "fig", "approx", "dept", "univ", "gov", "sen",
    ]

    /// Segment `text` into ordered chunks ready for synthesis.
    func segment(_ text: String) -> [String] {
        var chunks: [String] = []
        for paragraph in paragraphs(in: text) {
            let normalized = normalizeWhitespace(paragraph)
            guard !normalized.isEmpty else { continue }
            for sentence in splitSentences(normalized) {
                chunks.append(contentsOf: enforceMaxLength(sentence))
            }
        }
        return splitOpeningChunk(chunks)
    }

    /// If the opening chunk is long, split it once at a clause/word boundary so playback can start
    /// sooner. Order is preserved; the remainder becomes the next chunk.
    private func splitOpeningChunk(_ chunks: [String]) -> [String] {
        guard let first = chunks.first, first.count > firstChunkMaxLength else { return chunks }

        // Prefer a clause boundary within the limit, else the last word boundary.
        let limitIndex = first.index(first.startIndex, offsetBy: firstChunkMaxLength)
        let head = first[first.startIndex..<limitIndex]
        let cut = head.lastIndex(where: { $0 == "," || $0 == ";" || $0 == ":" })
            ?? head.lastIndex(of: " ")
        guard let cut else { return chunks }

        let opening = String(first[first.startIndex...cut]).trimmingCharacters(in: .whitespaces)
        let rest = String(first[first.index(after: cut)...]).trimmingCharacters(in: .whitespaces)
        guard !opening.isEmpty, !rest.isEmpty else { return chunks }

        return [opening, rest] + chunks.dropFirst()
    }

    // MARK: - Paragraphs

    /// Split on blank lines (two or more newlines, optionally with intervening whitespace).
    private func paragraphs(in text: String) -> [String] {
        let pattern = "\\n[ \\t]*\\n+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let split = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "\u{1}")
        return split.components(separatedBy: "\u{1}")
    }

    private func normalizeWhitespace(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sentence splitting

    private func splitSentences(_ text: String) -> [String] {
        var raw: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { raw.append(s) }
            return true
        }
        if raw.isEmpty { return [text] }

        // Safety-net merge: rejoin fragments where the split followed an abbreviation or a bare
        // single-letter initial (e.g. "J. R. R. Tolkien"), which occasionally slip past the tokenizer.
        var merged: [String] = []
        for sentence in raw {
            if let last = merged.last, endsWithAbbreviationOrInitial(last) {
                merged[merged.count - 1] = last + " " + sentence
            } else {
                merged.append(sentence)
            }
        }
        return merged
    }

    private func endsWithAbbreviationOrInitial(_ s: String) -> Bool {
        guard s.hasSuffix(".") else { return false }
        // Last whitespace-separated token, minus the trailing period.
        let lastToken = s.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).last.map(String.init) ?? s
        let word = lastToken.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]\"'"))
        if word.count == 1, let c = word.first, c.isLetter { return true } // initial like "J"
        return Self.abbreviations.contains(word.lowercased())
    }

    // MARK: - Max length

    private func enforceMaxLength(_ sentence: String) -> [String] {
        guard sentence.count > maxChunkLength else { return [sentence] }

        // First try clause boundaries (, ; :), then fall back to word packing.
        let clauses = splitKeepingDelimiters(sentence, delimiters: [",", ";", ":"])
        var result: [String] = []
        var current = ""
        for piece in clauses {
            for packed in packWords(piece) {
                if current.isEmpty {
                    current = packed
                } else if current.count + 1 + packed.count <= maxChunkLength {
                    current += " " + packed
                } else {
                    result.append(current)
                    current = packed
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [sentence] : result
    }

    /// Split into clause fragments, keeping the delimiter attached to the preceding fragment.
    private func splitKeepingDelimiters(_ s: String, delimiters: Set<Character>) -> [String] {
        var fragments: [String] = []
        var current = ""
        for ch in s {
            current.append(ch)
            if delimiters.contains(ch) {
                fragments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { fragments.append(tail) }
        return fragments.filter { !$0.isEmpty }
    }

    /// Pack a fragment's words into pieces no longer than maxChunkLength.
    private func packWords(_ fragment: String) -> [String] {
        guard fragment.count > maxChunkLength else { return [fragment] }
        var pieces: [String] = []
        var current = ""
        for word in fragment.split(separator: " ") {
            let w = String(word)
            if current.isEmpty {
                current = w
            } else if current.count + 1 + w.count <= maxChunkLength {
                current += " " + w
            } else {
                pieces.append(current)
                current = w
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
