use crate::downmix::push_interleaved_converted;
use crate::{
    f32_to_i16, IdleClosePolicy, MonoResampler, RingConsumer, SpscRingBuffer, StreamResampler,
};
use async_trait::async_trait;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, SizedSample};
use sez_core::{Clock, Mic, SezError};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle, Thread};
use std::time::Duration;

/// Tentative Windows-port idle timeout; not derived from the macOS reference.
pub const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

const RING_CAPACITY: usize = 65_536;

/// Sink for the recording as it is captured, 16 kHz mono PCM16, called while the user is still
/// speaking.
///
/// It runs on the thread that drains the capture ring, so it must return immediately: anything
/// slow here stops the ring from being emptied and the capture starts dropping samples.
pub type CaptureTap = Arc<dyn Fn(&[i16]) + Send + Sync>;

enum WorkerCommand {
    Start(Sender<()>),
    Stop(Sender<Result<Vec<i16>, SezError>>),
    Shutdown,
}

struct WarmCapture {
    stream: Option<cpal::Stream>,
    recording: Arc<AtomicBool>,
    callbacks_in_flight: Arc<AtomicUsize>,
    commands: Sender<WorkerCommand>,
    worker_thread: Thread,
    worker: Option<JoinHandle<()>>,
}

impl WarmCapture {
    fn prepare_dictation(&self) -> Result<(), SezError> {
        let (ack_tx, ack_rx) = mpsc::channel();
        self.commands
            .send(WorkerCommand::Start(ack_tx))
            .map_err(|_| SezError::Other("audio worker stopped unexpectedly".to_owned()))?;
        self.worker_thread.unpark();
        ack_rx
            .recv()
            .map_err(|_| SezError::Other("audio worker stopped unexpectedly".to_owned()))?;
        self.recording.store(true, Ordering::Release);
        Ok(())
    }

    fn play(&self) -> Result<(), SezError> {
        self.stream
            .as_ref()
            .ok_or_else(|| SezError::Other("audio stream is unavailable".to_owned()))?
            .play()
            .map_err(|error| SezError::Other(format!("failed to start audio stream: {error}")))
    }

    fn finish_dictation(&self) -> Result<Vec<i16>, SezError> {
        self.recording.store(false, Ordering::Release);
        while self.callbacks_in_flight.load(Ordering::Acquire) != 0 {
            thread::yield_now();
        }

        let (result_tx, result_rx) = mpsc::channel();
        self.commands
            .send(WorkerCommand::Stop(result_tx))
            .map_err(|_| SezError::Other("audio worker stopped unexpectedly".to_owned()))?;
        self.worker_thread.unpark();
        result_rx
            .recv()
            .map_err(|_| SezError::Other("audio worker stopped unexpectedly".to_owned()))?
    }

    fn shutdown(&mut self) {
        self.recording.store(false, Ordering::Release);
        self.stream.take();
        let _ = self.commands.send(WorkerCommand::Shutdown);
        self.worker_thread.unpark();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for WarmCapture {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// CPAL-backed implementation of the frozen [`Mic`] seam.
///
/// Construction is hardware-free. Device discovery and stream opening occur
/// only on the fresh-open branch of [`Mic::start`].
pub struct CpalMic {
    clock: Arc<dyn Clock>,
    idle_policy: IdleClosePolicy,
    warm_capture: Option<WarmCapture>,
    stream_error: Arc<Mutex<Option<SezError>>>,
    tap: Option<CaptureTap>,
}

impl CpalMic {
    /// Creates a hardware-free microphone adapter using the tentative 30-second idle timeout.
    pub fn new(clock: Arc<dyn Clock>) -> Self {
        Self::with_idle_timeout(clock, DEFAULT_IDLE_TIMEOUT)
    }

    /// Creates a hardware-free adapter with an explicit product-level idle timeout.
    pub fn with_idle_timeout(clock: Arc<dyn Clock>, idle_timeout: Duration) -> Self {
        Self {
            clock,
            idle_policy: IdleClosePolicy::new(idle_timeout),
            warm_capture: None,
            stream_error: Arc::new(Mutex::new(None)),
            tap: None,
        }
    }

    /// Publishes the recording as it is captured, so a transcriber can work on the beginning of
    /// a dictation while its end is still being spoken. Set before the first [`Mic::start`]:
    /// the capture thread that calls the tap is opened there and keeps the one it was given.
    pub fn set_tap(&mut self, tap: CaptureTap) {
        self.tap = Some(tap);
    }

    /// Feeds the same device-error path used by CPAL's stream error callback.
    pub fn report_stream_error(&self, error: cpal::StreamError) {
        record_stream_error(&self.stream_error, error);
    }

    /// Applies idle-close against the injected clock and tears down if due.
    pub fn close_if_idle(&mut self) -> bool {
        if self.idle_policy.close_if_idle(self.clock.as_ref()) {
            self.warm_capture.take();
            true
        } else {
            false
        }
    }

    fn take_stream_error(&self) -> Result<Option<SezError>, SezError> {
        self.stream_error
            .lock()
            .map(|mut slot| slot.take())
            .map_err(|_| SezError::Other("audio error state is unavailable".to_owned()))
    }

    fn open_capture(&self) -> Result<WarmCapture, SezError> {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or_else(|| SezError::Other("no audio input device is available".to_owned()))?;
        let supported = device.default_input_config().map_err(|error| {
            SezError::Other(format!("failed to query audio input format: {error}"))
        })?;
        let sample_format = supported.sample_format();
        let sample_rate = supported.sample_rate();
        let channels = supported.channels() as usize;
        let config = supported.config();

        let ring = SpscRingBuffer::new(RING_CAPACITY)
            .map_err(|error| SezError::Other(format!("failed to create audio ring: {error}")))?;
        let (producer, consumer) = ring.split();
        let (commands, command_rx) = mpsc::channel();
        let recording = Arc::new(AtomicBool::new(false));
        let callbacks_in_flight = Arc::new(AtomicUsize::new(0));

        let tap = self.tap.clone();
        let worker = thread::Builder::new()
            .name("sez-audio-worker".to_owned())
            .spawn(move || worker_loop(consumer, sample_rate, command_rx, tap))
            .map_err(|error| SezError::Other(format!("failed to start audio worker: {error}")))?;
        let worker_thread = worker.thread().clone();

        let stream = build_stream(
            &device,
            &config,
            sample_format,
            channels,
            producer,
            Arc::clone(&recording),
            Arc::clone(&callbacks_in_flight),
            worker_thread.clone(),
            Arc::clone(&self.stream_error),
        );

        match stream {
            Ok(stream) => Ok(WarmCapture {
                stream: Some(stream),
                recording,
                callbacks_in_flight,
                commands,
                worker_thread,
                worker: Some(worker),
            }),
            Err(error) => {
                let _ = commands.send(WorkerCommand::Shutdown);
                worker_thread.unpark();
                let _ = worker.join();
                Err(error)
            }
        }
    }
}

#[async_trait]
impl Mic for CpalMic {
    async fn start(&mut self) -> Result<(), SezError> {
        if let Some(error) = self.take_stream_error()? {
            self.warm_capture.take();
            self.idle_policy.mark_closed();
            return Err(error);
        }
        if self
            .warm_capture
            .as_ref()
            .is_some_and(|capture| capture.recording.load(Ordering::Acquire))
        {
            return Err(SezError::Other(
                "microphone capture is already active".to_owned(),
            ));
        }

        self.close_if_idle();
        let disposition = self.idle_policy.on_start(self.clock.as_ref());
        if let Some(capture) = &self.warm_capture {
            debug_assert_eq!(disposition, crate::StartDisposition::ReusedWarm);
            if let Err(error) = capture.prepare_dictation() {
                self.warm_capture.take();
                self.idle_policy.mark_closed();
                return Err(error);
            }
            return Ok(());
        }

        debug_assert_eq!(disposition, crate::StartDisposition::FreshOpen);
        let capture = match self.open_capture() {
            Ok(capture) => capture,
            Err(error) => {
                self.idle_policy.mark_closed();
                return Err(error);
            }
        };
        if let Err(error) = capture.prepare_dictation().and_then(|()| capture.play()) {
            self.idle_policy.mark_closed();
            return Err(error);
        }
        self.warm_capture = Some(capture);
        Ok(())
    }

    async fn stop(&mut self) -> Result<Vec<i16>, SezError> {
        let result = self
            .warm_capture
            .as_ref()
            .map(WarmCapture::finish_dictation);
        self.idle_policy.on_stop(self.clock.as_ref());

        if let Some(error) = self.take_stream_error()? {
            self.warm_capture.take();
            self.idle_policy.mark_closed();
            return Err(error);
        }

        match result {
            Some(Ok(samples)) => Ok(samples),
            Some(Err(error)) => {
                self.warm_capture.take();
                self.idle_policy.mark_closed();
                Err(error)
            }
            None => Err(SezError::Other(
                "microphone capture is not active".to_owned(),
            )),
        }
    }
}

fn worker_loop(
    mut consumer: RingConsumer,
    sample_rate: u32,
    commands: Receiver<WorkerCommand>,
    tap: Option<CaptureTap>,
) {
    let mut captured = Vec::new();
    let mut resampler = MonoResampler::new(sample_rate);
    // How much of `captured` the tap has already seen, and the resampler rendering it while the
    // recording goes on. The resampler is absent between dictations and after a failure.
    let mut published = 0;
    let mut stream = None;

    loop {
        while let Some(sample) = consumer.pop() {
            captured.push(sample);
        }
        publish(tap.as_ref(), &mut stream, &captured[published..]);
        published = captured.len();

        match commands.try_recv() {
            Ok(WorkerCommand::Start(ack)) => {
                captured.clear();
                published = 0;
                let _ = ack.send(());
                // Built after the acknowledgement: planning the transform takes a moment and
                // the hotkey is not made to wait for it.
                stream = tap
                    .as_ref()
                    .and_then(|_| StreamResampler::new(sample_rate).ok());
            }
            Ok(WorkerCommand::Stop(result)) => {
                while let Some(sample) = consumer.pop() {
                    captured.push(sample);
                }
                // The tail is published before the caller gets its answer: whoever transcribes
                // the stream must hold the whole take by the time it is asked for the text.
                publish(tap.as_ref(), &mut stream, &captured[published..]);
                flush(tap.as_ref(), stream.take());
                published = 0;
                let finalized = resampler
                    .as_mut()
                    .map_err(|error| SezError::Other(error.to_string()))
                    .and_then(|resampler| {
                        resampler
                            .process(&captured)
                            .map_err(|error| SezError::Other(error.to_string()))
                    })
                    .map(|samples| samples.into_iter().map(f32_to_i16).collect());
                captured.clear();
                let _ = result.send(finalized);
            }
            Ok(WorkerCommand::Shutdown) | Err(mpsc::TryRecvError::Disconnected) => break,
            Err(mpsc::TryRecvError::Empty) => thread::park(),
        }
    }
}

/// Publishes what is ready of `samples`. A resampler that failed is dropped: the rest of the
/// take stays unpublished, and the transcriber falls back to the whole recording because the
/// stream no longer covers it.
fn publish(tap: Option<&CaptureTap>, stream: &mut Option<StreamResampler>, samples: &[f32]) {
    let Some(tap) = tap else {
        return;
    };
    let Some(resampler) = stream.as_mut() else {
        return;
    };
    match resampler.push(samples) {
        Ok(ready) => send(tap, &ready),
        Err(_) => *stream = None,
    }
}

/// Publishes the last, partial block once the recording is over.
fn flush(tap: Option<&CaptureTap>, stream: Option<StreamResampler>) {
    let (Some(tap), Some(mut resampler)) = (tap, stream) else {
        return;
    };
    if let Ok(ready) = resampler.flush() {
        send(tap, &ready);
    }
}

fn send(tap: &CaptureTap, samples: &[f32]) {
    if samples.is_empty() {
        return;
    }
    tap(&samples.iter().copied().map(f32_to_i16).collect::<Vec<_>>());
}

#[allow(clippy::too_many_arguments)]
fn build_stream(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    sample_format: SampleFormat,
    channels: usize,
    producer: crate::RingProducer,
    recording: Arc<AtomicBool>,
    callbacks_in_flight: Arc<AtomicUsize>,
    worker_thread: Thread,
    stream_error: Arc<Mutex<Option<SezError>>>,
) -> Result<cpal::Stream, SezError> {
    match sample_format {
        SampleFormat::I8 => build_typed_stream::<i8>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        SampleFormat::I16 => build_typed_stream::<i16>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        SampleFormat::I24 => build_typed_stream::<cpal::I24>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        SampleFormat::I32 => build_typed_stream::<i32>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        SampleFormat::I64 => build_typed_stream::<i64>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        SampleFormat::U8 => build_typed_stream::<u8>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        SampleFormat::U16 => build_typed_stream::<u16>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        SampleFormat::U24 => build_typed_stream::<cpal::U24>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        SampleFormat::U32 => build_typed_stream::<u32>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        SampleFormat::U64 => build_typed_stream::<u64>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        SampleFormat::F32 => build_typed_stream::<f32>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        SampleFormat::F64 => build_typed_stream::<f64>(
            device,
            config,
            channels,
            producer,
            recording,
            callbacks_in_flight,
            worker_thread,
            stream_error,
        ),
        _ => Err(SezError::Other(format!(
            "unsupported audio sample format: {sample_format}"
        ))),
    }
}

#[allow(clippy::too_many_arguments)]
fn build_typed_stream<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    channels: usize,
    mut producer: crate::RingProducer,
    recording: Arc<AtomicBool>,
    callbacks_in_flight: Arc<AtomicUsize>,
    worker_thread: Thread,
    stream_error: Arc<Mutex<Option<SezError>>>,
) -> Result<cpal::Stream, SezError>
where
    T: SizedSample + Copy,
    f32: FromSample<T>,
{
    device
        .build_input_stream::<T, _, _>(
            config,
            move |data, _| {
                if !recording.load(Ordering::Acquire) {
                    return;
                }

                callbacks_in_flight.fetch_add(1, Ordering::AcqRel);
                if recording.load(Ordering::Acquire) {
                    let _ =
                        push_interleaved_converted(&mut producer, data, channels, f32::from_sample);
                    worker_thread.unpark();
                }
                callbacks_in_flight.fetch_sub(1, Ordering::Release);
            },
            move |error| record_stream_error(&stream_error, error),
            None,
        )
        .map_err(|error| SezError::Other(format!("failed to open audio input stream: {error}")))
}

fn record_stream_error(slot: &Mutex<Option<SezError>>, error: cpal::StreamError) {
    if let Ok(mut slot) = slot.lock() {
        *slot = Some(SezError::Other(format!(
            "audio stream device error: {error}"
        )));
    }
}
