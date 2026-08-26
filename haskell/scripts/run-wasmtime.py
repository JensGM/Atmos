import sys, wasmtime
mod_path = sys.argv[1]
args = sys.argv[2:]
# preopen mapping(s) after "--map" flags: host=guest
maps = []
rest = []
i = 0
while i < len(args):
    if args[i] == "--map":
        maps.append(args[i+1]); i += 2
    else:
        rest.append(args[i]); i += 1
engine = wasmtime.Engine()
store = wasmtime.Store(engine)
wasi = wasmtime.WasiConfig()
wasi.argv = [mod_path] + rest
wasi.inherit_stdout(); wasi.inherit_stderr()
if not maps:
    maps = ["/::/"]
for m in maps:
    host, guest = m.split("::")
    wasi.preopen_dir(host, guest)
store.set_wasi(wasi)
linker = wasmtime.Linker(engine)
linker.define_wasi()
module = wasmtime.Module.from_file(engine, mod_path)
inst = linker.instantiate(store, module)
start = inst.exports(store)["_start"]
try:
    start(store)
except wasmtime.ExitTrap as e:
    sys.exit(e.code)
