import Foundation

/// Greedy CTC decoding for the GigaAM acoustic model.
///
/// Pure and stateless: given per-timestep logit rows it returns the decoded text.
public enum CtcDecoder {
    /// Sentencepiece word-boundary marker, rendered as a space.
    static let spaceMarker = "▁"

    /// Token the model emits for something outside its vocabulary; never shown.
    static let unknownToken = "<unk>"

    /// Decodes greedy CTC output.
    ///
    /// Pipeline: argmax per frame → collapse consecutive duplicates → drop blank and
    /// `<unk>` → map id → token with every `▁` rendered as a space → keep a space only
    /// where a letter or digit follows (so punctuation hugs the previous word) → trim.
    /// Works for character-level and subword vocabs alike: in the former `▁` is a
    /// token of its own, in the latter a prefix inside tokens.
    ///
    /// - Parameters:
    ///   - frames: per-timestep logit rows, each of length `tokens.count`.
    ///   - tokens: id → token string.
    ///   - blankId: the CTC blank id to discard.
    public static func decode(frames: [[Float]], tokens: [String], blankId: Int) -> String {
        var ids: [Int] = []
        var previous = -1
        for frame in frames {
            guard let best = argmax(frame) else { continue }
            if best != previous { ids.append(best) }
            previous = best
        }

        var raw = ""
        for id in ids where id != blankId {
            guard id >= 0, id < tokens.count else { continue }
            let token = tokens[id]
            guard token != unknownToken else { continue }
            raw += token.replacingOccurrences(of: spaceMarker, with: " ")
        }

        var text = ""
        var pendingSpace = false
        for character in raw {
            if character == " " {
                pendingSpace = !text.isEmpty
                continue
            }
            if pendingSpace, character.isLetter || character.isNumber {
                text.append(" ")
            }
            pendingSpace = false
            text.append(character)
        }
        return text
    }

    private static func argmax(_ row: [Float]) -> Int? {
        guard var bestValue = row.first else { return nil }
        var bestIndex = 0
        for index in 1..<row.count where row[index] > bestValue {
            bestValue = row[index]
            bestIndex = index
        }
        return bestIndex
    }
}
