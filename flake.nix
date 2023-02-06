{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/22.11";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";

  outputs = { self, nixpkgs, flake-utils, pre-commit-hooks }:
    ## Systemd isn't compatible with Darwin, so we can't use `eachDefaultSystem`
    ## as long as `systemd` is a dependency.
    ## TODO: go back to `eachDefaultSystem` once systemd isn't needed anymore.
    with flake-utils.lib;
    eachSystem [ system.x86_64-linux system.aarch64-linux ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        hpkgs = pkgs.haskell.packages.ghc8107;

        pre-commit = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            nixfmt.enable = true;
            ormolu.enable = true;
            hpack.enable = true;
          };
        };
      in {
        formatter = pkgs.nixfmt;

        devShells = let
          ## The minimal dependency set to build the project with `cabal`.
          buildInputs = ([ hpkgs.ghc ]) ++ (with pkgs; [
            cabal-install
            libsodium
            secp256k1
            pkg-config
            zlib
            xz
            z3
            postgresql # For pg_config
            systemd
            pkg-config
            glibcLocales
          ]);

          ## Needed by `pirouette-plutusir` and `cooked`
          LD_LIBRARY_PATH = with pkgs;
            lib.strings.makeLibraryPath [ libsodium zlib xz z3 ];
          LANG = "C.UTF-8";
        in {
          ci = pkgs.mkShell {
            inherit buildInputs;
            inherit LD_LIBRARY_PATH;
            inherit LANG;
          };

          default = pkgs.mkShell {
            ## NOTE: `pkgs.ormolu` must appear before `hpkgs.haskell-language-server`
            ## in the `buildInputs`, so as to take precedence. This ensures that the
            ## version of Ormolu available in the path is that of nixpkgs and not the
            ## one pinned by HLS.
            buildInputs = buildInputs ++ (with pkgs; [ ormolu hpack hlint ])
              ++ (with hpkgs; [ haskell-language-server ]);
            inherit (pre-commit) shellHook;
            inherit LD_LIBRARY_PATH;
            inherit LANG;
          };
        };

        checks = { inherit pre-commit; };
      });
}
