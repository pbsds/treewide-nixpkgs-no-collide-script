{
  system ? builtins.currentSystem,
  baseRev,
  check ? false,
}:
let
  baseNixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/archive/${baseRev}.tar.gz";

  pinnedNixpkgsInfo = builtins.fromJSON (builtins.readFile (baseNixpkgs + "/ci/pinned-nixpkgs.json"));
  pinnedNixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${pinnedNixpkgsInfo.rev}.tar.gz";
    inherit (pinnedNixpkgsInfo) sha256;
  };

  pkgs = import pinnedNixpkgs {
    inherit system;
    config = {};
    overlays = [];
  };

  nixfmtSrc = fetchTarball {
    url = "https://github.com/NixOS/nixfmt/archive/b19ea26a7de2e4f46176990ebbe90528e5d79af1.tar.gz";
    sha256 = "0j8gv0cpjp2yxp5il8diq1lhw5jzra5zz6xp8rl3fss3v49f5kyz";
  };
  nixfmt = (import nixfmtSrc { inherit system; }).packages.nixfmt;

  nix = pkgs.nixVersions.latest;

  prsByFilePath = ./prs-by-file;

  files = pkgs.runCommand "files" {
    nativeBuildInputs = [
      pkgs.fd
    ];
  } ''
    mkdir $out
    cd ${baseNixpkgs}

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

  checkedNixfmt = pkgs.writeShellScript "checked-nixfmt" ''
    set -euo pipefail

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
        # TODO: Replace with pkgs.nixfmt-rfc-style once the pinned Nixpkgs has been updated in master:
        # https://github.com/NixOS/nixpkgs/tree/master/ci#pinned-nixpkgs
        nixfmt
        nix
        pkgs.gitMinimal
        pkgs.parallel
      ];
    }
    ''
      set -euo pipefail
      cp -r --no-preserve=mode ${baseNixpkgs} $out
      cd $out
      export NIX_STATE_DIR=$(mktemp -d)
      nix-store --init

      parallel --bar -P "$NIX_BUILD_CORES" -a "${files}/files-to-format" ${if check then checkedNixfmt else "nixfmt"} {}
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

        nix-build https://github.com/infinisil/treewide-nixpkgs-reformat-script/archive/$Format:%H$.tar.gz \
          --argstr baseRev ${baseRev}
        result/bin/apply-formatting $NIXPKGS_PATH
  '';

in
pkgs.writeShellApplication {
  name = "apply-formatting";
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
}
