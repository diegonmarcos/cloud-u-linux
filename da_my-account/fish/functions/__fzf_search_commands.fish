set -l cmd (begin
  # Get all commands from PATH
  for dir in $PATH
    if test -d $dir
      command ls -1 $dir 2>/dev/null
    end
  end
  # Also include fish functions and builtins
  functions -n
  builtin -n
end | sort -u | fzf --height 40% --reverse --border --prompt="Commands> ")
if test -n "$cmd"
  commandline -i $cmd
end
commandline -f repaint
