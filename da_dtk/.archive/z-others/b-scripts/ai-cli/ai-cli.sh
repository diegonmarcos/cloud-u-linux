#!/bin/sh
# ai-cli — Unified AI Agent launcher (Goose + MCP)
# Source: ~/git/cloud-mykonsole-dtk/b-scripts/ai-cli/
# POSIX-compliant, no bashisms
set -eu

VERSION="1.0.0"
CONFIG="${AI_CLI_CONFIG:-${HOME}/.config/goose/config.yaml}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AI_CLI_JSON="${SCRIPT_DIR}/ai-cli.json"

# Colors
C="\033[1;36m"   # cyan bold
W="\033[1;37m"   # white bold
Y="\033[1;33m"   # yellow bold
G="\033[32m"     # green
B="\033[36m"     # blue/cyan
D="\033[2m"      # dim
R="\033[0m"      # reset

show_help() {
    GOOSE_VER=$(goose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo '?')
    NUM_EXT=5
    NUM_MODELS=4

    echo ""
    printf "   \033[1;35m █████\033[1;36m ██\033[0m        \033[1;33m █████\033[1;32m ██\033[0m      \033[1;31m ██\033[0m\n"
    printf "   \033[1;35m██   ██\033[1;36m ██\033[0m       \033[1;33m██   ██\033[1;32m ██\033[0m      \033[1;31m ██\033[0m\n"
    printf "   \033[1;35m███████\033[1;36m ██\033[0m \033[2m═══\033[0m  \033[1;33m██     \033[1;32m ██\033[0m      \033[1;31m ██\033[0m\n"
    printf "   \033[1;35m██   ██\033[1;36m ██\033[0m       \033[1;33m██   ██\033[1;32m ██\033[0m      \033[1;31m ██\033[0m\n"
    printf "   \033[1;35m██   ██\033[1;36m ██\033[0m       \033[1;33m █████\033[1;32m ███████\033[0m \033[1;31m ██\033[0m\n"
    printf "                                        \033[1;33m __( O)>\033[0m  \033[1;32m  ██\033[0m\n"
    printf "                                        \033[1;33m\\____) \033[0m  \033[1;32m ████\033[0m\n"
    printf "                                        \033[1;33m  L L  \033[0m  \033[1;32m██  ██\033[1;31m▄\033[0m\n"
    printf "                                               \033[1;32m████████\033[0m\n"
    printf "                                               \033[1;32m██  ▀▀██\033[0m\n"
    printf "                                               \033[1;32m▀▀    ▀▀\033[0m\n"
    echo ""
    printf "   ${W}Unified AI Agent Launcher${R} v${VERSION}\n"
    printf "   ${D}goose v${GOOSE_VER} · block/goose · MCP-native · ${NUM_MODELS} models · ${NUM_EXT} extensions${R}\n"
    echo ""

    printf "  ${Y}SYNTAX${R}\n"
    echo "    ai-cli                         # Haiku 4.5 (default)"
    echo "    ai-cli <model>                 # Launch with specific model"
    echo "    ai-cli <model> <goose-args>    # Pass extra args to goose"
    echo "    ai-cli -h | --help             # This help page"
    echo ""

    printf "  ${Y}━━ A) CLOUD MODELS — Anthropic API ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}\n"
    printf "    ${G}(default)${R}  ${W}Haiku  4.5${R}   200K ctx   ${D}\$0.80/\$4.00 per 1M tok   batch \$0.40/\$2.00${R}\n"
    printf "    ${G}sonnet${R}     ${W}Sonnet 4.6${R}   200K ctx   ${D}\$3.00/\$15.00 per 1M tok  batch \$1.50/\$7.50${R}\n"
    printf "    ${G}opus${R}       ${W}Opus   4.6${R}     1M ctx   ${D}\$15.00/\$75.00 per 1M tok batch \$7.50/\$37.50${R}\n"
    echo ""

    printf "  ${Y}━━ B) LOCAL MODELS — Ollama on oci-apps (ARM CPU, always-on) ━━━━━━━━━━━━━━━━${R}\n"
    printf "    ${B}local${R}      ${W}Qwen   1.5B${R}    4K ctx   ${D}free · Q4_K_M · ~12s/msg · http://10.0.0.6:11435${R}\n"
    echo ""

    printf "  ${Y}━━ C) MCP EXTENSIONS — Tool servers (disabled by default) ━━━━━━━━━━━━━━━━━━${R}\n"
    printf "    ${D}cloud-services         Mattermost, Mail, Dagu, GHA, Ollama, ntfy, Syncthing${R}\n"
    printf "    ${D}cloud-infra            SSH, Docker, health, builds, deploys, VM lifecycle${R}\n"
    printf "    ${D}cloud-cgc-mcp          Infra knowledge graph, octocode semantic search${R}\n"
    printf "    ${D}google-workspace       Gmail, Calendar, Drive, Docs, Sheets, Forms${R}\n"
    printf "    ${D}diego-personal-data    Vault, identity, finance, media (read-only)${R}\n"
    echo "    Enable: goose configure → Extensions"
    echo ""

    printf "  ${Y}━━ D) GOOSE COMMANDS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}\n"
    echo "    goose configure         Configure providers, extensions, permissions"
    echo "    goose session           Start or resume interactive sessions"
    echo "    goose info              Show current configuration"
    echo "    goose run               Execute from instruction file or stdin"
    echo "    goose local-models      Manage local inference models"
    echo ""

    printf "  ${Y}EXAMPLES${R}\n"
    echo "    \$ ai-cli                              # Quick chat with Haiku (cheap+fast)"
    echo "    \$ ai-cli sonnet                       # Complex coding with Sonnet"
    echo "    \$ ai-cli opus                         # Deep reasoning with Opus (1M ctx)"
    echo "    \$ ai-cli local                        # Offline/free with local Qwen"
    echo "    \$ ai-cli sonnet session -r last       # Resume last Sonnet session"
    echo ""

    printf "  ${D}Config:   ${CONFIG}${R}\n"
    printf "  ${D}Models:   ${AI_CLI_JSON}${R}\n"
    printf "  ${D}Total:    ${NUM_MODELS} models (A:3 cloud B:1 local) + ${NUM_EXT} MCP extensions${R}\n"
    echo ""
}

case "${1:-}" in
    -h|--help|help|models)
        show_help
        exit 0
        ;;
    sonnet)
        shift
        GOOSE_PROVIDER=anthropic GOOSE_MODEL=claude-sonnet-4-6 exec goose "$@"
        ;;
    opus)
        shift
        GOOSE_PROVIDER=anthropic GOOSE_MODEL=claude-opus-4-6 exec goose "$@"
        ;;
    local|qwen)
        shift
        GOOSE_PROVIDER=ollama GOOSE_MODEL=qwen2.5-4k exec goose "$@"
        ;;
    haiku)
        shift
        GOOSE_PROVIDER=anthropic GOOSE_MODEL=claude-haiku-4-5-20251001 exec goose "$@"
        ;;
    "")
        GOOSE_PROVIDER=anthropic GOOSE_MODEL=claude-haiku-4-5-20251001 exec goose
        ;;
    *)
        GOOSE_PROVIDER=anthropic GOOSE_MODEL=claude-haiku-4-5-20251001 exec goose "$@"
        ;;
esac
