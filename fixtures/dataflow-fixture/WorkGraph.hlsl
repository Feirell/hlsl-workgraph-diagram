// Known-answer fixture for parse-dxil's dataflow and validate's field checks.
// Expected:
//  - Mid.idx  <- in:Entry.base + SV_DispatchThreadID.x ; indexes `data` in Leaf
//  - Entry.base indexes `data` via Mid.idx (one level of composition)
//  - Mid.count <- const:5 ; allocation count of Leaf output <- in:Entry.n
//  - Mid.missing: read by Leaf, never written by Head -> field-initialised WARN
//  - Mid.spare: written by Head, never read            -> field-unread INFO
struct EntryRec { uint base; uint n; };
struct Mid { uint idx; uint count; uint missing; uint spare; };
RWStructuredBuffer<uint> data : register(u0);
RWStructuredBuffer<uint> sink : register(u1);

[Shader("node")]
[NodeIsProgramEntry]
[NodeLaunch("broadcasting")]
[NodeDispatchGrid(1, 1, 1)]
[NumThreads(4, 1, 1)]
void Head(uint tid : SV_DispatchThreadID,
    DispatchNodeInputRecord<EntryRec> input,
    [MaxRecords(4)] [NodeID("Leaf")] NodeOutput<Mid> o)
{
    ThreadNodeOutputRecords<Mid> r = o.GetThreadNodeOutputRecords(input.Get().n & 1);
    if (input.Get().n & 1)
    {
        r.Get().idx = input.Get().base + tid;
        r.Get().count = 5;
        r.Get().spare = 7;
    }
    r.OutputComplete();
}

[Shader("node")]
[NodeLaunch("thread")]
void Leaf(ThreadNodeInputRecord<Mid> m)
{
    sink[m.Get().count] = data[m.Get().idx] + m.Get().missing;
}
