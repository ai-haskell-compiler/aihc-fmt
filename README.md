# aihc-fmt

aihc-fmt is a Haskell formatter.
It uses the parser and the pretty-printer of
[aihc-parser](https://github.com/ai-haskell-compiler/aihc-parser).

The formatter keeps each source token and each comment.
It changes only the whitespace between the tokens.
It takes the layout from the aihc-parser pretty-printer.
Then, it makes sure that the token stream of the output is the same as the input.

## Get the source

The repository includes aihc-parser as a Git submodule.
Clone it with the submodule:

```bash
git clone --recurse-submodules https://github.com/ai-haskell-compiler/aihc-fmt.git
```

## Build and test

Use the Nix development shell:

```bash
nix develop
```

Run the tests:

```bash
just test
```

Run the format checks, the lint checks, and the tests:

```bash
just check
```

Run the checks that CI runs:

```bash
nix flake check
```

## Change the pretty-printer

Cabal and Nix build aihc-parser from the `aihc-parser` submodule.
Thus, a change in the submodule has an immediate effect on aihc-fmt.

1. Make the change in `aihc-parser`.
2. Run `just test` to see the effect on the formatter fixtures.
3. Push the change to aihc-parser and merge it there.
4. Move the submodule to the new aihc-parser commit and commit it in aihc-fmt.

## Usage

```bash
aihc-fmt --help
```
