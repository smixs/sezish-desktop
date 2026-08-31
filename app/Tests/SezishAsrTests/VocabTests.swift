import Foundation
import Testing
@testable import SezishAsr

@Suite struct VocabTests {
    private func loadFixture() throws -> Vocab {
        let url = try #require(
            Bundle.module.url(forResource: "multilingual_vocab", withExtension: "txt")
        )
        return try Vocab(contentsOf: url)
    }

    @Test func parsesRealVocabFixture() throws {
        let vocab = try loadFixture()
        #expect(vocab.tokens.count == 71)
        #expect(vocab.tokens[0] == "▁")
        #expect(vocab.tokens[1] == "'")
        #expect(vocab.tokens[2] == "a")
        #expect(vocab.tokens[70] == "<blk>")
        #expect(vocab.blankId == 70)
    }

    @Test func parsesSubwordVocabFixture() throws {
        let url = try #require(
            Bundle.module.url(forResource: "v3_e2e_ctc_vocab", withExtension: "txt")
        )
        let vocab = try Vocab(contentsOf: url)
        #expect(vocab.tokens.count == 257)
        #expect(vocab.tokens[0] == "<unk>")
        #expect(vocab.tokens[1] == "▁")
        #expect(vocab.tokens[2] == ".")
        #expect(vocab.tokens[256] == "<blk>")
        #expect(vocab.blankId == 256)
    }

    @Test func parsesInlineText() throws {
        let vocab = try Vocab(text: "▁ 0\na 1\n<blk> 2\n")
        #expect(vocab.tokens == ["▁", "a", "<blk>"])
        #expect(vocab.blankId == 2)
    }
}
