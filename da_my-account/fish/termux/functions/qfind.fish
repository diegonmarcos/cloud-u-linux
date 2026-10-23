# no-arg guard added 2026-08-08 (audit: bare $argv[1] crashed/degenerated)
if test (count $argv) -eq 0; echo "usage: qfind <name-fragment>" >&2; return 1; end
command find . -name "*$argv[1]*"
