// Known-answer fixture for parse-dxil's globalAccess / output-allocation tracing.
struct Rec { uint v; };
StructuredBuffer<uint>   onlyRead    : register(t0);
StructuredBuffer<uint>   onlyQueried : register(t1);
RWStructuredBuffer<uint> onlyWritten : register(u0);
RWStructuredBuffer<uint> onlyAtomic  : register(u1);
RWStructuredBuffer<uint> pickA       : register(u2);
RWStructuredBuffer<uint> pickB       : register(u3);
RWStructuredBuffer<uint> readWrite   : register(u4);

[Shader("node")]
[NodeIsProgramEntry]
[NodeLaunch("broadcasting")]
[NodeDispatchGrid(1, 1, 1)]
[NumThreads(32, 1, 1)]
void Producer(uint i : SV_DispatchThreadID,
    [MaxRecords(32)] NodeOutput<Rec> live,
    [MaxRecords(32)] NodeOutput<Rec> dead)
{
    uint n, s;
    onlyQueried.GetDimensions(n, s);
    onlyWritten[i] = onlyRead[i] + n;
    InterlockedAdd(onlyAtomic[0], 1);
    readWrite[i] = readWrite[i + 1];
    // The handle is a select between two resources: both must be attributed.
    uint x = (i & 1) ? pickA[i] : pickB[i];
    ThreadNodeOutputRecords<Rec> r = live.GetThreadNodeOutputRecords(x & 1);
    if (x & 1) r.Get().v = x;
    r.OutputComplete();
    ThreadNodeOutputRecords<Rec> d = dead.GetThreadNodeOutputRecords(0);
    d.OutputComplete();
}

[Shader("node")]
[NodeLaunch("thread")]
void live(ThreadNodeInputRecord<Rec> r) {}

[Shader("node")]
[NodeLaunch("thread")]
void dead(ThreadNodeInputRecord<Rec> r) {}
