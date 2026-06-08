# gem5–Vortex integration plan (extraction-first)

## Scope

Define a practical integration strategy to extract Vortex SIMT core logic first, then connect it to gem5 memory/caches.

Primary target:
- Keep Vortex SIMT execution model.
- Make gem5 the long-term owner of memory hierarchy and timing.

---

## Findings

- Vortex core execution boundary is centered on `Core` + `Emulator` + functional units:
  - [sim/simx/core.cpp](../sim/simx/core.cpp)
  - [sim/simx/emulator.cpp](../sim/simx/emulator.cpp)
  - [sim/simx/func_unit.cpp](../sim/simx/func_unit.cpp)
- Timing requests are already port-based and externally visible from core/LSU paths.
- Current design still has functional memory bypass (`mmu_.read/write`) in emulator/execute path:
  - [sim/simx/emulator.cpp](../sim/simx/emulator.cpp)
  - [sim/simx/execute.cpp](../sim/simx/execute.cpp)
- Timing responses are metadata-only (`MemRsp`, `LsuRsp`), not value payload transport:
  - [sim/simx/types.h](../sim/simx/types.h)

Architectural takeaway: today the model separates value correctness (functional path) from timing pressure (cache path). Full gem5 ownership requires removing this dual-memory truth.

---

## Boundaries

## Keep for extraction

- SIMT/pipeline engine:
  - [sim/simx/core.h](../sim/simx/core.h)
  - [sim/simx/core.cpp](../sim/simx/core.cpp)
  - [sim/simx/emulator.h](../sim/simx/emulator.h)
  - [sim/simx/emulator.cpp](../sim/simx/emulator.cpp)
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

- LSU request shaping/coalescing:
  - [sim/simx/mem_coalescer.h](../sim/simx/mem_coalescer.h)
  - [sim/simx/mem_coalescer.cpp](../sim/simx/mem_coalescer.cpp)

## Replace/drop for gem5-owned memory system

- Internal Vortex hierarchy owners:
  - [sim/simx/cache_sim.h](../sim/simx/cache_sim.h)
  - [sim/simx/cache_sim.cpp](../sim/simx/cache_sim.cpp)
  - [sim/simx/cache_cluster.h](../sim/simx/cache_cluster.h)
  - [sim/simx/socket.h](../sim/simx/socket.h)
  - [sim/simx/socket.cpp](../sim/simx/socket.cpp)
  - [sim/simx/cluster.h](../sim/simx/cluster.h)
  - [sim/simx/cluster.cpp](../sim/simx/cluster.cpp)z
  - [sim/simx/processor.h](../sim/simx/processor.h)
  - [sim/simx/processor.cpp](../sim/simx/processor.cpp)
  - [sim/simx/mem_sim.h](../sim/simx/mem_sim.h)
  - [sim/simx/mem_sim.cpp](../sim/simx/mem_sim.cpp)

---

## Integration strategy

## Phase 1 (bring-up): extracted one-core engine

Deliverable:
- A standalone `SimtCore` wrapper around Vortex core engine with thin host API.

Suggested host API:
- `tick()`
- `running()`
- `drainIcacheReqs()`
- `drainDcacheReqs()`
- `injectIcacheRsp(...)`
- `injectDcacheRsp(...)`

Goal:
- Run one-core outside full Vortex processor/socket/cluster stack.

## Phase 2 (short-lived): timing hookup to gem5

- Connect request/response queues to gem5 ports.
- Keep current functional memory access temporarily for faster smoke test.

Goal:
- Verify scheduling/forward progress under gem5-driven timing/backpressure.

## Phase 3 (target): gem5-authoritative memory values

- Remove functional bypass in fetch/load/store/AMO paths.
- Make instruction/data completion dependent on gem5 response contract.

Goal:
- Single source of memory truth = gem5 hierarchy.

---

## First steps (actionable)

1. Build extraction target containing only kept SIMT files.
2. Add callback interface to break `Socket/Cluster/Processor` coupling (barrier + optional perf).
3. Add minimal queue adapters for I/D requests/responses.
4. Stand up mock memory harness and run deterministic smoke tests.
5. Add gem5 device wrapper with equivalent queue API.

Acceptance for first milestone:
- extracted core compiles, runs, and drains requests for a simple kernel.

---

## Hidden couplings to resolve early

- Global barrier and control paths that currently walk socket/cluster links.
- Perf CSR aggregation that depends on removed hierarchy classes.
- Dual-memory semantics (functional bypass + timing model in parallel).

---

## Recommendations

- Start with one core, one warp-enabled micro-test to avoid concurrency noise.
- Keep trace-based regression checks at each phase boundary.
- Treat Phase 2 as temporary; schedule Phase 3 immediately after first successful gem5 timing integration.

---

## Next steps

- Implement `SimtCore` wrapper skeleton and compile target.
- Enumerate exact symbols requiring callback abstraction from `Emulator` and `Core`.
- Create first smoke test (single core, direct memory responder).
