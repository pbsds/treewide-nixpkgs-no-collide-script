{
  system ? builtins.currentSystem,
}:
let
  baseRev = "6bf4ef3fafa1746608e08a21709e3f77f0790e8c";

  nixpkgs = fetchTarball {
    url = "https://github.com/tweag/nixpkgs/archive/${baseRev}.tar.gz";
    sha256 = "0xkvwfrdnszq43jqyfp0njr32kx3vnnb2pcbqwva3i9wzgljz155";
  };
  pkgs = import nixpkgs {
    inherit system;
    config = {};
    overlays = [];
  };
  filesToFormatFile = ./files-to-format;

  nixfmtSrc = fetchTarball {
    url = "https://github.com/NixOS/nixfmt/archive/99829a0b149eab4d82764fb0b5d4b6f3ea9a480d.tar.gz";
    sha256 = "0lnl9vlbyrfplmq3hpmpjlmhjdwwbgk900wgi25ib27v0mlgpnxp";
  };
  nixfmt = (import nixfmtSrc { inherit system; }).packages.nixfmt;

  formatted = pkgs.runCommand "nixpkgs-formatted"
    {
      outputHash = "YUEl4LCz5CDqRevJQaCplWpTLpoxhaxX8YonAAnIE10=";
      outputHashAlgo = "sha256";
      outputHashMode = "recursive";

      nativeBuildInputs = [
        nixfmt
      ];

      passthru.updateFiles = pkgs.writeShellApplication {
        name = "update-files-to-format";
        runtimeInputs = with pkgs; [
          github-cli
          jq
          fd
        ];
        text = ''
          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' exit

          set -x

          {
            for day in $(seq 0 30); do
              gh pr list -R NixOS/nixpkgs --limit 500 --search "updated:$(date --date="$day days ago" -I -u)" --json files |
                jq '.[]' -c 
            done
          } |
            jq -r '.files[].path' |
            sort -u > "$tmp"/pr-files

          cd ${nixpkgs}
          fd -t f -e nix \
            | sort > "$tmp"/all-files

          comm -23 "$tmp"/all-files "$tmp"/pr-files > ${toString filesToFormatFile}
        '';
      };

    }
    ''
      cp -r --no-preserve=mode ${nixpkgs} $out
      cd $out
      xargs -P "$NIX_BUILD_CORES" -a ${filesToFormatFile} nixfmt
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

    This can be reproduced with this gist: https://gist.github.com/infinisil/4b7a1a1e5db681d04446e73e39048aec/archive/$Format:%H$.tar.gz
  '';
in
pkgs.writeShellApplication {
  name = "check-formatting";
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
    echo -e "\n# treewide: Nix format pass 1\n$formattedRev" > "$tmp/formatted/.git-blame-ignore-revs"
    git -C "$tmp/formatted" commit -a -m ".git-blame-ignore-revs: Add treewide Nix format"
    finalRev=$(git -C "$tmp/formatted" rev-parse HEAD)
    echo "Final revision: $finalRev"
    git -C "$nixpkgs" diff "$formattedRev"
  '';
}
