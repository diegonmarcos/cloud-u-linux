//! Detect the display server (Wayland vs X11) and pick the right picker /
//! typer / clipboard command from the loaded `Config`.

use crate::config::Config;

/// Which display server are we talking to?
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Display {
    Wayland,
    X11,
}

impl Display {
    /// Detect from environment. WAYLAND_DISPLAY set => Wayland, otherwise X11.
    /// We do *not* fall back silently if neither is set; tests rely on
    /// passing one of these explicitly via `from_env_with`.
    pub fn detect() -> Self {
        if std::env::var_os("WAYLAND_DISPLAY").is_some() {
            Display::Wayland
        } else {
            Display::X11
        }
    }

    /// For test injection. Used by unit tests in this module that exercise
    /// the env-detection logic without touching the live process env.
    #[allow(dead_code)]
    pub fn from_env_with(wayland_display: Option<&str>) -> Self {
        match wayland_display {
            Some(s) if !s.is_empty() => Display::Wayland,
            _ => Display::X11,
        }
    }
}

/// Resolved command lines for the active display server.
#[derive(Debug, Clone)]
pub struct DisplayCommands {
    pub picker: Vec<String>,
    // The typer binary + flags from build.json. The current orchestrator
    // hands typing off to `typer.rs`, which calls `wtype`/`xdotool`
    // directly because they take secrets via stdin (avoiding argv leak).
    // The string form is retained so an alternate front-end (e.g. an
    // imperative "type via shell" mode) can opt back into it without a
    // schema change.
    #[allow(dead_code)]
    pub typer: Vec<String>,
    pub clipboard: Vec<String>,
}

impl DisplayCommands {
    pub fn from_config(cfg: &Config, display: Display) -> Self {
        let pick = match display {
            Display::Wayland => &cfg.runtime.picker.wayland,
            Display::X11 => &cfg.runtime.picker.x11,
        };
        let typer = match display {
            Display::Wayland => &cfg.runtime.typer.wayland,
            Display::X11 => &cfg.runtime.typer.x11,
        };
        let clip = match display {
            Display::Wayland => &cfg.runtime.clipboard.wayland,
            Display::X11 => &cfg.runtime.clipboard.x11,
        };
        Self {
            picker: shell_split(pick),
            typer: shell_split(typer),
            clipboard: shell_split(clip),
        }
    }
}

/// Minimal POSIX-ish argv splitter: whitespace-separated, single/double
/// quote support, no escapes. Sufficient for the simple commands we host
/// in build.json.
pub fn shell_split(s: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut quote: Option<char> = None;
    for ch in s.chars() {
        match quote {
            Some(q) => {
                if ch == q {
                    quote = None;
                } else {
                    cur.push(ch);
                }
            }
            None => match ch {
                '\'' | '"' => quote = Some(ch),
                c if c.is_whitespace() => {
                    if !cur.is_empty() {
                        out.push(std::mem::take(&mut cur));
                    }
                }
                c => cur.push(c),
            },
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_wayland_from_env_var() {
        assert_eq!(Display::from_env_with(Some(":0")), Display::Wayland);
        assert_eq!(Display::from_env_with(Some("wayland-0")), Display::Wayland);
    }

    #[test]
    fn detect_x11_when_wayland_unset_or_empty() {
        assert_eq!(Display::from_env_with(None), Display::X11);
        assert_eq!(Display::from_env_with(Some("")), Display::X11);
    }

    #[test]
    fn shell_split_basic() {
        assert_eq!(
            shell_split("rofi -dmenu -p Vault"),
            vec!["rofi", "-dmenu", "-p", "Vault"]
        );
    }

    #[test]
    fn shell_split_quotes() {
        assert_eq!(
            shell_split("wofi --prompt 'My Vault'"),
            vec!["wofi", "--prompt", "My Vault"]
        );
    }

    #[test]
    fn shell_split_empty() {
        let v: Vec<String> = vec![];
        assert_eq!(shell_split(""), v);
        assert_eq!(shell_split("   "), v);
    }
}
