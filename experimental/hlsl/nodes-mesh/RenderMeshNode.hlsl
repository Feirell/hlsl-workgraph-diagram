// ---------------------------------------------------------------------------
// Experimental v2 fixture — not part of the published tool, see
// experimental/README.md.
//
// Only pulled into the compile when ENABLE_MESH_PATH is defined (see
// WorkGraph.hlsl) — mesh-launch nodes need the mesh-nodes-preview dxc build.
// This file existing anywhere under the scanned tree is what fetch-dxc.sh
// looks for to decide whether to fetch that preview build, on purpose:
// that's the same "is there a mesh node in here at all" question the
// current regex-based tool has to answer from raw text too, guard or no
// guard.
// ---------------------------------------------------------------------------
#pragma once
#include "../structs/Records.hlsl"
#include "../structs/VertexTypes.hlsl"

#define RMN_THREADS 32

// Mesh-launch node: rasterizes up to 64 triangles per thread group.
[Shader("node")]
[NodeLaunch("mesh")]
[NodeMaxDispatchGrid(64, 1, 1)]
[NumThreads(RMN_THREADS, 1, 1)]
[OutputTopology("triangle")]
void RenderMeshNode(
    uint gtid : SV_GroupThreadID,

    DispatchNodeInputRecord<MeshInputRecord> inputRecord,

    out indices  uint3  triangles[64],
    out vertices Vertex verts[64]
)
{
}
