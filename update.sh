#!/usr/bin/env nix-shell
#!nix-shell -i bash --pure -p jq github-cli
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' exit
set -euo pipefail

initialChunkSize=40
days=60

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


fetchChunk() {
  local start=$1
  local end=$2
  local chunkSize
  local result

  echo "Trying to fetch files for PRs $(( start + 1 )) to $end out of ${#numbers[@]}" >&2

  chunkSize=$(( end - start ))

  {
    echo 'fragment Paths on PullRequest {
      number
      files(first: 100) {
        nodes {
          path
        }
      }
    }

    query {
      repository(owner: "NixOS", name: "nixpkgs") {'

    for number in "${numbers[@]:start:"$chunkSize"}"; do
      echo "n$number: pullRequest(number: $number) { ...Paths }"
    done

    echo '} }'
  } > "$tmp/query.graphql"

  if result=$(gh api graphql -f query="$(<"$tmp"/query.graphql)"); then
    jq -c '.data.repository.[] | { number: .number, path: .files.nodes[].path }' <<< "$result"
  else
    return 1
  fi
}

newEnd() {
  local start=$1
  local end=$(( start + initialChunkSize ))
  if (( end > ${#numbers[@]} )); then
    echo "${#numbers[@]}"
  else
    echo "$end"
  fi
}


start=0
end=$(newEnd "$start")

while (( start < ${#numbers[@]} )); do
  if ! fetchChunk "$start" "$end"; then
    end=$(( (start + end) / 2 )) || true
  else
    start=$end
    end=$(newEnd "$start")
  fi
done | \
  jq -s '
    reduce .[] as $item ({};
      . "\($item.path)" += [ $item.number ]
    ) |
    to_entries |
    sort_by(.value | length) |
    .[] |
    "\(.key) \(.value | join(" "))"
  ' -r > "$(dirname "${BASH_SOURCE[0]}")/prs-by-file"
