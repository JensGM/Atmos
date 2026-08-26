# Compiling a Haskell atmos to WebAssembly

An evaluation, with measurements. Everything below was run on x86_64 Linux
against a Haskell prototype of atmos that lives in [`haskell/`](../haskell);
the prototype compiles unchanged for both native and `wasm32-wasi`, so the
same source produced every number in this document.

## Summary

Compiling atmos to wasm works. The Haskell toolchain is not the problem, and
neither, in the end, is SQLite's *portability* — SQLite compiles to
`wasm32-wasi` untouched. The problems are elsewhere, and they are sharper than
expected:

1. **WASI will not create a symlink with an absolute target.** `path_symlink`
   returns `EPERM` on both runtimes tested, whatever is preopened. Python atmos
   writes absolute targets for every link it makes, so its central operation
   fails outright in wasm. Writing relative targets instead works completely,
   and is a small, well-contained change.
2. **SQLite on WASI silently switches to a different locking regime.** Its
   `#if defined(__wasi__)` block selects the `unix-dotfile` VFS and compiles
   WAL out. A native atmos and a wasm atmos therefore cannot safely touch the
   same database — their locks are mutually invisible. Reproduced below:
   a committed transaction lost, and a spurious "disk I/O error" in the other
   process.
3. **A killed wasm process wedges the database permanently.** The dotfile lock
   is a directory; nothing cleans it up; every later run fails with "database
   is locked" until a human removes it by hand.
4. **wasmtime refuses to `readlink` a link whose target is absolute.** That is
   the whole basis of `unlink --full` and of `verify`'s attribution logic —
   they inspect links atmos did not necessarily create. Under wasmtime those
   links also report as *nonexistent*, which would make atmos treat live links
   as dangling.

The recommendation is to drop the SQLite-backed cache in favour of a
file-per-library store, which is faster, simpler, crash-safe by construction,
and removes the largest wasm liability. That is worth doing on its own terms,
independently of whether the wasm build ever ships.

Whether the wasm build *should* ship is a separate question, answered at the
end: as a replacement for the native CLI, no. As a sandboxed planning and
verification engine, yes.

## 1. The toolchain

GHC is a single-target compiler, so a wasm build needs a GHC that was
configured for `wasm32-wasi`. The supported route is
[ghc-wasm-meta](https://gitlab.haskell.org/ghc/ghc-wasm-meta); its `bootstrap.sh`
installs a prebuilt cross compiler, wasi-sdk, node, binaryen and wasmtime.

Measured with GHC 10.1.20260821 (wasm cross bindist), wasi-sdk 29.0 and
cabal 3.14.2.0 driving the `head.hackage` overlay. Every dependency the
prototype has is a GHC boot library, so nothing else had to be built.

What actually needed hands-on work:

* **libffi.** GHC's `rts` package declares `extra-libraries: ffi`, so linking
  any wasm executable needs a `libffi.a` for `wasm32-wasi`. The real one,
  `haskell-wasm/libffi-wasm`, generates its dispatch tables with a Haskell
  program, so it wants a native GHC to build. For atmos — which uses neither
  `foreign import ccall "wrapper"` nor the bytecode interpreter — three stubs
  that `abort()` if ever called are enough to link. `scripts/setup-toolchain.sh`
  does this. Anything that later needs real adjustors must swap in the real
  library.
* Nothing else. No CPP, no conditional imports, no `#ifdef wasm` anywhere in
  the prototype.

Artefacts, for the same source:

| target | size |
| --- | --- |
| native executable (GHC 9.10.1) | 3,106,896 bytes |
| `atmos.wasm` | 2,458,354 bytes |
| a `main = putStrLn` wasm module, for reference | 1,625,391 bytes |

The RTS floor is ~1.6 MB, so atmos itself accounts for about 0.8 MB of the
module.

## 2. What WASI can and cannot do

`haskell/probes/FsProbe.hs` and `FsProbe2.hs` exercise every filesystem
operation atmos performs. Run natively, under node's `node:wasi` (uvwasi) with
`/` preopened, and under wasmtime (cap-std) with `/` preopened.

| operation | native | wasm / node | wasm / wasmtime |
| --- | --- | --- | --- |
| create dirs, read/write files, `listDirectory`, `stat`, mtime | ok | ok | ok |
| recursive walk of a library tree | ok | ok | ok |
| create symlink, **relative** target | ok | ok | ok |
| read it back, `lstat` it, follow it | ok | ok | ok |
| **create symlink, absolute target (inside the preopen)** | ok | **EPERM** | **EPERM** |
| **create symlink, absolute target (another preopen)** | ok | **EPERM** | **EPERM** |
| create a dangling relative link, `lstat`, remove it | ok | ok | ok |
| `readlink` a link the *host* made with an absolute target | ok | ok | **EPERM** |
| follow that link | ok | ok | **EPERM** |
| `doesFileExist` on that link | True | True | **False** |
| write temp + `rename` over the original | ok | ok | ok |
| `rename` into another preopen | ok | ok | ok |
| `fsync` a file | ok | ok | ok |
| **`fsync` a directory** | ok | ok | **EBADF** |
| `O_EXCL` create as a lock | ok | ok | ok |
| environment variables visible | 136 | 2 | 0 |

(The environment row reflects what each runner chose to pass in, not a WASI
limitation — but it is a reminder that `HOME` is not there, so a wasm build
cannot default its state directory to `~/.atmos`.)

Three of these decide the shape of a wasm atmos.

### 2.1 Absolute symlink targets are refused

Both runtimes reject `path_symlink` when the target is absolute, and they
reject it even when the whole filesystem is preopened and the target is inside
it. This is not a sandbox-width problem that a wider preopen fixes; an absolute
path in a symlink is uninterpretable in a capability-based filesystem, so the
call is refused at the API boundary.

Python atmos writes absolute targets:

```python
target.symlink_to(source)     # source is an absolute path
```

Run the prototype's acceptance test in wasm with that behaviour and two of
three links simply fail:

```
--- atmos link mylib ---
warning: could not link .../dest/bin/foo -> .../atmos_root/mylib/bin/foo:
         createSymbolicLink ...: permission denied (Operation not permitted)
warning: could not link .../dest/lib/libfoo.so.1 -> ...:
         createSymbolicLink ...: permission denied (Operation not permitted)
1 links created
```

The one link that succeeded is the *transported* symlink — atmos copies a
library's own symlink content verbatim, and that one happened to be relative.
It is left dangling, because the file it points at was never linked.

Switch to relative targets and the same binary, on both runtimes, does the
whole job:

```
--- atmos link mylib ---
3 links created
--- atmos verify ---
ok
--- resulting tree ---
dest/bin/foo        -> ../../atmos_root/mylib/bin/foo
dest/lib/libfoo.so  -> libfoo.so.1
dest/lib/libfoo.so.1 -> ../../atmos_root/mylib/lib/libfoo.so.1
--- do the links resolve on the host? ---
resolves: dest/bin/foo
resolves: dest/lib/libfoo.so
resolves: dest/lib/libfoo.so.1
```

The links are equivalent for anything reading the destination tree. They are
arguably better: a relative link survives moving both trees together, which an
absolute one does not. The cost is that `verify` can no longer compare link
content against an absolute source path directly — it has to collapse `..`
lexically first, which the prototype does in `Atmos.Link.collapse`. Using
`canonicalizePath` there would be wrong twice over: it resolves symlinks, which
is the thing under test, and it fails outright on paths that leave a preopen.

### 2.2 Reading other people's absolute links

`unlink --full` and `verify` do not only look at links atmos made. They scan
`dest_root` and attribute every symlink that points into `atmos_root`, which
means calling `readlink` on links that already exist — links a native atmos
wrote with absolute targets, or that a package manager wrote.

Under wasmtime, `readlink` on such a link returns `EPERM`, and worse,
`doesFileExist` reports `False`. An atmos that trusted that answer would
conclude that live links are dangling. node's implementation is more
permissive and returns the content, but that is a property of uvwasi, not of
WASI: the same program, same module, gives different answers on two conforming
runtimes.

So the full-scan features cannot be ported as they stand. Either the wasm build
declines to offer them, or attribution moves entirely onto the recorded
manifests — which is an argument for making those manifests trustworthy, and
therefore an argument about storage.

### 2.3 Directory fsync is not portable

`fsync` on a directory handle — the step that makes a `rename` durable across a
machine crash, not merely atomic — fails with `EBADF` on wasmtime and succeeds
on node. Any home-grown store has to treat that call as best-effort. The
prototype's `Atmos.Store.syncDirectory` swallows the error: losing durability
across a power cut on one runtime is acceptable, refusing to run on it is not.

### 2.4 In a browser there is no filesystem at all

Running `atmos.wasm` with no preopened directories, which is the closest node
gets to a browser:

```
$ node scripts/wasm-run-nofs.mjs atmos.wasm --state-dir=/state set atmos_root /a
atmos.wasm: Uncaught exception ... /: createDirectory: does not exist
```

atmos cannot create its own state directory, let alone symlink anything. A
browser build would need every filesystem operation routed through JSFFI to
OPFS or IndexedDB, and even then it would be manipulating a private virtual
tree that has nothing to do with `/usr/local`. That is a different program, not
a port.

## 3. SQLite

Python atmos stores its state in `diskcache.Cache('~/.atmos.cache')`, which is
SQLite plus a directory of blobs. The Haskell equivalent would be
`direct-sqlite` or `sqlite-simple` over the same engine.

### 3.1 It compiles, and it runs

`direct-sqlite` 2.3.29 builds for `wasm32-wasi` with no source changes — only
a version-bound relaxation, because its bounds predate the compiler used here —
and the resulting module opens a database, creates tables, inserts, queries,
`VACUUM`s and passes `PRAGMA integrity_check` on both runtimes. Databases
written by the wasm build are read correctly by native Python's `sqlite3`.

The reason it works so smoothly is that SQLite ships explicit WASI support.
From `sqlite3.c` (3.45.0):

```c
#if defined(__wasi__)
# define SQLITE_WASI 1
# define SQLITE_OMIT_WAL 1          /* because it requires shared memory APIs */
# define SQLITE_OMIT_LOAD_EXTENSION
# define SQLITE_THREADSAFE 0
#endif
...
# ifndef SQLITE_DEFAULT_UNIX_VFS
#  define SQLITE_DEFAULT_UNIX_VFS "unix-dotfile"
# endif
...
#ifdef SQLITE_WASI
# define osGetpid(X) (pid_t)1
#endif
```

`mmap` and `munmap` are compiled out of the syscall table as well. Three
consequences, all confirmed by running `haskell/probes/SqliteProbe.hs`:

* `PRAGMA journal_mode=WAL` returns `delete`. WAL is not merely slow, it is
  absent, and it fails silently rather than with an error. No concurrent
  readers during a write; no `-wal` recovery.
* Locking is not POSIX advisory locking. It is a lock *directory* next to the
  database.
* Every process reports pid 1, so no mechanism that would use the pid to detect
  a stale lock can work.

### 3.2 The dotfile lock excludes other wasm processes — and nothing else

Five wasm instances writing the same database at once behave correctly: one
commits, four get `SQLITE_BUSY`. Run sequentially, all three of three commit,
and the result passes `integrity_check`. So the dotfile lock does its job
*within* the wasm world.

Now mix the two builds. A native writer holds an open write transaction while a
wasm writer runs against the same file:

```
WASM: committed 100 rows
native: FAILED -> disk I/O error
final database: 100 rows, all native-*, integrity ok
```

Reproduced identically on two consecutive runs. The wasm process took a
dotfile lock, which the native process does not look at; the native process
held fcntl locks, which the wasm process cannot see. The result is a
transaction that reported success and then vanished, and an unrelated I/O error
in the other process.

This matters because it is exactly the situation an incremental port creates:
a native atmos installed from a package, a wasm atmos being trialled, one
`~/.atmos.cache`.

### 3.3 A killed process wedges the database, permanently

Kill a wasm writer mid-transaction and the lock directory survives it:

```
$ timeout -s KILL 0.35 node wasm-run.mjs lock-race.wasm s.db KILLED
$ ls
s.db  s.db-journal  s.db.lock/          <- the lock is a directory, still there

$ node wasm-run.mjs lock-race.wasm s.db AFTER1
AFTER1: ERROR SQLite3 returned ErrorBusy ...: database is locked
$ node wasm-run.mjs lock-race.wasm s.db AFTER2
AFTER2: ERROR SQLite3 returned ErrorBusy ...: database is locked
```

There is no timeout and no owner check — `osGetpid()` is the constant 1 — so
this never resolves on its own. The user's fix is `rmdir ~/.atmos.cache.lock`,
which they have to be told about. Meanwhile a *native* SQLite ignores the stale
lock entirely and writes straight through it.

Compare the failure mode of a plain-file store: a killed process leaves a
`.tmp` file that nothing reads and the next write overwrites.

### 3.4 What it costs in the module

The same trivial program with and without `direct-sqlite`:

| module | size |
| --- | --- |
| `base` + `text` only | 1,675,834 bytes |
| the same, plus `direct-sqlite` | 3,563,035 bytes |

SQLite adds **1.89 MB**, more than doubling a wasm module — to store, in
atmos' case, two configuration strings and a list of path pairs.

### 3.5 Could SQLite be made to work?

Yes, at a price, and it is worth stating so the recommendation is not mistaken
for "SQLite is broken on wasm":

* Force the same VFS on both sides. Building the *native* atmos with
  `SQLITE_DEFAULT_UNIX_VFS="unix-dotfile"`, or opening with
  `sqlite3_open_v2(..., "unix-dotfile")`, makes the two builds agree on
  locking. It also means atmos' database is now locked in a way no other
  SQLite tool on the machine respects, and inherits the stale-lock problem on
  both sides.
* Add stale-lock recovery of your own — a timestamp file, an age threshold, a
  `--force-unlock` flag. This is a small distributed-systems problem that
  atmos does not currently have.
* Accept the absence of WAL and the 1.9 MB.

That is a lot of machinery to keep a dependency that is doing the work of a
text file.

## 4. Alternatives

### 4.1 What is actually being stored

The entire state, from `atmos/core.py` and the subcommands:

* `atmos_root`, `dest_root` — two strings.
* `namespaces` — a set of names.
* `linked` — for each namespace and library, a list of `(source, target)` path
  pairs.

There are no queries. Nothing is ever looked up by anything other than
`(namespace, library)`. Nothing is sorted, joined, aggregated or indexed.
`link` writes one library's list; `unlink` deletes one; `list` and `verify`
read them. The largest plausible instance is a few hundred libraries with a few
thousand links each — single-digit megabytes of text.

This is not a database workload. It is a directory.

### 4.2 Option A: derive everything from the filesystem, store nothing

Tempting, and half-implemented already: `symlinks_to_lib` reconstructs which
links belong to a library by scanning `dest_root` and testing each symlink
against the library tree. If that worked in general, atmos would need no store
at all beyond two configuration strings.

It does not work in general, for two independent reasons:

* It cannot distinguish a link atmos made from an identical link something else
  made. The Python code is already careful about this — `unlink --full` is a
  separate, more dangerous mode precisely because attribution by scanning is
  not the same as attribution by record.
* It depends on reading the content of arbitrary existing symlinks, which
  §2.2 shows is unavailable under wasmtime when those targets are absolute.

So a record is needed. The question is what shape it takes.

### 4.3 Option B: one file

The whole state as one line-oriented file, rewritten atomically on every
change. Implemented in `Atmos.Store.SingleFile`:

```
config      atmos_root  /home/user/atmos
config      dest_root   /usr/local
namespace   staging
link  default  mylib  /home/user/atmos/mylib/lib/libfoo.so  /usr/local/lib/libfoo.so
```

Strengths: the commit protocol is one `rename`; the file is trivially copied,
diffed and versioned; recovery is `cp state.backup state`.

Weaknesses: every mutation rewrites every record, and two concurrent
`atmos link` runs on *different* libraries will clobber each other unless a
lock is introduced — reintroducing, in miniature, the problem SQLite was
having.

### 4.4 Option C: one file per library

Implemented in `Atmos.Store.Files`, and the recommendation:

```
~/.atmos/config                          key<TAB>value, one per line
~/.atmos/ns/default/linked/mylib.links   source<TAB>target, one per line
~/.atmos/ns/staging/                     created by `atmos new -t staging`
~/.atmos/ns/staging/linked/mylib.links
```

* **The unit of atomicity matches the unit of work.** `link` and `unlink` each
  rewrite exactly one file. Two `atmos link` runs on different libraries touch
  disjoint files and need no lock at all.
* **A namespace is a directory.** Creating one is `mkdir`; listing them is
  `readdir`. There is no schema to migrate when the next feature arrives.
* **Crash recovery is nothing.** A half-finished write leaves `mylib.links.tmp`,
  which no reader looks at and the next write replaces. Contrast §3.3.
* **The tools already exist.** `grep`, `diff`, `git`, `rm`.
* **Reads are proportional to what is read.** `atmos list linked` is a
  `readdir`; `atmos unlink mylib` parses one library's records, not everyone's.

Framing details worth pinning down, all in `Atmos.Codec`:

* Records are tab-separated; backslash, tab, newline and carriage return are
  escaped. Paths may legally contain newlines, and a store that corrupts on
  such a path is a store that corrupts on an attacker-chosen path.
* Library and namespace names become filenames, so anything outside
  `[A-Za-z0-9._-]` is percent-encoded. Ordinary names pass through untouched so
  the directory stays readable.
* Writes go through `Atmos.Store.atomicWriteFile`: temp file in the same
  directory, `fsync`, `rename`, best-effort directory `fsync` (§2.3).

### 4.5 Measured

`haskell/bench/Bench.hs`, N libraries × 40 links each, linking every library,
then reading every manifest, then unlinking every library. Native, in
milliseconds for the whole batch:

| N libraries | store | link all | read all | unlink all |
| --- | --- | --- | --- | --- |
| 10 | files | 21.4 | 3.2 | 3.9 |
| 10 | single-file | 35.5 | 42.4 | 34.0 |
| 50 | files | 33.6 | 7.3 | 7.2 |
| 50 | single-file | 965.2 | 1,235.7 | 1,105.0 |
| 200 | files | 307.6 | 36.4 | 73.2 |
| 200 | single-file | 17,516.7 | 21,338.5 | 17,583.3 |

Per operation at 200 libraries that is 1.5 ms against 87.6 ms — the single-file
store pays for the whole state on every command, and a CLI runs one command per
process, so there is no cache to amortise it against. The same shape holds in
wasm (50 libraries, node: 95.8 ms vs 2,769.2 ms; wasmtime: 99.4 ms vs
2,811.2 ms).

The absolute numbers are unflattering to both stores because the prototype
parses `String`, not `ByteString`; a faster parser would shrink the constant.
It would not change the exponent.

### 4.6 Migration from the diskcache

One-way, offline, and small: read `~/.atmos.cache` with `diskcache`, write out
`config`, one directory per namespace, one `.links` file per linked library.
A dozen lines of Python. Worth shipping as `atmos migrate` and worth doing
before, not during, any wasm work.

## 5. Startup

| | per run |
| --- | --- |
| native | 2.8 ms |
| wasm on node (bare `node -e ''` is 32 ms) | 155 ms |
| wasm on wasmtime, via the Python helper | 1,046 ms |

The wasmtime figure is not a fair measure of wasmtime: it includes Python
startup, engine construction and a fresh JIT compilation of a 2.4 MB module on
every run. A native `wasmtime` binary with a compiled-module cache would be far
better. The node figure is representative, and it is ~55× the native cost for
a tool whose entire job is a handful of `symlink` calls.

## 6. Recommendation

**Do the storage change; treat wasm as a separate decision.**

1. **Replace the SQLite-backed cache with the file-per-library store.** It is
   faster, has no lock to wedge, no schema to migrate, no 1.9 MB, and no
   dependency. This is worth doing whether or not wasm ever happens, and it is
   the change that makes wasm feasible at all.
2. **Add a relative link style, and make it the default.** It is required for
   any wasm build to create links, and it makes an atmos tree relocatable
   natively. Keep absolute as an option for the cases that need it.
3. **Move attribution fully onto the manifests.** Keep `unlink --full` as a
   native-only, clearly-labelled scanning mode; do not build features on
   `readlink` of links atmos did not write.

On wasm itself:

* **As a replacement for the native CLI: no.** 55× startup, no `unlink --full`
  under wasmtime, a sandbox that must be handed both trees explicitly, and a
  runtime-dependent answer to "does this link exist". The tool's whole purpose
  is privileged, absolute-path filesystem surgery in `/usr/local`; that is the
  one thing a capability sandbox is designed to prevent.
* **As a sandboxed plan-and-verify engine: yes, and it is genuinely useful.**
  Splitting atmos into a pure planner (walk a library, compute the link set,
  diff it against a manifest, report issues) and a thin effectful shell is good
  design regardless. Compiled to wasm, the planner becomes runnable inside a
  CI job, a language server, a browser-based inspector or another program's
  process, with no ability to touch anything it was not handed. The prototype's
  `Atmos.Link.verifyManifest` and the manifest reader are already that shape.
* **Browser: no.** There is no filesystem to manage (§2.4). A browser build
  could visualise or validate an exported manifest; it cannot be atmos.

## Reproducing

```
haskell/scripts/setup-toolchain.sh          # or ghc-wasm-meta's bootstrap.sh
cd haskell
cabal build all                             # native
. ~/.ghc-wasm/env && wasm32-wasi-cabal build all -f sqlite

# §2 filesystem table
cabal run fs-probe -- /tmp/probe-root /tmp/probe-outside
node ~/.ghc-wasm/wasm-run/bin/wasm-run.mjs "$(wasm32-wasi-cabal list-bin fs-probe)" \
  /tmp/probe-root /tmp/probe-outside
python3 scripts/run-wasmtime.py "$(wasm32-wasi-cabal list-bin fs-probe)" \
  /tmp/probe-root /tmp/probe-outside

# §2.1 the link-style difference
scripts/acceptance.sh "$(cabal list-bin exe:atmos)" absolute files
scripts/acceptance.sh \
  "node ~/.ghc-wasm/wasm-run/bin/wasm-run.mjs $(wasm32-wasi-cabal list-bin exe:atmos)" \
  absolute files      # two of three links fail
scripts/acceptance.sh \
  "node ~/.ghc-wasm/wasm-run/bin/wasm-run.mjs $(wasm32-wasi-cabal list-bin exe:atmos)" \
  relative files      # all three succeed and resolve

# §3 SQLite
node ~/.ghc-wasm/wasm-run/bin/wasm-run.mjs "$(wasm32-wasi-cabal list-bin sqlite-probe)" /tmp/a.db
for i in A B C D E; do
  node ~/.ghc-wasm/wasm-run/bin/wasm-run.mjs "$(wasm32-wasi-cabal list-bin lock-race)" /tmp/r.db $i &
done; wait

# §4.5 benchmark
cabal run atmos-bench -- 200 40 /tmp/bench
```
