{
  description = "Static Language Server";

  inputs = {
    hackage = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };
    hs-nix-infra = {
      url = "github:kadena-io/hs-nix-infra";
      inputs.hackage.follows = "hackage";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, hs-nix-infra, flake-utils, ... }:
    flake-utils.lib.eachSystem
      [ "x86_64-linux" "x86_64-darwin"
        "aarch64-linux" "aarch64-darwin" ] (system:
    let
      inherit (hs-nix-infra) nixpkgs haskellNix;
      pkgs = import nixpkgs {
        inherit system overlays;
        inherit (haskellNix) config;
      };
      project = pkgs.static-ls;
      flake = project.flake {
        # crossPlatforms = p: [ p.ghcjs ];
      };
      overlays = [ haskellNix.overlay
        (final: prev: {
          static-ls =
            final.haskell-nix.project' {
              src = ./.;
              compiler-nix-name = "ghc964";
              shell.tools = {
                cabal = {};
                haskell-language-server = {};
                # hlint = {};
              };
              shell.buildInputs = with pkgs; [
                sqlite
                ghcid
                hpack
                pkg-config
              ];
              # shell.crossPlatforms = p: [ p.ghcjs ];
            };
        })
      ];
      # This package depends on other packages at buildtime, but its output does not
      # depend on them. This way, we don't have to download the entire closure to verify
      # that those packages build.
      mkCheck = name: package: pkgs.runCommand ("check-"+name) {} ''
        echo ${name}: ${package}
        echo works > $out
      '';
    in rec {
      packages.default = flake.packages."static-ls:exe:static-ls";
      packages.recursive = with hs-nix-infra.lib.recursive system;
        wrapRecursiveWithMeta "static-ls" "${wrapFlake self}.default";

      inherit (flake) devShell;

      packages.check = pkgs.runCommand "check" {} ''
        echo ${mkCheck "static-ls" packages.default}
        echo ${mkCheck "devShell" devShell}
        echo works > $out
      '';

      # Other flake outputs provided by haskellNix can be accessed through
      # this project output
      inherit project;
    });
}
