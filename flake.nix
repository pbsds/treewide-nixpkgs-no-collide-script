{
  inputs.nixpkgs.url = "https://nixos.org/channels/nixpkgs-unstable/nixexprs.tar.xz";

  outputs =
    { self, nixpkgs }@inputs:
    let
      forSystems =
        systems: f:
        nixpkgs.lib.genAttrs systems (
          system:
          f rec {
            inherit system;
            pkgs = nixpkgs.legacyPackages.${system};
            lib = nixpkgs.legacyPackages.${system}.lib;
          }
        );
      forAllSystems = forSystems nixpkgs.lib.systems.flakeExposed;
    in
    {
      inherit inputs;

      packages = forAllSystems (
        { pkgs, lib, ... }:
        {
          default = pkgs.writeShellScriptBin "fetch.sh" ''
            export PATH="${
              lib.makeBinPath (
                with pkgs;
                [
                  gh
                  jq
                  gum
                ]
              )
            }''${$PATH:+:}$PATH"
            ${builtins.readFile ./fetch.sh}
          '';
        }
      );

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              gh
              jq
              gum
            ];
          };
        }
      );

    };
}
