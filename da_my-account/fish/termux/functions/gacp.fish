# no-arg guard added 2026-08-08 (audit: bare $argv[1] crashed/degenerated)
if test (count $argv) -eq 0; echo "usage: gacp <commit-message>" >&2; return 1; end
git add --all; and git commit -m $argv[1]; and git.push
