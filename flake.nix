{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
  inputs.pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, flake-utils, pre-commit-hooks }:
    flake-utils.lib.eachDefaultSystem (system:
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
          tools = {
            ## This setting specifies which tools to use in the `pre-commit`
            ## hooks. Since we take our tools (`nixfmt`, `ormolu`, `hpack`) from
            ## `nixpkgs`, then we can simply make sure that
            ## `pre-commit-hooks.nix`'s `nixpkgs` input follows ours, so there
            ## is nothing to see here.
            ##
            ## NOTE: Configuring `hpack` here would have no effect. See
            ## https://github.com/cachix/pre-commit-hooks.nix/issues/255
            ## for more information.

            ## NOTE: We want Ormolu to be exactly the one provided by HLS.
            ## However, `pre-commit-hooks.nix` expects as an `ormolu` tool a
            ## derivation containing a file `bin/ormolu`, which HLS's derivation
            ## does not provide. We therefore build a fake one that immediately
            ## executes to the runtime version of `ormolu` provided by HLS.
            ormolu = pkgs.writeShellApplication {
              name = "ormolu";
              runtimeInputs = [ hpkgs.haskell-language-server ];
              text = ''exec ormolu "$@"'';
            };
          };
        };
      in {
        formatter = pkgs.nixfmt;

        devShells = let
          ## The minimal dependency set to build the project with `cabal`.
          buildInputs = (with hpkgs; [ ghc cabal-install ]) ++ (with pkgs; [
            libsodium
            secp256k1
            pkg-config
            zlib
            xz
            glibcLocales
            postgresql # For pg_config
          ]);

          ## Needed by `pirouette-plutusir` and `cooked`
          LD_LIBRARY_PATH = with pkgs;
            lib.strings.makeLibraryPath [
              libsodium
              zlib
              xz
              postgresql # For cardano-node-emulator
              openldap # For freer-extras‽
            ];
          LANG = "C.UTF-8";
        in {
          ci = pkgs.mkShell {
            inherit buildInputs;
            inherit LD_LIBRARY_PATH;
            inherit LANG;
          };

          default = pkgs.mkShell {
            ## NOTE: haskell-language-server provides ormolu, so there's no
            ## need to add it here.
            buildInputs = buildInputs
              ++ (with hpkgs; [ haskell-language-server hpack hlint ]);
            inherit (pre-commit) shellHook;
            inherit LD_LIBRARY_PATH;
            inherit LANG;
          };
        };

        checks = { inherit pre-commit; };
      });

  nixConfig = {
    extra-trusted-substituters = [
      "https://tweag-cooked-validators.cachix.org/"
      "https://pre-commit-hooks.cachix.org/"
    ];
    extra-trusted-public-keys = [
      "tweag-cooked-validators.cachix.org-1:g1TP7YtXjkBGXP/VbSTGBOGONSzdfzYwNJM27bn8pik="
      "pre-commit-hooks.cachix.org-1:Pkk3Panw5AW24TOv6kz3PvLhlH8puAsJTBbOPmBo7Rc="
    ];
  };
}
