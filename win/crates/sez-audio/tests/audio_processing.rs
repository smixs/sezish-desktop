use sez_audio::{
    f32_to_i16, push_interleaved_f32, MonoResampler, SpscRingBuffer, StreamResampler,
    TARGET_SAMPLE_RATE,
};
use std::f32::consts::TAU;

#[test]
fn stereo_48khz_sine_downmixes_and_resamples_to_16khz_mono() {
    const INPUT_RATE: u32 = 48_000;
    const FREQUENCY: f32 = 440.0;
    const INPUT_FRAMES: usize = 12_000;

    let mut stereo = Vec::with_capacity(INPUT_FRAMES * 2);
    for frame in 0..INPUT_FRAMES {
        let wave = (TAU * FREQUENCY * frame as f32 / INPUT_RATE as f32).sin();
        stereo.extend_from_slice(&[wave * 0.8, wave * 0.4]);
    }

    let ring = SpscRingBuffer::new(INPUT_FRAMES).expect("positive capacity is valid");
    let (mut producer, mut consumer) = ring.split();
    let stats = push_interleaved_f32(&mut producer, &stereo, 2).expect("stereo input is valid");
    assert_eq!(stats.frames, INPUT_FRAMES);
    assert_eq!(stats.dropped, 0);

    let mut mono = Vec::with_capacity(INPUT_FRAMES);
    while let Some(sample) = consumer.pop() {
        mono.push(sample);
    }
    let expected_second_sample = (TAU * FREQUENCY / INPUT_RATE as f32).sin() * 0.6;
    assert!((mono[1] - expected_second_sample).abs() < 1.0e-6);

    let mut resampler = MonoResampler::new(INPUT_RATE).expect("48 kHz is valid");
    let output = resampler.process(&mono).expect("sine can be resampled");
    let expected_len = INPUT_FRAMES * TARGET_SAMPLE_RATE as usize / INPUT_RATE as usize;
    assert!(
        output.len().abs_diff(expected_len) <= 1,
        "expected about {expected_len} frames, got {}",
        output.len()
    );

    let strongest_frequency = (300_u32..=600)
        .step_by(10)
        .max_by(|left, right| {
            correlation(&output, *left as f32)
                .partial_cmp(&correlation(&output, *right as f32))
                .expect("correlations are finite")
        })
        .expect("frequency search is non-empty");
    assert!(
        strongest_frequency.abs_diff(FREQUENCY as u32) <= 10,
        "dominant frequency moved to {strongest_frequency} Hz"
    );
}

fn correlation(samples: &[f32], frequency: f32) -> f32 {
    let (sin_sum, cos_sum) = samples.iter().enumerate().fold(
        (0.0_f32, 0.0_f32),
        |(sin_sum, cos_sum), (index, sample)| {
            let phase = TAU * frequency * index as f32 / TARGET_SAMPLE_RATE as f32;
            (
                sin_sum + sample * phase.sin(),
                cos_sum + sample * phase.cos(),
            )
        },
    );
    sin_sum.mul_add(sin_sum, cos_sum * cos_sum)
}

#[test]
fn f32_conversion_clamps_extremes_scales_finite_values_and_silences_nan() {
    assert_eq!(f32_to_i16(f32::INFINITY), i16::MAX);
    assert_eq!(f32_to_i16(1.5), i16::MAX);
    assert_eq!(f32_to_i16(1.0), i16::MAX);
    assert_eq!(f32_to_i16(0.5), 16_384);
    assert_eq!(f32_to_i16(0.0), 0);
    assert_eq!(f32_to_i16(-0.5), -16_384);
    assert_eq!(f32_to_i16(-1.0), i16::MIN);
    assert_eq!(f32_to_i16(-1.5), i16::MIN);
    assert_eq!(f32_to_i16(f32::NEG_INFINITY), i16::MIN);
    assert_eq!(f32_to_i16(f32::NAN), 0);
}

/// Transcribing during the recording only works if what the tap publishes is the recording:
/// the blocks the stream produces have to be the clip the batch path produces, whatever size
/// the capture callback happens to deliver.
#[test]
fn streamed_resampling_renders_the_same_clip_as_the_batch_one() {
    const INPUT_RATE: u32 = 48_000;
    const FREQUENCY: f32 = 440.0;
    const INPUT_FRAMES: usize = 50_000;
    /// The stream stops one filter delay short of the batch, which is where the clip would
    /// need samples the microphone never captured.
    const TAIL_ALLOWANCE: usize = 400;

    let mono = (0..INPUT_FRAMES)
        .map(|frame| (TAU * FREQUENCY * frame as f32 / INPUT_RATE as f32).sin() * 0.7)
        .collect::<Vec<_>>();
    let batch = MonoResampler::new(INPUT_RATE)
        .expect("48 kHz is valid")
        .process(&mono)
        .expect("sine can be resampled");

    for block in [160, 480, 1_024, 7_777] {
        let mut resampler = StreamResampler::new(INPUT_RATE).expect("48 kHz is valid");
        let mut streamed = Vec::new();
        for part in mono.chunks(block) {
            streamed.extend(resampler.push(part).expect("sine can be resampled"));
        }
        streamed.extend(resampler.flush().expect("the tail can be resampled"));

        assert!(
            streamed.len() <= batch.len() && streamed.len() + TAIL_ALLOWANCE >= batch.len(),
            "block {block}: {} streamed frames against {} batch frames",
            streamed.len(),
            batch.len()
        );
        assert_eq!(
            streamed,
            batch[..streamed.len()],
            "block {block}: the stream is not the clip"
        );
    }
}

/// A microphone already running at the target rate is passed through, blocks and all.
#[test]
fn streamed_resampling_passes_16khz_capture_through() {
    let mut resampler = StreamResampler::new(TARGET_SAMPLE_RATE).expect("16 kHz is valid");

    assert_eq!(
        resampler
            .push(&[0.25, -0.5])
            .expect("passthrough cannot fail"),
        vec![0.25, -0.5]
    );
    assert!(resampler
        .flush()
        .expect("passthrough cannot fail")
        .is_empty());
}
