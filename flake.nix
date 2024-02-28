{
  description = "hfsnotify";

  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, flake-utils, haskellNix, ... }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ] (system:
    let
      overlays = [ haskellNix.overlay
        (final: prev: {
          hfsnotify =
            final.haskell-nix.cabalProject' {
              src = ./.;
              index-state = "2024-01-16T23:00:16Z";
              compiler-nix-name = "ghc964";
              shell = {
                tools = {
                  cabal = {};
                  ghcid = {};
                  haskell-language-server = {};
                };
                withHoogle = true;
              };

              modules =
                [{  enableLibraryProfiling = true;
                 }
                ];
            };
        })
      ];
      pkgs = import nixpkgs { inherit system overlays;
                              inherit (haskellNix) config; };
      flake = pkgs.hfsnotify.flake { };

    in flake);
}
