# no-arg guard added 2026-08-08 (audit: bare $argv[1] crashed/degenerated)
if test (count $argv) -eq 0; echo "usage: extract <archive>" >&2; return 1; end
if test -f $argv[1]
  switch $argv[1]
    case '*.tar.bz2'
      tar xjf $argv[1]
    case '*.tar.gz'
      tar xzf $argv[1]
    case '*.tar.xz'
      tar xJf $argv[1]
    case '*.tar.zst'
      unzstd $argv[1]
    case '*.bz2'
      bunzip2 $argv[1]
    case '*.gz'
      gunzip $argv[1]
    case '*.tar'
      tar xf $argv[1]
    case '*.zip'
      unzip $argv[1]
    case '*.7z'
      7z x $argv[1]
    case '*.deb'
      ar x $argv[1]
    case '*.rar'
      unrar x $argv[1]
    case '*'
      echo "'$argv[1]' cannot be extracted"
  end
end
