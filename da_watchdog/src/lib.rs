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
