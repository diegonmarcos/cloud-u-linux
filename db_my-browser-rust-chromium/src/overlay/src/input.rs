//! Pure translation from winit input events to CEF-shaped data.
//!
//! No CEF *calls* here (no `BrowserHost` methods, no `send_*_event`), and no
//! `App` state — everything below is data in, data out, so it can be unit
//! tested with plain `cargo test` and no running browser. `main.rs` owns the
//! `cef::MouseEvent` / `cef::KeyEvent` construction and the actual host calls;
//! it feeds them the values computed here.
//!
//! The one exception is `cef::sys::cef_event_flags_t`, which main.rs already
//! used (for SHIFT/CONTROL/ALT/COMMAND) before this module existed — see
//! `modifiers_to_eventflags` below. That's a plain FFI-bound integer enum, not
//! a struct with uncertain field layout, so pulling it in here doesn't carry
//! the same signature-guessing risk as the `MouseEvent`/`KeyEvent` structs,
//! which is why those stay out of this module entirely.

use winit::event::{MouseButton, MouseScrollDelta};
use winit::keyboard::{KeyCode, ModifiersState, PhysicalKey};

/// Which mouse buttons are currently held down, tracked by `App` across events
/// so the CEF button-down modifier bits (see `modifiers_to_eventflags`) can be
/// stamped onto every mouse event, not just the click that started a drag.
/// Plain bitflags-style `u8`; no `bitflags` crate dependency added.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct MouseButtons(u8);

impl MouseButtons {
    pub const LEFT: u8 = 1 << 0;
    pub const MIDDLE: u8 = 1 << 1;
    pub const RIGHT: u8 = 1 << 2;

    pub fn set(&mut self, bit: u8, held: bool) {
        if held {
            self.0 |= bit;
        } else {
            self.0 &= !bit;
        }
    }

    pub fn contains(self, bit: u8) -> bool {
        self.0 & bit != 0
    }
}

/// Maps a winit mouse button to the bit `MouseButtons` tracks it under.
/// `None` for buttons CEF has no click-event mapping for (see
/// `cef_mouse_button` in main.rs, which the same set of buttons feeds).
pub fn mouse_button_bit(button: MouseButton) -> Option<u8> {
    match button {
        MouseButton::Left => Some(MouseButtons::LEFT),
        MouseButton::Middle => Some(MouseButtons::MIDDLE),
        MouseButton::Right => Some(MouseButtons::RIGHT),
        _ => None,
    }
}

/// Builds the CEF `modifiers` bitmask for a mouse event: keyboard modifiers
/// plus whichever mouse buttons are currently held.
///
/// KNOWN BUG FIXED HERE: previously mouse events only ever carried keyboard
/// modifiers (see the old `cef_modifiers`, now `keyboard_eventflags` below) —
/// a held button was never stamped into `modifiers`, so CEF never saw a
/// mouse-down while the cursor moved and drag-to-select did not work. Move,
/// click and wheel events must all pass their current `MouseButtons` through
/// this function (not `keyboard_eventflags` alone).
pub fn modifiers_to_eventflags(mods: ModifiersState, buttons: MouseButtons) -> u32 {
    keyboard_eventflags(mods) | mouse_button_eventflags(buttons)
}

/// Keyboard-only portion of the CEF modifiers bitmask. Moved from main.rs's
/// former `cef_modifiers`, unchanged.
pub fn keyboard_eventflags(mods: ModifiersState) -> u32 {
    use cef::sys::cef_event_flags_t as Flags;
    let mut flags = 0u32;
    if mods.shift_key() {
        flags |= Flags::EVENTFLAG_SHIFT_DOWN.0;
    }
    if mods.control_key() {
        flags |= Flags::EVENTFLAG_CONTROL_DOWN.0;
    }
    if mods.alt_key() {
        flags |= Flags::EVENTFLAG_ALT_DOWN.0;
    }
    if mods.super_key() {
        flags |= Flags::EVENTFLAG_COMMAND_DOWN.0;
    }
    flags
}

/// Button-down portion of the CEF modifiers bitmask (the bug fix). UNVERIFIED:
/// `EVENTFLAG_LEFT_MOUSE_BUTTON` / `_MIDDLE_MOUSE_BUTTON` / `_RIGHT_MOUSE_BUTTON`
/// could not be checked against the vendored cef-rs sources (`.build/cef-rs`
/// does not exist in this checkout). They are CEF's standard, long-stable
/// public `cef_event_flags_t` names (`cef_types.h`, unchanged across CEF
/// releases) and sibling members of the same enum as the already-verified
/// `EVENTFLAG_SHIFT_DOWN` etc. above, but that is inference, not a source
/// read — if CI fails on these three symbols specifically, that is why.
pub fn mouse_button_eventflags(buttons: MouseButtons) -> u32 {
    use cef::sys::cef_event_flags_t as Flags;
    let mut flags = 0u32;
    if buttons.contains(MouseButtons::LEFT) {
        flags |= Flags::EVENTFLAG_LEFT_MOUSE_BUTTON.0;
    }
    if buttons.contains(MouseButtons::MIDDLE) {
        flags |= Flags::EVENTFLAG_MIDDLE_MOUSE_BUTTON.0;
    }
    if buttons.contains(MouseButtons::RIGHT) {
        flags |= Flags::EVENTFLAG_RIGHT_MOUSE_BUTTON.0;
    }
    flags
}

// CEF/Chromium key handling expects Windows VK_* codes for `windows_key_code` on
// every platform (not the native scan code), so map winit's platform-independent
// KeyCode onto them. Only the keys needed for basic navigation/text entry are mapped.
// Moved from main.rs's former `vkey_from_physical`, unchanged.
pub fn key_to_windows_vkey(key: PhysicalKey) -> i32 {
    let PhysicalKey::Code(code) = key else {
        return 0;
    };
    match code {
        KeyCode::KeyA => 0x41,
        KeyCode::KeyB => 0x42,
        KeyCode::KeyC => 0x43,
        KeyCode::KeyD => 0x44,
        KeyCode::KeyE => 0x45,
        KeyCode::KeyF => 0x46,
        KeyCode::KeyG => 0x47,
        KeyCode::KeyH => 0x48,
        KeyCode::KeyI => 0x49,
        KeyCode::KeyJ => 0x4A,
        KeyCode::KeyK => 0x4B,
        KeyCode::KeyL => 0x4C,
        KeyCode::KeyM => 0x4D,
        KeyCode::KeyN => 0x4E,
        KeyCode::KeyO => 0x4F,
        KeyCode::KeyP => 0x50,
        KeyCode::KeyQ => 0x51,
        KeyCode::KeyR => 0x52,
        KeyCode::KeyS => 0x53,
        KeyCode::KeyT => 0x54,
        KeyCode::KeyU => 0x55,
        KeyCode::KeyV => 0x56,
        KeyCode::KeyW => 0x57,
        KeyCode::KeyX => 0x58,
        KeyCode::KeyY => 0x59,
        KeyCode::KeyZ => 0x5A,
        KeyCode::Digit0 => 0x30,
        KeyCode::Digit1 => 0x31,
        KeyCode::Digit2 => 0x32,
        KeyCode::Digit3 => 0x33,
        KeyCode::Digit4 => 0x34,
        KeyCode::Digit5 => 0x35,
        KeyCode::Digit6 => 0x36,
        KeyCode::Digit7 => 0x37,
        KeyCode::Digit8 => 0x38,
        KeyCode::Digit9 => 0x39,
        KeyCode::Backspace => 0x08,
        KeyCode::Tab => 0x09,
        KeyCode::Enter | KeyCode::NumpadEnter => 0x0D,
        KeyCode::ShiftLeft | KeyCode::ShiftRight => 0x10,
        KeyCode::ControlLeft | KeyCode::ControlRight => 0x11,
        KeyCode::AltLeft | KeyCode::AltRight => 0x12,
        KeyCode::CapsLock => 0x14,
        KeyCode::Escape => 0x1B,
        KeyCode::Space => 0x20,
        KeyCode::PageUp => 0x21,
        KeyCode::PageDown => 0x22,
        KeyCode::End => 0x23,
        KeyCode::Home => 0x24,
        KeyCode::ArrowLeft => 0x25,
        KeyCode::ArrowUp => 0x26,
        KeyCode::ArrowRight => 0x27,
        KeyCode::ArrowDown => 0x28,
        KeyCode::Insert => 0x2D,
        KeyCode::Delete => 0x2E,
        KeyCode::F1 => 0x70,
        KeyCode::F2 => 0x71,
        KeyCode::F3 => 0x72,
        KeyCode::F4 => 0x73,
        KeyCode::F5 => 0x74,
        KeyCode::F6 => 0x75,
        KeyCode::F7 => 0x76,
        KeyCode::F8 => 0x77,
        KeyCode::F9 => 0x78,
        KeyCode::F10 => 0x79,
        KeyCode::F11 => 0x7A,
        KeyCode::F12 => 0x7B,
        _ => 0,
    }
}

/// Whether a translated key event is the key-down (RAWKEYDOWN) or key-up
/// (KEYUP) leg. Plain enum so this module never has to name
/// `cef::KeyEventType` — main.rs maps this to the real CEF enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAction {
    Down,
    Up,
}

/// Everything main.rs needs to build the CEF `KeyEvent`(s) for one winit
/// `KeyEvent`, computed with no CEF types involved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TranslatedKey {
    pub action: KeyAction,
    pub windows_key_code: i32,
    /// Set only on key-down, and only when the key produced non-control text.
    /// When present, main.rs sends a second CEF CHAR event carrying it (CEF's
    /// RAWKEYDOWN alone does not produce typed text).
    pub char_code: Option<u16>,
}

/// Translates one winit `KeyEvent` (given as its constituent fields, so this
/// stays decoupled from winit's own `KeyEvent` layout too) into the plain data
/// main.rs needs to drive `BrowserHost::send_key_event`.
pub fn translate_key_event(
    physical_key: PhysicalKey,
    pressed: bool,
    text: Option<&str>,
) -> TranslatedKey {
    let windows_key_code = key_to_windows_vkey(physical_key);
    let action = if pressed { KeyAction::Down } else { KeyAction::Up };
    // Skip on key-up and for control keys (e.g. Enter's text is "\r", which is
    // not something we want typed into a text field).
    let char_code = if pressed {
        text.and_then(|t| t.chars().next())
            .filter(|c| !c.is_control())
            .map(|c| {
                let mut units = [0u16; 2];
                c.encode_utf16(&mut units)[0]
            })
    } else {
        None
    };
    TranslatedKey {
        action,
        windows_key_code,
        char_code,
    }
}

/// CEF wants a pixel delta; approximate one wheel "line" as 40 logical px.
// ponytail: 40px/line is an admitted guess (see PLAN-deploy-gaps.md P5),
// not calibrated against real Chrome. Ceiling: wheel feels off by some
// constant factor. Upgrade path: measure Chrome's own LineDelta->px constant
// and replace this literal.
pub fn wheel_delta(delta: MouseScrollDelta, scale_factor: f64) -> (i32, i32) {
    match delta {
        MouseScrollDelta::LineDelta(x, y) => ((x * 40.0) as i32, (y * 40.0) as i32),
        MouseScrollDelta::PixelDelta(p) => {
            let p = p.to_logical::<f32>(scale_factor);
            (p.x as i32, p.y as i32)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_modifiers_no_buttons_is_zero() {
        assert_eq!(
            modifiers_to_eventflags(ModifiersState::empty(), MouseButtons::default()),
            0
        );
    }

    #[test]
    fn shift_sets_only_shift_bit() {
        let flags = keyboard_eventflags(ModifiersState::SHIFT);
        assert_ne!(flags, 0);
        assert_eq!(flags, keyboard_eventflags(ModifiersState::SHIFT));
        // Distinct bits per modifier: none of the others alone produce the same value.
        assert_ne!(flags, keyboard_eventflags(ModifiersState::CONTROL));
        assert_ne!(flags, keyboard_eventflags(ModifiersState::ALT));
        assert_ne!(flags, keyboard_eventflags(ModifiersState::SUPER));
    }

    #[test]
    fn modifiers_combine_as_disjoint_bits() {
        let shift = keyboard_eventflags(ModifiersState::SHIFT);
        let ctrl = keyboard_eventflags(ModifiersState::CONTROL);
        let alt = keyboard_eventflags(ModifiersState::ALT);
        let both = keyboard_eventflags(ModifiersState::SHIFT | ModifiersState::CONTROL);
        assert_eq!(both, shift | ctrl);
        assert_eq!(shift & ctrl, 0);
        assert_eq!(shift & alt, 0);
        assert_eq!(ctrl & alt, 0);
    }

    #[test]
    fn super_key_sets_command_bit() {
        let flags = keyboard_eventflags(ModifiersState::SUPER);
        assert_ne!(flags, 0);
    }

    #[test]
    fn held_button_bits_are_distinct_and_combine() {
        let mut buttons = MouseButtons::default();
        assert_eq!(mouse_button_eventflags(buttons), 0);

        buttons.set(MouseButtons::LEFT, true);
        let left = mouse_button_eventflags(buttons);
        assert_ne!(left, 0);

        let mut buttons2 = MouseButtons::default();
        buttons2.set(MouseButtons::MIDDLE, true);
        let middle = mouse_button_eventflags(buttons2);
        assert_ne!(middle, 0);
        assert_ne!(left, middle);

        let mut buttons3 = MouseButtons::default();
        buttons3.set(MouseButtons::RIGHT, true);
        let right = mouse_button_eventflags(buttons3);
        assert_ne!(right, 0);
        assert_ne!(left, right);
        assert_ne!(middle, right);

        buttons.set(MouseButtons::RIGHT, true);
        assert_eq!(mouse_button_eventflags(buttons), left | right);
    }

    #[test]
    fn releasing_a_button_clears_its_bit() {
        let mut buttons = MouseButtons::default();
        buttons.set(MouseButtons::LEFT, true);
        assert!(buttons.contains(MouseButtons::LEFT));
        buttons.set(MouseButtons::LEFT, false);
        assert!(!buttons.contains(MouseButtons::LEFT));
        assert_eq!(mouse_button_eventflags(buttons), 0);
    }

    #[test]
    fn modifiers_to_eventflags_combines_keyboard_and_buttons() {
        let mut buttons = MouseButtons::default();
        buttons.set(MouseButtons::LEFT, true);
        let combined = modifiers_to_eventflags(ModifiersState::SHIFT, buttons);
        assert_eq!(
            combined,
            keyboard_eventflags(ModifiersState::SHIFT) | mouse_button_eventflags(buttons)
        );
    }

    #[test]
    fn mouse_button_bit_maps_known_buttons() {
        assert_eq!(mouse_button_bit(MouseButton::Left), Some(MouseButtons::LEFT));
        assert_eq!(
            mouse_button_bit(MouseButton::Middle),
            Some(MouseButtons::MIDDLE)
        );
        assert_eq!(
            mouse_button_bit(MouseButton::Right),
            Some(MouseButtons::RIGHT)
        );
        assert_eq!(mouse_button_bit(MouseButton::Back), None);
    }

    #[test]
    fn vkey_letters_and_digits() {
        assert_eq!(
            key_to_windows_vkey(PhysicalKey::Code(KeyCode::KeyA)),
            0x41
        );
        assert_eq!(
            key_to_windows_vkey(PhysicalKey::Code(KeyCode::KeyZ)),
            0x5A
        );
        assert_eq!(
            key_to_windows_vkey(PhysicalKey::Code(KeyCode::Digit0)),
            0x30
        );
        assert_eq!(
            key_to_windows_vkey(PhysicalKey::Code(KeyCode::Digit9)),
            0x39
        );
    }

    #[test]
    fn vkey_named_keys() {
        assert_eq!(
            key_to_windows_vkey(PhysicalKey::Code(KeyCode::Enter)),
            0x0D
        );
        assert_eq!(
            key_to_windows_vkey(PhysicalKey::Code(KeyCode::Escape)),
            0x1B
        );
        assert_eq!(
            key_to_windows_vkey(PhysicalKey::Code(KeyCode::ArrowLeft)),
            0x25
        );
        assert_eq!(
            key_to_windows_vkey(PhysicalKey::Code(KeyCode::ArrowUp)),
            0x26
        );
        assert_eq!(
            key_to_windows_vkey(PhysicalKey::Code(KeyCode::ArrowRight)),
            0x27
        );
        assert_eq!(
            key_to_windows_vkey(PhysicalKey::Code(KeyCode::ArrowDown)),
            0x28
        );
    }

    #[test]
    fn vkey_function_keys() {
        assert_eq!(key_to_windows_vkey(PhysicalKey::Code(KeyCode::F1)), 0x70);
        assert_eq!(key_to_windows_vkey(PhysicalKey::Code(KeyCode::F12)), 0x7B);
    }

    #[test]
    fn vkey_unmapped_key_is_zero() {
        // Comma has no VK_* mapping in key_to_windows_vkey above.
        assert_eq!(key_to_windows_vkey(PhysicalKey::Code(KeyCode::Comma)), 0);
    }

    #[test]
    fn translate_key_down_with_text_produces_char_code() {
        let translated = translate_key_event(PhysicalKey::Code(KeyCode::KeyA), true, Some("a"));
        assert_eq!(translated.action, KeyAction::Down);
        assert_eq!(translated.windows_key_code, 0x41);
        assert_eq!(translated.char_code, Some(b'a' as u16));
    }

    #[test]
    fn translate_key_up_never_has_char_code() {
        let translated = translate_key_event(PhysicalKey::Code(KeyCode::KeyA), false, Some("a"));
        assert_eq!(translated.action, KeyAction::Up);
        assert_eq!(translated.char_code, None);
    }

    #[test]
    fn translate_key_down_control_char_is_filtered() {
        // Enter's text is "\r" - a control character we don't want typed.
        let translated = translate_key_event(PhysicalKey::Code(KeyCode::Enter), true, Some("\r"));
        assert_eq!(translated.char_code, None);
    }

    #[test]
    fn translate_key_down_no_text_has_no_char_code() {
        let translated = translate_key_event(PhysicalKey::Code(KeyCode::ArrowLeft), true, None);
        assert_eq!(translated.char_code, None);
    }

    #[test]
    fn wheel_line_delta_scales_by_40() {
        let (dx, dy) = wheel_delta(MouseScrollDelta::LineDelta(1.0, -2.0), 1.0);
        assert_eq!(dx, 40);
        assert_eq!(dy, -80);
    }

    #[test]
    fn wheel_pixel_delta_uses_logical_units() {
        let (dx, dy) = wheel_delta(
            MouseScrollDelta::PixelDelta(winit::dpi::PhysicalPosition::new(20.0, 40.0)),
            2.0,
        );
        // scale_factor 2.0 halves physical px to get logical px.
        assert_eq!(dx, 10);
        assert_eq!(dy, 20);
    }
}
