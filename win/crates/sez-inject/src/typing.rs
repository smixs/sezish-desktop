use crate::{KeyState, SELF_INJECTION_TAG};

/// Longest text still typed unit by unit; anything longer goes through the clipboard.
pub const MAX_TYPED_UNITS: usize = 4000;

/// Control character delivered as a real virtual key instead of a unicode unit.
///
/// Consoles and editors routinely ignore these two as injected unicode units,
/// so they travel as ordinary key presses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TypedKey {
    Return,
    Tab,
}

/// What one typing event carries into the focused window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TypeUnit {
    /// One UTF-16 code unit; a surrogate pair is two consecutive units.
    Unicode(u16),
    /// One control key press.
    Key(TypedKey),
}

/// Cross-platform description of one tagged typing event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TypeEvent {
    /// Payload of the event.
    pub unit: TypeUnit,
    /// Whether the key is pressed or released.
    pub state: KeyState,
    /// Marker copied into Win32 `dwExtraInfo`.
    pub extra_info: usize,
}

/// Which path carries the text into the focused window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InsertRoute {
    /// Type the text unit by unit; the clipboard is never touched.
    Type,
    /// Stage the text on the clipboard and paste it.
    Clipboard,
}

/// Picks the insertion path: typing is exact but slow past a few thousand units.
pub fn choose_route(text: &str) -> InsertRoute {
    if text.encode_utf16().count() > MAX_TYPED_UNITS {
        InsertRoute::Clipboard
    } else {
        InsertRoute::Type
    }
}

/// Expands text into the ordered down/up events that type it.
///
/// `\r\n`, `\n` and a lone `\r` collapse into one Return press; `\t` becomes a
/// Tab press. Every other character is emitted as its UTF-16 code units.
pub fn build_typing_events(text: &str) -> Vec<TypeEvent> {
    let mut events = Vec::new();
    let mut characters = text.chars().peekable();

    while let Some(character) = characters.next() {
        match character {
            '\r' => {
                if characters.peek() == Some(&'\n') {
                    characters.next();
                }
                push_event(&mut events, TypeUnit::Key(TypedKey::Return));
            }
            '\n' => push_event(&mut events, TypeUnit::Key(TypedKey::Return)),
            '\t' => push_event(&mut events, TypeUnit::Key(TypedKey::Tab)),
            _ => {
                let mut buffer = [0u16; 2];
                for unit in character.encode_utf16(&mut buffer) {
                    push_event(&mut events, TypeUnit::Unicode(*unit));
                }
            }
        }
    }

    events
}

fn push_event(events: &mut Vec<TypeEvent>, unit: TypeUnit) {
    for state in [KeyState::Down, KeyState::Up] {
        events.push(TypeEvent {
            unit,
            state,
            extra_info: SELF_INJECTION_TAG,
        });
    }
}

/// Length of the leading batch of `events` that one send call may take.
///
/// The cut never lands between the halves of a surrogate pair: a lone half
/// arriving in a later call can be dropped, or mixed with whatever the user
/// typed in between. `max_events` must be at least 4 - one pair is four events.
pub fn batch_len(events: &[TypeEvent], max_events: usize) -> usize {
    debug_assert!(max_events >= 4, "a surrogate pair must fit in one batch");
    // Events come strictly in down/up pairs, so an even cut is unit-aligned.
    let limit = events.len().min(max_events & !1);
    if limit < events.len() && ends_on_high_surrogate(&events[..limit]) {
        limit - 2
    } else {
        limit
    }
}

fn ends_on_high_surrogate(batch: &[TypeEvent]) -> bool {
    matches!(
        batch.last(),
        Some(TypeEvent {
            unit: TypeUnit::Unicode(unit),
            ..
        }) if (0xD800..=0xDBFF).contains(unit)
    )
}

/// How far a typing attempt got before the system stopped accepting events.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TypeOutcome {
    /// Every event was accepted.
    Typed,
    /// Nothing was accepted, so the clipboard path is still safe to try.
    Blocked,
    /// Some events landed; retrying another way would duplicate that text.
    Partial,
}

/// Reads the accepted-event tally a send call reported back.
pub fn classify(accepted: usize, total: usize) -> TypeOutcome {
    match accepted {
        _ if accepted == total => TypeOutcome::Typed,
        0 => TypeOutcome::Blocked,
        _ => TypeOutcome::Partial,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        batch_len, build_typing_events, choose_route, classify, InsertRoute, TypeOutcome, TypeUnit,
        TypedKey, MAX_TYPED_UNITS,
    };
    use crate::{KeyState, SELF_INJECTION_TAG};

    fn units(text: &str) -> Vec<TypeUnit> {
        build_typing_events(text)
            .chunks(2)
            .map(|pair| {
                assert_eq!(pair[0].state, KeyState::Down);
                assert_eq!(pair[1].state, KeyState::Up);
                assert_eq!(pair[0].unit, pair[1].unit);
                pair[0].unit
            })
            .collect()
    }

    #[test]
    fn ascii_becomes_one_tagged_down_up_pair_per_character() {
        let events = build_typing_events("hi");

        assert_eq!(events.len(), 4);
        assert!(events
            .iter()
            .all(|event| event.extra_info == SELF_INJECTION_TAG));
        assert_eq!(
            units("hi"),
            vec![
                TypeUnit::Unicode(b'h'.into()),
                TypeUnit::Unicode(b'i'.into())
            ]
        );
    }

    #[test]
    fn cyrillic_travels_as_single_code_units() {
        assert_eq!(
            units("да"),
            vec![TypeUnit::Unicode(0x0434), TypeUnit::Unicode(0x0430)]
        );
    }

    #[test]
    fn an_emoji_travels_as_its_two_surrogate_units() {
        assert_eq!(
            units("🙂"),
            vec![TypeUnit::Unicode(0xD83D), TypeUnit::Unicode(0xDE42)]
        );
    }

    #[test]
    fn line_breaks_and_tabs_become_control_key_presses() {
        assert!(build_typing_events("a\r\nb\n\tc\r")
            .iter()
            .all(|event| event.extra_info == SELF_INJECTION_TAG));
        assert_eq!(
            units("a\r\nb\n\tc\r"),
            vec![
                TypeUnit::Unicode(b'a'.into()),
                TypeUnit::Key(TypedKey::Return),
                TypeUnit::Unicode(b'b'.into()),
                TypeUnit::Key(TypedKey::Return),
                TypeUnit::Key(TypedKey::Tab),
                TypeUnit::Unicode(b'c'.into()),
                TypeUnit::Key(TypedKey::Return),
            ]
        );
    }

    #[test]
    fn empty_text_produces_no_events() {
        assert!(build_typing_events("").is_empty());
    }

    #[test]
    fn the_clipboard_takes_over_past_the_typing_bound() {
        let at_bound = "a".repeat(MAX_TYPED_UNITS);
        let over_bound = "a".repeat(MAX_TYPED_UNITS + 1);
        // Surrogate pairs count as the two units they really are.
        let over_bound_by_surrogates = "🙂".repeat(MAX_TYPED_UNITS / 2 + 1);

        assert_eq!(choose_route(""), InsertRoute::Type);
        assert_eq!(choose_route(&at_bound), InsertRoute::Type);
        assert_eq!(choose_route(&over_bound), InsertRoute::Clipboard);
        assert_eq!(
            choose_route(&over_bound_by_surrogates),
            InsertRoute::Clipboard
        );
    }

    #[test]
    fn a_batch_boundary_never_lands_inside_a_surrogate_pair() {
        // "a🙂" puts the high surrogate on events 2..4, so a 4-event cut would
        // split the pair and has to retreat to the character before it.
        let split_pair = build_typing_events("a🙂b");
        let clean_cut = build_typing_events("ab🙂");

        assert_eq!(batch_len(&split_pair, 4), 2);
        assert_eq!(batch_len(&clean_cut, 4), 4);
    }

    #[test]
    fn a_batch_is_capped_but_never_longer_than_what_is_left() {
        let events = build_typing_events("abc");

        assert_eq!(batch_len(&events, 4), 4);
        assert_eq!(batch_len(&events[4..], 4), 2);
        assert_eq!(batch_len(&[], 4), 0);
    }

    #[test]
    fn the_accepted_event_tally_tells_typed_from_blocked_and_partial() {
        assert_eq!(classify(8, 8), TypeOutcome::Typed);
        assert_eq!(classify(0, 0), TypeOutcome::Typed);
        assert_eq!(classify(0, 8), TypeOutcome::Blocked);
        assert_eq!(classify(6, 8), TypeOutcome::Partial);
    }
}
