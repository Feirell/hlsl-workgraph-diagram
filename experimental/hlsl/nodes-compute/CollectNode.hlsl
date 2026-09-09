// ---------------------------------------------------------------------------
// Experimental v2 fixture — not part of the published tool, see
// experimental/README.md.
// ---------------------------------------------------------------------------
#pragma once
#include "../structs/Records.hlsl"

#define COLLECT_THREADS 32

// Gathers up to 64 ResultRecords per invocation. Terminal node - no output.
[Shader("node")]
[NodeLaunch("coalescing")]
[NumThreads(COLLECT_THREADS, 1, 1)]
void CollectNode(
    uint gtid : SV_GroupThreadID,

    [MaxRecords(64)]
    GroupNodeInputRecords<ResultRecord> results
)
{
}
