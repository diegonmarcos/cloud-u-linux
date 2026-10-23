# no-arg guard added 2026-08-08 (audit: bare $argv[1] crashed/degenerated)
if test (count $argv) -eq 0; echo "usage: backup <file>" >&2; return 1; end
if test -f $argv[1]
  set -l timestamp (date +%Y%m%d_%H%M%S)
  cp $argv[1] "$argv[1].backup.$timestamp"
  echo "Backup created: $argv[1].backup.$timestamp"
else
  echo "File not found: $argv[1]"
end
