# ---------------------------------------------------------------------------
# Configuration — constants and mount tables
# ---------------------------------------------------------------------------

# AI Agent selection (default: claude)
AI_AGENT="${AI_AGENT:-claude}"

# Claude
PKG="@anthropic-ai/claude-code"
CLAUDE_IMAGE="node:20-slim"
CARBONYL_IMAGE="fathyb/carbonyl"
LOGFILE="${HOME}/claude.log"

# Sandbox read-only mounts (source:dest — omit dest if same as source)
SANDBOX_RO_MOUNTS="
/nix
/usr
/lib
/lib64
/bin
/sbin
/etc/resolv.conf
/etc/hosts
/etc/ssl
/etc/ca-certificates
/etc/passwd
/etc/group
${HOME}/.ssh
${HOME}/.gitconfig
"

# Sandbox read-write mounts
SANDBOX_RW_MOUNTS="
${HOME}/.claude
${HOME}/.config
${HOME}/.npm-global
${HOME}/mnt_git
"

# SSL cert paths (distro-agnostic)
SSL_CERT_PATHS="
/etc/ssl/certs/ca-certificates.crt
/etc/ssl/certs/ca-bundle.crt
/etc/pki/tls/certs/ca-bundle.crt
/etc/ssl/cert.pem
"
