import Foundation
import Testing
@testable import SezishAsr

@Suite struct CtcDecoderTests {
    // A compact synthetic vocab where the array index equals the token id:
    // 0:▁(space) 1:п 2:р 3:и 4:в 5:е 6:т 7:a 8:<blk>(blank)
    static let tokens = ["▁", "п", "р", "и", "в", "е", "т", "a", "<blk>"]
    static let blank = 8

    /// A one-hot logit row whose argmax is `id`.
    static func frame(_ id: Int) -> [Float] {
        var row = [Float](repeating: 0, count: tokens.count)
        row[id] = 1
        return row
    }

    static func frames(_ ids: [Int]) -> [[Float]] { ids.map(frame) }

    static func decode(_ ids: [Int]) -> String {
        CtcDecoder.decode(frames: frames(ids), tokens: tokens, blankId: blank)
    }

    @Test func collapsesConsecutiveDuplicates() {
        // argmax "ппривет" collapses the doubled "п" → "привет"
        #expect(Self.decode([1, 1, 2, 3, 4, 5, 6]) == "привет")
    }

    @Test func blankSeparatesRepeats() {
        // a, blank, a → the blank keeps the two "a"s from merging → "aa"
        #expect(Self.decode([7, 8, 7]) == "aa")
    }

    @Test func spaceMarkerBecomesSpaceAndCollapses() {
        // ▁ splits words; leading/trailing/duplicate spaces are collapsed and trimmed
        #expect(Self.decode([0, 1, 2, 3, 4, 5, 6, 0, 0, 7, 0]) == "привет a")
    }

    @Test func emptyInputYieldsEmptyString() {
        #expect(CtcDecoder.decode(frames: [], tokens: Self.tokens, blankId: Self.blank) == "")
    }

    @Test func allBlankYieldsEmptyString() {
        #expect(Self.decode([8, 8, 8, 8]) == "")
    }
}

/// Decoding against a subword vocab: `▁` is a word-boundary prefix inside tokens,
/// punctuation is its own token, `<unk>` must never leak into text.
@Suite struct CtcDecoderSubwordTests {
    // 0:<unk> 1:▁ 2:▁при 3:вет 4:▁как 5:, 6:? 7:П 8:▁Hello 9:<blk>
    static let tokens = ["<unk>", "▁", "▁при", "вет", "▁как", ",", "?", "П", "▁Hello", "<blk>"]
    static let blank = 9

    static func frame(_ id: Int) -> [Float] {
        var row = [Float](repeating: 0, count: tokens.count)
        row[id] = 1
        return row
    }

    static func decode(_ ids: [Int]) -> String {
        CtcDecoder.decode(frames: ids.map(frame), tokens: tokens, blankId: blank)
    }

    @Test func prefixMarkerSplitsWords() {
        #expect(Self.decode([2, 3, 4]) == "привет как")
    }

    @Test func punctuationHugsThePreviousWord() {
        #expect(Self.decode([2, 3, 5, 4, 6]) == "привет, как?")
    }

    @Test func leadingMarkerLeavesNoSpace() {
        #expect(Self.decode([1, 2, 3]) == "привет")
    }

    @Test func unknownTokenIsDropped() {
        #expect(Self.decode([2, 0, 3, 0, 4]) == "привет как")
    }

    @Test func caseAndLatinPassThrough() {
        #expect(Self.decode([7, 3, 5, 8, 6]) == "Пвет, Hello?")
    }

    @Test func standaloneMarkerBeforePunctuationIsDropped() {
        #expect(Self.decode([2, 3, 1, 5, 4]) == "привет, как")
    }

    /// Randomized invariants over the real subword vocab: whatever the model emits,
    /// the text never carries markers, `<unk>`, stray or doubled spaces.
    @Test func randomSequencesKeepTextInvariants() throws {
        let url = try #require(Bundle.module.url(forResource: "v3_e2e_ctc_vocab", withExtension: "txt"))
        let vocab = try Vocab(contentsOf: url)
        var rng = SplitMix64(seed: 0x5E215_4A5)
        for round in 0..<200 {
            let count = Int(rng.next() % 40)
            let ids = (0..<count).map { _ in Int(rng.next() % UInt64(vocab.tokens.count)) }
            let frames = ids.map { id -> [Float] in
                var row = [Float](repeating: 0, count: vocab.tokens.count)
                row[id] = 1
                return row
            }
            let text = CtcDecoder.decode(frames: frames, tokens: vocab.tokens, blankId: vocab.blankId)
            let why = "round \(round) ids \(ids) → \"\(text)\""
            #expect(!text.contains("▁"), Comment(rawValue: why))
            #expect(!text.contains("<unk>"), Comment(rawValue: why))
            #expect(!text.contains("<blk>"), Comment(rawValue: why))
            #expect(!text.contains("  "), Comment(rawValue: why))
            #expect(text == text.trimmingCharacters(in: .whitespaces), Comment(rawValue: why))
            // A space is only ever followed by a letter or a digit.
            for (a, b) in zip(text, text.dropFirst()) where a == " " {
                #expect(b.isLetter || b.isNumber, Comment(rawValue: why))
            }
        }
    }
}

/// Tiny deterministic generator so a failure is reproducible from the seed above.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
