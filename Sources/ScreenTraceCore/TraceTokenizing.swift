import Foundation

/// Word segmentation for languages without spaces. The core stays portable, so
/// the default is a dependency-free bigram fallback; platform layers inject a
/// real segmenter. Keeping this behind a protocol lets the future Rust worker
/// supply its own without changing the organizer.
public protocol TraceTokenizing: Sendable {
    func words(in text: String) -> [String]
}

public struct BigramTokenizer: TraceTokenizing {
    public init() {}

    public func words(in text: String) -> [String] {
        var result: [String] = []
        guard let regex = try? NSRegularExpression(pattern: #"\p{Han}{2,}"#) else {
            return result
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let characters = Array(text[swiftRange])
            if characters.count <= 6 { result.append(String(characters)) }
            guard characters.count >= 2 else { continue }
            for index in 0..<(characters.count - 1) {
                result.append(String(characters[index...index + 1]))
            }
        }
        return result
    }
}
