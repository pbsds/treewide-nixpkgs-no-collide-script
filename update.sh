#!/usr/bin/env nix-shell
#!nix-shell -i bash --pure -p jq github-cli parallel
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' exit
set -euo pipefail

# https://stackoverflow.com/a/246128/6605742
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

days=60
chunkSize=40
concurrent=20

numbers=()
# From the back so that we don't miss PRs updated while running this script
for day in $(seq "$(( days - 1 ))" -1 0); do
  date=$(date --date="$day days ago" -I -u)
  echo "Fetching PRs from $date" >&2
  result=$(gh pr list -R NixOS/nixpkgs --limit 1000 --search "updated:$date -label:\"2.status: merge conflict\"" --json number |
    jq '.[].number | select(. != 322537 and . != 327796)')
  readarray -t -O"${#numbers[@]}" numbers <<< "$result"
done
echo "Got ${#numbers[@]} PRs" >&2

printf "%s\n" "${numbers[@]}" | \
  parallel --bar -n "$chunkSize" -P "$concurrent" "$SCRIPT_DIR"/fetch.sh | \
  jq -s '
    reduce .[] as $item ({};
      . "\($item.path)" += [ $item.number ]
    ) |
    to_entries |
    sort_by((.value | length), .key) |
    .[] |
    "\(.key) \(.value | sort | join(" "))"
  ' -r > "$(dirname "${BASH_SOURCE[0]}")/prs-by-file"
