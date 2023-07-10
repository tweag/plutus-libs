{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-stable.follows = "";
    };
  };

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
            ## hooks. Since we take our tools (`nixfmt`, `hpack`) from
            ## `nixpkgs`, then we can simply make sure that
            ## `pre-commit-hooks.nix`'s `nixpkgs` input follows ours, so there
            ## is nothing to see here.

            ## NOTE: Configuring `hpack` here would have no effect. See
            ## https://github.com/cachix/pre-commit-hooks.nix/issues/255
            ## for more information.

            ## NOTE: We want Ormolu to be exactly the one provided by HLS, but
            ## this Ormolu is actually a dependency of `hls-ormolu-plugin`,
            ## itself a dependency of HLS. We therefore define a function
            ## `getDeps` that gathers direct Haskell build dependencies and we
            ## use it to go get our Ormolu.
            ormolu = let
              getDeps = p:
                builtins.listToAttrs (map (dependency:
                  pkgs.lib.nameValuePair dependency.pname dependency)
                  p.passthru.getBuildInputs.haskellBuildInputs);
            in (getDeps (getDeps
              hpkgs.haskell-language-server).hls-ormolu-plugin).ormolu.bin;
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
            ## NOTE: `haskell-language-server` provides Ormolu, so there is no
            ## need to add it here. If it did not, we would have to resort to a
            ## trick such as the one used in `pre-commit-hooks`'s configuration
            ## above.
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
