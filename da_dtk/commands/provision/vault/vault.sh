#!/bin/sh
# Vault setup — build credentials + export env vars
# Usage: vault.sh [build|env-export]
set -eu

R='\033[0m'; C='\033[1;36m'; Y='\033[1;33m'; G='\033[1;32m'
W='\033[1;37m'; D='\033[0;90m'; RED='\033[1;31m'

VAULT_DIR="${HOME}/git/cloud-vault"
VAULT_BUILD="$VAULT_DIR/build.sh"
PROVIDERS_DIR="$VAULT_DIR/A0_keys/providers"

_check_vault() {
  if [ ! -d "$VAULT_DIR" ]; then
    printf "  ${RED}Vault repo not found${R}  %s\n" "$VAULT_DIR"
    printf "  ${D}git clone git@github.com:diegonmarcos/cloud-vault.git ~/git/cloud-vault${R}\n"
    return 1
  fi
  return 0
}

do_build() {
  printf "\n${C}── Vault Build ──${R}\n\n"
  _check_vault || return 1

  if [ ! -f "$VAULT_BUILD" ]; then
    printf "  ${RED}build.sh not found${R}  %s\n" "$VAULT_BUILD"
    return 1
  fi

  printf "  ${Y}Running vault build.sh...${R}\n\n"
  sh "$VAULT_BUILD"
}

do_env_export() {
  printf "\n${C}── Vault Env Vars Export ──${R}\n\n"
  _check_vault || return 1

  _count=0

  # Anthropic
  _key="$PROVIDERS_DIR/anthropic/api-key_opaque"
  if [ -f "$_key" ]; then
    ANTHROPIC_API_KEY=$(cat "$_key")
    export ANTHROPIC_API_KEY
    printf "  ${G}%-30s${R} ${D}%s${R}\n" "ANTHROPIC_API_KEY" "set"
    _count=$((_count + 1))
  fi

  # GitHub
  _key="$PROVIDERS_DIR/github/api-key_opaque"
  if [ -f "$_key" ]; then
    GITHUB_TOKEN=$(cat "$_key")
    export GITHUB_TOKEN
    printf "  ${G}%-30s${R} ${D}%s${R}\n" "GITHUB_TOKEN" "set"
    _count=$((_count + 1))
  fi
  _key="$PROVIDERS_DIR/github/token"
  if [ -f "$_key" ]; then
    GH_TOKEN=$(cat "$_key")
    export GH_TOKEN
    printf "  ${G}%-30s${R} ${D}%s${R}\n" "GH_TOKEN" "set"
    _count=$((_count + 1))
  fi

  # Cloudflare
  _key="$PROVIDERS_DIR/cloudflare/api-key_opaque"
  if [ -f "$_key" ]; then
    CLOUDFLARE_API_TOKEN=$(cat "$_key")
    export CLOUDFLARE_API_TOKEN
    printf "  ${G}%-30s${R} ${D}%s${R}\n" "CLOUDFLARE_API_TOKEN" "set"
    _count=$((_count + 1))
  fi

  # Cloudflare Wrangler
  _key="$PROVIDERS_DIR/cloudflare-wrangler/api-key_opaque"
  if [ -f "$_key" ]; then
    CLOUDFLARE_API_TOKEN_WRANGLER=$(cat "$_key")
    export CLOUDFLARE_API_TOKEN_WRANGLER
    printf "  ${G}%-30s${R} ${D}%s${R}\n" "CLOUDFLARE_API_TOKEN_WRANGLER" "set"
    _count=$((_count + 1))
  fi

  # AWS
  _key="$PROVIDERS_DIR/aws/api-key_opaque"
  if [ -f "$_key" ]; then
    AWS_ACCESS_KEY_ID=$(cat "$_key")
    export AWS_ACCESS_KEY_ID
    printf "  ${G}%-30s${R} ${D}%s${R}\n" "AWS_ACCESS_KEY_ID" "set"
    _count=$((_count + 1))
  fi

  # C3 API
  _key="$PROVIDERS_DIR/c3-api/api-key_opaque"
  if [ -f "$_key" ]; then
    C3_API_KEY=$(cat "$_key")
    export C3_API_KEY
    printf "  ${G}%-30s${R} ${D}%s${R}\n" "C3_API_KEY" "set"
    _count=$((_count + 1))
  fi

  # NocoDB
  _key="$PROVIDERS_DIR/nocodb/api-key_opaque"
  if [ -f "$_key" ]; then
    NOCODB_API_TOKEN=$(cat "$_key")
    export NOCODB_API_TOKEN
    printf "  ${G}%-30s${R} ${D}%s${R}\n" "NOCODB_API_TOKEN" "set"
    _count=$((_count + 1))
  fi

  # Crawlee
  _key="$PROVIDERS_DIR/crawlee/api-key_opaque"
  if [ -f "$_key" ]; then
    CRAWLEE_API_KEY=$(cat "$_key")
    export CRAWLEE_API_KEY
    printf "  ${G}%-30s${R} ${D}%s${R}\n" "CRAWLEE_API_KEY" "set"
    _count=$((_count + 1))
  fi

  # Resend
  _key="$PROVIDERS_DIR/resend/resend.env"
  if [ -f "$_key" ]; then
    # Source env file (KEY=VALUE format)
    while IFS='=' read -r _k _v; do
      [ -z "$_k" ] && continue
      case "$_k" in \#*) continue ;; esac
      export "$_k=$_v"
      printf "  ${G}%-30s${R} ${D}%s${R}\n" "$_k" "set"
      _count=$((_count + 1))
    done < "$_key"
  fi

  printf "\n  ${W}%d${R} env vars exported\n" "$_count"
  printf "  ${D}Note: vars are set in this shell only. Source with:${R}\n"
  printf "  ${D}  eval \$(~/git/cloud-mykonsole-dtk/commands/provision/vault/vault.sh env-export-eval)${R}\n\n"
}

do_env_export_eval() {
  # Machine-readable output for eval — no colors, just export statements
  _check_vault || return 1

  for _provider in anthropic github cloudflare cloudflare-wrangler aws c3-api nocodb crawlee; do
    _key="$PROVIDERS_DIR/$_provider/api-key_opaque"
    [ ! -f "$_key" ] && continue
    _val=$(cat "$_key")
    case "$_provider" in
      anthropic)            printf 'export ANTHROPIC_API_KEY="%s"\n' "$_val" ;;
      github)               printf 'export GITHUB_TOKEN="%s"\n' "$_val" ;;
      cloudflare)           printf 'export CLOUDFLARE_API_TOKEN="%s"\n' "$_val" ;;
      cloudflare-wrangler)  printf 'export CLOUDFLARE_API_TOKEN_WRANGLER="%s"\n' "$_val" ;;
      aws)                  printf 'export AWS_ACCESS_KEY_ID="%s"\n' "$_val" ;;
      c3-api)               printf 'export C3_API_KEY="%s"\n' "$_val" ;;
      nocodb)               printf 'export NOCODB_API_TOKEN="%s"\n' "$_val" ;;
      crawlee)              printf 'export CRAWLEE_API_KEY="%s"\n' "$_val" ;;
    esac
  done

  _key="$PROVIDERS_DIR/github/token"
  [ -f "$_key" ] && printf 'export GH_TOKEN="%s"\n' "$(cat "$_key")"

  _key="$PROVIDERS_DIR/resend/resend.env"
  if [ -f "$_key" ]; then
    while IFS='=' read -r _k _v; do
      [ -z "$_k" ] && continue
      case "$_k" in \#*) continue ;; esac
      printf 'export %s="%s"\n' "$_k" "$_v"
    done < "$_key"
  fi
}

# ── dispatch ──
_cmd="${1:-}"
case "$_cmd" in
  build)          do_build ;;
  env-export)     do_env_export ;;
  env-export-eval) do_env_export_eval ;;
  *)
    printf "\n${C}── Vault Setup ──${R}\n\n"
    printf "  ${Y}46a${R}  vault-build       Run vault build.sh (symlinks + perms)\n"
    printf "  ${Y}46b${R}  env-vars-export   Export API keys as env vars\n\n"
    ;;
esac
