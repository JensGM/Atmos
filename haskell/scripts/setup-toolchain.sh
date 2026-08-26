#!/usr/bin/env bash
# Install the GHC wasm backend the way the evaluation in
# docs/haskell-wasm-evaluation.md was produced.
#
# The supported route is ghc-wasm-meta's own installer:
#
#   curl https://gitlab.haskell.org/ghc/ghc-wasm-meta/-/raw/master/bootstrap.sh | sh
#
# Use that if you can reach GitHub releases.  This script exists for machines
# that cannot: it pulls the same bindists from gitlab.haskell.org CI artifacts
# instead, which is where ghc-wasm-meta's own UPSTREAM_*_PIPELINE_ID paths
# point.  Artifacts expire after a few weeks, so the pipeline/job ids below
# have to be refreshed; the API queries that find current ones are inline.
set -euo pipefail

PREFIX=${PREFIX:-$HOME/.ghc-wasm}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- wasi-sdk -----------------------------------------------------------------
# Current job id:
#   curl -s "https://gitlab.haskell.org/api/v4/projects/3212/pipelines?status=success&per_page=1"
#   curl -s "https://gitlab.haskell.org/api/v4/projects/3212/pipelines/<id>/jobs" | grep x86_64-linux
WASI_SDK_JOB=${WASI_SDK_JOB:-2368960}
WASI_SDK_FILE=${WASI_SDK_FILE:-dist/wasi-sdk-29.0-x86_64-linux.tar.gz}

mkdir -p "$PREFIX/wasi-sdk"
curl -fL --retry 5 \
  "https://gitlab.haskell.org/haskell-wasm/wasi-sdk/-/jobs/$WASI_SDK_JOB/artifacts/raw/$WASI_SDK_FILE" \
  -o "$WORK/wasi-sdk.tar.gz"
tar xzf "$WORK/wasi-sdk.tar.gz" -C "$PREFIX/wasi-sdk" --no-same-owner --strip-components=1

# --- libffi -------------------------------------------------------------------
# GHC's rts declares `extra-libraries: ffi`, so linking needs a libffi for
# wasm32.  The real one is haskell-wasm/libffi-wasm, whose generated sources
# need a native GHC to produce.  Nothing in atmos uses `foreign import ccall
# "wrapper"` or the bytecode interpreter, so stubs that abort if called are
# enough to link; swap in the real library if you add anything that needs it.
cat >"$WORK/ffi_stub.c" <<'STUB'
#include <ffi.h>
#include <stdio.h>
#include <stdlib.h>
static void unsupported(const char *what) {
  fprintf(stderr, "libffi-wasm stub: %s unsupported in this build\n", what);
  abort();
}
void ffi_call(ffi_cif *c, void (*f)(void), void *r, void **a) {
  (void)c; (void)f; (void)r; (void)a; unsupported("ffi_call");
}
ffi_status ffi_alloc_prep_closure(ffi_closure **p, ffi_cif *c,
                                  void (*f)(ffi_cif *, void *, void **, void *),
                                  void *u, void **code) {
  (void)p; (void)c; (void)f; (void)u; (void)code;
  unsupported("ffi_alloc_prep_closure");
  return FFI_CLOSURE_ALLOC_FAIL;
}
void ffi_closure_free(void *p) { (void)p; unsupported("ffi_closure_free"); }
STUB
git clone --depth 1 https://gitlab.haskell.org/haskell-wasm/libffi-wasm.git "$WORK/libffi-wasm"
SYSROOT="$PREFIX/wasi-sdk/share/wasi-sysroot"
"$PREFIX/wasi-sdk/bin/wasm32-wasi-clang" -O2 -I"$WORK/libffi-wasm/cbits" \
  -c "$WORK/libffi-wasm/cbits/ffi.c" -o "$WORK/ffi.o"
"$PREFIX/wasi-sdk/bin/wasm32-wasi-clang" -O2 -I"$WORK/libffi-wasm/cbits" \
  -c "$WORK/ffi_stub.c" -o "$WORK/ffi_stub.o"
"$PREFIX/wasi-sdk/bin/llvm-ar" rcs "$SYSROOT/lib/wasm32-wasi/libffi.a" "$WORK/ffi.o" "$WORK/ffi_stub.o"
cp "$WORK/libffi-wasm/cbits/ffi.h" "$WORK/libffi-wasm/cbits/ffitarget.h" \
  "$SYSROOT/include/wasm32-wasi/"

# --- wasm32-wasi-ghc ----------------------------------------------------------
# Current job id:
#   curl -s "https://gitlab.haskell.org/api/v4/projects/1/pipelines?status=success&ref=master&per_page=1"
#   curl -s ".../pipelines/<id>/jobs?per_page=100" | grep wasm-cross
GHC_JOB=${GHC_JOB:-2623742}
GHC_JOB_NAME=${GHC_JOB_NAME:-x86_64-linux-alpine3_23-wasm-cross_wasm32-wasi-release+host_fully_static+text_simdutf}

curl -fL --retry 5 \
  "https://gitlab.haskell.org/api/v4/projects/1/jobs/$GHC_JOB/artifacts/ghc-$GHC_JOB_NAME.tar.xz" \
  -o "$WORK/ghc.tar.xz"
mkdir -p "$WORK/ghc"
tar xJf "$WORK/ghc.tar.xz" -C "$WORK/ghc" --no-same-owner --strip-components=1

cat >"$PREFIX/env" <<EOF
export PATH=$PREFIX/wasm32-wasi-cabal/bin:$PREFIX/wasi-sdk/bin:$PREFIX/wasm32-wasi-ghc/bin:\$PATH
export AR=$PREFIX/wasi-sdk/bin/llvm-ar
export CC=$PREFIX/wasi-sdk/bin/wasm32-wasi-clang
export CC_FOR_BUILD=cc
export CXX=$PREFIX/wasi-sdk/bin/wasm32-wasi-clang++
export LD=$PREFIX/wasi-sdk/bin/wasm-ld
export NM=$PREFIX/wasi-sdk/bin/llvm-nm
export OBJCOPY=$PREFIX/wasi-sdk/bin/llvm-objcopy
export OBJDUMP=$PREFIX/wasi-sdk/bin/llvm-objdump
export RANLIB=$PREFIX/wasi-sdk/bin/llvm-ranlib
export STRIP=$PREFIX/wasi-sdk/bin/llvm-strip
export LLC=/bin/false
export OPT=/bin/false
EOF

( cd "$WORK/ghc" \
  && . "$PREFIX/env" \
  && ./configure --host=x86_64-linux --target=wasm32-wasi --prefix="$PREFIX/wasm32-wasi-ghc" \
  && RelocatableBuild=YES make install )

# --- cabal --------------------------------------------------------------------
CABAL_VERSION=${CABAL_VERSION:-3.14.2.0}
mkdir -p "$PREFIX/cabal/bin" "$PREFIX/wasm32-wasi-cabal/bin" "$PREFIX/.cabal"
curl -fL --retry 5 \
  "https://downloads.haskell.org/cabal/cabal-install-$CABAL_VERSION/cabal-install-$CABAL_VERSION-x86_64-linux-alpine3_18.tar.xz" \
  -o "$WORK/cabal.tar.xz"
tar xJf "$WORK/cabal.tar.xz" --no-same-owner -C "$PREFIX/cabal/bin" cabal

cat >"$PREFIX/wasm32-wasi-cabal/bin/wasm32-wasi-cabal" <<EOF
#!/bin/sh
CABAL_DIR=$PREFIX/.cabal exec $PREFIX/cabal/bin/cabal \\
  --with-compiler=$PREFIX/wasm32-wasi-ghc/bin/wasm32-wasi-ghc \\
  --with-hc-pkg=$PREFIX/wasm32-wasi-ghc/bin/wasm32-wasi-ghc-pkg \\
  --with-hsc2hs=$PREFIX/wasm32-wasi-ghc/bin/wasm32-wasi-hsc2hs \\
  \${1+"\$@"}
EOF
chmod 755 "$PREFIX/wasm32-wasi-cabal/bin/wasm32-wasi-cabal"

curl -fL --retry 5 \
  https://gitlab.haskell.org/ghc/ghc-wasm-meta/-/raw/master/cabal.head.config \
  -o "$PREFIX/.cabal/config"
"$PREFIX/wasm32-wasi-cabal/bin/wasm32-wasi-cabal" update

echo "done: source $PREFIX/env, then use wasm32-wasi-cabal"
