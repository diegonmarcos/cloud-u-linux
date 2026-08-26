#!/bin/sh
# ai-cli — Unified AI Agent launcher (Claude Code + Goose)
# https://github.com/diegonmarcos/cloud-unix
# POSIX-compliant, no bashisms
set -eu

AI_CLI_VERSION="%%VERSION%%"
# back-compat
CLAUDE_LAUNCHER_VERSION="$AI_CLI_VERSION"
