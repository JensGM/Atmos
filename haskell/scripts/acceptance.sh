#!/usr/bin/env bash
# End-to-end exercise of the prototype against a throwaway tree.
#
#   scripts/acceptance.sh "<runner>" <link-style> <store>
#
# <runner> is how to invoke the binary, e.g.
#   "$(cabal list-bin exe:atmos)"                              native
#   "node .../wasm-run.mjs $(wasm32-wasi-cabal list-bin exe:atmos)"   wasm on node
#   "python3 run-wasmtime.py $(...)"                           wasm on wasmtime
#
# Exits non-zero if any step fails, so it can be used as a regression gate.
set -uo pipefail

RUNNER=${1:?runner command}
STYLE=${2:-absolute}
STORE=${3:-files}
WORK=${WORK:-/tmp/atmos-accept}

rm -rf "$WORK"
mkdir -p "$WORK/atmos_root/mylib/lib" "$WORK/atmos_root/mylib/bin" "$WORK/dest" "$WORK/state"

echo 'so' >"$WORK/atmos_root/mylib/lib/libfoo.so.1"
echo 'bin' >"$WORK/atmos_root/mylib/bin/foo"
# a relative symlink inside the library: atmos must transport it verbatim
ln -s libfoo.so.1 "$WORK/atmos_root/mylib/lib/libfoo.so"

atmos() { $RUNNER --store="$STORE" --state-dir="$WORK/state" --link-style="$STYLE" "$@"; }

fail=0
step() {
  echo "--- $* ---"
  "$@" || { echo "STEP FAILED: $*"; fail=1; }
}

step atmos set atmos_root "$WORK/atmos_root"
step atmos set dest_root "$WORK/dest"
step atmos list unlinked
step atmos link mylib
step atmos list linked
step atmos list links
step atmos verify

echo "--- resulting tree ---"
find "$WORK/dest" -mindepth 1 -printf '%p -> %l\n' | sort

echo "--- do the links resolve on the host? ---"
for l in $(find "$WORK/dest" -type l | sort); do
  if [ -e "$l" ]; then echo "resolves: $l"; else echo "DANGLING: $l"; fail=1; fi
done

step atmos unlink mylib
remaining=$(find "$WORK/dest" -type l | wc -l)
echo "links remaining after unlink: $remaining"
[ "$remaining" = "0" ] || fail=1

exit $fail
