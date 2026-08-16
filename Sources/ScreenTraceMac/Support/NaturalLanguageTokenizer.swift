import Foundation
import NaturalLanguage
import ScreenTraceCore

/// Real word segmentation for Chinese and Japanese. The bigram fallback in the
/// core produced fragments like "个配" that surfaced as tags; a proper segmenter
/// plus a lexical-class filter keeps only nouns and verbs worth indexing.
struct NaturalLanguageTokenizer: TraceTokenizing {
    func words(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var result: [String] = []
        let keptClasses: Set<NLTag> = [.noun, .verb, .adjective, .otherWord]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace, .omitOther]
        ) { tag, range in
            let word = String(text[range])
            guard word.count >= 2,
                  let tag, keptClasses.contains(tag) else { return true }
            result.append(word)
            return true
        }
        return result
    }
}
