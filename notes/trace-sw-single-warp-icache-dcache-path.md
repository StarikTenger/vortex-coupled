# Step-by-step explanation of SW trace (single warp, icache + dcache write path)

## Scope

Explain the provided trace chronologically for one warp (`wid=0`, UUID `#33`), including stage meaning and key push/pop transitions.

The given trace is a part of `run.log` filtered by instruction UUID.

---

## Trace (as provided)

```text
DEBUG Fetch: code=0x812423, cid=0, wid=0, tmask=1111, PC=0x8000019c (#33)
DEBUG Instr: SW x2, x8, 0x8, cid=0, wid=0, tmask=1111, PC=0x8000019c (#33)
TRACE        456: pipeline-schedule: cid=0, wid=0, tmask=1111, PC=0x8000019c, wb=0, rs0=x2, rs1=x8, ex=LSU (#33)
TRACE        457: icache-req: addr=0x8000019c, tag=0x0, cid=0, wid=0, tmask=1111, PC=0x8000019c, wb=0, rs0=x2, rs1=x8, ex=LSU (#33)
TRACE        460: socket0-icaches-cache0-bank0-core-req: rw=0, addr=0x8000019c, type=Global, tag=0x0, cid=0 (#33)
TRACE        461: socket0-icaches-cache0-bank0-core-rsp: tag=0x0, cid=0 (#33)
TRACE        462: socket0-icaches-cache0-core-rsp: tag=0x0, cid=0 (#33)
TRACE        462: icache-rsp: addr=0x8000019c, tag=0x0, cid=0, wid=0, tmask=1111, PC=0x8000019c, wb=0, rs0=x2, rs1=x8, ex=LSU (#33)
TRACE        463: pipeline-decode: cid=0, wid=0, tmask=1111, PC=0x8000019c, wb=0, rs0=x2, rs1=x8, ex=LSU (#33)
TRACE        464: pipeline-ibuffer: cid=0, wid=0, tmask=1111, PC=0x8000019c, wb=0, rs0=x2, rs1=x8, ex=LSU (#33)
TRACE        465: pipeline-operands: cid=0, wid=0, tmask=1111, PC=0x8000019c, wb=0, rs0=x2, rs1=x8, ex=LSU (#33)
TRACE        468: pipeline-dispatch: cid=0, wid=0, tmask=1111, PC=0x8000019c, wb=0, rs0=x2, rs1=x8, ex=LSU (#33)
TRACE        471: lsu-unit-mem-req: rw=1, mask=1111, addr={0xfffefff8, 0xfffedff8, 0xfffebff8, 0xfffe9ff8}, tag=0x0, cid=0 (#33)
TRACE        473: pipeline-commit: cid=0, wid=0, tmask=1111, PC=0x8000019c, wb=0, rs0=x2, rs1=x8, ex=LSU (#33)
TRACE        476: socket0-dcaches-cache0-bank0-core-req: rw=1, addr=0xfffefff0, type=Global, tag=0x0, cid=0 (#33)
TRACE        477: socket0-dcaches-cache0-bank0-core-req: rw=1, addr=0xfffedff0, type=Global, tag=0x0, cid=0 (#33)
TRACE        477: socket0-dcaches-cache0-bank0-writethrough: rw=1, addr=0xfffeffc0, type=Global, tag=0x0, cid=0 (#33)
TRACE        478: socket0-dcaches-cache0-bank0-core-req: rw=1, addr=0xfffebff0, type=Global, tag=0x0, cid=0 (#33)
TRACE        478: socket0-dcaches-cache0-bank0-writethrough: rw=1, addr=0xfffedfc0, type=Global, tag=0x0, cid=0 (#33)
TRACE        479: socket0-dcaches-cache0-bank0-core-req: rw=1, addr=0xfffe9ff0, type=Global, tag=0x0, cid=0 (#33)
TRACE        479: socket0-dcaches-cache0-bank0-writethrough: rw=1, addr=0xfffebfc0, type=Global, tag=0x0, cid=0 (#33)
TRACE        480: socket0-dcaches-cache0-bank0-writethrough: rw=1, addr=0xfffe9fc0, type=Global, tag=0x0, cid=0 (#33)
TRACE        481: dram-mem-req1: rw=1, addr=0xfffeffc0, type=Global, tag=0x1, cid=0 (#33)
TRACE        482: dram-mem-req1: rw=1, addr=0xfffedfc0, type=Global, tag=0x1, cid=0 (#33)
TRACE        483: dram-mem-req1: rw=1, addr=0xfffebfc0, type=Global, tag=0x1, cid=0 (#33)
TRACE        484: dram-mem-req1: rw=1, addr=0xfffe9fc0, type=Global, tag=0x1, cid=0 (#33)
```

---

## Parameter legend (quick)

- `cid`: core id
- `wid`: warp id
- `tmask`: active lanes
- `wb`: writeback-to-register flag
- `ex=LSU`: instruction routed to load/store unit
- `tag`: request/response correlation id
- `rw`: `0` read, `1` write
- `(#33)`: dynamic instruction UUID

---

## Step-by-step

1. Functional fetch/decode of instruction
- `DEBUG Fetch` and `DEBUG Instr` lines are emitted by emulator functional path:
  - [sim/simx/emulator.cpp](../sim/simx/emulator.cpp#L147)
  - [sim/simx/execute.cpp](../sim/simx/execute.cpp#L145)
- Meaning: instruction bits `0x812423` decode to `SW x2, x8, 0x8`.
- Buffer movement: no core pipeline push/pop yet.

2. Schedule into pipeline
- `pipeline-schedule` from [sim/simx/core.cpp](../sim/simx/core.cpp#L228)
- Push:
  - `fetch_latch_.push(trace)`
  - `pending_instrs_.push_back(trace)`
- Warp is suspended until decode admission.

3. ICache request issued
- `icache-req` from [sim/simx/core.cpp](../sim/simx/core.cpp#L265)
- Push:
  - `icache_req_ports[0].push(mem_req, 2)`
  - `pending_icache_.allocate(trace)` (tag map)
- Pop:
  - `fetch_latch_.pop()`

4. ICache bank accepts request
- `...bank0-core-req` from [sim/simx/cache_sim.cpp](../sim/simx/cache_sim.cpp#L395)
- Push:
  - cache internal `pipe_req_`
- Pop:
  - bank `core_req_port`

5. ICache responds back up
- `...bank0-core-rsp` / `...cache0-core-rsp` are cache-side response logs from [sim/simx/cache_sim.cpp](../sim/simx/cache_sim.cpp#L459)
- Then core consumes it as `icache-rsp` in [sim/simx/core.cpp](../sim/simx/core.cpp#L248)
- Push:
  - `decode_latch_.push(trace)`
- Pop:
  - `icache_rsp_ports[0].pop()`
  - `pending_icache_.release(tag)`

6. Decode stage inserts into ibuffer
- `pipeline-decode` from [sim/simx/core.cpp](../sim/simx/core.cpp#L294)
- Push:
  - `ibuffers_[wid].push(trace)`
- Pop:
  - `decode_latch_.pop()`

7. Issue picks from ibuffer
- `pipeline-ibuffer` from [sim/simx/core.cpp](../sim/simx/core.cpp#L373)
- Push:
  - `operands_[iw]->Input.push(trace, 1)`
- Pop:
  - `ibuffer.pop()`

8. Operand collector stage
- `pipeline-operands` from [sim/simx/opc_unit.cpp](../sim/simx/opc_unit.cpp#L60)
- Push:
  - `OpcUnit::Output.push(trace, 2 + stalls)`
- Pop:
  - `OpcUnit::Input.pop()`

9. Dispatch stage toward LSU
- `pipeline-dispatch` from [sim/simx/dispatcher.cpp](../sim/simx/dispatcher.cpp#L100)
- Push:
  - dispatcher output (toward FU input)
- Pop:
  - dispatcher input (non-partial case)

10. LSU emits memory request batch for store
- `lsu-unit-mem-req` from [sim/simx/func_unit.cpp](../sim/simx/func_unit.cpp#L318)
- Meaning:
  - store request (`rw=1`) for all active lanes (`mask=1111`)
  - lane addresses are per-thread effective addresses
- Push:
  - `lmem_switch_[block].ReqIn.push(lsu_req)`
- Pop:
  - FU input trace is popped once this request packetization step completes.

11. Commit retires instruction before memory write reaches DRAM
- `pipeline-commit` from [sim/simx/core.cpp](../sim/simx/core.cpp#L412)
- Because `wb=0` for store, no destination register writeback is required.
- Push/pop:
  - pop commit arbiter output
  - remove trace from `pending_instrs_`
  - deallocate trace

12. DCache receives store requests after commit
- `socket0-dcaches-cache0-bank0-core-req` lines from cache bank request handling path ([sim/simx/cache_sim.cpp](../sim/simx/cache_sim.cpp#L395))
- Note the addresses appear aligned (`...fff0`) at bank/core interface.

13. DCache writethrough forwards to lower memory
- `...bank0-writethrough` from [sim/simx/cache_sim.cpp](../sim/simx/cache_sim.cpp#L449)
- Meaning:
  - write-through mode forwards store to next level instead of waiting for dirty eviction.

14. DRAM backend enqueues memory writes
- `dram-mem-req1` from [sim/simx/mem_sim.cpp](../sim/simx/mem_sim.cpp#L98)
- Meaning:
  - memory system accepted write requests on DRAM port 1.
  - store writes typically do not generate immediate data responses to core in this path.

---

## Key interpretation

- This trace shows normal behavior for a store (`SW`):
  - core-side instruction retirement (`pipeline-commit`) occurs once LSU has accepted/issued store request,
  - actual cache-to-DRAM propagation continues asynchronously afterward.
- So it is expected that `pipeline-commit` appears before final `dcache writethrough` and `dram-mem-req` lines.
