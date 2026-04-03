# LSU memory-request path from `LsuUnit::tick()`

## Scope
- Goal: trace the timing-side memory request path starting at `LsuUnit::tick()` and identify:
  - which queues are involved,
  - which objects own/operate each stage,
  - how ports are bound,
  - key caveats.
- Inspected files:
  - [sim/simx/func_unit.cpp](../sim/simx/func_unit.cpp)
  - [sim/simx/func_unit.h](../sim/simx/func_unit.h)
  - [sim/simx/core.cpp](../sim/simx/core.cpp)
  - [sim/simx/types.cpp](../sim/simx/types.cpp)
  - [sim/simx/types.h](../sim/simx/types.h)
  - [sim/simx/mem_coalescer.cpp](../sim/simx/mem_coalescer.cpp)
  - [sim/simx/local_mem.cpp](../sim/simx/local_mem.cpp)
  - [sim/simx/socket.cpp](../sim/simx/socket.cpp)
  - [sim/simx/cache_cluster.h](../sim/simx/cache_cluster.h)
  - [sim/simx/cluster.cpp](../sim/simx/cluster.cpp)
  - [sim/simx/processor.cpp](../sim/simx/processor.cpp)
  - [sim/simx/cache_sim.cpp](../sim/simx/cache_sim.cpp)
  - [sim/simx/mem_sim.cpp](../sim/simx/mem_sim.cpp)
  - [sim/common/simobject.h](../sim/common/simobject.h)

## Findings

### 1) Entry point: `LsuUnit::tick()` request/response bookkeeping
- LSU consumes responses from per-block `LocalMemSwitch::RspIn` and decrements per-tag outstanding read counters.
  - See [sim/simx/func_unit.cpp L175-L203](../sim/simx/func_unit.cpp#L175).
- Read tracking queue is `pending_rd_reqs` per LSU block (`HashTable<pending_req_t>`), capacity `LSUQ_IN_SIZE`.
  - See [sim/simx/func_unit.h L83-L96](../sim/simx/func_unit.h#L83).
- New read requests allocate a tag from `pending_rd_reqs`; writes do not allocate read-tracking tags.
  - See [sim/simx/func_unit.cpp L310-L317](../sim/simx/func_unit.cpp#L310).
- LSU emits request batches to `core_->lmem_switch_[block]->ReqIn`.
  - See [sim/simx/func_unit.cpp L317](../sim/simx/func_unit.cpp#L317).
- Backpressure point at LSU entry: if read-tracking table is full, the instruction stalls in-place.
  - See [sim/simx/func_unit.cpp L256-L263](../sim/simx/func_unit.cpp#L256).

### 2) First split: shared/local vs global path (`LocalMemSwitch`)
- Address-type classification is by `get_addr_type(addr)` (`Shared` for LMEM range, `IO` for IO range, else `Global`).
  - See [sim/simx/types.h L708-L723](../sim/simx/types.h#L708).
- `LocalMemSwitch::tick()` copies one incoming `LsuReq` into two masked requests:
  - `ReqLmem` for `AddrType::Shared`,
  - `ReqDC` for non-shared (global + IO).
  - See [sim/simx/types.cpp L34-L80](../sim/simx/types.cpp#L34).
- Responses from both sides (`RspLmem`, `RspDC`) are merged back into `RspIn`.
  - See [sim/simx/types.cpp L35-L47](../sim/simx/types.cpp#L35).

### 3) Core-level wiring from LSU block to LMEM and DCache pipelines
- Core constructor creates these objects:
  - per-block `MemCoalescer`,
  - per-block `LocalMemSwitch`,
  - one `LsuArbiter` (LMEM fan-in),
  - one `LsuMemAdapter` for LMEM,
  - per-block `LsuMemAdapter` for DCache path.
  - See [sim/simx/core.cpp L66-L101](../sim/simx/core.cpp#L66).
- Binding topology:
  - `lmem_switch.ReqDC -> mem_coalescer.ReqIn`,
  - `lmem_switch.ReqLmem -> lmem_arb.ReqIn[b]`,
  - `mem_coalescer.RspIn -> lmem_switch.RspDC`,
  - `lmem_arb.RspIn[b] -> lmem_switch.RspLmem`.
  - See [sim/simx/core.cpp L105-L109](../sim/simx/core.cpp#L105).
- LMEM subpath binding:
  - `lmem_arb.ReqOut[0] -> lsu_lmem_adapter.ReqIn`,
  - `lsu_lmem_adapter.ReqOut[c] -> local_mem.Inputs[c]`,
  - `local_mem.Outputs[c] -> lsu_lmem_adapter.RspOut[c]`,
  - `lsu_lmem_adapter.RspIn -> lmem_arb.RspOut[0]`.
  - See [sim/simx/core.cpp L113-L119](../sim/simx/core.cpp#L113).
- DCache subpath binding:
  - `mem_coalescer.ReqOut -> lsu_dcache_adapter.ReqIn`,
  - `lsu_dcache_adapter.RspIn -> mem_coalescer.RspOut`,
  - `lsu_dcache_adapter.ReqOut[c] -> core.dcache_req_ports[p]`,
  - `core.dcache_rsp_ports[p] -> lsu_dcache_adapter.RspOut[c]`.
  - See [sim/simx/core.cpp L124-L133](../sim/simx/core.cpp#L124).

### 4) LMEM subpath internals
- `LsuMemAdapter` converts one masked `LsuReq` into per-lane `MemReq` (`ReqOut[i]`) and re-aggregates per-lane `MemRsp` with same tag into one `LsuRsp`.
  - See [sim/simx/types.cpp L104-L156](../sim/simx/types.cpp#L104).
- `LocalMem` uses a `MemCrossBar` (priority arbitration) into banks; returns `MemRsp` for reads (and optionally writes if configured).
  - See [sim/simx/local_mem.cpp L48-L55](../sim/simx/local_mem.cpp#L48), [sim/simx/local_mem.cpp L77-L95](../sim/simx/local_mem.cpp#L77).

### 5) DCache subpath internals
- `MemCoalescer` merges lanes to cache-line granularity (`line_size` mask), tracks partially sent lane set via `sent_mask_`, and uses internal read tag table (`pending_rd_reqs_`).
  - See [sim/simx/mem_coalescer.cpp L91-L157](../sim/simx/mem_coalescer.cpp#L91).
- Coalescer has its own backpressure point: if `pending_rd_reqs_` is full, it stalls input request.
  - See [sim/simx/mem_coalescer.cpp L91-L94](../sim/simx/mem_coalescer.cpp#L91).
- Core DCache ports are connected to socket-level DCache cluster.
  - See [sim/simx/socket.cpp L110-L111](../sim/simx/socket.cpp#L110).
- DCache cluster is a `CacheCluster` that uses input arbiters and mem arbiters around multiple `CacheSim` instances.
  - See [sim/simx/cache_cluster.h L51-L78](../sim/simx/cache_cluster.h#L51).
- `CacheSim` bank pipeline:
  - core request enters bank pipeline,
  - hit/miss lookup,
  - optional MSHR allocation/replay,
  - memory fill/writeback/writethrough,
  - response to core (for reads; writes depend on `write_reponse`).
  - See [sim/simx/cache_sim.cpp L384-L520](../sim/simx/cache_sim.cpp#L384), [sim/simx/cache_sim.cpp L425-L457](../sim/simx/cache_sim.cpp#L425).

### 6) Beyond L1 DCache: socket -> L2 -> L3 -> DRAM sim
- Socket wires L1 cache memory ports (I$ and D$ via arbiter overlap) to socket `mem_req_ports`.
  - See [sim/simx/socket.cpp L71-L89](../sim/simx/socket.cpp#L71).
- Cluster wires socket memory ports into L2 `CacheSim`.
  - See [sim/simx/cluster.cpp L46-L73](../sim/simx/cluster.cpp#L46).
- Processor wires cluster memory ports into L3 `CacheSim`, then into `MemSim`.
  - See [sim/simx/processor.cpp L41-L69](../sim/simx/processor.cpp#L41).
- `MemSim` uses a banked crossbar and sends requests into `DramSim`; read completion callback pushes `MemRsp` back.
  - See [sim/simx/mem_sim.cpp L47-L53](../sim/simx/mem_sim.cpp#L47), [sim/simx/mem_sim.cpp L82-L90](../sim/simx/mem_sim.cpp#L82).

### 7) Queue/port mechanics and who manages object lifetime
- `SimPort::bind()` requires virtual ports (capacity 0) and forwards to sink.
  - See [sim/common/simobject.h L90-L111](../sim/common/simobject.h#L90).
- Sim objects are owned by `SimPlatform` global object list (`objects_.push_back(obj)` in `create_object`).
  - See [sim/common/simobject.h L394-L397](../sim/common/simobject.h#L394).
- Even locally scoped pointers created via `::Create(...)` remain alive because platform owns them.
- Push/pop are deferred per simulation cycle; same port cannot be pushed/popped multiple times in one cycle by same source/sink API path.
  - See [sim/common/simobject.h L466-L484](../sim/common/simobject.h#L466).

## Queue map (request side)
- `LsuUnit`
  - software-visible tracking: `states_[block].pending_rd_reqs` (HashTable)
  - output port: `lmem_switch_[block].ReqIn`
- `LocalMemSwitch`
  - input: `ReqIn`
  - outputs: `ReqLmem`, `ReqDC`
- LMEM branch
  - `LsuArbiter ReqIn[b] -> ReqOut[0]`
  - `LsuMemAdapter ReqIn -> ReqOut[c]`
  - `LocalMem Inputs[c] -> banked MemCrossBar`
- DCache branch
  - `MemCoalescer ReqIn -> ReqOut`
  - per-block `LsuMemAdapter ReqIn -> ReqOut[c]`
  - core `dcache_req_ports[p]`
  - socket DCache cluster / `CacheSim` banks / MSHR
  - socket mem ports -> cluster L2 -> processor L3 -> `MemSim`/DRAM

## Boundaries
- Kept in this note: timing/control flow of request and response envelopes (`LsuReq`/`LsuRsp`/`MemReq`/`MemRsp`).
- Not expanded here: instruction decode-side address generation details and all vector LSU submodes (only where they feed `LsuUnit` request masks).

## Caveats
- Functional data path is separate from timing path in simx:
  - Actual load/store bytes are read/written through emulator/MMU or local RAM helpers (`dcache_read`/`dcache_write`), while timing uses cache/memory simulation ports.
  - See [sim/simx/emulator.cpp L311-L376](../sim/simx/emulator.cpp#L311), [sim/simx/local_mem.cpp L65-L74](../sim/simx/local_mem.cpp#L65).
- `LocalMem::tick()` handles request/response bookkeeping and perf, but data array updates happen in explicit `read()`/`write()` methods, not in `tick()`.
  - See [sim/simx/local_mem.cpp L77-L95](../sim/simx/local_mem.cpp#L77).
- Many cache configs in this path set `write_reponse=false` (L1 D$, L2, L3), so stores are generally fire-and-forget on timing side.
  - See [sim/simx/socket.cpp L62-L63](../sim/simx/socket.cpp#L62), [sim/simx/cluster.cpp L56-L58](../sim/simx/cluster.cpp#L56), [sim/simx/processor.cpp L51-L53](../sim/simx/processor.cpp#L51).
- Tag rewriting occurs in arbiters/crossbars; response tags are de-multiplexed by inverse shifts.
  - See [sim/simx/types.h L1404-L1438](../sim/simx/types.h#L1404), [sim/simx/types.h L1502-L1548](../sim/simx/types.h#L1502).
- IO requests are bypassed in cache path (`AddrType::IO`), routed through non-cacheable arbiter logic.
  - See [sim/simx/cache_sim.cpp L667-L704](../sim/simx/cache_sim.cpp#L667).
- Cache init delay exists (`init_cycles_ = sets_per_bank`) before normal operation.
  - See [sim/simx/cache_sim.cpp L625-L635](../sim/simx/cache_sim.cpp#L625).

## Recommendations
- For debugging one request end-to-end, log these tuple fields at each stage: `{cid, uuid, tag, mask, addr/type}`.
- For queue-pressure diagnosis, inspect both:
  - LSU read-tracking fullness in [sim/simx/func_unit.cpp L256-L263](../sim/simx/func_unit.cpp#L256),
  - coalescer read-tag fullness in [sim/simx/mem_coalescer.cpp L91-L94](../sim/simx/mem_coalescer.cpp#L91),
  - cache-bank MSHR pressure in [sim/simx/cache_sim.cpp L390-L393](../sim/simx/cache_sim.cpp#L390).

## Next steps
- If needed, produce a second note with a cycle-by-cycle trace example for one scalar load and one vector segmented load, showing tag/mask evolution at each object boundary.
