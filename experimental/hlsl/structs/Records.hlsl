// ---------------------------------------------------------------------------
// Experimental v2 fixture — not part of the published tool, see
// experimental/README.md. No real compute, just enough to be a valid,
// compilable work graph.
// ---------------------------------------------------------------------------
// Include guard, not #pragma once: this file is #included via differently
// spelled relative paths from nodes-compute/ and nodes-mesh/
// ("nodes-compute/../structs/Records.hlsl" vs
// "nodes-mesh/../structs/Records.hlsl") and dxc's #pragma once tracking
// doesn't dedupe those as the same file — a real finding from actually
// running dxc against this fixture, see experimental/README.md.
#ifndef EXPERIMENTAL_STRUCTS_RECORDS_HLSL
#define EXPERIMENTAL_STRUCTS_RECORDS_HLSL

// Emitted by EntryNode, one record per unit of work.
struct WorkItemRecord
{
    uint itemId;
};

// Emitted by GenerateNode, gathered by CollectNode.
struct ResultRecord
{
    float value;
};

#endif
