> **⚠️ LLM-GENERATED CONTENT** - review before relying on it.

# `pipeline`: diagrams from dispatch definitions

What a work graph *does* in a frame depends on host code the tool cannot see: which entrypoint each
`DispatchGraph` starts at, which entry record it passes, and which `#define`s the library was compiled with.
A **dispatch definition** file states exactly those things, and `pipeline` runs the rest of the tool over it.

```sh
hlsl-workgraph-diagram pipeline workgraph.config.json out/ --jar ~/plantuml.jar     # render locally
hlsl-workgraph-diagram pipeline workgraph.config.json out/ --server http://localhost:8080
hlsl-workgraph-diagram pipeline workgraph.config.json out/                           # .puml only, no rendering
```

A runnable example with committed output: [`../examples/multi-dispatch/`](../examples/multi-dispatch/).

## Config

```json
{
  "source": "shaders/GraphNodes.hlsl",
  "compile": {
    "profile": "lib_6_9",
    "defines": ["SHADER_DIAGNOSTICS=1"],
    "dxcArgs": [],
    "dxc": "/opt/dxc/bin/dxc"
  },
  "diagram": {
    "lineType": "spline",
    "frameLineTypes": [],
    "short": true,
    "nodeComments": false,
    "hideGlobals": []
  },
  "inventory": "startup-log.txt",
  "dispatches": [
    { "name": "generation", "entry": "EntryNode" },
    { "name": "shadow", "entry": "RasterEntryNode", "entryRecord": { "isShadowPass": 1 } },
    { "name": "camera", "entry": "RasterEntryNode", "entryRecord": { "isShadowPass": 0 }, "defines": ["EXTRA=1"] }
  ]
}
```

Paths are relative to the config file. Only `source` and `dispatches` (each with `name` and `entry`) are required.

| Field | Meaning |
| --- | --- |
| `source` | The single HLSL file that `#include`s the whole graph. |
| `compile.profile` | dxc target profile (default `lib_6_8`). **Use exactly what your app compiles with**, including its defines - the diagrams describe the code that gets compiled. |
| `compile.defines` | `KEY=VALUE` defines for every dispatch. A shader that tests `#ifdef X` treats `X=0` as defined: leave the define out to switch such a feature off. |
| `compile.dxcArgs` | Extra dxc arguments (e.g. `-enable-16bit-types`). |
| `compile.dxc` / `compile.dxcVersion` | The compiler to use, as `parse-dxil --dxc` / `--dxc-version`; omit both to use one `setup-dxil` installed. |
| `diagram.lineType` | `spline` (default, curved), `polyline` or `ortho` for every diagram. |
| `diagram.frameLineTypes` | Extra frame renderings, one `frame-<style>.puml` per listed style - handy for comparing. |
| `diagram.short`, `nodeComments`, `globalFields`, `edgeRecordSize`, `recordComments` | As the matching `build-puml` / `build-records` flags. |
| `diagram.hideGlobals` | Resources to leave out of the frame (e.g. a diagnostics log every node writes). Noted in the legend. |
| `inventory` | Optional text file with the app's `[WorkGraph]` startup lines, for `validate --inventory`. |
| `dispatches[]` | In frame order. `name`, `entry` (a `[NodeIsProgramEntry]` node), optional `entryRecord` (field → number) and `defines` (added to `compile.defines`). |

The library is compiled once per distinct set of defines, so dispatches that share their defines share one compile.

## Outputs

| File | Content |
| --- | --- |
| `NN-<name>.ir.json` | The dispatch's part of the IR: nodes reachable from its entry (dead ones included), their globals and record types, plus a `dispatch` field with the definition. |
| `NN-<name>.graph.puml` | Node graph of that dispatch. |
| `NN-<name>.records.puml` | Record layouts used in that dispatch. |
| `compile-K.ir.json` | The full IR of each distinct compile. |
| `frame.plan.json` / `frame.puml` | The merged frame: every dispatch as a package in order, with the UAV hand-offs between them. |
| `frame-<style>.puml` | Only with `diagram.frameLineTypes`. |
| `validation.txt` / `.json` | Graph-wide checks per compile, then the frame checks. |

With `--jar`, `--server` or `--render`, every `.puml` is rendered to `.svg` and `.png` next to it. Source paths in
the IRs are written relative to the config file, so outputs can be committed.

## Entry records

Each value is checked against the entry node's input record layout: the field must exist, the value must be a
number, and an entry without an input record cannot take one. The frame shows the values and, per field, what
the DXIL dataflow says it reaches in that dispatch - branches it decides, output counts it affects, buffers it
indexes, record fields it is copied into (followed transitively).

The value itself is **not** propagated through the shader: the tool does not fold `isShadowPass = 1` into the
code to prune branches, so two dispatches of the same entry show the same subgraph and differ in their entry
record and its listed effects. Different `defines`, in contrast, produce a separately compiled graph.

## Reading the frame

Solid arrows are records inside one dispatch. Each UAV any node touches gets one box, with dashed edges: red =
write, orange = atomic, blue = read. Dotted edges are statically dead (every allocation is the literal 0) and
greyed nodes are never launched. The legend lists the global resource table, the dispatches, and exactly which
parts came from the definitions (order, entries, entry-record values, defines) - everything else is read from the
compiled DXIL. For a large graph, `spline` with `short` and no node comments is usually the most readable.
