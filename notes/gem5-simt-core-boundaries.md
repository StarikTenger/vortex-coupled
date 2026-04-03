# Boundary Plan: Use gem5 memory/caches, extract only Vortex SIMT cores

## Target architecture
Use gem5 for:
- memory system
- caches/coherence/interconnect
- clocked event ownership

Use Vortex only for:
- SIMT core execution semantics (warp/thread control, divergence, pipeline behavior)

---

## What to extract from Vortex (keep)

### Core and pipeline logic
- [sim/simx/core.h](../sim/simx/core.h)
- [sim/simx/core.cpp L205](../sim/simx/core.cpp#L205)
- [sim/simx/decode.cpp](../sim/simx/decode.cpp)
- [sim/simx/execute.cpp](../sim/simx/execute.cpp)
- [sim/simx/func_unit.h](../sim/simx/func_unit.h)
- [sim/simx/func_unit.cpp](../sim/simx/func_unit.cpp)
- [sim/simx/dispatcher.h](../sim/simx/dispatcher.h)
- [sim/simx/dispatcher.cpp](../sim/simx/dispatcher.cpp)
- [sim/simx/operands.h](../sim/simx/operands.h)
- [sim/simx/operands.cpp](../sim/simx/operands.cpp)
- [sim/simx/scoreboard.h](../sim/simx/scoreboard.h)
- [sim/simx/instr.h](../sim/simx/instr.h)
- [sim/simx/instr_trace.h](../sim/simx/instr_trace.h)

### SIMT control and state
- [sim/simx/emulator.h](../sim/simx/emulator.h)
- [sim/simx/emulator.cpp](../sim/simx/emulator.cpp)
- includes `ipdom_stack`, `tmask`, `wspawn`, local/global barrier control paths.

### LSU-side shaping/coalescing (still useful even with gem5 caches)
- [sim/simx/mem_coalescer.h](../sim/simx/mem_coalescer.h)
- [sim/simx/mem_coalescer.cpp](../sim/simx/mem_coalescer.cpp)
- [sim/simx/types.h L907-L1035](../sim/simx/types.h#L907)
- [sim/simx/types.cpp](../sim/simx/types.cpp)

### Optional keep
- [sim/simx/local_mem.h](../sim/simx/local_mem.h)
- [sim/simx/local_mem.cpp](../sim/simx/local_mem.cpp)

Keep local/shared memory as an internal scratchpad unless you want to model it explicitly in gem5.

---

## What to drop/replace (gem5 will own this)

- [sim/simx/cache_sim.h](../sim/simx/cache_sim.h)
- [sim/simx/cache_sim.cpp](../sim/simx/cache_sim.cpp)
- [sim/simx/cache_cluster.h](../sim/simx/cache_cluster.h)
- [sim/simx/mem_sim.h](../sim/simx/mem_sim.h)
- [sim/simx/mem_sim.cpp](../sim/simx/mem_sim.cpp)
- [sim/simx/socket.h](../sim/simx/socket.h)
- [sim/simx/socket.cpp](../sim/simx/socket.cpp)
- [sim/simx/cluster.h](../sim/simx/cluster.h)
- [sim/simx/cluster.cpp](../sim/simx/cluster.cpp)
- [sim/simx/processor.h](../sim/simx/processor.h)
- [sim/simx/processor.cpp L28-L126](../sim/simx/processor.cpp#L28)

Reason: these files instantiate Vortex internal caches and DRAM loop (`SimPlatform::tick()`), which conflicts with gem5 owning memory hierarchy and event loop.

---

## Critical boundary findings (must-fix for true gem5 memory ownership)

## 1) Functional memory bypass exists today
Current code performs functional memory reads/writes directly in the emulator path:
- I-fetch data read from local MMU/RAM:
  - [sim/simx/emulator.cpp L145](../sim/simx/emulator.cpp#L145)
  - [sim/simx/emulator.cpp L284-L298](../sim/simx/emulator.cpp#L284)
- Load/store/AMO data read-write in execute path:
  - [sim/simx/execute.cpp L674](../sim/simx/execute.cpp#L674)
  - [sim/simx/execute.cpp L719](../sim/simx/execute.cpp#L719)
  - plus many AMO accesses [sim/simx/execute.cpp L766-L921](../sim/simx/execute.cpp#L766)

So memory ports currently model timing traffic, but values come from local RAM/MMU.

If you want gem5 caches/memory to be authoritative, this is the main seam to cut.

## 2) Core already exposes external request ports (good seam)
- I-cache request port exposed:
  - [sim/simx/core.cpp L35](../sim/simx/core.cpp#L35)
  - request issue at [sim/simx/core.cpp L263](../sim/simx/core.cpp#L263)
- D-cache request ports exposed:
  - [sim/simx/core.cpp L37](../sim/simx/core.cpp#L37)
  - adapter wiring at [sim/simx/core.cpp L132](../sim/simx/core.cpp#L132)

This is a natural attachment point to gem5 ports, but it is not enough alone because of functional bypass above.

## 3) Multi-core/barrier/perf coupling goes through Socket/Cluster/Processor
- global barrier call:
  - [sim/simx/emulator.cpp L264](../sim/simx/emulator.cpp#L264)
- memory perf CSR aggregation via socket/cluster/processor chain:
  - [sim/simx/emulator.cpp L508](../sim/simx/emulator.cpp#L508)

For extraction, replace this dependency with thin callback interfaces.

---

## Proposed hard boundaries for extraction

## Boundary A: SIMT Core Engine API
Create a new host-facing API around one core:
- `step()/tick()`
- `injectIcacheRsp(...)`
- `injectDcacheRsp(...)`
- `drainOutgoingReqs()`
- `isRunning()`

Backed by kept core/pipeline files.

## Boundary B: Memory Provider Interface
Replace direct `mmu_.read/write` usage from emulator/execute with abstract interface, e.g.:
- `readInstr(addr)`
- `load(addr,size)`
- `store(addr,size,data)`
- `amo(...)`

In gem5 mode, this interface must be fulfilled by gem5 request/response flow (not local RAM).

## Boundary C: Global Control Interface
Replace `Socket/Cluster/Processor` coupling with callbacks:
- `globalBarrier(bar_id,count,core_id)`
- `queryPerfCounters()` (optional)

This removes extraction blockers in emulator.

---

## Integration modes

## Mode 1: Fast path (timing-only memory integration)
- Keep current functional memory (`mmu_` path).
- Hook current I/D request ports to gem5 caches for timing/backpressure only.

Pros: quickest.
Cons: gem5 memory data path is not authoritative.

## Mode 2: Full path (recommended for your goal)
- Remove/disable functional bypass in emulator/execute.
- Make instruction/data values come from gem5 responses.
- Preserve SIMT scheduling/divergence semantics from Vortex.

Pros: true gem5 memory/cache ownership.
Cons: requires deeper refactor around fetch/load/store/AMO result staging.

---

## Minimal file cut list for your stated goal

## Keep (SIMT engine)
- core/emulator/decode/execute/dispatcher/func_unit/operands/scoreboard/instr/instr_trace
- mem_coalescer + relevant type adapters
- arch + dcrs

## Replace with gem5
- processor/cluster/socket/cache_sim/cache_cluster/mem_sim
- sim-common event ownership for top-level stepping

---

## Practical next implementation order

1. Decouple `Emulator` from `Socket/Cluster/Processor` callbacks.
2. Build a `SimtCore` wrapper from current `Core` + dependencies.
3. Attach existing I/D request ports to gem5 ports.
4. Remove `mmu_` functional bypass in fetch + LSU/AMO execute path.
5. Add response-driven register/memory completion flow.
6. Re-enable/validate barriers and SIMT control (`tmc/split/join/wspawn/bar`).

This sequence gives clean boundaries and avoids mixing two memory truths.
