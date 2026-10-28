{
  description = "aihc-fmt: a Haskell formatter based on aihc-parser";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # The aihc-parser submodule is part of the source. Nix 2.27 or later
    # copies it into the flake source only when this flag is set.
    self.submodules = true;
  };

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    forAllSystems = nixpkgs.lib.genAttrs systems;

    fmtSource = pkgs:
      pkgs.lib.fileset.toSource {
        root = ./.;
        fileset = pkgs.lib.fileset.unions [
          ./LICENSE
          ./aihc-fmt.cabal
          ./app
          ./src
          ./test
        ];
      };

    parserSource = pkgs:
      pkgs.lib.fileset.toSource {
        root = ./aihc-parser;
        fileset = pkgs.lib.fileset.unions [
          ./aihc-parser/LICENSE
          ./aihc-parser/CHANGELOG.md
          ./aihc-parser/aihc-parser.cabal
          ./aihc-parser/docs
          ./aihc-parser/src
          ./aihc-parser/test
          ./aihc-parser/common
        ];
      };

    mkHsPkgs = pkgs: let
      hsLib = pkgs.haskell.lib;
      withoutProfiling = drv:
        hsLib.disableExecutableProfiling (hsLib.disableLibraryProfiling drv);
      localPackageNames = ["aihc-fmt" "aihc-parser"];
      isOverridableHaskellDrv = drv:
        pkgs.lib.isDerivation drv && drv.isHaskellLibrary or false;
      # Do not run the tests, Haddock, or profiling builds of upstream
      # packages. The aihc repository uses the same override, so the two
      # flakes can share these store paths.
      disableUpstreamChecks = builtins.mapAttrs (
        name: drv:
          if builtins.elem name localPackageNames || !(isOverridableHaskellDrv drv)
          then drv
          else hsLib.dontCheck (hsLib.dontHaddock (withoutProfiling drv))
      );
    in
      pkgs.haskell.packages.ghc9124.override {
        overrides = final: prev:
          disableUpstreamChecks prev
          // {
            # The aihc-parser test suite needs packages that are not in
            # nixpkgs. The formatter needs only the library, so the build
            # does not run those tests.
            aihc-parser = hsLib.dontCheck (hsLib.dontHaddock (withoutProfiling (
              final.callCabal2nix "aihc-parser" (parserSource pkgs) {
                aihc-cpp = null;
                aihc-hackage = null;
              }
            )));
            aihc-fmt =
              hsLib.overrideCabal (withoutProfiling (
                final.callCabal2nix "aihc-fmt" (fmtSource pkgs) {}
              )) (old: {
                doCheck = true;
                configureFlags = (old.configureFlags or []) ++ ["--ghc-options=-Werror"];
                testFlags = ["--hide-successes"];
              });
          };
      };

    lintSource = pkgs:
      pkgs.lib.fileset.toSource {
        root = ./.;
        fileset = pkgs.lib.fileset.unions [
          ./aihc-fmt.cabal
          ./app
          ./src
          ./test
          ./flake.nix
        ];
      };
  in {
    packages = forAllSystems (system: let
      pkgs = import nixpkgs {inherit system;};
      hsPkgs = mkHsPkgs pkgs;
    in {
      default = hsPkgs.aihc-fmt;
      inherit (hsPkgs) aihc-fmt;
    });

    apps = forAllSystems (system: let
      pkgs = import nixpkgs {inherit system;};
    in {
      default = {
        type = "app";
        program = pkgs.lib.getExe' self.packages.${system}.aihc-fmt "aihc-fmt";
        meta.description = "Format Haskell source files";
      };
    });

    checks = forAllSystems (system: let
      pkgs = import nixpkgs {inherit system;};
      src = lintSource pkgs;
      sourceCheck = name: inputs: command:
        pkgs.runCommand name {
          nativeBuildInputs = inputs;
          inherit src;
        } ''
          cp -r "$src" source
          chmod -R u+w source
          cd source
          ${command}
          touch "$out"
        '';
      haskellFiles = "find app src test -name '*.hs' -print0";
    in {
      fmt-tests = self.packages.${system}.aihc-fmt;
      haskell-format = sourceCheck "aihc-fmt-haskell-format" [pkgs.ormolu pkgs.findutils] ''
        ${haskellFiles} | xargs -0 ormolu --mode check
      '';
      haskell-lint = sourceCheck "aihc-fmt-haskell-lint" [pkgs.hlint pkgs.findutils] ''
        ${haskellFiles} | xargs -0 hlint
      '';
      cabal-format = sourceCheck "aihc-fmt-cabal-format" [pkgs.haskellPackages.cabal-gild] ''
        cabal-gild --mode check --input aihc-fmt.cabal
      '';
      nix-format = sourceCheck "aihc-fmt-nix-format" [pkgs.alejandra] ''
        alejandra --check flake.nix
      '';
      nix-lint = sourceCheck "aihc-fmt-nix-lint" [pkgs.statix] ''
        statix check flake.nix
      '';
    });

    devShells = forAllSystems (system: let
      pkgs = import nixpkgs {inherit system;};
      hsPkgs = mkHsPkgs pkgs;
    in {
      default = pkgs.mkShell {
        packages = [
          hsPkgs.ghc
          pkgs.cabal-install
          pkgs.just
          pkgs.ormolu
          pkgs.hlint
          pkgs.haskellPackages.cabal-gild
          pkgs.alejandra
          pkgs.statix
          pkgs.zlib
        ];
      };
    });

    formatter = forAllSystems (system: (import nixpkgs {inherit system;}).alejandra);
  };
}
