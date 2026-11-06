//! The recording wave on the HUD: mic loudness → a 0…1 level that the page
//! turns into capsule heights. Ported from the macOS reference
//! (`AudioLevel.swift`, `WaveIntensity.swift`), whose `AutoLevel` is hex's
//! (anomalyco/hex `src/rune_hud/dot_scope.rs`, MIT, © 2026 Christopher Langton).

#[cfg(test)]
mod tests {
    use super::{decibels, rms, AutoLevel, LevelSmoother, WaveIntensity};

    /// `seconds` of alternating syllables at `peak` dBFS over a room at `room`,
    /// ~12 Hz like the mic tap; every level the auto level produced.
    fn speak(auto: &mut AutoLevel, peak: f32, room: f32, seconds: f32) -> Vec<f32> {
        let dt = 1.0 / 12.0;
        let mut levels = Vec::new();
        let mut t = 0.0;
        while t < seconds {
            let syllable = ((t * 4.0) as i32) % 2 == 0;
            levels.push(auto.step(if syllable { peak } else { room }, dt));
            t += dt;
        }
        levels
    }

    fn max_of_last(levels: &[f32], n: usize) -> f32 {
        levels[levels.len() - n..].iter().copied().fold(0.0, f32::max)
    }

    #[test]
    fn rms_of_silence_is_zero_and_of_a_full_sine_root_half() {
        assert_eq!(rms(&[]), 0.0);
        assert_eq!(rms(&[0, 0, 0]), 0.0);
        let sine: Vec<i16> = (0..16_000)
            .map(|i| (32_767.0 * (i as f32 * 440.0 * std::f32::consts::TAU / 16_000.0).sin()) as i16)
            .collect();
        assert!((rms(&sine) - 0.7071).abs() < 0.001);
    }

    #[test]
    fn rms_converts_to_decibels() {
        assert_eq!(decibels(1.0), 0.0);
        assert!((decibels(0.1) + 20.0).abs() < 0.001);
        assert_eq!(decibels(0.0), -120.0);
        assert_eq!(decibels(f32::NAN), -120.0);
    }

    #[test]
    fn a_quiet_and_a_loud_microphone_both_reach_full() {
        let mut quiet = AutoLevel::default();
        let quiet_levels = speak(&mut quiet, -40.0, -68.0, 3.0);
        let mut loud = AutoLevel::default();
        let loud_levels = speak(&mut loud, -12.0, -50.0, 3.0);
        assert!(max_of_last(&quiet_levels, 12) > 0.9);
        assert!(max_of_last(&loud_levels, 12) > 0.9);
    }

    #[test]
    fn the_room_reads_as_silence() {
        let mut auto = AutoLevel::default();
        speak(&mut auto, -30.0, -55.0, 3.0);
        assert!(auto.level(-55.0) < 0.05);
    }

    #[test]
    fn the_peak_releases_so_a_quieter_voice_fills_again() {
        let mut auto = AutoLevel::default();
        speak(&mut auto, -10.0, -55.0, 2.0);
        let right = auto.level(-30.0);
        speak(&mut auto, -30.0, -55.0, 6.0);
        let later = auto.level(-30.0);
        assert!(later > right + 0.3);
        assert!(later > 0.85);
    }

    #[test]
    fn silence_and_garbage_stay_at_zero() {
        let mut auto = AutoLevel::default();
        assert_eq!(auto.step(f32::NEG_INFINITY, 0.1), 0.0);
        assert_eq!(auto.step(f32::NAN, 0.1), 0.0);
        assert_eq!(auto.level(-120.0), 0.0);
    }

    #[test]
    fn zero_dt_learns_nothing() {
        let mut auto = AutoLevel::default();
        let before = auto.level(-30.0);
        auto.step(0.0, 0.0);
        assert_eq!(auto.level(-30.0), before);
    }

    #[test]
    fn the_smoother_attacks_faster_than_it_releases() {
        let mut rising = LevelSmoother::new(0.04, 0.25);
        let risen = rising.step(1.0, 0.05);
        let mut falling = LevelSmoother::new(0.04, 0.25);
        falling.step(1.0, 10.0);
        let after = falling.step(0.0, 0.05);
        assert!(risen > 1.0 - after);
    }

    #[test]
    fn the_smoother_converges_ignores_zero_dt_and_clamps_garbage() {
        let mut s = LevelSmoother::new(0.04, 0.25);
        s.step(0.8, 5.0);
        assert!((s.value() - 0.8).abs() < 0.01);
        let before = s.value();
        s.step(0.0, 0.0);
        assert_eq!(s.value(), before);
        s.step(f32::NAN, 0.1);
        assert!(s.value().is_finite());
        s.step(5.0, 10.0);
        assert!(s.value() <= 1.0);
    }

    #[test]
    fn intensity_defaults_to_lively_and_each_step_is_stronger() {
        assert_eq!(WaveIntensity::default(), WaveIntensity::Lively);
        let steps = WaveIntensity::ALL;
        assert_eq!(steps, [WaveIntensity::Calm, WaveIntensity::Lively, WaveIntensity::Bold]);
        for pair in steps.windows(2) {
            assert!(pair[1].swing() > pair[0].swing());
            assert!(pair[1].speed_gain() > pair[0].speed_gain());
            assert!(pair[1].attack() < pair[0].attack());
        }
    }

    #[test]
    fn intensity_constants_match_the_macos_reference() {
        let lively = WaveIntensity::Lively;
        assert_eq!(
            (lively.swing(), lively.base_frequency(), lively.speed_gain()),
            (0.85, 1.3, 1.2)
        );
        assert_eq!((lively.attack(), lively.release()), (0.05, 0.22));
        assert_eq!(WaveIntensity::MINIMUM_SCALE, 0.25);
    }

    #[test]
    fn bold_reaches_double_height_and_nothing_collapses() {
        assert!((WaveIntensity::Bold.capsule_scale(1.0, 1.0) - 2.0).abs() < 0.001);
        for intensity in WaveIntensity::ALL {
            assert!(intensity.capsule_scale(1.0, -1.0) >= 0.25);
            assert_eq!(intensity.capsule_scale(0.0, 1.0), 1.0);
            assert!(intensity.frequency(1.0) > intensity.frequency(0.0));
        }
    }

    #[test]
    fn intensities_have_stable_names_for_settings() {
        for intensity in WaveIntensity::ALL {
            assert_eq!(WaveIntensity::from_name(intensity.name()), Some(intensity));
        }
        assert_eq!(WaveIntensity::Calm.name(), "calm");
        assert_eq!(WaveIntensity::from_name("garbage"), None);
    }
}
