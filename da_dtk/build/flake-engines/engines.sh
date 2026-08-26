#!/bin/sh
# Engines module — launch build engines for each repo
set -eu

_git="${HOME:-/home/diego}/git"
_idx="${1:-}"

if [ -z "$_idx" ]; then
  echo "Build Engines:"
  echo "  1) nixos-host       ~/git/cloud-unix/aa_nixos-surface_host/build.sh"
  echo "  2) home-desktop     ~/git/cloud-unix/ba_flakes_desktop/build.sh"
  echo "  3) home-termux      ~/git/cloud-unix/bb_flakes_termux/build.sh"
  echo "  4) cloud-service    ~/git/cloud-infra/a_solutions/<service>/build.sh"
  echo "  5) front-end        ~/git/front/1.ops/build_main.sh"
  printf "> "
  read -r _idx
fi

case "$_idx" in
  1) sh "$_git/cloud-unix/aa_nixos-surface_host/build.sh" ;;
  2) sh "$_git/cloud-unix/ba_flakes_desktop/build.sh" ;;
  3) sh "$_git/cloud-unix/bb_flakes_termux/build.sh" ;;
  4)
    echo "Cloud services:"
    _i=1; _services=""
    for _bs in "$_git"/cloud/a_solutions/*/build.sh; do
      [ -f "$_bs" ] || continue
      _svc=$(basename "$(dirname "$_bs")")
      printf "  %d) %s\n" "$_i" "$_svc"
      _services="${_services}${_svc}
"
      _i=$((_i + 1))
    done
    printf "> "
    read -r _sidx
    _c=0
    echo "$_services" | while read -r _s; do
      [ -z "$_s" ] && continue
      _c=$((_c + 1))
      if [ "$_c" -eq "$_sidx" ]; then
        sh "$_git/cloud-infra/a_solutions/$_s/build.sh"
        break
      fi
    done
    ;;
  5) sh "$_git/front/1.ops/build_main.sh" ;;
  *) echo "Invalid" ;;
esac
