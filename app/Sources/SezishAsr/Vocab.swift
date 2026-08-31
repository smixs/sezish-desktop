import Foundation

/// Token table for the GigaAM multilingual CTC model.
///
/// File format is one entry per line: `<token><space><id>`. Token id `0` is `▁`, the
/// sentencepiece word-boundary marker rendered as a space; the last entry is the CTC
/// blank `<blk>`.
public struct Vocab: Sendable {
    /// Tokens indexed by id: `tokens[id]` is the string emitted for that class.
    public let tokens: [String]

    /// The CTC blank id.
    public let blankId: Int

    public init(tokens: [String], blankId: Int) {
        self.tokens = tokens
        self.blankId = blankId
    }

    /// Parses the vocab file contents. Each line is `token id`; the array is ordered by the
    /// id column (not line position) and sized to `maxId + 1`.
    public init(text: String) throws {
        var pairs: [(id: Int, token: String)] = []
        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
            // Token and id are separated by the last whitespace run; the token itself
            // (e.g. "▁") never contains ASCII whitespace.
            guard let separator = line.lastIndex(where: { $0 == " " || $0 == "\t" }),
                  let id = Int(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
            else {
                throw SezishAsrError.badVocabLine(String(line))
            }
            pairs.append((id, String(line[..<separator])))
        }

        guard let maxId = pairs.map(\.id).max() else {
            throw SezishAsrError.badVocabLine("empty vocab")
        }

        var tokens = [String](repeating: "", count: maxId + 1)
        for pair in pairs { tokens[pair.id] = pair.token }
        self.tokens = tokens
        self.blankId = tokens.firstIndex(of: "<blk>") ?? maxId
    }

    public init(contentsOf url: URL) throws {
        try self.init(text: String(contentsOf: url, encoding: .utf8))
    }
}
