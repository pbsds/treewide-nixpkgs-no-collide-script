#!/usr/bin/env nix-shell
#!nix-shell -i bash --pure -p jq github-cli
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' exit

{
  for day in $(seq 0 60); do
    date=$(date --date="$day days ago" -I -u)
    echo "Fetching PRs from $date" >&2
    result=$(gh pr list -R NixOS/nixpkgs --limit 500 --search "updated:$date -label:\"2.status: merge conflict\"" --json files,number |
      jq '.[] | select(.number != 322537 and .number != 327796)' -c)
    count=$(jq -s 'length' <<< "$result")
    echo "Got $count PRs" >&2
    echo -n "$result"
  done
} |
  jq -s 'map(
    .number as $number |
      .files[] |
      { number: $number, path: .path }
    ) |
    reduce .[] as $item ({};
      . "\($item.path)" += [ $item.number ]
    ) |
    to_entries |
    sort_by(.value | length) |
    .[] |
    "\(.key) \(.value | join(" "))"
  ' -r > "$(dirname "${BASH_SOURCE[0]}")/prs-by-file"
