// ---------------------------------------------------------------------------
// Experimental v2 fixture — not part of the published tool, see
// experimental/README.md.
// ---------------------------------------------------------------------------
// Include guard, not #pragma once — see structs/Records.hlsl for why.
#ifndef EXPERIMENTAL_STRUCTS_VERTEXTYPES_HLSL
#define EXPERIMENTAL_STRUCTS_VERTEXTYPES_HLSL

// Consumed by RenderMeshNode (only compiled when ENABLE_MESH_PATH is set,
// see WorkGraph.hlsl) — one record per broadcasting dispatch grid cell.
// SV_DispatchGrid is required on a [NodeMaxDispatchGrid(...)] node's input
// record — it's how the runtime dispatch grid size is actually supplied;
// another real finding from running dxc, see experimental/README.md.
struct MeshInputRecord
{
    uint3 dispatchGrid : SV_DispatchGrid;
};

struct Vertex
{
    float4 position : SV_Position;
    float3 normal : NORMAL;
};

#endif
