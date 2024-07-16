{
  system ? builtins.currentSystem,
}:
let
  baseRev = "7ffbecde9aa26364ac79010154bf78bb77529fd2";

  nixpkgs = fetchTarball "https://github.com/tweag/nixpkgs/archive/${baseRev}.tar.gz";

  pkgs = import nixpkgs {
    inherit system;
    config = {};
    overlays = [];
  };
  prsByFilePath = ./prs-by-file;

  nixfmtSrc = fetchTarball {
    url = "https://github.com/NixOS/nixfmt/archive/99829a0b149eab4d82764fb0b5d4b6f3ea9a480d.tar.gz";
    sha256 = "0lnl9vlbyrfplmq3hpmpjlmhjdwwbgk900wgi25ib27v0mlgpnxp";
  };
  nixfmt = (import nixfmtSrc { inherit system; }).packages.nixfmt;

  formatted = pkgs.runCommand "nixpkgs-formatted"
    {
      nativeBuildInputs = [
        nixfmt
        pkgs.fd
        pkgs.nix
      ];
    }
    ''
      tmp=$(mktemp -d)

      cp -r --no-preserve=mode ${nixpkgs} $out
      cd $out

      fd -t f -e nix \
        | sort > "$tmp"/all-files

      cut -d' ' -f1 "${prsByFilePath}" |
        sort -u > "$tmp/pr-files"

      comm -23 "$tmp"/all-files "$tmp"/pr-files > "$tmp/files-to-format"

      xargs -P "$NIX_BUILD_CORES" -a "$tmp/files-to-format" nixfmt

      export NIX_STATE_DIR=$(mktemp -d)

      while IFS= read -r file; do
        if [[ "$(nix-instantiate --parse "''${nixpkgs}/$file")" != "$(nix-instantiate --parse ./"$file")" ]]; then
          echo "$file parses differently after formatting"
        fi
      done < "$tmp/files-to-format"
    '';

  message = ''
    treewide: format all inactive Nix files

    Inactive means that there are no open PRs with activity in the
    last month that touch those files.
    A bunch later, we can do another pass to get the rest.

    Doing it this way makes ensures that we don't cause any conflicts for
    recently active PRs that would be ready to merge.
    Only once those PRs get updated, CI will kick in and require the files
    to be formatted.

    Furthermore, this makes sure that we can merge this PR without having
    to constantly rebase it!

    This can be verified using

        nix-build https://gist.github.com/infinisil/4b7a1a1e5db681d04446e73e39048aec/archive/$Format:%H$.tar.gz
        result/bin/check-formatting $NIXPKGS_PATH
  '';
in
pkgs.writeShellApplication {
  name = "check-formatting";
  excludeShellChecks = [ "SC2016" ];
  text = ''
    nixpkgs=$1

    tmp=$(mktemp -d)
    cleanup() {
      # Don't exit early if anything fails to cleanup
      set +o errexit
      [[ -e "$tmp/formatted" ]] && git -C "$nixpkgs" worktree remove --force "$tmp/formatted"
      rm -rf "$tmp"
    }
    trap cleanup exit

    git -C "$nixpkgs" worktree add "$tmp/formatted" "${baseRev}"

    rsync -r ${formatted}/ "$tmp/formatted"
    git -C "$tmp/formatted" commit -a -m ${pkgs.lib.escapeShellArg message}
    formattedRev=$(git -C "$tmp/formatted" rev-parse HEAD)
    echo -e "\n# treewide: Nix format pass 1\n$formattedRev" >> "$tmp/formatted/.git-blame-ignore-revs"
    git -C "$tmp/formatted" commit -a -m ".git-blame-ignore-revs: Add treewide Nix format"
    finalRev=$(git -C "$tmp/formatted" rev-parse HEAD)
    git -C "$nixpkgs" diff HEAD.."$finalRev" || true
    echo "Final revision: $finalRev (you can use this in e.g. \`git reset --hard\`)"
  '';
} // {
  updateFiles = pkgs.writeShellApplication {
    name = "update-files-to-format";
    runtimeInputs = with pkgs; [
      github-cli
      jq
      fd
    ];
    text = ''
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' exit

      {
        for day in $(seq 0 60); do
          date=$(date --date="$day days ago" -I -u)
          echo "Fetching PRs from $date" >&2
          result=$(gh pr list -R NixOS/nixpkgs --limit 500 --search "updated:$date -label:\"2.status: merge conflict\"" --json files,number |
            jq '.[] | select(.number != 322537)' -c)
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
        ' -r > "${toString prsByFilePath}"
    '';
  };
}
