import XCTest
@testable import LensCore
@testable import LensMac

final class NaturalLanguageTokenizerTests: XCTestCase {
    /// The core bigram fallback emits fragments like "个配" from a sliding
    /// window over every adjacent pair. A real segmenter plus a lexical-class
    /// filter must keep only words worth putting in the tag bar.
    func testChineseSentenceDoesNotEmitBigramFragments() {
        let words = NaturalLanguageTokenizer().words(in: "我们来看这个配置文件")
        XCTAssertFalse(
            words.contains("个配"),
            "真分词不应把滑窗碎片当成词"
        )
    }
}
