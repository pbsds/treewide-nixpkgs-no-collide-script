{
  system ? builtins.currentSystem,
  baseRev ? "7ffbecde9aa26364ac79010154bf78bb77529fd2",
}:
rec {
  nixpkgs = fetchTarball {
    url = "https://github.com/tweag/nixpkgs/archive/${baseRev}.tar.gz";
    sha256 = "11b7nvmz4qfh6dk0p6cs11qsinpa0xcj99h8m9xd9rbrghf3pxh9";
  };

  pkgs = import nixpkgs {
    inherit system;
    config = {};
    overlays = [];
  };
  prsByFilePath = ./prs-by-file;

  nixSrc = fetchTarball {
    url = "https://github.com/NixOS/nix/archive/8f22245fdfee1516614b0eb09538ea7e4448f5bb.tar.gz";
    sha256 = "1bb4fpb6kdi7vrhwqghl2880rx3pzzxij42izfn4br93ymbi6vgk";
  };

  nixfmtSrc = fetchTarball {
    url = "https://github.com/NixOS/nixfmt/archive/99829a0b149eab4d82764fb0b5d4b6f3ea9a480d.tar.gz";
    sha256 = "0lnl9vlbyrfplmq3hpmpjlmhjdwwbgk900wgi25ib27v0mlgpnxp";
  };
  nixfmt = (import nixfmtSrc { inherit system; }).packages.nixfmt;

  files = pkgs.runCommand "files" {
      nativeBuildInputs = [
        pkgs.fd
      ];
  } ''
    mkdir $out
    cd ${nixpkgs}

    # All Nix files
    fd -t f -e nix \
      | sort > "$out"/all-files

    # All files touched by recent PRs
    cut -d' ' -f1 "${prsByFilePath}" |
      sort -u > "$out/pr-files"

    # All Nix files that haven't been touched by recent PRs
    comm -23 "$out"/all-files "$out"/pr-files > "$out/files-to-format"

    # The number of those
    wc -l < $out/files-to-format > $out/count
  '';

  processFile = pkgs.writeShellScript "process" ''
    set -euo pipefail

    #echo "Formatting file $1" >&2
    before=$(nix-instantiate --parse "$1")
    nixfmt --verify "$1"
    after=$(nix-instantiate --parse "$1")
    if [[ "$before" != "$after" ]]; then
      echo "$1 parses differently after formatting:" >&2
      git -P diff --no-index --word-diff <(cat <<< "$before") <(cat <<< "$after") || true
      exit 255
    fi
  '';

  formatted = pkgs.runCommand "nixpkgs-formatted"
    {
      nativeBuildInputs = [
        (pkgs.nixVersions.latest.overrideAttrs (old: {
          src = nixSrc;
          patches = old.patches or [] ++ [
            # https://github.com/NixOS/nix/pull/11120
            (pkgs.fetchpatch {
              url = "https://github.com/NixOS/nix/commit/9fae50ed4be6c7f8bd16ece9626709d78bb4b01c.patch";
              hash = "sha256-2Z9UxT3m/m3acpRiqjGHd3bKjUz78/6IU8susrk59OU=";
            })
            (pkgs.fetchpatch {
              url = "https://github.com/NixOS/nix/commit/23c44d98664b81f06259fc785a31dfcf6d7c1a9f.patch";
              hash = "sha256-BMMM0SPzrPmsnmCaezuqjx4Yif5IyV96CPsAzGnBvvY=";
            })
            # https://github.com/NixOS/nix/pull/11123
            (pkgs.fetchpatch {
              url = "https://github.com/NixOS/nix/commit/94975d4625b464609a2e5cd7e4862375518bf4ec.patch";
              hash = "sha256-2QE204IqKk0x0htD9nuBOCqxnGVAdeBaTthcV+lR8ok=";
            })
          ];
        }))
        nixfmt
        pkgs.gitMinimal
        pkgs.parallel
      ];
    }
    ''
      set -euo pipefail
      cp -r --no-preserve=mode ${nixpkgs} $out
      cd $out
      export NIX_STATE_DIR=$(mktemp -d)
      nix-store --init

      parallel --bar -P "$NIX_BUILD_CORES" -a "${files}/files-to-format" ${processFile} {}
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

  applyFormatting = pkgs.writeShellApplication {
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
  };

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
