//! Pure, key-aware description of the dictation hotkey — a Windows port of the
//! macOS `Shortcut` value type (`app/Sources/SezishCore/Shortcut.swift`).
//!
//! This module has **no dependency on the `windows` crate**: virtual-key codes are
//! plain `u16` constants, so the whole matching surface compiles and unit-tests on
//! macOS CI. The thin WH_KEYBOARD_LL adapter in `src-tauri/src/hotkey.rs` feeds raw
//! values (`vkCode`, the extended-key flag, and the currently-held modifier set read
//! via `GetAsyncKeyState`) into [`Shortcut::evaluate`] and acts on the returned
//! [`HookDecision`].

use serde::de::{self, Deserializer};
use serde::ser::{SerializeSeq, Serializer};
use serde::{Deserialize, Serialize};

/// Windows virtual-key codes this module reasons about. Side-specific modifier codes
/// are what the low-level keyboard hook actually delivers; the generic ones
/// (`VK_CONTROL`/`VK_MENU`/`VK_SHIFT`) are what `GetAsyncKeyState` reports and are
/// normalised to a side defensively.
pub mod vk {
    pub const CONTROL: u16 = 0x11;
    pub const MENU: u16 = 0x12; // Alt
    pub const SHIFT: u16 = 0x10;

    pub const LSHIFT: u16 = 0xA0;
    pub const RSHIFT: u16 = 0xA1;
    pub const LCONTROL: u16 = 0xA2;
    pub const RCONTROL: u16 = 0xA3;
    pub const LMENU: u16 = 0xA4;
    pub const RMENU: u16 = 0xA5;
    pub const LWIN: u16 = 0x5B;
    pub const RWIN: u16 = 0x5C;
}

/// A set of the four generic modifiers a `.key` combo can require. Serialises to a
/// stable lowercase-name array, e.g. `["ctrl","alt"]`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Modifiers(u8);

impl Modifiers {
    pub const CTRL: Modifiers = Modifiers(1 << 0);
    pub const ALT: Modifiers = Modifiers(1 << 1);
    pub const SHIFT: Modifiers = Modifiers(1 << 2);
    pub const WIN: Modifiers = Modifiers(1 << 3);

    const ALL: [(Modifiers, &'static str); 4] = [
        (Modifiers::CTRL, "ctrl"),
        (Modifiers::ALT, "alt"),
        (Modifiers::SHIFT, "shift"),
        (Modifiers::WIN, "win"),
    ];

    pub const fn empty() -> Self {
        Modifiers(0)
    }

    pub const fn contains(self, other: Modifiers) -> bool {
        self.0 & other.0 == other.0
    }

    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    pub fn insert(&mut self, other: Modifiers) {
        self.0 |= other.0;
    }
}

impl std::ops::BitOr for Modifiers {
    type Output = Modifiers;
    fn bitor(self, rhs: Modifiers) -> Modifiers {
        Modifiers(self.0 | rhs.0)
    }
}

impl Serialize for Modifiers {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let names: Vec<&str> = Modifiers::ALL
            .iter()
            .filter(|(bit, _)| self.contains(*bit))
            .map(|(_, name)| *name)
            .collect();
        let mut seq = serializer.serialize_seq(Some(names.len()))?;
        for name in names {
            seq.serialize_element(name)?;
        }
        seq.end()
    }
}

impl<'de> Deserialize<'de> for Modifiers {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let names = Vec::<String>::deserialize(deserializer)?;
        let mut mods = Modifiers::empty();
        for name in names {
            let matched = Modifiers::ALL
                .iter()
                .find(|(_, candidate)| *candidate == name.as_str());
            match matched {
                Some((bit, _)) => mods.insert(*bit),
                None => return Err(de::Error::custom(format!("unknown modifier {name:?}"))),
            }
        }
        Ok(mods)
    }
}

/// A push-to-talk shortcut: either a bare side-specific modifier, or a main key with
/// an exact set of required modifiers.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum Shortcut {
    /// Bare modifier held down (e.g. Right Ctrl). `vk` is a side-specific modifier code.
    #[serde(rename = "modifier")]
    ModifierOnly { vk: u16 },
    /// A non-modifier key plus zero-or-more required modifiers (e.g. Alt+Q, F9).
    #[serde(rename = "key")]
    Key { vk: u16, mods: Modifiers },
}

impl Default for Shortcut {
    /// The shipped default: hold the right Ctrl.
    fn default() -> Self {
        Shortcut::ModifierOnly { vk: vk::RCONTROL }
    }
}

/// Which kind of edge the hook should feed into the mode interpreter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Edge {
    Press,
    Release,
}

/// The verdict for a single keyboard event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HookDecision {
    /// Edge to hand to the interpreter, if any.
    pub edge: Option<Edge>,
    /// Whether to swallow the event (return `LRESULT(1)`) so it never reaches the app.
    pub swallow: bool,
    /// The updated "combo engaged" latch to carry into the next event.
    pub engaged: bool,
}

impl HookDecision {
    fn idle(engaged: bool) -> Self {
        HookDecision {
            edge: None,
            swallow: false,
            engaged,
        }
    }
}

/// A single low-level keyboard event, reduced to the values matching needs.
#[derive(Clone, Copy, Debug)]
pub struct KeyEvent {
    pub vk: u16,
    /// The `LLKHF_EXTENDED` flag — set for right-side Ctrl/Alt and a few others.
    pub extended: bool,
    /// `true` for key-down (`WM_KEYDOWN`/`WM_SYSKEYDOWN`), `false` for key-up.
    pub key_down: bool,
    /// Modifiers currently held, read from `GetAsyncKeyState` at event time.
    pub active: Modifiers,
}

/// Map a modifier virtual-key code to its side-specific form. Right-side Ctrl/Alt
/// report the generic code with the extended flag set on the low-level hook; the
/// side-specific codes (0xA0–0xA5, LWin/RWin) pass through unchanged. Returns `None`
/// for any non-modifier key.
pub fn normalize_modifier_vk(vk: u16, extended: bool) -> Option<u16> {
    match vk {
        vk::LSHIFT
        | vk::RSHIFT
        | vk::LCONTROL
        | vk::RCONTROL
        | vk::LMENU
        | vk::RMENU
        | vk::LWIN
        | vk::RWIN => Some(vk),
        vk::CONTROL => Some(if extended { vk::RCONTROL } else { vk::LCONTROL }),
        vk::MENU => Some(if extended { vk::RMENU } else { vk::LMENU }),
        vk::SHIFT => Some(vk::LSHIFT),
        _ => None,
    }
}

/// The generic-modifier bit a modifier vk belongs to (`Right Alt` → `ALT`), or `None`.
fn modifier_bit(vk: u16, extended: bool) -> Option<Modifiers> {
    match normalize_modifier_vk(vk, extended)? {
        vk::LCONTROL | vk::RCONTROL => Some(Modifiers::CTRL),
        vk::LMENU | vk::RMENU => Some(Modifiers::ALT),
        vk::LSHIFT | vk::RSHIFT => Some(Modifiers::SHIFT),
        vk::LWIN | vk::RWIN => Some(Modifiers::WIN),
        _ => None,
    }
}

impl Shortcut {
    /// A `.key` combo is swallowed so the letter never reaches the focused app; a bare
    /// modifier passes through so it keeps working normally.
    pub fn should_swallow(&self) -> bool {
        matches!(self, Shortcut::Key { .. })
    }

    /// Decide what to do with one keyboard event, given whether a combo is currently
    /// engaged (the latch carried between events for `.key` shortcuts).
    pub fn evaluate(&self, event: &KeyEvent, engaged: bool) -> HookDecision {
        match self {
            Shortcut::ModifierOnly { vk: target } => {
                match normalize_modifier_vk(event.vk, event.extended) {
                    Some(norm) if norm == *target => HookDecision {
                        edge: Some(if event.key_down {
                            Edge::Press
                        } else {
                            Edge::Release
                        }),
                        swallow: false,
                        engaged: false,
                    },
                    _ => HookDecision::idle(engaged),
                }
            }
            Shortcut::Key { vk: target, mods } => {
                if event.key_down {
                    if event.vk == *target && event.active == *mods {
                        HookDecision {
                            edge: Some(Edge::Press),
                            swallow: true,
                            engaged: true,
                        }
                    } else {
                        HookDecision::idle(engaged)
                    }
                } else if engaged && event.vk == *target {
                    // The main key came up: end the combo and swallow the matching up.
                    HookDecision {
                        edge: Some(Edge::Release),
                        swallow: true,
                        engaged: false,
                    }
                } else if engaged && is_required_modifier_up(event, *mods) {
                    // A required modifier was released first — synthesise the release so
                    // hold-mode dictation can't get stuck. The eventual main-key up then
                    // leaks harmlessly (apps key off key-down).
                    HookDecision {
                        edge: Some(Edge::Release),
                        swallow: false,
                        engaged: false,
                    }
                } else {
                    HookDecision::idle(engaged)
                }
            }
        }
    }
}

fn is_required_modifier_up(event: &KeyEvent, mods: Modifiers) -> bool {
    match modifier_bit(event.vk, event.extended) {
        Some(bit) => mods.contains(bit),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn down(vk: u16, extended: bool, active: Modifiers) -> KeyEvent {
        KeyEvent {
            vk,
            extended,
            key_down: true,
            active,
        }
    }

    fn up(vk: u16, extended: bool, active: Modifiers) -> KeyEvent {
        KeyEvent {
            vk,
            extended,
            key_down: false,
            active,
        }
    }

    #[test]
    fn default_is_right_ctrl_modifier_only() {
        assert_eq!(
            Shortcut::default(),
            Shortcut::ModifierOnly { vk: vk::RCONTROL }
        );
    }

    #[test]
    fn serde_roundtrip_and_json_shape() {
        let modifier = Shortcut::ModifierOnly { vk: vk::RCONTROL };
        let json = serde_json::to_value(&modifier).unwrap();
        assert_eq!(json, serde_json::json!({ "kind": "modifier", "vk": 163 }));
        assert_eq!(serde_json::from_value::<Shortcut>(json).unwrap(), modifier);

        let combo = Shortcut::Key {
            vk: 0x51,
            mods: Modifiers::ALT,
        };
        let json = serde_json::to_value(&combo).unwrap();
        assert_eq!(
            json,
            serde_json::json!({ "kind": "key", "vk": 81, "mods": ["alt"] })
        );
        assert_eq!(serde_json::from_value::<Shortcut>(json).unwrap(), combo);

        let chord = Shortcut::Key {
            vk: 0x78,
            mods: Modifiers::CTRL | Modifiers::SHIFT,
        };
        let json = serde_json::to_value(&chord).unwrap();
        assert_eq!(json["mods"], serde_json::json!(["ctrl", "shift"]));
        assert_eq!(serde_json::from_value::<Shortcut>(json).unwrap(), chord);
    }

    #[test]
    fn unknown_modifier_name_is_rejected() {
        let bad = serde_json::json!({ "kind": "key", "vk": 81, "mods": ["hyper"] });
        assert!(serde_json::from_value::<Shortcut>(bad).is_err());
    }

    #[test]
    fn normalize_maps_generic_and_passes_side_specific() {
        assert_eq!(normalize_modifier_vk(vk::CONTROL, true), Some(vk::RCONTROL));
        assert_eq!(
            normalize_modifier_vk(vk::CONTROL, false),
            Some(vk::LCONTROL)
        );
        assert_eq!(normalize_modifier_vk(vk::MENU, true), Some(vk::RMENU));
        assert_eq!(
            normalize_modifier_vk(vk::RCONTROL, true),
            Some(vk::RCONTROL)
        );
        assert_eq!(normalize_modifier_vk(vk::LWIN, false), Some(vk::LWIN));
        assert_eq!(normalize_modifier_vk(0x51, false), None); // 'Q'
    }

    #[test]
    fn modifier_only_matches_right_ctrl_both_encodings_not_left() {
        let sc = Shortcut::ModifierOnly { vk: vk::RCONTROL };
        let none = Modifiers::empty();

        // Side-specific code.
        let d = sc.evaluate(&down(vk::RCONTROL, true, none), false);
        assert_eq!(d.edge, Some(Edge::Press));
        assert!(!d.swallow);
        assert_eq!(
            sc.evaluate(&up(vk::RCONTROL, true, none), false).edge,
            Some(Edge::Release)
        );

        // Generic ctrl + extended also counts as right ctrl.
        assert_eq!(
            sc.evaluate(&down(vk::CONTROL, true, none), false).edge,
            Some(Edge::Press)
        );

        // Left ctrl must not match.
        assert_eq!(
            sc.evaluate(&down(vk::LCONTROL, false, none), false).edge,
            None
        );
        assert_eq!(
            sc.evaluate(&down(vk::CONTROL, false, none), false).edge,
            None
        );
    }

    #[test]
    fn modifier_only_never_swallows() {
        let sc = Shortcut::ModifierOnly { vk: vk::RCONTROL };
        assert!(!sc.should_swallow());
        assert!(
            !sc.evaluate(&down(vk::RCONTROL, true, Modifiers::empty()), false)
                .swallow
        );
    }

    #[test]
    fn key_combo_matches_exact_modifiers_and_swallows() {
        let sc = Shortcut::Key {
            vk: 0x51,
            mods: Modifiers::ALT,
        }; // Alt+Q
        assert!(sc.should_swallow());

        // Q down while Alt held -> engage, swallow.
        let d = sc.evaluate(&down(0x51, false, Modifiers::ALT), false);
        assert_eq!(d.edge, Some(Edge::Press));
        assert!(d.swallow);
        assert!(d.engaged);

        // Q up while engaged -> release, swallow, disengage.
        let u = sc.evaluate(&up(0x51, false, Modifiers::empty()), true);
        assert_eq!(u.edge, Some(Edge::Release));
        assert!(u.swallow);
        assert!(!u.engaged);
    }

    #[test]
    fn key_combo_rejects_missing_or_extra_modifiers_and_bare_modifier() {
        let sc = Shortcut::Key {
            vk: 0x51,
            mods: Modifiers::ALT,
        };

        // No modifier held.
        assert_eq!(
            sc.evaluate(&down(0x51, false, Modifiers::empty()), false)
                .edge,
            None
        );
        // Extra modifier held.
        let extra = Modifiers::CTRL | Modifiers::ALT;
        assert_eq!(sc.evaluate(&down(0x51, false, extra), false).edge, None);
        // Pressing the Alt modifier key itself is not the main key.
        assert_eq!(
            sc.evaluate(&down(vk::RMENU, true, Modifiers::ALT), false)
                .edge,
            None
        );
    }

    #[test]
    fn bare_function_key_is_allowed_without_modifiers() {
        let sc = Shortcut::Key {
            vk: 0x78,
            mods: Modifiers::empty(),
        }; // F9
        let d = sc.evaluate(&down(0x78, false, Modifiers::empty()), false);
        assert_eq!(d.edge, Some(Edge::Press));
        assert!(d.swallow);
        // F9 with a stray modifier no longer matches the bare shortcut.
        assert_eq!(
            sc.evaluate(&down(0x78, false, Modifiers::CTRL), false).edge,
            None
        );
    }

    #[test]
    fn releasing_required_modifier_synthesises_release() {
        let sc = Shortcut::Key {
            vk: 0x51,
            mods: Modifiers::ALT,
        };
        // Combo engaged, user lifts Alt before Q.
        let u = sc.evaluate(&up(vk::RMENU, true, Modifiers::empty()), true);
        assert_eq!(u.edge, Some(Edge::Release));
        assert!(!u.swallow);
        assert!(!u.engaged);
    }
}
