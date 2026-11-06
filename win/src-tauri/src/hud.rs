//! On-screen dictation indicator: a small transparent always-on-top window at
//! the bottom centre of the primary monitor. It never takes focus
//! (`focusable(false)` = `WS_EX_NOACTIVATE`) and ignores the cursor, so the
//! text being dictated into keeps the caret. Pure Tauri, no WinAPI (ADR-0001).
//!
//! Everything here is best-effort: if the window cannot be built the tray icon
//! still shows the phase, and every failure goes to the field log.

use crate::tray::TrayPhase;
use tauri::{AppHandle, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

pub const LABEL: &str = "hud";
/// Logical window size; the page draws a 44 px circle inside a glow margin.
const SIZE: f64 = 72.0;
/// Logical distance from the bottom edge of the work area (above the taskbar).
const BOTTOM_MARGIN: f64 = 80.0;

pub struct Hud {
    window: WebviewWindow,
}

impl Hud {
    pub fn create(app: &AppHandle) -> tauri::Result<Self> {
        let builder = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("hud.html".into()))
            .title("sezish")
            .inner_size(SIZE, SIZE)
            .decorations(false)
            .shadow(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .focusable(false)
            .focused(false)
            .resizable(false)
            .visible(false);
        // `transparent` is gated out of the macOS build (dev host only) — the
        // shipped binary is Windows, where a transparent WebView2 window is plain.
        #[cfg(not(target_os = "macos"))]
        let builder = builder.transparent(true);
        let window = builder.build()?;
        window.set_ignore_cursor_events(true)?;
        Ok(Self { window })
    }

    /// Shows the indicator on recording, morphs it on transcribing, hides on idle.
    pub fn set_phase(&self, phase: TrayPhase) {
        let result = match phase {
            TrayPhase::Idle => self.window.hide(),
            TrayPhase::Recording => self
                .place()
                .and_then(|()| self.window.eval(phase_script(phase)))
                .and_then(|()| self.window.show()),
            TrayPhase::Transcribing => self.window.eval(phase_script(phase)),
        };
        if let Err(error) = result {
            crate::obs::log(&format!("hud {phase:?} failed: {error}"));
        }
    }

    /// Re-anchors to the current primary monitor: displays get plugged and
    /// unplugged between dictations, so the position is computed on every show.
    fn place(&self) -> tauri::Result<()> {
        let Some(monitor) = self.window.primary_monitor()? else {
            return Ok(());
        };
        let area = monitor.work_area();
        let scale = monitor.scale_factor();
        let size = (SIZE * scale).round() as i32;
        let (x, y) = origin(
            WorkArea {
                x: area.position.x,
                y: area.position.y,
                width: area.size.width as i32,
                height: area.size.height as i32,
            },
            size,
            scale,
        );
        self.window.set_position(PhysicalPosition::new(x, y))
    }
}

/// Monitor work area in physical pixels (excludes the taskbar).
#[derive(Clone, Copy, Debug)]
pub struct WorkArea {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

/// Top-left corner for a `size` px square window: horizontally centred,
/// `BOTTOM_MARGIN` (scaled) above the bottom of the work area, clamped inside it.
pub fn origin(area: WorkArea, size: i32, scale: f64) -> (i32, i32) {
    let margin = (BOTTOM_MARGIN * scale).round() as i32;
    let x = area.x + ((area.width - size) / 2).max(0);
    let y = area.y + (area.height - size - margin).max(0);
    (x, y)
}

/// JS that tells the page which phase to draw; a no-op until the page has loaded.
pub fn phase_script(phase: TrayPhase) -> &'static str {
    match phase {
        TrayPhase::Idle => "window.sezishPhase&&window.sezishPhase('idle')",
        TrayPhase::Recording => "window.sezishPhase&&window.sezishPhase('recording')",
        TrayPhase::Transcribing => "window.sezishPhase&&window.sezishPhase('transcribing')",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tray::TrayPhase;

    #[test]
    fn origin_centers_horizontally_and_sits_above_the_taskbar() {
        // 1920x1040 work area (taskbar takes 40 px), 72 px window, 100% scale.
        let (x, y) = origin(
            WorkArea {
                x: 0,
                y: 0,
                width: 1920,
                height: 1040,
            },
            72,
            1.0,
        );
        assert_eq!((x, y), (924, 1040 - 72 - 80));
    }

    #[test]
    fn origin_scales_the_bottom_margin_with_dpi() {
        // 200% scale: the window is 144 physical px and the margin 160.
        let (x, y) = origin(
            WorkArea {
                x: 0,
                y: 0,
                width: 3840,
                height: 2000,
            },
            144,
            2.0,
        );
        assert_eq!((x, y), (1848, 2000 - 144 - 160));
    }

    #[test]
    fn origin_honours_the_monitor_offset() {
        // Secondary monitor placed left of the primary: negative origin.
        let (x, y) = origin(
            WorkArea {
                x: -1000,
                y: 200,
                width: 1000,
                height: 800,
            },
            72,
            1.0,
        );
        assert_eq!((x, y), (-1000 + 464, 200 + 800 - 72 - 80));
    }

    #[test]
    fn origin_never_leaves_the_work_area_on_tiny_screens() {
        let (x, y) = origin(
            WorkArea {
                x: 0,
                y: 0,
                width: 60,
                height: 100,
            },
            72,
            1.0,
        );
        assert_eq!((x, y), (0, 0));
    }

    #[test]
    fn phase_scripts_call_the_page_hook_with_the_phase_name() {
        assert_eq!(
            phase_script(TrayPhase::Recording),
            "window.sezishPhase&&window.sezishPhase('recording')"
        );
        assert_eq!(
            phase_script(TrayPhase::Transcribing),
            "window.sezishPhase&&window.sezishPhase('transcribing')"
        );
        assert_eq!(
            phase_script(TrayPhase::Idle),
            "window.sezishPhase&&window.sezishPhase('idle')"
        );
    }

    #[test]
    fn the_top_placement_sits_just_under_the_screen_edge() {
        // Mac `HUDGeometry.topGap` = 10 pt; Windows has no menu bar above it.
        let area = WorkArea {
            x: 0,
            y: 0,
            width: 1920,
            height: 1040,
        };
        assert_eq!(placed(area, 72, 1.0, HudPlacement::Top), (924, 10));
        assert_eq!(placed(area, 72, 1.0, HudPlacement::Bottom), origin(area, 72, 1.0));
        let shifted = WorkArea { y: 300, ..area };
        assert_eq!(placed(shifted, 144, 2.0, HudPlacement::Top), (888, 320));
    }

    #[test]
    fn placements_have_stable_names_for_settings() {
        assert_eq!(HudPlacement::default(), HudPlacement::Bottom);
        for placement in [HudPlacement::Bottom, HudPlacement::Top] {
            assert_eq!(HudPlacement::from_name(placement.name()), Some(placement));
        }
        assert_eq!(HudPlacement::from_name("notch"), None);
    }

    /// The mic tap delivers ~10 ms blocks; the page gets a level ~12 times a
    /// second, like the Mac meter.
    #[test]
    fn the_level_feed_emits_about_twelve_times_a_second() {
        let mut feed = LevelFeed::default();
        let block = vec![4_000i16; 160]; // 10 ms
        let emitted = (0..100).filter_map(|_| feed.push(&block)).count();
        assert!((11..=13).contains(&emitted), "{emitted}");
    }

    #[test]
    fn the_level_feed_tells_speech_from_the_room() {
        let mut feed = LevelFeed::default();
        let speech: Vec<i16> = (0..1_360)
            .map(|i| (6_000.0 * (i as f32 * 0.35).sin()) as i16)
            .collect();
        let room = vec![20i16; 1_360];
        let mut last_speech = 0.0;
        let mut last_room = 1.0;
        for _ in 0..24 {
            if let Some(level) = feed.push(&speech) {
                last_speech = level;
            }
            if let Some(level) = feed.push(&room) {
                last_room = level;
            }
        }
        assert!(last_speech > 0.8, "{last_speech}");
        assert!(last_room < 0.1, "{last_room}");
    }

    #[test]
    fn a_new_take_starts_the_level_at_rest() {
        let mut feed = LevelFeed::default();
        feed.push(&vec![8_000i16; 1_360]);
        feed.restart();
        let first = feed.push(&vec![0i16; 1_360]).expect("first block emits");
        assert_eq!(first, 0.0);
    }

    #[test]
    fn scripts_pass_values_to_the_page() {
        assert_eq!(level_script(0.5), "window.sezishLevel&&window.sezishLevel(0.500)");
        assert_eq!(
            wave_script(sez_core::wave::WaveIntensity::Lively),
            "window.sezishWave&&window.sezishWave({\"swing\":0.85,\"base\":1.3,\"gain\":1.2,\"attack\":0.05,\"release\":0.22,\"minScale\":0.25})"
        );
        assert_eq!(
            notice_script("Текст в буфере — \"Ctrl+V\"", 2_000, false),
            "window.sezishNotice&&window.sezishNotice(\"Текст в буфере — \\\"Ctrl+V\\\"\",2000,false)"
        );
    }

    /// The pill needs room the 72 px circle does not: the window widens to the
    /// text and stays centred where the circle was.
    #[test]
    fn the_notice_window_widens_around_the_same_centre() {
        let area = WorkArea {
            x: 0,
            y: 0,
            width: 1920,
            height: 1040,
        };
        let (x, y, width) = notice_frame(area, 1.0, HudPlacement::Bottom, 20);
        assert_eq!(width, 20 * NOTICE_CHAR_PX as i32 + NOTICE_PADDING_PX as i32);
        assert_eq!(x, (1920 - width) / 2);
        assert_eq!(y, origin(area, 72, 1.0).1);
        let (_, _, capped) = notice_frame(area, 1.0, HudPlacement::Bottom, 500);
        assert_eq!(capped, NOTICE_MAX_PX as i32);
    }
}
