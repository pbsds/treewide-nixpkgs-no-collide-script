#!/usr/bin/env nix-shell
#!nix-shell -i bash -p github-cli jq

set -euo pipefail
set -x

#from='last month'
from='yesterday'
nixpkgs=$HOME/src/nixpkgs/main

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' exit

gh pr list -R NixOS/nixpkgs --limit 10000 --search "updated:>$(date --date="$from" -I)" --json files \
  | jq -r '.[].files[].path' \
  | sort -u > "$tmp"/pr-files

git -C "$nixpkgs" ls-files "*.nix" \
  | sort > "$tmp"/all-files

comm -23 "$tmp"/all-files "$tmp"/pr-files > "$SCRIPT_DIR"/files-to-format
