// ---------------------------------------------------------------------------
// Experimental v2 fixture — not part of the published tool, see
// experimental/README.md.
// ---------------------------------------------------------------------------
#pragma once
#include "../structs/Records.hlsl"

[Shader("node")]
[NodeLaunch("thread")]
void GenerateNode(
    ThreadNodeInputRecord<WorkItemRecord> inputRecord,

    [MaxRecords(1)]
    [NodeID("CollectNode")]
    NodeOutput<ResultRecord> resultOutput
)
{
    ThreadNodeOutputRecords<ResultRecord> result = resultOutput.GetThreadNodeOutputRecords(1);
    result.OutputComplete();
}
