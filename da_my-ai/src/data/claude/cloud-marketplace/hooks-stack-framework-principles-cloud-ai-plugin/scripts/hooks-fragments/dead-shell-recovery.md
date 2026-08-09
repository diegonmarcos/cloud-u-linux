## DEAD SHELL RECOVERY

If Bash fails on everything (even `echo test`), the CWD was deleted by git mv/rm.
**Fix**: Use `Write` tool to create a dummy file at the dead path → restores CWD → Bash works again.
Then clean up with `git checkout HEAD -- path/` or continue with absolute paths.
