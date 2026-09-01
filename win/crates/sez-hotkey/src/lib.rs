//! Hotkey interpretation for dictation.
//!
//! The pure `HotkeyModeInterpreter` (Hold/Toggle semantics, ported from
//! HotkeyMode.swift) is the tested seam. The WH_KEYBOARD_LL adapter that feeds
//! it lives in the Tauri shell (`win/src-tauri/src/hotkey.rs`) where it can be
//! wired to runtime mode changes, Esc-swallow and clean shutdown.

mod interpreter;
mod shortcut;

pub use interpreter::{
    hold_rearm_allowed, Command, HotkeyMode, HotkeyModeInterpreter, SWALLOWED_PRESS_HOLD_WINDOW,
};
pub use shortcut::{normalize_modifier_vk, vk, Edge, HookDecision, KeyEvent, Modifiers, Shortcut};
