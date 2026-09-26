> **⚠️ LLM-GENERATED CONTENT** - review before relying on it.

# Dispatch plans (`build-puml --dispatches`, `validate --dispatches`)

A work graph with several entrypoints is usually dispatched more than once per frame, each `DispatchGraph`
starting at a different entry (or the same entry under a different program), with data handed from one
dispatch to the next through UAVs. None of that is in the HLSL: the order, the program and the bindings are
host-side decisions. A dispatch plan is a small JSON file that states them, so the diagram and the checks can
use them.

```json
{
  "title": "One frame = three DispatchGraph calls",
  "sources": ["where each fact below comes from - shown in the legend"],
  "betweenDispatches": "global UAV barrier after every dispatch",
  "frameStart": { "note": "...", "initialisedResources": ["counters"] },
  "programs": {
    "Colour": {
      "stateObjectName": "MyGraph",
      "meshNodePixelShaders": { "MeshNode": "MyPixelShader" },
      "renamedCopies": ["MeshNodeUnusedDepth"]
    },
    "DepthOnly": { "stateObjectName": "MyGraph_Secondary1", "meshNodePixelShaders": { "MeshNode": null } }
  },
  "dispatches": [
    { "id": "A", "label": "Generation", "entry": "EntryNode", "program": "Colour",
      "bindings": "...", "entryRecord": "...", "conditional": "...", "note": "..." }
  ],
  "diagram": { "hideResources": ["debugLog"], "hideResourcesNote": "why" },
  "rules": [
    { "id": "no-pass-table-in-compute", "description": "...", "forbidRead": { "space": 2 },
      "launchModes": ["broadcasting", "coalescing", "thread"], "dispatches": ["B", "C"] }
  ]
}
```

Only `dispatches[].id` and `dispatches[].entry` are required; everything else is optional.

- **`programs.<name>.meshNodePixelShaders`**: `null` means depth-only (no pixel shader). Shown in each mesh
  node's box.
- **`programs.<name>.renamedCopies`**: node names the runtime reports that do not exist in HLSL (e.g. a mesh
  node's generic program renamed in the program that does not use it). Listed in the legend, and expected by
  `validate --inventory`.
- **`programs.<name>.stateObjectName`**: matches the program name in a `[WorkGraph] program N ("<name>")`
  inventory line.
- **`frameStart.initialisedResources`**: UAVs that are valid before the first dispatch (cleared, uploaded).
  Reading them is not reported as read-before-write.
- **`attachmentFlows`**: data that moves between dispatches outside the node library, e.g. a shadow map that is
  one dispatch's depth target and a later dispatch's pixel-shader input. The node DXIL cannot show this: pixel
  shaders are a separate compile, and a render target is not a UAV. Each flow has `resource`, optional
  `kind`/`transition`/`evidence`, `producers` and `consumers` (`{dispatch, nodes[], how}`). It is drawn as a
  bold purple box and checked like a UAV flow, including against a conditional producer.
- **`dispatches[].conditional`**: the dispatch may be skipped. `validate` warns when a later read's only
  producers are conditional and the resource is not in `frameStart.initialisedResources`.
- **`rules`**: forbid any live node (optionally only of the listed launch modes and dispatches) from reading
  a resource in the given register space.

## What the view shows

One package per dispatch, holding a copy of every node reachable from that dispatch's entry (aliases are
`<dispatchId>__<nodeId>`). Each node's depth is measured from that dispatch's entry. Solid arrows are records.
A dotted arrow is an edge whose every `allocate...Records` call in the DXIL passes the literal `0`, and a node
reachable only through such edges is drawn greyed out as *never launched*. Every UAV that a live node touches
gets one box, with dashed edges: red for write, orange for atomic, blue for read. These come from the IR's
optional `globalAccess` field (see `ir-format.md`), so they need `parse-dxil`. SRVs stay in the node bodies.

## What `validate` checks

Without a plan: that record types and byte sizes match on every edge, that there are no orphan nodes and no
mesh node with outputs, and the spec's node output limits (MaxRecords <= 256 / <= 8 for thread launch,
MaxOutputSize <= 32 KB / 128 B, the 48 KB combined rule including groupshared memory). With a plan: that every
entry exists and is a `[NodeIsProgramEntry]`, graph depth, and that every node is part of some dispatch. It
flags entries no dispatch uses and subgraphs shared between different entries. It also checks cross-dispatch
UAV flow: a plain read needs a write or atomic in an **earlier** dispatch, or frame-start initialisation, and a
read and a write inside **one** dispatch need `globallycoherent` plus a barrier. Finally it applies the plan's
rules. With `--inventory`, it compares against the runtime's `[WorkGraph]` node and entrypoint listing.
Output is one `PASS/WARN/FAIL/INFO` line per check; the exit code is 1 on any FAIL.
