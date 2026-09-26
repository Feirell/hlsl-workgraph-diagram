// Known-answer fixture for parse-dxil's recordTypes: SV_DispatchGrid at a non-zero
// offset with a 16-bit component type, a nested struct, an array, and real padding.
struct Inner { float3 p; };                    // 12 B
struct GridRec
{
    float2 before;                             // +0
    uint16_t2 grid : SV_DispatchGrid;          // +8, uint16 x2
    uint16_t small;                            // +12, then 2 B padding
    uint after;                                // +16
    Inner inner[2];                            // +20, 24 B
};                                             // 44 B

[Shader("node")]
[NodeIsProgramEntry]
[NodeLaunch("broadcasting")]
[NodeDispatchGrid(1, 1, 1)]
[NumThreads(1, 1, 1)]
void Producer([MaxRecords(1)] [NodeID("Consumer")] NodeOutput<GridRec> o)
{
    GroupNodeOutputRecords<GridRec> r = o.GetGroupNodeOutputRecords(1);
    r.Get().grid = uint16_t2(1, 1);
    r.OutputComplete();
}

[Shader("node")]
[NodeLaunch("broadcasting")]
[NodeMaxDispatchGrid(4, 4, 1)]
[NumThreads(1, 1, 1)]
void Consumer(DispatchNodeInputRecord<GridRec> r) {}
