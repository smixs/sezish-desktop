use thiserror::Error;

/// Parsed token table indexed by class id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Vocab {
    /// Tokens indexed by id.
    pub tokens: Vec<String>,
    /// Class id of the CTC blank token.
    pub blank_id: usize,
}

/// Failures from parsing the bundled token table.
#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum VocabError {
    /// A non-empty line did not end in a parseable integer id.
    #[error("bad vocab line: {0}")]
    BadLine(String),
}

impl Vocab {
    /// Parses one token-and-id pair per non-empty line.
    pub fn parse(text: &str) -> Result<Self, VocabError> {
        let mut pairs = Vec::new();
        for line in text.lines().filter(|line| !line.is_empty()) {
            let Some(separator) = line.rfind([' ', '\t']) else {
                return Err(VocabError::BadLine(line.to_owned()));
            };
            let id = line[separator + 1..]
                .trim_matches([' ', '\t'])
                .parse::<usize>()
                .map_err(|_| VocabError::BadLine(line.to_owned()))?;
            pairs.push((id, &line[..separator]));
        }

        let max_id = pairs
            .iter()
            .map(|(id, _)| *id)
            .max()
            .ok_or_else(|| VocabError::BadLine("empty vocab".to_owned()))?;
        let mut tokens = vec![String::new(); max_id + 1];
        for (id, token) in pairs {
            tokens[id] = token.to_owned();
        }
        let blank_id = tokens
            .iter()
            .position(|token| token == "<blk>")
            .unwrap_or(max_id);

        Ok(Self { tokens, blank_id })
    }

    /// Parses the token table embedded in this crate.
    pub fn bundled() -> Result<Self, VocabError> {
        Self::parse(include_str!("../resources/multilingual_vocab.txt"))
    }
}

/// Pure greedy CTC decoder.
pub struct CtcDecoder;

impl CtcDecoder {
    /// SentencePiece word-boundary marker rendered as a space.
    pub const SPACE_MARKER: &'static str = "▁";

    /// Greedily decodes per-frame class scores.
    pub fn decode(frames: &[Vec<f32>], tokens: &[String], blank_id: usize) -> String {
        let mut previous = None;
        let mut text = String::new();

        for frame in frames {
            let best = frame.first().map(|first| {
                let mut best_index = 0;
                let mut best_value = first;
                for (index, value) in frame.iter().enumerate().skip(1) {
                    if value > best_value {
                        best_index = index;
                        best_value = value;
                    }
                }
                best_index
            });
            if best == previous {
                continue;
            }
            previous = best;
            if let Some(token) = best
                .filter(|&index| index != blank_id)
                .and_then(|index| tokens.get(index))
            {
                text.push_str(if token == Self::SPACE_MARKER {
                    " "
                } else {
                    token
                });
            }
        }

        text.split(' ')
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
    }
}

#[cfg(test)]
mod tests {
    use super::{CtcDecoder, Vocab, VocabError};

    fn tokens() -> Vec<String> {
        ["▁", "w", "o", "<blk>"]
            .into_iter()
            .map(str::to_owned)
            .collect()
    }

    #[test]
    fn repeat_frames_collapse_to_one_token() {
        let frames = vec![
            vec![0.0, 1.0, 0.0, 0.0],
            vec![0.0, 1.0, 0.0, 0.0],
            vec![0.0, 1.0, 0.0, 0.0],
            vec![0.0, 0.0, 1.0, 0.0],
            vec![0.0, 0.0, 1.0, 0.0],
        ];

        assert_eq!(CtcDecoder::decode(&frames, &tokens(), 3), "wo");
    }

    #[test]
    fn blank_between_identical_tokens_keeps_both_repeats() {
        let frames = vec![
            vec![0.0, 1.0, 0.0, 0.0],
            vec![0.0, 1.0, 0.0, 0.0],
            vec![0.0, 0.0, 0.0, 1.0],
            vec![0.0, 1.0, 0.0, 0.0],
            vec![0.0, 1.0, 0.0, 0.0],
        ];

        assert_eq!(CtcDecoder::decode(&frames, &tokens(), 3), "ww");
    }

    #[test]
    fn space_markers_collapse_and_trim_around_blank_gap() {
        let frames = vec![
            vec![1.0, 0.0, 0.0, 0.0],
            vec![0.0, 0.0, 0.0, 1.0],
            vec![1.0, 0.0, 0.0, 0.0],
            vec![0.0, 1.0, 0.0, 0.0],
        ];

        assert_eq!(CtcDecoder::decode(&frames, &tokens(), 3), "w");
    }

    #[test]
    fn vocab_is_ordered_by_id_not_file_position() {
        let vocab = Vocab::parse("▁ 0\nb 2\na 1\n<blk> 3\n").expect("valid vocab should parse");

        assert_eq!(vocab.tokens, vec!["▁", "a", "b", "<blk>"]);
        assert_eq!(vocab.blank_id, 3);
    }

    #[test]
    fn vocab_line_without_parseable_id_is_rejected() {
        let error = Vocab::parse("not-a-valid-line").expect_err("bad line should fail");

        assert_eq!(error, VocabError::BadLine("not-a-valid-line".to_owned()));
    }

    #[test]
    fn bundled_vocab_parses_and_starts_with_space_marker() {
        let vocab = Vocab::bundled().expect("bundled vocab should parse");

        assert_eq!(vocab.tokens.first().map(String::as_str), Some("▁"));
    }

    #[test]
    fn argmax_ties_keep_earliest_index() {
        let frames = vec![vec![0.0, 1.0, 1.0, 0.0]];

        assert_eq!(CtcDecoder::decode(&frames, &tokens(), 3), "w");
    }
}
