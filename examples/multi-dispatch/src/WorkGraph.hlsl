// examples/multi-dispatch - a minimal two-stage frame for `pipeline`:
//   dispatch "produce" (entry EmitNode) fills `items` and counts them in `counters`;
//   dispatches "consume-*" (entry DrawEntryNode) read the count back, fan out one record per item and
//   read `items` by the index they carry. WITH_STATS (set per dispatch in pipeline.config.json) adds a
//   statistics counter, to show a dispatch compiled with its own #defines.

struct Config { uint itemsPerGroup; float scale; };
struct Item { float3 position; uint kind; };

StructuredBuffer<Config>   config   : register(t0);
RWStructuredBuffer<Item>   items    : register(u0);
RWStructuredBuffer<uint>   counters : register(u1); // [0] = items allocated, [1] = statistics
RWStructuredBuffer<float>  results  : register(u2);

struct ItemRecord { float3 position; uint kind; };
struct DrawEntryRecord { uint pass; };
struct FanOutRecord { uint3 DispatchGrid : SV_DispatchGrid; uint count; uint pass; };
struct ItemRef { uint index; uint pass; };

#define EMIT_THREADS 64
#define FANOUT_THREADS 32

[Shader("node")]
[NodeIsProgramEntry]
[NodeLaunch("broadcasting")]
[NodeDispatchGrid(4, 1, 1)]
[NumThreads(EMIT_THREADS, 1, 1)]
void EmitNode(uint tid : SV_DispatchThreadID,
    [MaxRecords(EMIT_THREADS)] [NodeID("StoreNode")] NodeOutput<ItemRecord> itemOutput)
{
    const bool emit = tid < config[0].itemsPerGroup * 4;
    ThreadNodeOutputRecords<ItemRecord> r = itemOutput.GetThreadNodeOutputRecords(emit ? 1 : 0);
    if (emit)
    {
        r.Get().position = float3(tid, 0, 0) * config[0].scale;
        r.Get().kind = tid & 3;
    }
    r.OutputComplete();
}

[Shader("node")]
[NodeLaunch("thread")]
void StoreNode(ThreadNodeInputRecord<ItemRecord> item)
{
    uint slot;
    InterlockedAdd(counters[0], 1, slot);
    items[slot].position = item.Get().position;
    items[slot].kind = item.Get().kind;
}

[Shader("node")]
[NodeIsProgramEntry]
[NodeLaunch("broadcasting")]
[NodeDispatchGrid(1, 1, 1)]
[NumThreads(1, 1, 1)]
void DrawEntryNode(DispatchNodeInputRecord<DrawEntryRecord> entry,
    [MaxRecords(1)] [NodeID("FanOutNode")] NodeOutput<FanOutRecord> fanOutput)
{
    const uint count = counters[0];
    GroupNodeOutputRecords<FanOutRecord> r = fanOutput.GetGroupNodeOutputRecords(count > 0 ? 1 : 0);
    if (count > 0)
    {
        r.Get().DispatchGrid = uint3((count + FANOUT_THREADS - 1) / FANOUT_THREADS, 1, 1);
        r.Get().count = count;
        r.Get().pass = entry.Get().pass;
    }
    r.OutputComplete();
}

[Shader("node")]
[NodeLaunch("broadcasting")]
[NodeMaxDispatchGrid(1024, 1, 1)]
[NumThreads(FANOUT_THREADS, 1, 1)]
void FanOutNode(uint tid : SV_DispatchThreadID,
    DispatchNodeInputRecord<FanOutRecord> fan,
    [MaxRecords(FANOUT_THREADS)] [NodeID("ShadeNode")] NodeOutput<ItemRef> refOutput)
{
    const bool inRange = tid < fan.Get().count;
    ThreadNodeOutputRecords<ItemRef> r = refOutput.GetThreadNodeOutputRecords(inRange ? 1 : 0);
    if (inRange)
    {
        r.Get().index = tid;
        r.Get().pass = fan.Get().pass;
    }
    r.OutputComplete();
}

[Shader("node")]
[NodeLaunch("thread")]
void ShadeNode(ThreadNodeInputRecord<ItemRef> ref)
{
    const Item it = items[ref.Get().index];
    results[ref.Get().index] = ref.Get().pass == 0 ? it.position.x : float(it.kind);
#ifdef WITH_STATS
    InterlockedAdd(counters[1], 1);
#endif
}
