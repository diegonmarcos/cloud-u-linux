//! Put text on the clipboard from inside a full-screen TUI.
//!
//! TWO MECHANISMS, BOTH TRIED, because the panel runs in two places that share
//! no clipboard at all:
//!
//!   OSC 52  an escape sequence the TERMINAL acts on. It is the only thing
//!           that works over ssh — and this dashboard is read over ssh far
//!           more often than it is read locally, since every fleet machine is
//!           somewhere else. Nothing needs to be installed at either end.
//!   wl-copy / xclip / xsel
//!           the local session's own clipboard, for a desktop where the
//!           terminal may have OSC 52 disabled (many do, since a program that
//!           can write your clipboard can also read the screen you paste into).
//!
//! Both are attempted and the caller is told which worked, because "copied"
//! with nothing on the clipboard is worse than an error.
use std::io::Write;
use std::process::{Command, Stdio};

/// base64, by hand. Four lines of table lookup against a whole crate for a
/// dependency that would appear in the closure of every machine this ships to
/// — including the static musl build whose entire point is that it carries
/// nothing.
fn b64(bytes: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let b = [c[0], *c.get(1).unwrap_or(&0), *c.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(A[(n >> 18 & 63) as usize] as char);
        out.push(A[(n >> 12 & 63) as usize] as char);
        out.push(if c.len() > 1 { A[(n >> 6 & 63) as usize] as char } else { '=' });
        out.push(if c.len() > 2 { A[(n & 63) as usize] as char } else { '=' });
    }
    out
}

/// Feed one local clipboard tool on stdin. Absent tool is not an error — most
/// machines have exactly one of these and no reason to have the others.
fn pipe(prog: &str, args: &[&str], text: &str) -> bool {
    let Ok(mut ch) = Command::new(prog)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    let Some(mut si) = ch.stdin.take() else { return false };
    let ok = si.write_all(text.as_bytes()).is_ok();
    drop(si);
    matches!(ch.wait(), Ok(s) if s.success()) && ok
}

/// Copy, and say how. `Err` only when nothing at all could have worked.
pub fn copy(text: &str) -> Result<String, String> {
    let mut how: Vec<&str> = vec![];

    // Terminal first: it is the one that works from a peer over ssh, and it
    // costs a write either way.
    //
    // Some terminals cap the sequence (~74KB is the common figure) and a
    // screenful is a few KB, so the cap is not worth a chunking protocol here.
    // Written straight to stdout: the alternate screen is still up, and an OSC
    // is not drawn, so nothing on screen moves.
    let mut out = std::io::stdout();
    if out.write_all(format!("\x1b]52;c;{}\x07", b64(text.as_bytes())).as_bytes()).is_ok()
        && out.flush().is_ok()
    {
        how.push("terminal (OSC 52)");
    }

    // …then the local session, for a terminal with OSC 52 turned off. Wayland
    // before X11 because this desktop is Plasma on Wayland; xclip still works
    // there through Xwayland, but it is the fallback's fallback.
    if pipe("wl-copy", &[], text) {
        how.push("wl-copy");
    } else if pipe("xclip", &["-selection", "clipboard"], text) {
        how.push("xclip");
    } else if pipe("xsel", &["--clipboard", "--input"], text) {
        how.push("xsel");
    }

    if how.is_empty() {
        Err("no clipboard — the terminal refused OSC 52 and no wl-copy/xclip/xsel is installed".into())
    } else {
        Ok(how.join(" + "))
    }
}

#[cfg(test)]
mod tests {
    use super::b64;

    // The one part with rules in it. RFC 4648 vectors, including both padding
    // shapes — a base64 that is right on 3-byte multiples and wrong on the
    // remainder produces a clipboard that silently truncates.
    #[test]
    fn base64_matches_the_rfc_vectors() {
        assert_eq!(b64(b""), "");
        assert_eq!(b64(b"f"), "Zg==");
        assert_eq!(b64(b"fo"), "Zm8=");
        assert_eq!(b64(b"foo"), "Zm9v");
        assert_eq!(b64(b"foob"), "Zm9vYg==");
        assert_eq!(b64(b"fooba"), "Zm9vYmE=");
        assert_eq!(b64(b"foobar"), "Zm9vYmFy");
    }
}
