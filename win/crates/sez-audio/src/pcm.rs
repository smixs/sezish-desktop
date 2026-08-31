/// Converts a normalized floating-point sample to signed PCM16.
///
/// Values outside `[-1.0, 1.0]` are clamped to the exact PCM endpoints.
/// `NaN` is defined as silence.
#[inline]
pub fn f32_to_i16(sample: f32) -> i16 {
    if sample.is_nan() {
        return 0;
    }
    if sample >= 1.0 {
        return i16::MAX;
    }
    if sample <= -1.0 {
        return i16::MIN;
    }

    if sample >= 0.0 {
        (sample * i16::MAX as f32).round() as i16
    } else {
        (sample * -(i16::MIN as f32)).round() as i16
    }
}
