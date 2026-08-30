// my-watchdog as a library, so the one copy of the sampler serves both its own
// binary and my-konsole.
//
// my-konsole used to carry a second copy of watchdog.rs. Two files that must
// stay identical are a bug waiting for someone to fix one of them, and this
// repo already has the answer next door: `pty-core = { path = "../pty-core" }`
// in the very Cargo.toml that needs this. A path dependency rather than a
// filesystem symlink because cargo compiles it once and rustc resolves it the
// same way on every machine, where a symlink is a property of one checkout.
pub mod watchdog;

// The terminal UI. Optional so the fleet daemon stays std + libc — see
// tui/mod.rs for why that matters more than the convenience of one binary.
// INHERITED LINTS, NOT ACCEPTED ONES.
//
// This tree is 11k lines that moved here from my-konsole, where it was never
// linted: that crate ran `build.sh check` without -D warnings. da_watchdog
// runs clippy strictly, which is the better arrangement and is why these
// surfaced the first time it looked at them.
//
// They are allowed at the module boundary rather than fixed in the same commit
// as the move, because every one of them is a rewrite inside code whose
// behaviour has just changed address — and a style fix that quietly changes
// behaviour is far more expensive than the lint. Each is a real thing to burn
// down, individually, where the diff can be read:
//   type_complexity     a few signatures that want a `type` alias
//   needless_lifetimes  elidable 'a
//   if_same_then_else   branches that ended up identical
//   useless_vec         vec![] where a slice would do
//   new_without_default Monitor::new has no Default
//   absurd_extreme_comparisons  a saturating_sub guard that can never fire —
//                       the one with real meaning, and the reason this list is
//                       a TODO rather than a decision
#[cfg(feature = "tui")]
#[allow(
    clippy::type_complexity,
    clippy::needless_lifetimes,
    clippy::if_same_then_else,
    clippy::useless_vec,
    clippy::new_without_default,
    clippy::absurd_extreme_comparisons,
    // rustc's, not clippy's, and separate for that reason.
    unused_mut,
    dead_code
)]
pub mod tui;
