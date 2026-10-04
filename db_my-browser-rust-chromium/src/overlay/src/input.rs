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

/// A rectangle in window-logical pixels, used to place the content browser
/// beneath the chrome rows and to hit-test cursor input against it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ContentRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// Computes the content browser's rect: full window width, starting right
/// below the chrome rows and running to the bottom of the window.
// ponytail: `chrome_height` comes from the static `--chrome-height` CLI switch
// (see main.rs), not from the shell itself. Ceiling: it can't react to the
// shell changing its own row heights (a themed compact toolbar, a dropped
// download bar, etc). Upgrade path: have the shell report its real chrome
// height over the P1 Rust->JS state channel (reversed - here JS->Rust, which
// P1's ponytail note already flags as the next thing that channel needs) and
// feed that in each frame instead of this fixed switch value.
pub fn content_rect(window_width: f32, window_height: f32, chrome_height: f32) -> ContentRect {
    let chrome_height = chrome_height.clamp(0.0, window_height.max(0.0));
    ContentRect {
        x: 0.0,
        y: chrome_height,
        width: window_width.max(0.0),
        height: (window_height - chrome_height).max(0.0),
    }
}

/// Which browser a point in window-logical coordinates should be routed to,
/// carrying the point translated into that browser's own local coordinate
/// space (the content browser only ever sees coordinates relative to its own
/// top-left corner, never the window's).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum HitTarget {
    Chrome { x: f32, y: f32 },
    Content { x: f32, y: f32 },
}

/// Hit-tests a cursor position (window-logical pixels) against the content
/// rect. Inside routes to `Content` with coordinates translated into the
/// content browser's local space; outside (including the chrome rows above
/// it) routes to `Chrome` with the window coordinates unchanged, since the
/// chrome browser is sized to the full window.
pub fn hit_test(cursor_x: f32, cursor_y: f32, content: ContentRect) -> HitTarget {
    let inside = cursor_x >= content.x
        && cursor_x < content.x + content.width
        && cursor_y >= content.y
        && cursor_y < content.y + content.height;
    if inside {
        HitTarget::Content {
            x: cursor_x - content.x,
            y: cursor_y - content.y,
        }
    } else {
        HitTarget::Chrome {
            x: cursor_x,
            y: cursor_y,
        }
    }
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

/// One JS -> Rust command, parsed from the chrome browser's `document.title`
/// after the shell prefixes it with `COMMAND_PREFIX` (see `parse_command`).
/// Dispatch - actually calling CEF - lives in main.rs; this module only turns
/// the wire string into data, so it stays unit-testable with no browser.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    Navigate(String),
    Back,
    Forward,
    Reload,
    Stop,
    Find(String),
    FindNext,
    FindPrev,
    FindCancel,
    Scroll(i32, i32),
    Js(String),
    Focus(FocusTarget),
    Quit,
}

/// Which browser `Command::Focus` should route keyboard input to. A separate
/// type from main.rs's own `Focus` (same two variants) so this module never
/// has to name a main.rs type - main.rs maps one onto the other.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusTarget {
    Content,
    Chrome,
}

/// The chrome shell signals a command by setting
/// `document.title = COMMAND_PREFIX + "<command>"`. main.rs resets the title
/// after handling it so an identical next command still triggers CEF's
/// `on_title_change` (CEF does not re-fire that callback when the title
/// string is unchanged).
pub const COMMAND_PREFIX: &str = "__CMD__";

/// Parses one raw title string into a `Command`. Returns `None` for anything
/// not a recognized command - including titles with no `COMMAND_PREFIX`,
/// since ordinary page titles flow through the same callback on the content
/// browser - and for malformed arguments to a known verb. The caller logs and
/// ignores rather than treating this as an error; never panics.
///
/// Exact wire syntax (what the shell must emit, one command per
/// `document.title` assignment):
///   `navigate <url>` | `back` | `forward` | `reload` | `stop`
///   `find <text>` | `find-next` | `find-prev` | `find-cancel`
///   `scroll <dx> <dy>` | `js <script>` | `focus content|chrome` | `quit`
pub fn parse_command(raw: &str) -> Option<Command> {
    let body = raw.strip_prefix(COMMAND_PREFIX)?.trim();
    let (verb, rest) = match body.split_once(char::is_whitespace) {
        Some((verb, rest)) => (verb, rest.trim()),
        None => (body, ""),
    };
    match verb {
        "navigate" if !rest.is_empty() => Some(Command::Navigate(rest.to_string())),
        "back" => Some(Command::Back),
        "forward" => Some(Command::Forward),
        "reload" => Some(Command::Reload),
        "stop" => Some(Command::Stop),
        "find" if !rest.is_empty() => Some(Command::Find(rest.to_string())),
        "find-next" => Some(Command::FindNext),
        "find-prev" => Some(Command::FindPrev),
        "find-cancel" => Some(Command::FindCancel),
        "scroll" => {
            let mut parts = rest.split_whitespace();
            let dx: i32 = parts.next()?.parse().ok()?;
            let dy: i32 = parts.next()?.parse().ok()?;
            if parts.next().is_some() {
                return None; // trailing garbage
            }
            Some(Command::Scroll(dx, dy))
        }
        "js" if !rest.is_empty() => Some(Command::Js(rest.to_string())),
        "focus" => match rest {
            "content" => Some(Command::Focus(FocusTarget::Content)),
            "chrome" => Some(Command::Focus(FocusTarget::Chrome)),
            _ => None,
        },
        "quit" => Some(Command::Quit),
        _ => None,
    }
}

/// The content browser's navigation state, reported to the shell via
/// `nav_state_js` below. Every field is backed by a verified CEF callback
/// (`on_address_change`, `on_title_change`, `on_loading_state_change` - see
/// `webrender.rs`'s `OsrDisplayHandler`/`OsrLoadHandler`), per the P1 rule of
/// only reporting state actually observed, not guessed.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct NavState {
    pub url: String,
    pub title: String,
    pub loading: bool,
    pub can_back: bool,
    pub can_forward: bool,
}

/// Escapes a string for embedding as a JSON string literal. Hand-rolled
/// instead of a `serde_json` dependency (none added by this change, per the
/// task's "no new dependencies" constraint) - the input is a page title or
/// URL, not attacker-controlled structured data, so covering the
/// JSON-mandatory escapes is enough.
pub fn json_escape_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Renders `nav` as the complete `shell/state/nav.js` script body: a single
/// `window.__NAV = {...};` assignment, matching the wire format
/// `2_configs/shell/state.js` polls for (see that file's header comment).
/// main.rs writes this atomically (temp file + rename); this function only
/// builds the string.
pub fn nav_state_js(nav: &NavState) -> String {
    format!(
        "window.__NAV = {{\"url\":{},\"title\":{},\"loading\":{},\"can_back\":{},\"can_forward\":{}}};\n",
        json_escape_str(&nav.url),
        json_escape_str(&nav.title),
        nav.loading,
        nav.can_back,
        nav.can_forward,
    )
}

/// Derives the `shell/state/` directory from the chrome shell's `file://`
/// URL (the same URL loaded into the chrome browser), so main.rs writes
/// `nav.js` next to `state.js` without needing a separate `--state-dir`
/// switch. `None` for any non-`file://` shell URL - nothing sensible to
/// write to.
///
/// Strips a `#fragment` first: `build.sh`'s launcher appends
/// `#open=<base64>` when it hands the shell a URL to open in a tab, and
/// base64's alphabet includes `/` - left in, that could make `Path::parent`
/// treat a byte inside the fragment as a directory separator.
pub fn shell_state_dir(shell_url: &str) -> Option<std::path::PathBuf> {
    let without_fragment = shell_url.split('#').next().unwrap_or(shell_url);
    let path = without_fragment.strip_prefix("file://")?;
    let parent = std::path::Path::new(path).parent()?;
    Some(parent.join("state"))
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

    #[test]
    fn content_rect_starts_below_chrome_and_spans_full_width() {
        let rect = content_rect(1000.0, 800.0, 100.0);
        assert_eq!(rect.x, 0.0);
        assert_eq!(rect.y, 100.0);
        assert_eq!(rect.width, 1000.0);
        assert_eq!(rect.height, 700.0);
    }

    #[test]
    fn content_rect_clamps_chrome_height_taller_than_window() {
        let rect = content_rect(1000.0, 50.0, 100.0);
        assert_eq!(rect.y, 50.0);
        assert_eq!(rect.height, 0.0);
    }

    #[test]
    fn hit_test_above_content_rect_hits_chrome_unchanged() {
        let content = content_rect(1000.0, 800.0, 100.0);
        assert_eq!(
            hit_test(50.0, 50.0, content),
            HitTarget::Chrome { x: 50.0, y: 50.0 }
        );
    }

    #[test]
    fn hit_test_top_edge_of_content_rect_hits_content() {
        // The content rect starts AT y == chrome_height (inclusive).
        let content = content_rect(1000.0, 800.0, 100.0);
        assert_eq!(
            hit_test(50.0, 100.0, content),
            HitTarget::Content { x: 50.0, y: 0.0 }
        );
    }

    #[test]
    fn hit_test_inside_content_translates_to_local_space() {
        let content = content_rect(1000.0, 800.0, 100.0);
        assert_eq!(
            hit_test(120.0, 250.0, content),
            HitTarget::Content { x: 120.0, y: 150.0 }
        );
    }

    #[test]
    fn hit_test_outside_content_bounds_hits_chrome() {
        let content = content_rect(1000.0, 800.0, 100.0);
        // Past the right/bottom edges of the window entirely.
        assert_eq!(
            hit_test(1000.0, 799.0, content),
            HitTarget::Chrome {
                x: 1000.0,
                y: 799.0
            }
        );
    }

    #[test]
    fn parse_command_requires_prefix() {
        assert_eq!(parse_command("navigate https://example.com"), None);
    }

    #[test]
    fn parse_command_navigate() {
        assert_eq!(
            parse_command("__CMD__navigate https://example.com"),
            Some(Command::Navigate("https://example.com".to_string()))
        );
    }

    #[test]
    fn parse_command_navigate_requires_url() {
        assert_eq!(parse_command("__CMD__navigate"), None);
        assert_eq!(parse_command("__CMD__navigate   "), None);
    }

    #[test]
    fn parse_command_simple_verbs() {
        assert_eq!(parse_command("__CMD__back"), Some(Command::Back));
        assert_eq!(parse_command("__CMD__forward"), Some(Command::Forward));
        assert_eq!(parse_command("__CMD__reload"), Some(Command::Reload));
        assert_eq!(parse_command("__CMD__stop"), Some(Command::Stop));
        assert_eq!(parse_command("__CMD__quit"), Some(Command::Quit));
    }

    #[test]
    fn parse_command_find_family() {
        assert_eq!(
            parse_command("__CMD__find hello world"),
            Some(Command::Find("hello world".to_string()))
        );
        assert_eq!(parse_command("__CMD__find-next"), Some(Command::FindNext));
        assert_eq!(parse_command("__CMD__find-prev"), Some(Command::FindPrev));
        assert_eq!(
            parse_command("__CMD__find-cancel"),
            Some(Command::FindCancel)
        );
        assert_eq!(parse_command("__CMD__find"), None);
    }

    #[test]
    fn parse_command_scroll() {
        assert_eq!(
            parse_command("__CMD__scroll 0 120"),
            Some(Command::Scroll(0, 120))
        );
        assert_eq!(
            parse_command("__CMD__scroll -10 -20"),
            Some(Command::Scroll(-10, -20))
        );
        assert_eq!(parse_command("__CMD__scroll 1"), None);
        assert_eq!(parse_command("__CMD__scroll a b"), None);
        assert_eq!(parse_command("__CMD__scroll 1 2 3"), None);
    }

    #[test]
    fn parse_command_js() {
        assert_eq!(
            parse_command("__CMD__js alert(1)"),
            Some(Command::Js("alert(1)".to_string()))
        );
        assert_eq!(parse_command("__CMD__js"), None);
    }

    #[test]
    fn parse_command_focus() {
        assert_eq!(
            parse_command("__CMD__focus content"),
            Some(Command::Focus(FocusTarget::Content))
        );
        assert_eq!(
            parse_command("__CMD__focus chrome"),
            Some(Command::Focus(FocusTarget::Chrome))
        );
        assert_eq!(parse_command("__CMD__focus tab"), None);
    }

    #[test]
    fn parse_command_unknown_verb_is_none() {
        assert_eq!(parse_command("__CMD__bogus"), None);
    }

    #[test]
    fn json_escape_handles_quotes_and_backslashes() {
        let escaped = json_escape_str("a\"b\\c");
        assert!(escaped.starts_with('"') && escaped.ends_with('"'));
        assert!(escaped.contains("\\\"")); // escaped quote
        assert!(escaped.contains("\\\\")); // escaped backslash
    }

    #[test]
    fn json_escape_handles_control_chars() {
        assert_eq!(json_escape_str("a\nb"), "\"a\\nb\"");
    }

    #[test]
    fn nav_state_js_produces_window_assignment() {
        let nav = NavState {
            url: "https://example.com".to_string(),
            title: "Example".to_string(),
            loading: true,
            can_back: false,
            can_forward: true,
        };
        let js = nav_state_js(&nav);
        assert!(js.starts_with("window.__NAV = {"));
        assert!(js.contains("\"url\":\"https://example.com\""));
        assert!(js.contains("\"title\":\"Example\""));
        assert!(js.contains("\"loading\":true"));
        assert!(js.contains("\"can_back\":false"));
        assert!(js.contains("\"can_forward\":true"));
    }

    #[test]
    fn shell_state_dir_from_file_url() {
        assert_eq!(
            shell_state_dir("file:///home/x/shell/index.html"),
            Some(std::path::PathBuf::from("/home/x/shell/state"))
        );
    }

    #[test]
    fn shell_state_dir_rejects_non_file_url() {
        assert_eq!(shell_state_dir("https://example.com/index.html"), None);
    }

    #[test]
    fn shell_state_dir_strips_fragment_with_embedded_slash() {
        // A base64 fragment can contain '/' - it must not be mistaken for a
        // path separator when deriving the parent directory.
        assert_eq!(
            shell_state_dir("file:///home/x/shell/index.html#open=aG/R0cA=="),
            Some(std::path::PathBuf::from("/home/x/shell/state"))
        );
    }
}
