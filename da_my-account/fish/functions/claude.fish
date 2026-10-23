# claude — wrap the auto-patched binary in `script` so that Claude Code
# always sees a real PTY on all FDs. Under proot+Nix+Termux, stdout of a
# glibc-linked Node.js process can lose its TTY status even when running
# from an interactive terminal (ioctl TCGETS → ENOTTY). script creates an
# unambiguous PTY that both the kernel and Node.js recognise.
script -q -c "command claude $argv" /dev/null