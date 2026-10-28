# Commands for aihc-fmt

# Run the test suite and hide successful results.
test:
  cabal test -v0 all --test-options=--hide-successes

# Format the Haskell, Cabal, and Nix files.
fmt:
  nix develop --quiet --command bash -c 'cabal-gild --mode format --io aihc-fmt.cabal; find app src test -name "*.hs" -print0 | xargs -0 ormolu --mode inplace; alejandra -q flake.nix'

# Run the format checks, the lint checks, and the test suite.
check:
  nix develop --quiet --command bash -c 'cabal-gild --mode check --input aihc-fmt.cabal'
  nix develop --quiet --command bash -c 'find app src test -name "*.hs" -print0 | xargs -0 ormolu --mode check'
  nix develop --quiet --command bash -c 'find app src test -name "*.hs" -print0 | xargs -0 hlint'
  nix develop --quiet --command bash -c 'alejandra --check -q flake.nix && statix check flake.nix'
  cabal test -v0 all --ghc-options=-Werror --test-options=--hide-successes

# Run all checks in an isolated sandbox, as CI does.
nix-check:
  nix flake check -L
