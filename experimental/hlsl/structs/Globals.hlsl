// ---------------------------------------------------------------------------
// Experimental v2 fixture — not part of the published tool, see
// experimental/README.md. Mirrors examples/mesh-culling/structs/Globals.hlsl:
// one global resource, read by exactly one node, to validate that per-node
// global-resource-usage extraction actually works against a real dxc
// compile (not just in theory).
// ---------------------------------------------------------------------------
#ifndef EXPERIMENTAL_STRUCTS_GLOBALS_HLSL
#define EXPERIMENTAL_STRUCTS_GLOBALS_HLSL

struct ItemMeta
{
    uint tag;
};

StructuredBuffer<ItemMeta> itemMeta : register(t0);

#endif
