#!/usr/bin/env bash
set -euo pipefail

# requires gh jq, optionally gum

export OWNER="${OWNER:-NixOS}"
export REPO="${REPO:-nixpkgs}"

fetchPage() {
  local cursor="${1:-null}" # must be json, usually a quoted base64 string

  echo >&2 "fetchPage {cursor: $cursor}"

  # https://docs.github.com/en/graphql/reference/objects#repository
  # https://docs.github.com/en/graphql/reference/objects#pullrequest
  # todo: somehow filter out merge conflicts using the labels
  graphql_query='
    query {
      repository(owner: "'"$OWNER"'", name: "'"$REPO"'") {
        pullRequests(last: 35, states: OPEN, before: '"$cursor"') {
          nodes {
            number
            isDraft
            updatedAt
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

if [[ -z "$cursor" && -t 0 ]] && command -v gum >/dev/null && gum confirm "Resume from $(</tmp/nixpkgs_prs_graphql_cursor)?"; then
  cursor="$(</tmp/nixpkgs_prs_graphql_cursor)"
fi

touch "$output_file"
[[ -w "$output_file" ]]

let retry_count=0 || :
while true; do
  declare resp
  if resp="$(fetchPage "$cursor")"; then

    echo >&2 "jq ..."
    jq <<<"$resp" '.data.repository.pullRequests.nodes[] | select(.isDraft|not) | { number: .number, path: .files.nodes[].path }' -c >>"$output_file"

    if [[ "$(jq <<<"$resp" '.data.repository.pullRequests.pageInfo.hasPreviousPage')" = "true" ]]; then
      cursor=$(jq <<<"$resp" '.data.repository.pullRequests.pageInfo.startCursor')
      cat <<<"$cursor" >/tmp/nixpkgs_prs_graphql_cursor
      echo >&2 "lowest pr number: $(jq <<<"$resp" '.data.repository.pullRequests.nodes|map(.number)|min') {cursor: $cursor}"

    else
      echo >&2 "No more pages!"
      break
    fi

    if [[ "$(jq <<<"$resp" '.data.repository.pullRequests.nodes | [.[].updatedAt | fromdateiso8601 | (now - .) > 60*60*4*356*2] | all')" = true ]]; then
      echo >&2 "Full page of PRs last updated over 2 years ago, exiting..."
      break
    fi

    # decrease backoff
    if [[ $retry_count -gt 0 ]]; then
      ((retry_count--)) || :
    fi

  else
    # retry with backoff
    ((retry_count++))
    if [[ $retry_count -gt 7 ]]; then
      break
    fi

  fi

  echo >&2 "sleep $((2 ** $retry_count))" || :
  sleep "$((2 ** $retry_count))" || :
done

echo "last cursor: $cursor"
