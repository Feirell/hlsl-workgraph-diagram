// ---------------------------------------------------------------------------
// Harness compile unit for validating parse-workgraph.js against the repo's
// real examples/mesh-culling (not the experimental/hlsl spike fixture).
// See experimental/HANDOFF.md, "not done yet" #1.
//
// Points at mesh-culling/ below (a local copy of examples/mesh-culling),
// not examples/ directly: the real example hits the exact same dxc
// #pragma-once cross-directory dedup bug already found and fixed in
// experimental/hlsl/structs/Records.hlsl (see experimental/README.md) -
// examples/mesh-culling/structs/Records.hlsl is #included via two
// differently-spelled relative paths (nodes-compute/ vs nodes-mesh/) and
// dxc fails with "redefinition of 'DispatchRecord'"/'MeshInputRecord'.
// mesh-culling/structs/Records.hlsl here is a copy with the same #ifndef
// guard fix applied; every node file is an unmodified byte-copy of the
// real example. examples/ itself is left untouched.
// ---------------------------------------------------------------------------
#include "mesh-culling/nodes-compute/EntryNode.hlsl"
#include "mesh-culling/nodes-compute/CullNode.hlsl"
#include "mesh-culling/nodes-mesh/RenderMeshNode.hlsl"
