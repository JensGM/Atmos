# atmos, in Haskell, aimed at wasm

A working subset of atmos written to answer a specific question: what does it
cost to compile atmos to WebAssembly, and what has to change about storage to
get there. The findings are in
[`docs/haskell-wasm-evaluation.md`](../docs/haskell-wasm-evaluation.md); this
directory is the code they were measured on.

Everything here builds unchanged with a stock GHC and with `wasm32-wasi-ghc`.
It depends only on GHC boot libraries (`base`, `containers`, `directory`,
`filepath`, `time`, `unix`) — no `aeson`, no `sqlite`, nothing needing a C
toolchain beyond the RTS.

## Layout

    src/Atmos/Types.hs           the whole of atmos' persistent state, as types
    src/Atmos/Codec.hs           line framing and filename escaping
    src/Atmos/Store.hs           the storage interface, and atomic file replace
    src/Atmos/Store/Files.hs     file-per-library store (recommended)
    src/Atmos/Store/SingleFile.hs  one-file store, kept for comparison
    src/Atmos/Link.hs            symlink creation, removal and verification
    app/Main.hs                  CLI
    bench/Bench.hs               storage micro-benchmark
    probes/                      one program per question about the wasm runtime
    scripts/                     toolchain setup, wasm runners, acceptance test

## Building

Native:

    cabal build all

wasm, once `scripts/setup-toolchain.sh` (or ghc-wasm-meta's `bootstrap.sh`)
has run:

    . ~/.ghc-wasm/env
    wasm32-wasi-cabal build all

Add `-f sqlite` to build the two probes that pull in `direct-sqlite`.

## Running the wasm build

With node, mapping the whole host filesystem in:

    node ~/.ghc-wasm/wasm-run/bin/wasm-run.mjs \
      "$(wasm32-wasi-cabal list-bin exe:atmos)" --link-style=relative list linked

With wasmtime, via the helper that makes preopens explicit:

    python3 scripts/run-wasmtime.py "$(wasm32-wasi-cabal list-bin exe:atmos)" \
      --map "$HOME/atmos::/atmos" --map /usr/local::/dest list linked

`scripts/wasm-run-nofs.mjs` runs a module with no preopened directories at all,
which is the closest node gets to the browser's situation.

## The two flags that are not in the Python CLI

    --store=files|single-file        which backend to use
    --link-style=absolute|relative   what to write into the symlinks

`--link-style` exists because WASI refuses to create a symlink whose target is
absolute. Python atmos always writes absolute targets; a wasm build can only
create links at all with `relative`. Both styles resolve to the same file for
anything reading the destination tree.

## Acceptance test

    scripts/acceptance.sh "$(cabal list-bin exe:atmos)" absolute files
    scripts/acceptance.sh "node .../wasm-run.mjs $(wasm32-wasi-cabal list-bin exe:atmos)" relative files

It builds a throwaway library (including a relative symlink that must be
transported verbatim), links it, verifies it, checks every resulting link
resolves on the host, and unlinks it.

## What is deliberately missing

`unlink --full` and the parts of `verify` that attribute unrecorded links by
scanning `dest_root`. Both rest on reading the target of links that atmos did
not record, which is exactly what wasmtime refuses to do when the target is
absolute — see the evaluation for the measurements.
