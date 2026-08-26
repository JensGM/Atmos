// Same as ghc-wasm-meta's wasm-run.mjs but with NO preopened directories:
// the closest node can get to the browser's "no host filesystem" situation.
import fs from "node:fs";
import stream from "node:stream";
import { WASI } from "node:wasi";
const argv = process.argv.slice(2);
const wasi = new WASI({ version: "preview1", args: argv, env: {}, preopens: {} });
const mod = await WebAssembly.compileStreaming(
  new Response(stream.Readable.toWeb(fs.createReadStream(argv[0])), {
    headers: { "Content-Type": "application/wasm" },
  })
);
const import_obj = { wasi_snapshot_preview1: wasi.wasiImport };
for (const { module, name, kind } of WebAssembly.Module.imports(mod)) {
  if (import_obj[module]?.[name]) continue;
  if (kind === "function") {
    import_obj[module] ??= {};
    import_obj[module][name] = () => { throw new Error(`missing import ${module}.${name}`); };
  }
}
try { wasi.start(await WebAssembly.instantiate(mod, import_obj)); }
catch (e) { console.log("exit:", e.message ?? e); }
