> **⚠️ LLM-GENERATED CONTENT** - review before relying on it.

# `pipeline`: diagrams from dispatch definitions

What a work graph *does* in a frame depends on host code the tool cannot see: which entrypoint each
`DispatchGraph` starts at, which entry record it passes, and which `#define`s the library was compiled with.
A **dispatch definition** file states exactly those things, and `pipeline` runs the rest of the tool over it:

```sh
hlsl-workgraph-diagram pipeline workgraph.config.json out/ --jar ~/.local/share/plantuml/plantuml.jar
```

```json
{
  "source": "shaders/GraphNodes.hlsl",
  "compile": { "profile": "lib_6_9", "defines": ["SHADER_DIAGNOSTICS=1"], "dxcArgs": [], "dxc": "/opt/dxc/bin/dxc" },
  "diagram": { "lineType": "spline", "frameLineTypes": ["spline", "polyline", "ortho"], "short": true, "nodeComments": false, "hideGlobals": [] },
  "inventory": "startup-log.txt",
  "dispatches": [
    { "name": "generation", "entry": "EntryNode" },
    { "name": "shadow", "entry": "RasterEntryNode", "entryRecord": { "isShadowPass": 1 } },
    { "name": "camera", "entry": "RasterEntryNode", "entryRecord": { "isShadowPass": 0 }, "defines": ["EXTRA=1"] }
  ]
}
```

Paths are relative to the config file. `compile.defines` apply to every dispatch; a dispatch's own `defines`
are added to them. The library is compiled once per distinct define set. `compile.dxc` / `compile.dxcVersion`
select the compiler as for `parse-dxil`. `diagram` holds display options; `frameLineTypes` additionally writes `frame-<style>.puml` per edge-routing
style (`spline` curves, `polyline` straight segments, `ortho` right angles). `inventory` (optional) is a text file with
the app's `[WorkGraph]` startup lines, for `validate --inventory`.

**Outputs** (in the order of `dispatches`, which is the frame order):
- `NN-<name>.ir.json` - the dispatch's part of the IR (nodes reachable from its entry, their globals and record
  types), with a `dispatch` field recording the definition;
- `NN-<name>.graph.puml`, `NN-<name>.records.puml` - graph and record-layout diagrams of that dispatch;
- `compile-K.ir.json` - the full IR of each distinct compile;
- `frame.plan.json` / `frame.puml` - all dispatches as packages, with the UAV hand-offs between them;
- `validation.txt` / `.json` - graph-wide checks per compile, then the frame checks (entries, entry records,
  cross-dispatch read-before-write in the declared order, inventory).

**Entry records.** Each value is checked against the entry node's input record layout (field exists, value is
numeric). The frame diagram shows the values and, per field, what the DXIL dataflow says it reaches in that
dispatch: branches it decides, output counts it affects, buffers it indexes, record fields it is copied into
(followed transitively). The value itself is **not** propagated through the shader: the tool does not fold
`isShadowPass = 1` into the code to prune branches, so both dispatches of one entry show the same subgraph.
