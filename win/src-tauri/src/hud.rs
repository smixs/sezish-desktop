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
}
