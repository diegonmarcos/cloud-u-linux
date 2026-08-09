## MANDATORY PRE-ACTION CHECKLIST

Before EVERY modification:
1. **SOURCE CHECK**: Am I editing SOURCE (git `src/`) or DEPLOYED output (VM, dist/, ~/.claude/)?
2. **PIPELINE CHECK**: Am I using `build.sh` or bypassing it?
3. **SECRETS CHECK**: Am I creating secrets via sops pipeline or manually?
4. **SHELL CHECK**: `command -v` not `which`. Nix source not `sed` on VM.
