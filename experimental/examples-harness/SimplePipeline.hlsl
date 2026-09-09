// ---------------------------------------------------------------------------
// Harness compile unit for validating parse-workgraph.js against the repo's
// real examples/simple-pipeline (not the experimental/hlsl spike fixture).
// #includes the real, unmodified example node files directly - nothing here
// duplicates their content. See experimental/HANDOFF.md, "not done yet" #1.
// ---------------------------------------------------------------------------
#include "../../examples/simple-pipeline/nodes-compute/EntryNode.hlsl"
#include "../../examples/simple-pipeline/nodes-compute/GenerateNode.hlsl"
#include "../../examples/simple-pipeline/nodes-compute/CollectNode.hlsl"
