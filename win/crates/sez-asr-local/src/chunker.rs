//! Cuts a long recording into pieces the local model can swallow.
//!
//! The model is trained on short utterances: past roughly 30 s of audio in one tensor the CTC
//! output degrades into mush, and past 200 s the session throws outright ("Attempting to
//! broadcast an axis by a dimension other than 1"), because the ONNX export carries a
//! self-attention mask baked for 5000 encoder frames. So anything longer is cut, preferably
//! where nobody is speaking: a boundary through the middle of a word costs both chunks their
//! last and first token.

use std::ops::Range;

/// 30 s at 16 kHz, the length past which the model starts losing words.
pub const DEFAULT_LIMIT: usize = 30 * 16_000;

/// How far back from the ideal boundary a quiet spot is worth looking for.
pub const SEARCH_WINDOW: usize = 10 * 16_000;

/// Energy window whose middle becomes the cut. 200 ms is longer than the closure inside a word
/// and shorter than the pause between sentences. Together with the 50 ms hop it means any
/// silence of 250 ms or more has a window entirely inside it.
const PROBE_WINDOW: usize = 3_200;
const PROBE_HOP: usize = 800;

/// Below this RMS the probe window counts as silence. Roughly -40 dBFS: quiet enough that no
/// phoneme survives in it, loud enough to still be found in a noisy room.
const SILENCE_RMS: f32 = 0.01;

/// Consecutive ranges covering every sample exactly once, none longer than [`DEFAULT_LIMIT`].
pub fn split(samples: &[f32]) -> Vec<Range<usize>> {
    split_with(samples, DEFAULT_LIMIT, SEARCH_WINDOW)
}

/// [`split`] with the limit and search window spelled out, for tests that cannot afford
/// minutes of synthetic audio.
///
/// # Panics
///
/// Panics when `limit` is zero: no set of ranges satisfies it.
pub fn split_with(samples: &[f32], limit: usize, search_window: usize) -> Vec<Range<usize>> {
    assert!(limit > 0, "limit must be positive");
    if samples.is_empty() {
        return Vec::new();
    }

    let mut ranges = Vec::new();
    let mut start = 0;
    while let Some(cut) = next_cut(samples, start, limit, search_window) {
        ranges.push(start..cut);
        start = cut;
    }
    ranges.push(start..samples.len());
    ranges
}

/// Where the chunk starting at `start` ends, or `None` when what is left already fits in
/// `limit`. Only samples before the boundary decide it, so a recording still being spoken gets
/// the same answer here as the finished one gets from [`split`].
fn next_cut(samples: &[f32], start: usize, limit: usize, search_window: usize) -> Option<usize> {
    if samples.len() - start <= limit {
        return None;
    }
    let hard = start + limit;
    // The quiet spot is searched for behind the ideal boundary only: moving it forward would
    // push the chunk past the limit the whole exercise is about.
    let earliest = (start + 1).max(hard.saturating_sub(search_window));
    Some(quietest_cut(samples, earliest, hard).unwrap_or(hard))
}

/// The streaming half of the chunker: samples arrive a little at a time and a chunk leaves as
/// soon as its end is certain, which is the moment more than `limit` is buffered.
///
/// Because [`next_cut`] reads nothing past the boundary it returns, the chunks that come out
/// here are exactly the ones [`split`] produces over the same recording once it is finished.
pub struct StreamCutter {
    pending: Vec<f32>,
    limit: usize,
    search_window: usize,
}

impl StreamCutter {
    /// A cutter with the shipped limit and search window.
    pub fn new() -> Self {
        Self::with_limits(DEFAULT_LIMIT, SEARCH_WINDOW)
    }

    /// [`StreamCutter::new`] with the limit and search window spelled out, for tests that
    /// cannot afford minutes of synthetic audio.
    ///
    /// # Panics
    ///
    /// Panics when `limit` is zero: no chunk satisfies it.
    pub fn with_limits(limit: usize, search_window: usize) -> Self {
        assert!(limit > 0, "limit must be positive");
        Self {
            pending: Vec::new(),
            limit,
            search_window,
        }
    }

    /// Buffers the samples captured since the last call.
    pub fn append(&mut self, samples: &[f32]) {
        self.pending.extend_from_slice(samples);
    }

    /// The next chunk whose boundary is already decided, or `None` while everything buffered
    /// still fits one chunk and could yet grow into it.
    pub fn next_chunk(&mut self) -> Option<Vec<f32>> {
        let cut = next_cut(&self.pending, 0, self.limit, self.search_window)?;
        Some(self.pending.drain(..cut).collect())
    }

    /// Everything left over once the recording is over. Never longer than the limit.
    pub fn take_rest(&mut self) -> Vec<f32> {
        std::mem::take(&mut self.pending)
    }
}

impl Default for StreamCutter {
    fn default() -> Self {
        Self::new()
    }
}

/// Middle of the quietest probe window in `from..to`, or `None` when the whole stretch is
/// speech: then the caller cuts hard and pays for one mangled word.
fn quietest_cut(samples: &[f32], from: usize, to: usize) -> Option<usize> {
    if from >= to {
        return None;
    }
    // A partial window would be measured over a handful of samples, and a zero crossing inside
    // a vowel reads as quiet as a real pause. Only whole windows are compared; a search range
    // too short for one is measured as a single window.
    let width = PROBE_WINDOW.min(to - from);
    let mut best: Option<(f32, usize)> = None;
    let mut probe = from;
    while probe + width <= to {
        let level = rms(&samples[probe..probe + width]);
        if best.is_none_or(|(quietest, _)| level < quietest) {
            best = Some((level, probe + width / 2));
        }
        probe += PROBE_HOP;
    }

    let (level, cut) = best?;
    (level < SILENCE_RMS).then_some(cut)
}

fn rms(window: &[f32]) -> f32 {
    if window.is_empty() {
        return f32::INFINITY;
    }
    let sum: f32 = window.iter().map(|sample| sample * sample).sum();
    (sum / window.len() as f32).sqrt()
}

#[cfg(test)]
mod tests {
    use super::{split, split_with, StreamCutter, DEFAULT_LIMIT};

    /// Loud enough that no probe window reads as silence.
    fn speech(count: usize) -> Vec<f32> {
        (0..count)
            .map(|index| {
                (0.4 * (2.0 * std::f64::consts::PI * 220.0 * index as f64 / 16_000.0).sin()) as f32
            })
            .collect()
    }

    #[test]
    fn empty_audio_produces_no_chunks() {
        assert!(split_with(&[], 1_000, 250).is_empty());
    }

    #[test]
    fn audio_shorter_than_the_limit_is_not_split() {
        assert_eq!(
            split_with(&speech(99_999), 100_000, 20_000),
            vec![0..99_999]
        );
    }

    #[test]
    fn exactly_the_limit_is_not_split() {
        assert_eq!(
            split_with(&speech(100_000), 100_000, 20_000),
            vec![0..100_000]
        );
    }

    #[test]
    fn one_sample_past_the_limit_is_split() {
        let chunks = split_with(&speech(100_001), 100_000, 20_000);

        assert_eq!(chunks.len(), 2);
        assert!(chunks.iter().all(|chunk| !chunk.is_empty()));
        assert_eq!(chunks.last().map(|chunk| chunk.end), Some(100_001));
    }

    #[test]
    fn chunks_cover_every_sample_once_in_order() {
        let cases = [
            (0, 1_000),
            (1, 1_000),
            (999, 1_000),
            (1_000, 1_000),
            (1_001, 1_000),
            (7, 3),
            (250_000, 100_000),
            (1_000_000, 100_000),
            (333_333, 40_000),
            (2, 1),
            (100_000, 7),
        ];

        for (count, limit) in cases {
            let chunks = split_with(&speech(count), limit, limit / 4);

            assert!(
                chunks.iter().all(|chunk| chunk.len() <= limit),
                "{count} samples at limit {limit}: a chunk is longer than the limit"
            );
            assert!(
                chunks.iter().all(|chunk| !chunk.is_empty()),
                "{count} samples at limit {limit}: an empty chunk"
            );
            // Contiguous from the first sample to the last: nothing dropped, nothing heard
            // twice, nothing reordered.
            assert_eq!(
                chunks.first().map_or(0, |chunk| chunk.start),
                0,
                "{count} samples at limit {limit}: does not start at the first sample"
            );
            assert_eq!(
                chunks.last().map_or(0, |chunk| chunk.end),
                count,
                "{count} samples at limit {limit}: does not end at the last sample"
            );
            for pair in chunks.windows(2) {
                assert_eq!(
                    pair[0].end, pair[1].start,
                    "{count} samples at limit {limit}: a gap between chunks"
                );
            }
        }
    }

    #[test]
    fn the_cut_lands_in_the_silence_before_the_limit() {
        let mut samples = speech(250_000);
        let gap = 85_000..91_000;
        samples[gap.clone()].fill(0.0);

        let chunks = split_with(&samples, 100_000, 20_000);

        assert!(gap.contains(&chunks[0].end), "cut at {}", chunks[0].end);
    }

    #[test]
    fn uninterrupted_speech_is_cut_at_the_limit() {
        let chunks = split_with(&speech(250_000), 100_000, 20_000);

        assert_eq!(chunks[0].end, 100_000);
    }

    /// Silence outside the search window is not worth a chunk 40% shorter than it could be.
    #[test]
    fn silence_too_far_back_is_ignored() {
        let mut samples = speech(250_000);
        samples[40_000..46_000].fill(0.0);

        let chunks = split_with(&samples, 100_000, 20_000);

        assert_eq!(chunks[0].end, 100_000);
    }

    /// Every boundary of a long recording gets its own quiet spot, not just the first one.
    #[test]
    fn every_boundary_looks_for_its_own_silence() {
        let mut samples = speech(300_000);
        let gaps = [88_000..92_000, 186_000..190_000];
        for gap in gaps.clone() {
            samples[gap].fill(0.0);
        }

        let chunks = split_with(&samples, 100_000, 20_000);

        assert!(chunks.len() >= 3);
        assert!(gaps[0].contains(&chunks[0].end), "cut at {}", chunks[0].end);
        assert!(gaps[1].contains(&chunks[1].end), "cut at {}", chunks[1].end);
    }

    /// The shipped numbers: 30 s of audio per chunk, far under the 200 s the ONNX attention
    /// mask is baked for.
    #[test]
    fn the_default_limit_keeps_chunks_short() {
        assert_eq!(DEFAULT_LIMIT, 30 * 16_000);

        let chunks = split(&speech(16_000 * 100));

        assert_eq!(chunks.len(), 4);
        assert!(chunks.iter().all(|chunk| chunk.len() <= DEFAULT_LIMIT));
    }

    /// Feeds the whole recording through the cutter in blocks of `block` samples and returns
    /// the chunks it produced, the last one being what the release of the hotkey leaves.
    fn stream(samples: &[f32], block: usize, limit: usize, search_window: usize) -> Vec<Vec<f32>> {
        let mut cutter = StreamCutter::with_limits(limit, search_window);
        let mut chunks = Vec::new();
        for part in samples.chunks(block) {
            cutter.append(part);
            while let Some(chunk) = cutter.next_chunk() {
                chunks.push(chunk);
            }
        }
        chunks.push(cutter.take_rest());
        chunks
    }

    /// The point of the exercise: a recording cut while it is still being spoken comes out
    /// exactly as the finished one does, whatever size the capture blocks happen to be.
    #[test]
    fn streamed_chunks_match_the_ones_split_produces() {
        let mut samples = speech(250_000);
        for gap in [85_000..91_000, 180_000..186_000] {
            samples[gap].fill(0.0);
        }

        for block in [1, 999, 4_096, 100_000, 250_000] {
            let chunks = stream(&samples, block, 100_000, 20_000);
            let ranges = split_with(&samples, 100_000, 20_000);

            assert_eq!(
                chunks.iter().map(Vec::len).collect::<Vec<_>>(),
                ranges.iter().map(std::ops::Range::len).collect::<Vec<_>>(),
                "block {block}: the stream cut somewhere else"
            );
            assert_eq!(
                chunks.concat(),
                samples,
                "block {block}: the stream lost or reordered samples"
            );
        }
    }

    /// A chunk is only certain once the buffer outgrows the limit: until then the samples
    /// could still turn out to belong to it.
    #[test]
    fn nothing_leaves_while_the_buffer_could_still_be_one_chunk() {
        let samples = speech(100_001);
        let mut cutter = StreamCutter::with_limits(100_000, 20_000);

        cutter.append(&samples[..100_000]);
        assert!(cutter.next_chunk().is_none());

        cutter.append(&samples[100_000..]);
        assert!(cutter.next_chunk().is_some());
        assert!(cutter.next_chunk().is_none());
        assert_eq!(cutter.take_rest().len(), 1);
    }
}
