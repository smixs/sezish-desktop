//! File-backed FIFO history for completed dictations.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use sez_core::{wav::encode_pcm16_mono_16k, History, HistoryEntry, SezError};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const INDEX_FILE_NAME: &str = "index.json";
/// `sez_core::wav::encode_pcm16_mono_16k` writes the canonical 44-byte header.
const WAV_HEADER_BYTES: usize = 44;

/// File-backed history storing metadata in `index.json` and audio in sibling WAV files.
pub struct FileHistory {
    directory: PathBuf,
    max_count: usize,
    records: Vec<StoredRecord>,
    now: fn() -> SystemTime,
}

impl FileHistory {
    /// Default maximum number of dictations retained on disk.
    pub const DEFAULT_CAPACITY: usize = 10;

    /// Creates or loads a history directory with the default capacity of 10 dictations.
    pub fn new(directory: impl AsRef<Path>) -> Result<Self, SezError> {
        Self::with_capacity(directory, Self::DEFAULT_CAPACITY)
    }

    /// Creates or loads a history directory with a caller-supplied FIFO capacity.
    pub fn with_capacity(directory: impl AsRef<Path>, max_count: usize) -> Result<Self, SezError> {
        Self::with_capacity_and_clock(directory, max_count, SystemTime::now)
    }

    fn with_capacity_and_clock(
        directory: impl AsRef<Path>,
        max_count: usize,
        now: fn() -> SystemTime,
    ) -> Result<Self, SezError> {
        let directory = directory.as_ref().to_path_buf();
        fs::create_dir_all(&directory)?;
        let records = Self::load_records(&directory.join(INDEX_FILE_NAME));

        Ok(Self {
            directory,
            max_count,
            records,
            now,
        })
    }

    fn load_records(index_path: &Path) -> Vec<StoredRecord> {
        let Ok(index) = fs::read(index_path) else {
            return Vec::new();
        };
        let Ok(records) = serde_json::from_slice::<Vec<StoredRecord>>(&index) else {
            return Vec::new();
        };

        if records.iter().all(StoredRecord::is_valid) {
            records
        } else {
            Vec::new()
        }
    }

    /// Only takes with text count against the capacity: one whose text never came
    /// out keeps its audio until a retry recovers it (Mac `evictOverflow`).
    fn evict_overflow(&mut self) {
        while self
            .records
            .iter()
            .filter(|record| !record.text.is_empty())
            .count()
            > self.max_count
        {
            let Some(oldest) = self
                .records
                .iter()
                .position(|record| !record.text.is_empty())
            else {
                return;
            };
            let removed = self.records.remove(oldest);
            let _ = fs::remove_file(self.directory.join(removed.audio_file));
        }
    }

    /// `newest_index` counts from the newest, as `recent` lists them.
    fn position(&self, newest_index: usize) -> Result<usize, SezError> {
        self.records
            .len()
            .checked_sub(newest_index + 1)
            .ok_or_else(|| SezError::Other("history index is outside the list".to_owned()))
    }

    /// Where a take's audio lies, for «Послушать».
    pub fn audio_path(&self, newest_index: usize) -> Result<PathBuf, SezError> {
        let record = &self.records[self.position(newest_index)?];
        Ok(self.directory.join(&record.audio_file))
    }

    /// The take's audio as it was recorded, for «Распознать заново».
    pub fn samples(&self, newest_index: usize) -> Result<Vec<i16>, SezError> {
        let bytes = fs::read(self.audio_path(newest_index)?)?;
        let pcm = bytes.get(WAV_HEADER_BYTES..).ok_or_else(|| {
            SezError::Other("history audio is shorter than its header".to_owned())
        })?;
        Ok(pcm
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| i16::from_le_bytes(*pair))
            .collect())
    }

    /// A retry's text replaces the stored one; id, date and audio stay.
    pub fn update_text(&mut self, newest_index: usize, text: &str) -> Result<(), SezError> {
        let position = self.position(newest_index)?;
        self.records[position].text = text.to_owned();
        self.evict_overflow();
        self.persist()
    }

    fn persist(&self) -> Result<(), SezError> {
        let index = serde_json::to_vec(&self.records)
            .map_err(|error| SezError::Other(error.to_string()))?;
        fs::write(self.directory.join(INDEX_FILE_NAME), index)?;
        Ok(())
    }
}

#[async_trait]
impl History for FileHistory {
    async fn record(&mut self, text: &str, audio: &[i16]) -> Result<(), SezError> {
        let id = Uuid::new_v4().to_string();
        let audio_file = format!("{id}.wav");
        fs::write(
            self.directory.join(&audio_file),
            encode_pcm16_mono_16k(audio),
        )?;

        let elapsed = (self.now)()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| SezError::Other(error.to_string()))?;
        self.records.push(StoredRecord {
            id,
            audio_file,
            text: text.to_owned(),
            recorded_at: StoredTimestamp::from(elapsed),
        });

        self.evict_overflow();
        self.persist()
    }

    async fn recent(&self) -> Result<Vec<HistoryEntry>, SezError> {
        self.records
            .iter()
            .rev()
            .map(StoredRecord::history_entry)
            .collect()
    }
}

#[derive(Debug, Deserialize, Serialize)]
struct StoredRecord {
    id: String,
    audio_file: String,
    text: String,
    recorded_at: StoredTimestamp,
}

impl StoredRecord {
    fn is_valid(&self) -> bool {
        self.audio_file == format!("{}.wav", self.id)
            && !self.audio_file.contains(['/', '\\'])
            && self.recorded_at.is_valid()
    }

    fn history_entry(&self) -> Result<HistoryEntry, SezError> {
        Ok(HistoryEntry {
            text: self.text.clone(),
            recorded_at: UNIX_EPOCH
                .checked_add(self.recorded_at.duration()?)
                .ok_or_else(|| SezError::Other("history timestamp is out of range".to_owned()))?,
        })
    }
}

#[derive(Debug, Deserialize, Serialize)]
struct StoredTimestamp {
    seconds: u64,
    nanoseconds: u32,
}

impl StoredTimestamp {
    fn is_valid(&self) -> bool {
        self.nanoseconds < 1_000_000_000
            && UNIX_EPOCH
                .checked_add(Duration::new(self.seconds, self.nanoseconds))
                .is_some()
    }

    fn duration(&self) -> Result<Duration, SezError> {
        if self.nanoseconds >= 1_000_000_000 {
            return Err(SezError::Other(
                "history timestamp has invalid nanoseconds".to_owned(),
            ));
        }
        Ok(Duration::new(self.seconds, self.nanoseconds))
    }
}

impl From<Duration> for StoredTimestamp {
    fn from(duration: Duration) -> Self {
        Self {
            seconds: duration.as_secs(),
            nanoseconds: duration.subsec_nanos(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::FileHistory;
    use serde_json::Value;
    use sez_core::{wav::encode_pcm16_mono_16k, History};
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};
    use tempfile::TempDir;

    fn fixed_now() -> SystemTime {
        UNIX_EPOCH + Duration::new(1_753_662_896, 123_456_789)
    }

    fn history(directory: &Path) -> FileHistory {
        history_with_capacity(directory, FileHistory::DEFAULT_CAPACITY)
    }

    fn history_with_capacity(directory: &Path, max_count: usize) -> FileHistory {
        FileHistory::with_capacity_and_clock(directory, max_count, fixed_now)
            .expect("history should be created")
    }

    fn index_records(directory: &Path) -> Vec<Value> {
        let index = fs::read(directory.join("index.json")).expect("index should be readable");
        serde_json::from_slice(&index).expect("index should contain valid JSON")
    }

    fn wav_file_name(record: &Value) -> &str {
        record["audio_file"]
            .as_str()
            .expect("record should contain an audio file name")
    }

    fn only_wav_path(directory: &Path) -> PathBuf {
        let mut wav_paths: Vec<_> = fs::read_dir(directory)
            .expect("history directory should be readable")
            .map(|entry| entry.expect("directory entry should be readable").path())
            .filter(|path| path.extension().is_some_and(|extension| extension == "wav"))
            .collect();
        assert_eq!(wav_paths.len(), 1, "expected exactly one WAV file");
        wav_paths.pop().expect("one WAV path should exist")
    }

    #[tokio::test]
    async fn fresh_history_is_empty() {
        let directory = TempDir::new().expect("temp directory should be created");
        let history = history(directory.path());

        assert_eq!(
            history.recent().await.expect("recent should succeed"),
            Vec::new()
        );
    }

    #[tokio::test]
    async fn eleventh_dictation_evicts_oldest_entry_and_its_wav() {
        let directory = TempDir::new().expect("temp directory should be created");
        let mut history = history_with_capacity(directory.path(), 10);

        history
            .record("oldest", &[1, -1])
            .await
            .expect("first dictation should be recorded");
        let oldest_record = index_records(directory.path())
            .pop()
            .expect("first index record should exist");
        let oldest_wav = directory.path().join(wav_file_name(&oldest_record));
        assert!(oldest_wav.exists(), "oldest WAV should initially exist");

        for number in 1..=10 {
            history
                .record(&format!("dictation {number}"), &[number, -number])
                .await
                .expect("dictation should be recorded");
        }

        let recent = history.recent().await.expect("recent should succeed");
        assert_eq!(recent.len(), 10);
        assert_eq!(recent[0].text, "dictation 10");
        assert_eq!(recent[9].text, "dictation 1");
        assert!(recent.iter().all(|entry| entry.text != "oldest"));
        assert!(
            !oldest_wav.exists(),
            "evicted dictation's WAV should be deleted"
        );

        let persisted = index_records(directory.path());
        assert_eq!(persisted.len(), 10);
        assert!(persisted
            .iter()
            .all(|record| record["text"].as_str() != Some("oldest")));
    }

    #[tokio::test]
    async fn index_roundtrips_entries_and_timestamps_newest_first() {
        let directory = TempDir::new().expect("temp directory should be created");
        let mut first = history(directory.path());

        for text in ["first", "second", "third"] {
            first
                .record(text, &[10, 20, 30])
                .await
                .expect("dictation should be recorded");
        }
        let before_reload = first.recent().await.expect("recent should succeed");
        drop(first);

        let reloaded = history(directory.path());
        let after_reload = reloaded.recent().await.expect("recent should succeed");

        assert_eq!(
            after_reload
                .iter()
                .map(|entry| entry.text.as_str())
                .collect::<Vec<_>>(),
            vec!["third", "second", "first"]
        );
        assert_eq!(after_reload, before_reload);
        assert!(after_reload
            .iter()
            .all(|entry| entry.recorded_at == fixed_now()));
    }

    #[tokio::test]
    async fn empty_text_and_audio_survive_reload() {
        let directory = TempDir::new().expect("temp directory should be created");
        let samples = [i16::MIN, 0, i16::MAX];
        let mut first = history(directory.path());

        first
            .record("", &samples)
            .await
            .expect("empty-text dictation should be recorded");
        let record = index_records(directory.path())
            .pop()
            .expect("index record should exist");
        let wav_path = directory.path().join(wav_file_name(&record));
        drop(first);

        let reloaded = history(directory.path());
        let recent = reloaded.recent().await.expect("recent should succeed");

        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].text, "");
        assert_eq!(
            fs::read(wav_path).expect("empty-text WAV should remain readable"),
            encode_pcm16_mono_16k(&samples)
        );
    }

    #[tokio::test]
    async fn corrupt_index_loads_empty_and_next_record_repairs_it() {
        let directory = TempDir::new().expect("temp directory should be created");
        fs::write(directory.path().join("index.json"), b"{truncated")
            .expect("corrupt index should be written");

        let mut history = history(directory.path());
        assert!(history
            .recent()
            .await
            .expect("recent should succeed")
            .is_empty());

        history
            .record("recovered", &[7, 8, 9])
            .await
            .expect("recording should recover from a corrupt index");

        let records = index_records(directory.path());
        assert_eq!(records.len(), 1);
        assert_eq!(records[0]["text"], "recovered");
        assert!(directory.path().join(wav_file_name(&records[0])).exists());
    }

    #[tokio::test]
    async fn wav_file_matches_sez_core_encoder() {
        let directory = TempDir::new().expect("temp directory should be created");
        let samples = [0, 1, -1, i16::MAX, i16::MIN];
        let mut history = history(directory.path());

        history
            .record("audio", &samples)
            .await
            .expect("dictation should be recorded");

        let actual = fs::read(only_wav_path(directory.path())).expect("WAV should be readable");
        let canonical = encode_pcm16_mono_16k(&samples);
        assert_eq!(&actual[..44], &canonical[..44]);
        assert_eq!(actual, canonical);
    }

    #[tokio::test]
    async fn index_serializes_only_relative_wav_file_names() {
        let directory = TempDir::new().expect("temp directory should be created");
        let mut history = history(directory.path());

        history
            .record("one", &[1])
            .await
            .expect("first dictation should be recorded");
        history
            .record("two", &[2])
            .await
            .expect("second dictation should be recorded");

        let raw_index =
            fs::read_to_string(directory.path().join("index.json")).expect("index should be UTF-8");
        let records: Vec<Value> =
            serde_json::from_str(&raw_index).expect("index should contain valid JSON");
        for record in records {
            let audio_file = wav_file_name(&record);
            assert!(audio_file.ends_with(".wav"));
            assert!(!audio_file.contains('/'));
            assert!(!audio_file.contains('\\'));
            assert!(!Path::new(audio_file).is_absolute());
            assert_eq!(Path::new(audio_file).components().count(), 1);
        }
        assert!(
            !raw_index.contains(
                directory
                    .path()
                    .to_str()
                    .expect("temp directory should be UTF-8")
            ),
            "serialized index must not contain the absolute history directory"
        );
    }

    /// Mac `DictationHistory`: a take whose text never came out keeps its audio
    /// outside the FIFO, so it can still be recognised again later.
    #[tokio::test]
    async fn failed_takes_stay_outside_the_fifo() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let mut history = history_with_capacity(directory.path(), 2);
        history.record("", &[1, 2, 3]).await.unwrap();
        history.record("one", &[4]).await.unwrap();
        history.record("two", &[5]).await.unwrap();
        history.record("three", &[6]).await.unwrap();

        let texts: Vec<String> = history
            .recent()
            .await
            .unwrap()
            .into_iter()
            .map(|entry| entry.text)
            .collect();
        assert_eq!(texts, ["three", "two", ""]);
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 3 + 1);
    }

    /// Index 0 is the newest, as `recent` lists them.
    #[tokio::test]
    async fn a_take_is_read_back_and_its_text_replaced_after_a_retry() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let mut history = history_with_capacity(directory.path(), 2);
        history.record("", &[7, -8, 9]).await.unwrap();
        history.record("newer", &[1]).await.unwrap();

        assert_eq!(history.samples(1).unwrap(), vec![7, -8, 9]);
        assert!(history
            .audio_path(1)
            .unwrap()
            .ends_with(wav_file_name(&index_records(directory.path())[0])));

        history.update_text(1, "recovered").unwrap();

        let reloaded = history_with_capacity(directory.path(), 2);
        let entries = reloaded.recent().await.unwrap();
        assert_eq!(entries[1].text, "recovered");
        assert_eq!(entries[1].recorded_at, fixed_now());
        assert_eq!(reloaded.samples(1).unwrap(), vec![7, -8, 9]);
        assert!(history.samples(5).is_err());
    }

    /// A recovered take joins the FIFO, and the oldest text makes room for it.
    #[tokio::test]
    async fn a_recovered_take_counts_against_the_capacity() {
        let directory = TempDir::new().expect("temporary directory should be created");
        let mut history = history_with_capacity(directory.path(), 2);
        history.record("old", &[1]).await.unwrap();
        history.record("", &[2]).await.unwrap();
        history.record("new", &[3]).await.unwrap();

        history.update_text(1, "recovered").unwrap();

        let texts: Vec<String> = history
            .recent()
            .await
            .unwrap()
            .into_iter()
            .map(|entry| entry.text)
            .collect();
        assert_eq!(texts, ["new", "recovered"]);
    }
}
