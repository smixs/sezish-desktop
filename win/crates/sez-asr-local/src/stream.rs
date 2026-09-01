//! One dictation transcribed while it is still being recorded.
//!
//! The recording is cut into chunks by [`StreamCutter`], and every chunk whose end is already
//! decided goes through the model at once, so releasing the hotkey costs the tail alone
//! instead of the whole take.

use crate::chunker::StreamCutter;

/// What one take accumulates between its first sample and the release of the hotkey.
///
/// The caller holds this behind a lock and hands it the inference callback, which is how the
/// chunks reach the model in the order they were spoken: a drain that arrives while another
/// one is running waits, then picks up the samples the first one did not have yet.
pub struct StreamTake<E> {
    cutter: StreamCutter,
    parts: Vec<String>,
    /// The first chunk that failed. It fails the whole take: half a transcript silently
    /// missing its middle is worse than none, and the caller keeps the audio and the reason so
    /// the user can run it again.
    failure: Option<E>,
    fed: usize,
    open: bool,
}

impl<E> StreamTake<E> {
    /// A closed take with the shipped chunk limit.
    pub fn new() -> Self {
        Self::with_cutter(StreamCutter::new())
    }

    /// [`StreamTake::new`] over a cutter with test-sized limits.
    pub fn with_cutter(cutter: StreamCutter) -> Self {
        Self {
            cutter,
            parts: Vec::new(),
            failure: None,
            fed: 0,
            open: false,
        }
    }

    /// Opens a take, discarding whatever the previous one left behind.
    pub fn start(&mut self) {
        self.cutter.take_rest();
        self.parts.clear();
        self.failure = None;
        self.fed = 0;
        self.open = true;
    }

    /// Whether a take is being recorded right now.
    pub fn is_open(&self) -> bool {
        self.open
    }

    /// How many samples this take has seen. The caller compares it against the recording the
    /// microphone returned: a stream that did not cover the take must not be trusted.
    pub fn fed(&self) -> usize {
        self.fed
    }

    /// Buffers samples captured since the last call. No inference happens here: this runs on
    /// the thread that drains the capture ring.
    pub fn append(&mut self, samples: &[f32]) {
        self.fed += samples.len();
        self.cutter.append(samples);
    }

    /// Transcribes every chunk the take has completed so far, oldest first. Stops at the first
    /// failure and keeps it for [`StreamTake::finish`].
    pub fn transcribe_ready(&mut self, mut run: impl FnMut(&[f32]) -> Result<String, E>) {
        if !self.open || self.failure.is_some() {
            return;
        }
        while let Some(chunk) = self.cutter.next_chunk() {
            match run(&chunk) {
                Ok(text) => {
                    if !text.is_empty() {
                        self.parts.push(text);
                    }
                }
                Err(error) => {
                    self.failure = Some(error);
                    return;
                }
            }
        }
    }

    /// Closes the take and returns its transcript: the chunks already done plus the tail, which
    /// is what is left once the recording stops and is never longer than one chunk.
    ///
    /// # Errors
    ///
    /// Returns the failure of the first chunk that did not make it through the model, or the
    /// failure of the tail. Neither returns partial text.
    pub fn finish(
        &mut self,
        mut run: impl FnMut(&[f32]) -> Result<String, E>,
    ) -> Result<String, E> {
        self.transcribe_ready(&mut run);
        self.open = false;
        let rest = self.cutter.take_rest();
        let mut parts = std::mem::take(&mut self.parts);
        self.fed = 0;
        if let Some(failure) = self.failure.take() {
            return Err(failure);
        }

        // A take released exactly on a chunk boundary has no tail, and an empty buffer is not
        // something the model is asked to swallow.
        if !rest.is_empty() {
            let tail = run(&rest)?;
            if !tail.is_empty() {
                parts.push(tail);
            }
        }
        Ok(parts.join(" "))
    }

    /// Drops the take without transcribing anything left in it.
    pub fn discard(&mut self) {
        self.cutter.take_rest();
        self.parts.clear();
        self.failure = None;
        self.fed = 0;
        self.open = false;
    }
}

impl<E> Default for StreamTake<E> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::{StreamCutter, StreamTake};

    /// Loud enough that no probe window reads as silence, so the cuts land on the limit and
    /// the chunk boundaries are predictable.
    fn speech(count: usize) -> Vec<f32> {
        (0..count)
            .map(|index| {
                (0.4 * (2.0 * std::f64::consts::PI * 220.0 * index as f64 / 16_000.0).sin()) as f32
            })
            .collect()
    }

    fn take() -> StreamTake<String> {
        StreamTake::with_cutter(StreamCutter::with_limits(1_000, 250))
    }

    #[test]
    fn chunks_reach_the_model_in_the_order_they_were_spoken() {
        let mut take = take();
        let samples = speech(2_500);
        let mut seen = Vec::new();

        take.start();
        for block in samples.chunks(300) {
            take.append(block);
            take.transcribe_ready(|chunk| {
                seen.push(chunk.len());
                Ok(format!("part{}", seen.len()))
            });
        }
        let text = take
            .finish(|chunk| {
                seen.push(chunk.len());
                Ok(format!("part{}", seen.len()))
            })
            .expect("no chunk failed");

        assert_eq!(seen, vec![1_000, 1_000, 500]);
        assert_eq!(text, "part1 part2 part3");
    }

    #[test]
    fn nothing_runs_before_a_chunk_is_certain() {
        let mut take = take();
        let mut runs = 0;

        take.start();
        take.append(&speech(1_000));
        take.transcribe_ready(|_| {
            runs += 1;
            Ok(String::new())
        });

        assert_eq!(runs, 0);
        assert_eq!(take.fed(), 1_000);
    }

    #[test]
    fn a_failed_chunk_fails_the_take_with_its_own_cause_and_no_partial_text() {
        let mut take = take();
        let mut runs = 0;

        take.start();
        take.append(&speech(3_500));
        take.transcribe_ready(|_| {
            runs += 1;
            if runs == 2 {
                Err("broadcast an axis by a dimension other than 1".to_owned())
            } else {
                Ok("part".to_owned())
            }
        });
        let result = take.finish(|_| Ok("tail".to_owned()));

        // The third chunk was ready and was not run, and the tail did not replace the error.
        assert_eq!(runs, 2);
        assert_eq!(
            result,
            Err("broadcast an axis by a dimension other than 1".to_owned())
        );
    }

    #[test]
    fn a_new_take_keeps_nothing_of_the_one_before_it() {
        let mut take = take();

        take.start();
        take.append(&speech(1_500));
        take.transcribe_ready(|_| Ok("stale".to_owned()));
        take.start();
        take.append(&speech(400));
        let text = take
            .finish(|chunk| Ok(format!("len{}", chunk.len())))
            .expect("no chunk failed");

        assert_eq!(text, "len400");
        assert!(!take.is_open());
    }
}
