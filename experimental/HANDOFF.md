> **CONCLUDED — kept as historical record only.** This handoff's spike succeeded and was productionized:
> see `src/parse-dxil/`, `src/setup-dxil/`, `docs/ir-format.md`, and the root `README.md`. The file paths
> and "not done yet" items below describe the state as of the spike, before that port — most of the open
> items here were resolved during it (real parity testing against `examples/`, the `--record-*-names` gap
> confirmed and documented, node depth now computed in `build-puml`). Not maintained further.

# Handoff: dxc-based Work Graph parsing spike (v2)

Written for a fresh Claude Code session starting on the user's Windows box
(moving there from a Linux sandbox for native dxc execution + automated
debugging, no more manual copy-paste round trips). Read this first, then
**`experimental/README.md` is the actual source of truth** for the full
narrative, every finding, and the reasoning behind each decision — this
file is a map and a "don't redo this" list, not a replacement for it.

## One-paragraph context

Repo `hlsl-workgraph-diagram`: v1 (`src/`, `generate-workgraph-diagram.js`,
untouched by this spike) reverse-engineers a D3D12 Work Graph's topology
from HLSL source via regex/paren-balance scanning — no real preprocessor,
no real compiler. This spike asks: can `dxc` (DirectX Shader Compiler)
itself supply that structure instead, compiled and resolved, as a
candidate v2? Everything lives under `experimental/`, a throwaway spike
directory, not wired into the published tool.

## Why Windows, why this matters

`dxc.exe` is a native Windows PE binary. `Microsoft.Direct3D.DXC` on
nuget.org ships **no Linux build**, at any version. The prior session ran
in a Linux sandbox (with the git working directory synced to the user's
Windows checkout — paths like `D:\hlsl-workgraph-diagram\...` showed up as
`/tool/...` there) and had to install `wine64` to run dxc at all, which
crashed on this specific dxc build's exception-unwind format
(`RtlVirtualUnwind2 unknown unwind info version 0` → stack overflow) on
every attempt, reproducibly, on both dxc builds tried. From that point on,
the user ran every dxc command themselves on their actual Windows machine
and pasted results back. That manual round-trip is the entire reason this
moved to a Windows session — you should be able to just run dxc directly.

## What already exists — don't rebuild any of this

```
experimental/
  README.md                 <- full narrative + findings, READ THIS
  HANDOFF.md                 <- this file
  dxc-command-line-help.txt  <- full --help of the mesh-nodes-preview dxc build
  .gitignore                 <- excludes tools/dxc/ (fetched binaries) and out/
  hlsl/                       <- the fixture work graph (see below)
  tools/
    fetch-dxc.ps1 / .sh       <- downloads+caches the right dxc build from nuget.org
    run-dxc.ps1 / .sh          <- runs dxc with configurable entry/defines/mode
    extract-nupkg-entries.js    <- pure-Node zip extractor (only used by the .sh path)
    parse-workgraph.js           <- the actual parser prototype, see below
    dxc/                          <- (gitignored) fetched dxc builds land here
  out/                        <- (gitignored) compile outputs land here
```

**Use the `.ps1` scripts now** — they're the native-Windows path (no wine,
no Node needed for fetch/extract; `Expand-Archive` instead). The `.sh`
scripts exist for the Linux/wine path that's no longer relevant to you.
Both were kept in sync feature-for-feature while this ran cross-platform;
if you only maintain one going forward, it should probably be the `.ps1`
side now.

### The fixture (`hlsl/`)

`EntryNode` (broadcasting) → `GenerateNode` (thread) → `CollectNode`
(coalescing), plus `RenderMeshNode` (mesh, gated behind
`#if ENABLE_MESH_PATH`, off by default — `WorkGraph.hlsl` is the single
compile unit `#include`ing everything else). Deliberately encodes test
cases, don't remove them without reason:

- `ENTRY_MAX_RECORDS` — a `#define` used in an attribute, to test resolved-value extraction.
- An `#if 0`-guarded dead `EntryNode_OldVersion` — to test dead-code elimination.
- `itemMeta` (`StructuredBuffer`, `structs/Globals.hlsl`) — read only by
  `EntryNode`, to test per-node global-resource-usage attribution.

### The parser prototype (`tools/parse-workgraph.js`)

Pure Node, zero dependencies. Reads a `-Fc` disassembly (from a
`-T lib_6_8 -Zi -Qembed_debug` compile) and produces node/edge/comment/
record-field JSON. **Verified working** against this fixture's real
compiled output — cross-checked by hand against the known source for every
node: launch mode, `NumThreads`, `DispatchGrid`/`MaxDispatchGrid`, resolved
`MaxRecords`, `NodeID` producer→consumer linkage, each parameter's real
record type name + field list (from debug info, not the opaque metadata
flags bitmask), each node's doc comment (from `dx.source.contents`), and
per-node global-resource usage (from `!dx.resources` +
`createHandleForLib` body scanning — `EntryNode` correctly reports
`itemMeta`, the other three correctly report none).

Run it:

```powershell
cd experimental
node tools\parse-workgraph.js out\WorkGraph.debug.dis.ll          # human-readable
node tools\parse-workgraph.js out\WorkGraph.debug.dis.ll --json   # full structure
```

### The known-good compile command (produces the file the parser reads)

From inside `experimental/`, after `fetch-dxc.ps1` has cached a build:

```powershell
$dxc = ".\tools\dxc\1.8.2404.55-mesh-nodes-preview\x64\dxc.exe"
& $dxc -T lib_6_8 -D ENABLE_MESH_PATH=1 -Zi -Qembed_debug -Vd `
    -Fo out\WorkGraph.debug.dxil -Fc out\WorkGraph.debug.dis.ll .\hlsl\WorkGraph.hlsl
```

- `-Vd`: this preview build ships no `dxil.dll` validator, so validation
  must be skipped.
- `-Zi -Qembed_debug`: **the whole reason comments/original-source/record
  names are recoverable at all** — see README's "Follow-up" section for
  the full reasoning and verification.
- Or use `tools\run-dxc.ps1 -Mode compile -Define ENABLE_MESH_PATH=1`,
  which wraps `fetch-dxc.ps1` + this invocation, though as of this handoff
  it does **not** pass `-Zi -Qembed_debug` by default — the debug-info
  flags were only ever added by hand for the deeper investigation. Worth
  adding a `-Debug`/`--debug` switch to `run-dxc.ps1`/`.sh` that adds
  `-Zi -Qembed_debug` (and switches `-Fc` output naming accordingly) as a
  first small task, so this doesn't need to be typed by hand every time.

## Key findings — already established, don't re-litigate

Full detail + sources for every one of these is in `README.md`.

1. dxc's compiled output correctly resolves `#define`s, eliminates dead/
   `#if`-guarded code, and gives launch mode/`NumThreads`/dispatch grid/
   `NodeID` linkage/record types — all matching source exactly.
2. The DXIL node-metadata tag scheme (`NumThreads=4`, `NodeLaunchType=13`,
   `NodeID=15`, `NodeMaxDispatchGrid=22`, etc. — see `PROP_TAGS` in
   `parse-workgraph.js`) is **officially documented** in the [Work Graphs
   spec](https://microsoft.github.io/DirectX-Specs/d3d/WorkGraphs.html#dxil)
   and in dxc's own `DxilMetadataHelper.h` — not fragile reverse-engineered
   internals. (Doc gap: the spec's launch-type enum table omits `Mesh=4`,
   which was observed consistently anyway — treat as a stale table cell,
   not instability.)
3. The D3D12 reflection API (`ID3D12LibraryReflection`/
   `ID3D12WorkGraphProperties`) is a **dead end** for this — needs a live
   device + a fully built PSO (Windows+GPU/WARP only), and doesn't even
   expose launch mode or dispatch grid. An earlier pass in this spike
   wrongly recommended it before checking primary sources, then corrected
   course after research — don't repeat that mistake. The no-device,
   no-compile-step-for-users path (parse the compiled DXIL metadata
   directly) is the right one and is what's implemented.
4. `-Zi -Qembed_debug` embeds the **original, per-file, pre-preprocessor**
   source — comments, un-expanded macro names, even fully `#if 0`-dead
   code — into the compiled container, byte-exact (checked down to an
   embedded em dash surviving as its raw escaped UTF-8 bytes), addressable
   via `!DISubprogram`'s `(file, line)`. This is confirmed by actually
   running it, not just by reading docs.
5. Gotchas already hit and fixed in the fixture — don't reintroduce them:
   - `#pragma once` does **not** dedupe across differently-spelled relative
     `#include` paths in dxc (e.g. `nodes-compute/../structs/Records.hlsl`
     vs `nodes-mesh/../structs/Records.hlsl`) — use `#ifndef` include
     guards instead (see the comment in `structs/Records.hlsl`).
   - A `[NodeMaxDispatchGrid(...)]` node's input record needs a field with
     the `SV_DispatchGrid` semantic, or dxc rejects the compile.
   - `-P <file>` is deprecated in favor of `-P -Fi <file>` (already fixed
     in both `run-dxc` scripts).
   - **PowerShell encoding**: Windows PowerShell 5.1 reads `.ps1` files
     using the system codepage, not UTF-8, when there's no BOM — any
     non-ASCII character (em dashes, etc.) you add to a `.ps1` file risks
     silently breaking string literals elsewhere in the file. Both `.ps1`
     files here are deliberately pure-ASCII; keep new edits that way too
     (or add a UTF-8 BOM if you need non-ASCII).

## Not done yet — natural next steps, roughly in order

1. ~~`parse-workgraph.js` has never been run against the repo's real
   examples~~ — **done**, on the Windows box, this session. Both
   `examples/simple-pipeline` and `examples/mesh-culling` parse cleanly via
   harness compile units under `examples-harness/` (`SimplePipeline.hlsl`,
   `MeshCulling.hlsl`) — see README.md's "Validated against the repo's real
   examples" section for a new finding (dxc DCEs an unused `GetDimensions`
   call entirely, so no `!dx.resources` node exists for it — correct
   behavior, not a parser bug). Mesh-culling initially hit the fixture's
   `#pragma once` cross-directory dedup bug on the real files too — **also
   fixed at the source this session**, on the user's explicit ask: every
   `.hlsl` under `examples/` now uses `#ifndef`/`#define`/`#endif` guards
   instead of `#pragma once` (same convention the fixture already used),
   so `examples-harness/MeshCulling.hlsl` now `#include`s the real files
   directly — no local patched copy needed anymore.
2. ~~Add a `-Debug`/`--debug` flag to `run-dxc.ps1`/`.sh`~~ — **done**
   (`-EmbedDebug` / `--debug`), verified working this session. Was already
   implemented but uncommitted as of this handoff; still uncommitted now —
   check `git status` before assuming it's landed.
3. ~~Un-evaluated original expressions~~ — **done**, this session. See
   README.md's "Original (un-evaluated) attribute expressions" section.
   `numThreadsOriginal`/`dispatchGridOriginal`/`maxDispatchGridOriginal`/
   `maxRecordsOriginal` fields, shown in the CLI output as `[source: ...]`
   only when they differ from the resolved value.
3.5. **New this session**: a full feature-parity check of `parse-workgraph.js`
   against everything the root README promises/documents as limitations —
   see README.md's "Feature-parity check against the published tool (v1)"
   section. Headline: node depth (longest-path-from-entry) and PlantUML
   rendering itself are recreatable but not yet built (no blocking dxc
   issue, just not done); `--record-in-names`/`--record-out-names` (a
   record parameter's own HLSL variable name) is a **genuine gap** — dxc's
   debug info has zero `DW_TAG_arg_variable` entries for node function
   parameters, only `DW_TAG_auto_variable` for in-body locals, so parameter
   names don't survive into the `DISubprogram`/`DISubroutineType` data this
   tool already reads. No workaround found or tried yet.
4. Not exercised at all yet: `[NodeArraySize]` / multi-node arrays,
   `MaxRecordsSharedWith`, `NodeShareInputOf` (tag `17` is in the table but
   the fixture never triggers it), and a closer look at mesh-shader output
   arrays (`indices`/`vertices`/`primitives` — currently excluded from
   node I/O entirely, matching v1's own documented behavior, but worth
   confirming against a real mesh-culling-shaped example rather than just
   assuming parity).
5. `ioFlagsRaw`/`recordLayoutRaw` in `decodeIORecord()` are carried through
   **undecoded on purpose** — debug info already gives the same
   information (record type name, field list) more reliably. Only worth
   decoding those opaque tag/value pairs if you need a path that works
   *without* `-Zi` (e.g. a faster non-debug compile mode) and still want
   type identification.
6. **No decision has been made on productionizing this** — whether it
   becomes a new code path in `src/`, a CLI flag switching between
   regex-scan and dxc-compile modes, a fully separate v2, etc. This is
   still purely a feasibility spike that succeeded; check with the user
   before starting any real integration work.

## Repo state

Nothing under `experimental/` is known to have been committed as of this
handoff — the Linux sandbox this ran in had no `git` binary available, so
that couldn't be verified from there either. Run `git status` / `git log`
first thing on the Windows box to get an accurate picture rather than
assuming a clean baseline.
