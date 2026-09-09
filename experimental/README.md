# Experimental: dxc-based work graph parsing (v2 spike)

Temporary, throwaway setup for evaluating a v2 approach: instead of the current
regex/paren-balance scan (see the root [`README.md`](../README.md)), ask
`dxc` (the DirectX Shader Compiler) itself to parse and preprocess the HLSL,
and see how much of the work graph's structure it can hand back directly —
especially the two things the regex scanner fundamentally can't do:

- **preprocessor resolution** — `#define`-driven attribute values, and
  `#if`/`#ifdef`-guarded node definitions
- **dead code elimination** — node functions and branches that exist in the
  source text but are never actually compiled in for a given set of `-D`
  defines

Nothing here is wired into the published tool (`src/`, `generate-workgraph-diagram.js`).
This is scratch space for the spike only.

## Layout

```
experimental/
  hlsl/                    fixture work graph (see below)
  tools/
    fetch-dxc.sh / fetch-dxc.ps1   downloads + caches the right dxc build from nuget.org
    run-dxc.sh / run-dxc.ps1        runs dxc against a fixture with a configurable entry point
    extract-nupkg-entries.js         pure-Node .nupkg (zip) extractor, no `unzip`/deps required
    dxc/                             (gitignored) fetched dxc builds land here
  out/                               (gitignored) run-dxc output lands here
```

There are two parallel implementations of the fetch/run scripts: `.sh` (bash
+ Node, for Linux/macOS/WSL, using `wine` since dxc.exe is Windows-only —
see the blocker below) and `.ps1` (native PowerShell, no Node dependency,
for running directly on Windows where dxc.exe actually runs). Same
behavior, same flags (`-Entry`/`--entry`, `-Define`/`--define`,
`-Mode`/`--mode`, `-TargetProfile`/`--profile`, `-OutDir`/`--out-dir`).

## The fixture (`hlsl/`)

A minimal broadcasting → thread → coalescing graph
(`EntryNode` → `GenerateNode` → `CollectNode`, mirroring
[`examples/simple-pipeline`](../examples/simple-pipeline)), plus an optional
mesh-launch node (`RenderMeshNode`, mirroring
[`examples/mesh-culling`](../examples/mesh-culling)) that only enters the
compile when `ENABLE_MESH_PATH` is defined. None of it computes anything real
— just enough to be a *valid*, compilable work graph.

`hlsl/WorkGraph.hlsl` is the single compile unit (`#include`s everything
else) that gets handed to dxc. It deliberately encodes two test cases to
probe against later:

1. **`#define` resolution** — `EntryNode.hlsl` defines `ENTRY_MAX_RECORDS 64`
   and uses it in `[MaxRecords(ENTRY_MAX_RECORDS)]`. The regex scanner has to
   separately track `#define`s and substitute them into attributes by hand;
   dxc resolves this as a normal part of compilation.
2. **dead code / conditional compilation** — `EntryNode.hlsl` also has an
   `#if 0`-guarded duplicate `EntryNode_OldVersion` (text a regex scan would
   still see), and `WorkGraph.hlsl` only pulls in `RenderMeshNode` when
   `ENABLE_MESH_PATH` is defined. A regex scan of the raw files finds
   `NodeLaunch("mesh")` unconditionally, regardless of whether the node is
   actually live; a real compile does not.

## Usage

On Linux/macOS/WSL (bash + wine, see the blocker below):

```sh
# Fetch (and cache) the right dxc build for hlsl/, print its directory:
tools/fetch-dxc.sh

# Preprocess only — shows dxc's fully macro/#if-resolved source:
tools/run-dxc.sh --mode preprocess

# Same, but with the mesh node compiled in:
tools/run-dxc.sh --mode preprocess --define ENABLE_MESH_PATH=1

# Full compile + disassembly, restricted to one node's export:
tools/run-dxc.sh --mode compile --entry CollectNode

# See all options:
tools/run-dxc.sh --help
```

On native Windows (PowerShell, dxc.exe runs directly — no wine needed):

```powershell
# Fetch (and cache) the right dxc build for hlsl/, print its directory:
.\tools\fetch-dxc.ps1

# Preprocess only — shows dxc's fully macro/#if-resolved source:
.\tools\run-dxc.ps1 -Mode preprocess

# Same, but with the mesh node compiled in:
.\tools\run-dxc.ps1 -Mode preprocess -Define ENABLE_MESH_PATH=1

# Full compile + disassembly, restricted to one node's export:
.\tools\run-dxc.ps1 -Mode compile -Entry CollectNode
```

Run these from inside `experimental/` (relative paths — `hlsl\WorkGraph.hlsl`,
`out\`, `tools\dxc\` — are resolved from there).

`fetch-dxc.sh` picks the dxc version by scanning the given HLSL tree's raw
text for `NodeLaunch("mesh")`: if found anywhere (guarded or not — same
limitation the regex scanner has, before any dxc invocation exists to
resolve the guard), it pins to nuget's
`1.8.2404.55-mesh-nodes-preview` build, since that's the only DXC version
that can compile a mesh-launch node so far. Otherwise it resolves and fetches
whatever nuget.org currently reports as the latest stable release.

## Known blocker in this repo's Linux dev sandbox: dxc.exe won't run there

`Microsoft.Direct3D.DXC` on nuget.org ships **Windows-only** binaries at
every version checked (`1.8.2404.55-mesh-nodes-preview` through the current
`1.9.2607.13`) — `dxc.exe`/`dxcompiler.dll` for x86/x64/arm64, no Linux ELF
build, unlike some other Microsoft native nuget packages.

This sandbox reports itself as WSL2 (`uname -a` says
`6.6.114.1-microsoft-standard-WSL2`) but has no actual Windows underneath it
— no `/mnt/c`, no `cmd.exe`/`powershell.exe` interop. So `run-dxc.sh` falls
back to `wine64`, which is installed here. But under this container's Wine
10.0, **both** dxc builds tested (stable `1.9.2607.13` and
`1.8.2404.55-mesh-nodes-preview`) crash before producing any output:

```
0024:fixme:unwind:RtlVirtualUnwind2 unknown unwind info version 0 at 0x...
   (repeats, then:)
0024:fixme:unwind:RtlVirtualUnwind2 stack overflow 4672 bytes ...
```

i.e. Wine's PE unwinder doesn't recognize the exception-unwind metadata
format these dxc builds were compiled with, recurses, and blows the stack —
this reproduces identically on `--version` alone, before any real HLSL work,
and on both dxc versions, so it isn't a version-specific fix. `ulimit -s
unlimited` doesn't help (Wine's guest thread stack size isn't governed by
the host ulimit).

**`run-dxc.sh` and `fetch-dxc.sh` are otherwise verified working end-to-end**
in this sandbox: version selection, nuget download, and the pure-Node
`.nupkg` extraction all ran successfully (confirmed by extracting and
byte-comparing both the mesh-preview and stable win-x64 `dxc.exe` builds).
Only the actual `dxc.exe` execution is blocked here. To actually get dxc's
output, run these scripts from:

- native Windows, or
- a real WSL2 install with Windows interop enabled (`/mnt/c` present), or
- a Linux box with a newer/patched Wine build that handles this unwind-info
  format (untested here — not pursued further since this is meant to be a
  quick spike, not a Wine compatibility project)

## Findings (actually run on native Windows)

Both modes were run for real on Windows (PowerShell, `run-dxc.ps1`) against
this fixture. Summary: **yes, dxc's actual output resolves everything the
regex scanner approximates by hand, and catches real errors the regex
scanner can't — but the CLI's only text form of the structured data is an
undocumented, dxc-internal encoding, which changes what "v2" should
actually integrate against.**

**`-P` (preprocess-only)**: `ENTRY_MAX_RECORDS` and `COLLECT_THREADS`
resolved to `64`/`32` everywhere they're used (attributes *and* function
bodies); the `#if 0`-guarded `EntryNode_OldVersion` was dropped entirely;
and without `-D ENABLE_MESH_PATH=1`, `RenderMeshNode` was absent from the
output even though the raw text `NodeLaunch("mesh")` is on disk under
`nodes-mesh/` (and is exactly what `fetch-dxc` scans for to pick the
mesh-capable compiler in the first place). Confirms both of the fixture's
test cases.

**`-T lib_6_8` compile + `-Fc` disassembly**: with `-D ENABLE_MESH_PATH=1`,
this caught two real bugs in the fixture that a regex scanner would never
have noticed, because it doesn't actually resolve `#include`s or check
semantic requirements:

1. `#pragma once` on `structs/Records.hlsl` didn't dedupe, because the file
   is `#include`d via two differently-spelled relative paths
   (`nodes-compute/../structs/Records.hlsl` vs
   `nodes-mesh/../structs/Records.hlsl`) and dxc's pragma-once tracking
   keys on the unnormalized path string — fixed by switching to `#ifndef`
   include guards (see `structs/Records.hlsl`, `structs/VertexTypes.hlsl`).
2. `RenderMeshNode`'s `[NodeMaxDispatchGrid(...)]` requires its input
   record to carry an `SV_DispatchGrid`-semantic field, which the fixture
   was missing — fixed to match the pattern already used in this repo's own
   `examples/mesh-culling/structs/Records.hlsl`.

Once fixed, the compile succeeded and the `!dx.entryPoints` metadata in the
disassembly encoded every node correctly — cross-checked by hand against
the source: launch mode is a clean small integer enum, one value per node,
distinct per launch mode (`broadcasting=1`, `coalescing=2`, `thread=3`,
`mesh=4` in this build); `NumThreads`, `NodeMaxDispatchGrid`, and `NodeID`
all appear as resolved literal values matching the source exactly (dxc even
deduplicates identical metadata nodes — `CollectNode`'s and
`RenderMeshNode`'s `NumThreads(32,1,1)` share one metadata node).

**Correction — the metadata tag scheme is not undocumented.** An earlier
version of this section claimed the `(tag: i32, value)` pairs above (e.g.
`!10 = !{i32 8, i32 15, i32 13, i32 2, ...}`) were a fragile, internal-only
encoding, and recommended going through the D3D12 reflection API instead.
Checked against the actual sources, that was wrong on both counts:

- The tag scheme is **officially published** in the [Work Graphs
  spec](https://microsoft.github.io/DirectX-Specs/d3d/WorkGraphs.html#dxil)
  itself, under "DXIL Shader function attributes" — `NumThreads = 4`,
  `NodeLaunchType = 13`, `NodeID = 15`, `NodeMaxDispatchGrid = 22`, etc.,
  an exact match for what was hand-decoded above, with dedicated subsections
  for the `NodeLaunchType`/`NodeID`/`SV_DispatchGrid` encodings and a worked
  example. It's mirrored in the compiler's own
  [`DxilMetadataHelper.h`](https://github.com/microsoft/DirectXShaderCompiler/blob/main/include/dxc/DXIL/DxilMetadataHelper.h)
  source under the identical constant names, with no preview/instability
  caveats attached. This is a documented part of the Shader Model 6.8 spec,
  not reverse-engineered dxc internals — it should be exactly as stable as
  the shader model itself. (One doc gap worth noting: the spec's own
  `NodeLaunchType` enum table only lists `Broadcasting=1`/`Coalescing=2`/
  `Thread=3`, no `Mesh=4` entry, even though mesh launch nodes are
  documented extensively elsewhere on the same page — looks like a stale
  table cell rather than mesh being unofficial. A real parser should treat
  unrecognized launch-type values as "unknown numeric N" rather than
  failing, both for this and for future values.) The one part that *isn't*
  a stability contract is the outer `-Fc` textual syntax itself — that's
  LLVM's IR printer, tied to whichever LLVM version dxc embeds — so a
  parser should target the documented metadata nodes specifically, not
  scrape arbitrary surrounding LLVM syntax.
- The D3D12 **reflection API is not a lighter alternative — it's heavier,
  and exposes less**. There's no node-attribute support in
  `ID3D12LibraryReflection`/`ID3D12FunctionReflection` at all. The only
  work-graph reflection interface, `ID3D12WorkGraphProperties`, is obtained
  from `ID3D12StateObject` — meaning it requires a live D3D12 device (real
  GPU or WARP), a root signature, and actually calling `CreateStateObject`
  to build the full PSO before anything can be queried. What it then
  exposes (entrypoint counts, record sizes) doesn't even include launch
  mode or dispatch grid — those would still have to come from the DXIL
  metadata regardless. So it's Windows+device-only, a few hundred lines of
  D3D12 boilerplate, for strictly less information than `-Fc` already
  provides with no device at all.

**Conclusion / recommendation for v2**: parse the documented DXIL node
metadata out of the compiled output — via `-Fc` disassembly text, or
(cleaner, no LLVM-IR text to skip past) `IDxcContainerReflection`/
`IDxcUtils` against the compiled container directly. Either way this stays
inside the original goal: fetch dxc, run it, read structured output with
plain script code — no native COM helper, no D3D12 device, no separate
compile step for the tool's own users.

## Follow-up: comments, un-evaluated expressions, and global-resource usage

A second round raised three more things the pure `!dx.entryPoints` metadata
doesn't cover: doc comments (the current tool's `src/comments.js` feature),
seeing an attribute's *original* expression (e.g. `[NumThreads(32 *
SOME_CONSTANT, 1, 1)]`) alongside its resolved value, and per-node global
resource usage. All three turned out to have one answer: add `-Zi
-Qembed_debug` to the compile.

- **Debug info metadata is documented too** — the named-metadata constants
  (`dx.source.contents`, `dx.source.defines`, `dx.source.mainFileName`,
  `dx.source.args`) are real, defined in dxc's own
  [`DxilMetadataHelper.h`](https://github.com/microsoft/DirectXShaderCompiler/blob/main/include/dxc/DXIL/DxilMetadataHelper.h).
- **Confirmed by actually running it** (`-Zi -Qembed_debug -Fo ... -Fc ...`
  against this fixture): `dx.source.contents` embeds the full **original,
  per-file, pre-preprocessor** source — comments, un-expanded macro names,
  and even the `#if 0`-dead `EntryNode_OldVersion` block all round-trip
  verbatim (checked byte-for-byte: an embedded em dash survived as its raw
  escaped UTF-8 bytes, `\E2\80\94`, not re-encoded). So a node's doc comment
  and its attributes' original expressions are both recoverable from the
  *same* compile that resolves everything else — no need to choose between
  "resolved" and "original," get both.
- **Bonus, not originally expected**: `!DISubprogram`/`!DISubroutineType`/
  `!DICompositeType` (also part of `-Zi` debug info) give each node's
  defining `(file, line)` *and* its parameters' real HLSL type names
  (`"GroupNodeInputRecords<ResultRecord>"`, not just an opaque flags
  bitmask) plus the record struct's field list by name — richer than what
  `!dx.entryPoints` alone provides for this, and the thing that makes
  joining "resolved metadata" back to "the right slice of original source"
  tractable at all (join key: function name → `(file, line)` →
  `dx.source.contents[file]`, walk upward from `line` past any `[...]`
  attribute lines collecting a contiguous leading `//` block — the same
  "immediately preceding, no blank line gap" heuristic `src/comments.js`
  already uses, just line-addressed instead of char-offset-addressed since
  that's what debug info gives us).
- **Global resource usage**: `!dx.resources` (stable since SM6.0) declares
  every resource global; each node keeps its own separate DXIL function in
  a `lib_6_8` compile (confirmed directly in this fixture's own output), and
  DXIL disallows non-intrinsic function calls — so any HLSL helper function
  a node calls must be fully inlined into it. That means every resource
  handle a node's compiled body still references, post-optimization, is
  genuinely used by that node, *including through helper-function calls a
  text scan of the node's own source could never follow* — strictly better
  than the current tool's documented limitation ("inspects only the first
  occurrence... doesn't track nested-block scoping").

### The prototype parser

[`tools/parse-workgraph.js`](tools/parse-workgraph.js) — pure Node, no
dependencies — reads a `-Fc` disassembly (from a `-Zi -Qembed_debug`
compile) and produces the node/edge/comment/record-field structure above as
JSON. It implements just enough of the LLVM metadata grammar to walk
`!N = !{...}` tuples and `!N = !DIXxx(key: val, ...)` debug-info nodes
(memoized, cycle-guarded — this format reuses/dedupes metadata nodes
constantly), then layers the documented tag table
(`PROP_TAGS`/`LAUNCH_TYPES` in the file) and the debug-info join described
above on top.

**Verified against this fixture's actual compiled output** (all four
nodes): launch mode, `NumThreads`, `DispatchGrid`/`MaxDispatchGrid`,
resolved `MaxRecords`, output→consumer `NodeID` linkage, each parameter's
real record type name and field list (via debug info, not the opaque flags
bitmask), and each node's doc comment — all cross-checked and matching the
source exactly, including correctly filtering out non-node-I/O parameters
(`uint gtid`/`dtid` system values) that would otherwise misalign the
positional zip against `!dx.entryPoints`' inputs/outputs lists.

**Global-resource-usage extraction — now also verified**, after adding one
global to the fixture (`structs/Globals.hlsl`, an `itemMeta`
`StructuredBuffer` read by `EntryNode`, mirroring `examples/mesh-culling`'s
`objects`/`CullNode` pair) and recompiling. The real `!dx.resources` shape
turned out richer than first guessed — the global reference is a
`bitcast (...)` constant expression wrapping an LLVM *quoted* identifier
(`@"\01?itemMeta@@3V?$StructuredBuffer@..."`, MSVC name-mangled, since
`?`/`@` aren't valid in a bare LLVM identifier) — which needed a small fix
to `parseElement`'s reference matching (search for the quoted form, not
just anchor on a bare `@Name`). Once fixed: `EntryNode` correctly reports
`globals: itemMeta`; `GenerateNode`, `CollectNode`, and `RenderMeshNode` —
which don't touch it — correctly report none. Confirms the resource
metadata's declared 4-slot `[SRVs, UAVs, CBVs, Samplers]` shape and the
per-node body text-match approach both work as designed.

### Status

Every concern raised in this round — comments, un-evaluated attribute
expressions, global-resource usage, node linkage — now has a verified
answer, sourced from one dxc invocation (`-T lib_6_8 -Zi -Qembed_debug`),
parsed by [`tools/parse-workgraph.js`](tools/parse-workgraph.js) with no
native helper, no D3D12 device, and no dependency beyond Node itself. That
script is a working proof of concept, not a finished v2 — see its own
header comment for what's simplified (e.g. `recordLayoutRaw`/`ioFlagsRaw`
are carried through unparsed, since debug info already gives the same
information by name) versus what a real v2 would need (running against
`examples/simple-pipeline` and `examples/mesh-culling`, multi-node-array
handling, `[NodeArraySize]`, `MaxRecordsSharedWith`, and so on).
