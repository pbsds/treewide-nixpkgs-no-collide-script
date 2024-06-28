{
  system ? builtins.currentSystem,
  from ? "2024-06-27",
}:
let
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/383744754ed3bf2cfb6cf6ab108bb12b804f8737.tar.gz";
    sha256 = "1bl56im8n0pyn81l89srf7xd03gkq57blwszdgrgsx9srx7ggrm8";
  };
  pkgs = import nixpkgs {
    inherit system;
    config = {};
    overlays = [];
  };
  filesToFormatFile = ./files-to-format;
in
pkgs.runCommand "nixpkgs-formatted"
  {
    outputHash = "sha256-ZwR/McRzXGRiNxJhitd9fHEy1YiYf8uhUSu6ApDKiLo=";
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";

    nativeBuildInputs = with pkgs; [
      nixfmt-rfc-style
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

        gh pr list -R NixOS/nixpkgs --limit 10000 --search "updated:>$(date --date="${from}" -I)" --json files \
          | jq -r '.[].files[].path' \
          | sort -u > "$tmp"/pr-files

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
  ''
