#!/usr/bin/env bash
set -euo pipefail

# requires gh jq

fetchPage() {
  local cursor="${1:-null}" # must be json, usually a quoted base64 string

  echo >&2 "fetchPage {cursor: $cursor}"

  # https://docs.github.com/en/graphql/reference/objects#repository
  # https://docs.github.com/en/graphql/reference/objects#pullrequest
  # todo: somehow filter out merge conflicts using the labels
  graphql_query='
    query {
      repository(owner: "NixOS", name: "nixpkgs") {
        pullRequests(last: 50, states: OPEN, before: '"$cursor"') {
          nodes {
            number
            isDraft
            files(first: 100) {
              nodes {
                path
              }
            }
          }
          pageInfo {
            startCursor
            hasPreviousPage
          }
        }
      }
    }'

  gh api graphql --raw-field query="$graphql_query"
}


declare output_file="$1"
declare cursor="${2:-}"

touch "$output_file"
[[ -w "$output_file" ]]

while true; do
  declare resp
  if resp="$(fetchPage "$cursor")"; then

    jq <<<"$resp" '.data.repository.pullRequests.nodes[] | select(.isDraft|not) | { number: .number, path: .files.nodes[].path }' -c >>"$output_file"

    # if [[ "$(jq <<<"$resp" '.data.repository.pullRequests.pageInfo.hasNextPage')" = "true" ]]; then
    if [[ "$(jq <<<"$resp" '.data.repository.pullRequests.pageInfo.hasPreviousPage')" = "true" ]]; then
      # cursor=$(jq <<<"$resp" '.data.repository.pullRequests.pageInfo.endCursor')
      cursor=$(jq <<<"$resp" '.data.repository.pullRequests.pageInfo.startCursor')
    else
      break
    fi
  else
    break
  fi

  sleep 0.2
done

echo "last cursor: $cursor"
