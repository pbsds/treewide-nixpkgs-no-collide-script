#!/usr/bin/env bash

set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' exit

numbers=( "$@" )

fetchChunk() {
  local start=$1
  local end=$2
  local chunkSize
  local result

  #echo "Trying to fetch files for PRs $(( start + 1 )) to $end out of ${#numbers[@]}" >&2

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

fetchRange() {
  local start=$1
  local end=$2
  local mid=$(( (start + end ) / 2 ))

  if ! fetchChunk "$start" "$end"; then
    echo "Fetching failed, trying again split in two" >&2
    fetchRange "$start" "$mid"
    fetchRange "$mid" "$end"
  fi
}

start=0
end=${#numbers[@]}

fetchRange 0 "${#numbers[@]}"
