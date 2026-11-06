//! The recording wave on the HUD: mic loudness → a 0…1 level that the page
//! turns into capsule heights. Ported from the macOS reference
//! (`AudioLevel.swift`, `WaveIntensity.swift`), whose `AutoLevel` is hex's
//! (anomalyco/hex `src/rune_hud/dot_scope.rs`, MIT, © 2026 Christopher Langton).

/// Root-mean-square of a block of PCM16 samples, full scale = 1. 0 when empty.
pub fn rms(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f64 = samples
        .iter()
        .map(|&s| {
            let v = f64::from(s) / 32_768.0;
            v * v
        })
        .sum();
    (sum / samples.len() as f64).sqrt() as f32
}

/// dBFS of an RMS value; silence and garbage read as -120.
pub fn decibels(rms: f32) -> f32 {
    if !(rms > 0.0 && rms.is_finite()) {
        return -120.0;
    }
    (20.0 * rms.log10()).max(-120.0)
}

/// Asymmetric exponential follower: fast attack so the wave jumps with speech,
/// slow release so it settles instead of flickering.
#[derive(Debug, Clone, Copy)]
pub struct LevelSmoother {
    value: f32,
    attack_tau: f32,
    release_tau: f32,
}

impl LevelSmoother {
    pub fn new(attack_tau: f32, release_tau: f32) -> Self {
        Self {
            value: 0.0,
            attack_tau,
            release_tau,
        }
    }

    pub fn value(&self) -> f32 {
        self.value
    }

    /// Advances toward `target` by `dt` seconds and returns the new value.
    pub fn step(&mut self, target: f32, dt: f32) -> f32 {
        let clamped = if target.is_finite() {
            target.clamp(0.0, 1.0)
        } else {
            0.0
        };
        if dt <= 0.0 {
            return self.value;
        }
        let tau = if clamped > self.value {
            self.attack_tau
        } else {
            self.release_tau
        };
        self.value += (clamped - self.value) * (1.0 - (-dt / tau).exp());
        self.value
    }
}

/// Slow auto level: the loudest the speaker has recently been reads as full and
/// the room as silent, so a quiet laptop microphone moves the wave as much as a
/// close studio one. hex's constants, kept.
#[derive(Debug, Clone, Copy)]
pub struct AutoLevel {
    /// The speaker's recent peak and the room, dBFS; defaults are a laptop
    /// microphone at talking distance.
    peak: f32,
    room: f32,
}

impl Default for AutoLevel {
    fn default() -> Self {
        Self {
            peak: -30.0,
            room: -55.0,
        }
    }
}

impl AutoLevel {
    /// The quietest the speaker's peak may be thought to be, above the room.
    const MIN_SPAN: f32 = 16.0;
    /// How far below the peak the level starts.
    const RANGE: f32 = 24.0;
    /// How far above the room the level starts.
    const ROOM_MARGIN: f32 = 5.0;
    const ATTACK: f32 = 0.04;
    const ROOM_FALL: f32 = 0.3;
    const ROOM_RISE: f32 = 6.0;
    /// Seconds the peak takes to fall back once the speaker is quieter.
    const RELEASE: f32 = 3.0;
    /// Nothing below this counts as sound, however quiet the room.
    const NOISE_FLOOR: f32 = -60.0;

    /// Learns from `dt` seconds at `loudness` dBFS and returns the 0…1 level.
    pub fn step(&mut self, loudness: f32, dt: f32) -> f32 {
        let db = if loudness.is_nan() {
            -120.0
        } else {
            loudness.max(-120.0)
        };
        if !(dt > 0.0 && dt.is_finite()) {
            return self.level(db);
        }
        let follow = |value: &mut f32, target: f32, time: f32| {
            *value += (target - *value) * (1.0 - (-dt / time.max(1e-3)).exp());
        };
        let room_time = if db < self.room {
            Self::ROOM_FALL
        } else {
            Self::ROOM_RISE
        };
        follow(&mut self.room, db, room_time);
        let lowest = self.room.max(Self::NOISE_FLOOR) + Self::MIN_SPAN;
        let (target, time) = if db > self.peak {
            (db, Self::ATTACK)
        } else {
            (lowest, Self::RELEASE)
        };
        follow(&mut self.peak, target, time);
        self.peak = self.peak.max(lowest);
        self.level(db)
    }

    /// Where `loudness` dBFS sits in the current window, 0…1, without learning.
    pub fn level(&self, loudness: f32) -> f32 {
        if loudness.is_nan() {
            return 0.0;
        }
        let low =
            (self.room.max(Self::NOISE_FLOOR) + Self::ROOM_MARGIN).max(self.peak - Self::RANGE);
        ((loudness - low) / (self.peak - low).max(1.0)).clamp(0.0, 1.0)
    }
}

/// How hard the wave moves: «Спокойно», «Живее» (default), «Дерзко».
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WaveIntensity {
    Calm,
    #[default]
    Lively,
    Bold,
}

impl WaveIntensity {
    pub const ALL: [WaveIntensity; 3] = [Self::Calm, Self::Lively, Self::Bold];
    /// Shortest a capsule may get at a trough, so it never vanishes.
    pub const MINIMUM_SCALE: f64 = 0.25;

    pub fn name(self) -> &'static str {
        match self {
            Self::Calm => "calm",
            Self::Lively => "lively",
            Self::Bold => "bold",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|i| i.name() == name)
    }

    /// Height swing at full voice, as a fraction of a capsule's rest height.
    pub fn swing(self) -> f64 {
        match self {
            Self::Calm => 0.7,
            Self::Lively => 0.85,
            Self::Bold => 1.0,
        }
    }

    /// Wave speed in silence (Hz).
    pub fn base_frequency(self) -> f64 {
        match self {
            Self::Calm => 1.1,
            Self::Lively => 1.3,
            Self::Bold => 1.5,
        }
    }

    /// How much a full voice adds to the wave speed (Hz).
    pub fn speed_gain(self) -> f64 {
        match self {
            Self::Calm => 0.6,
            Self::Lively => 1.2,
            Self::Bold => 2.0,
        }
    }

    /// Level follower attack, seconds.
    pub fn attack(self) -> f32 {
        match self {
            Self::Calm => 0.07,
            Self::Lively => 0.05,
            Self::Bold => 0.03,
        }
    }

    /// Level follower release, seconds.
    pub fn release(self) -> f32 {
        match self {
            Self::Calm => 0.30,
            Self::Lively => 0.22,
            Self::Bold => 0.15,
        }
    }

    /// Height scale of a capsule at `level` (0…1) and wave `oscillation` (-1…1).
    pub fn capsule_scale(self, level: f64, oscillation: f64) -> f64 {
        (1.0 + level * self.swing() * oscillation).max(Self::MINIMUM_SCALE)
    }

    /// Wave frequency (Hz) at `level`: louder speech runs the wave faster.
    pub fn frequency(self, level: f64) -> f64 {
        self.base_frequency() + self.speed_gain() * level.clamp(0.0, 1.0)
    }
}

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
        levels[levels.len() - n..]
            .iter()
            .copied()
            .fold(0.0, f32::max)
    }

    #[test]
    fn rms_of_silence_is_zero_and_of_a_full_sine_root_half() {
        assert_eq!(rms(&[]), 0.0);
        assert_eq!(rms(&[0, 0, 0]), 0.0);
        let sine: Vec<i16> = (0..16_000)
            .map(|i| {
                (32_767.0 * (i as f32 * 440.0 * std::f32::consts::TAU / 16_000.0).sin()) as i16
            })
            .collect();
        assert!((rms(&sine) - std::f32::consts::FRAC_1_SQRT_2).abs() < 0.001);
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
        assert_eq!(
            steps,
            [
                WaveIntensity::Calm,
                WaveIntensity::Lively,
                WaveIntensity::Bold
            ]
        );
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
