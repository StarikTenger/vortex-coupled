# Trace line to source mapping (SimX)

## Scope

Map each provided runtime trace/debug line to the exact code location that emits it.

Input snippet analyzed:
- one instruction (`#1`) flowing from fetch to commit
- mix of `DEBUG` (`DP/DPH`) and `TRACE` (`DT`) outputs

---

## Findings

## Macro origin for prefixes

- `DEBUG ...` lines come from `DP`/`DPH` macros in [sim/simx/debug.h L31](../sim/simx/debug.h#L31)
- `TRACE ...` lines come from `DT` macro in [sim/simx/debug.h L49](../sim/simx/debug.h#L49)

## Per-line mapping

1. `DEBUG Fetch: code=0x317, cid=0, wid=0, tmask=1000, PC=0x80000004 (#1)`
- Emitted at [sim/simx/emulator.cpp L147](../sim/simx/emulator.cpp#L147)

2. `DEBUG Instr: AUIPC x6, 0x0, cid=0, wid=0, tmask=1000, PC=0x80000004 (#1)`
- Emitted at [sim/simx/execute.cpp L145](../sim/simx/execute.cpp#L145)
- `Instr` string formatting implemented at [sim/simx/decode.cpp L482](../sim/simx/decode.cpp#L482)

3. `DEBUG Dest Reg: x6={0x80000004, -, -, -}`
- Emitted at [sim/simx/execute.cpp L1497](../sim/simx/execute.cpp#L1497)

4. `TRACE         96: pipeline-schedule: ...`
- Emitted at [sim/simx/core.cpp L228](../sim/simx/core.cpp#L228)

5. `TRACE         97: icache-req: addr=0x80000004, tag=0x0, ...`
- Emitted at [sim/simx/core.cpp L265](../sim/simx/core.cpp#L265)

6. `TRACE        100: socket0-icaches-cache0-bank0-core-req: rw=0, addr=0x80000004, ...`
- Emitted at [sim/simx/cache_sim.cpp L395](../sim/simx/cache_sim.cpp#L395)

7. `TRACE        102: icache-rsp: addr=0x80000004, tag=0x0, ...`
- Emitted at [sim/simx/core.cpp L248](../sim/simx/core.cpp#L248)

8. `TRACE        103: pipeline-decode: ...`
- Emitted at [sim/simx/core.cpp L294](../sim/simx/core.cpp#L294)

9. `DEBUG Src0 Reg: x6={0x80000004, -, -, -}`
- Emitted from register read helper at [sim/simx/execute.cpp L72](../sim/simx/execute.cpp#L72)

10. `TRACE        104: pipeline-ibuffer: ...`
- Emitted at [sim/simx/core.cpp L373](../sim/simx/core.cpp#L373)

11. `TRACE        105: pipeline-operands: ...`
- Emitted at [sim/simx/opc_unit.cpp L60](../sim/simx/opc_unit.cpp#L60)
- (Vector variant exists at [sim/simx/vopc_unit.cpp L78](../sim/simx/vopc_unit.cpp#L78))

12. `TRACE        108: pipeline-dispatch: ...`
- Emitted at [sim/simx/dispatcher.cpp L100](../sim/simx/dispatcher.cpp#L100)

13. `TRACE        111: alu-unit: op=AUIPC, ...`
- Emitted at [sim/simx/func_unit.cpp L59](../sim/simx/func_unit.cpp#L59)

14. `TRACE        114: pipeline-commit: ...`
- Emitted at [sim/simx/core.cpp L412](../sim/simx/core.cpp#L412)

---

## Step-by-step explanation (what happens, push/pop state)

1. `DEBUG Fetch: ...`
- Code: [sim/simx/emulator.cpp L147](../sim/simx/emulator.cpp#L147)
- What happens:
	- `Emulator::fetch()` reads instruction bits from memory via `icache_read()`.
- Push/pop:
	- No pipeline queue/latch push or pop here.
	- Functional memory read only.

2. `DEBUG Instr: AUIPC ...`
- Code: [sim/simx/execute.cpp L145](../sim/simx/execute.cpp#L145)
- What happens:
	- `Emulator::execute()` starts instruction semantic execution for this trace.
- Push/pop:
	- No queue/latch push or pop at this log site.

3. `DEBUG Dest Reg: x6=...`
- Code: [sim/simx/execute.cpp L1497](../sim/simx/execute.cpp#L1497)
- What happens:
	- AUIPC result is written into warp register file (`x6`) for active lane(s).
- Push/pop:
	- No queue/latch push or pop.
	- Architectural register-file update only.

4. `TRACE ... pipeline-schedule: ...`
- Code: [sim/simx/core.cpp L228](../sim/simx/core.cpp#L228)
- What happens:
	- `Core::schedule()` receives trace from `emulator_.step()` and suspends warp.
- Push/pop:
	- Push `fetch_latch_` via `fetch_latch_.push(trace)`.
	- Push `pending_instrs_` via `pending_instrs_.push_back(trace)`.
	- No pop.

5. `TRACE ... icache-req: ...`
- Code: [sim/simx/core.cpp L265](../sim/simx/core.cpp#L265)
- What happens:
	- `Core::fetch()` issues instruction-cache timing request for `trace->PC`.
- Push/pop:
	- Push `icache_req_ports[0]` via `icache_req_ports.at(0).push(mem_req, 2)`.
	- Pop `fetch_latch_` via `fetch_latch_.pop()`.
	- Also allocates `pending_icache_` entry (tag→trace).

6. `TRACE ... socket0-icaches-cache0-bank0-core-req: ...`
- Code: [sim/simx/cache_sim.cpp L395](../sim/simx/cache_sim.cpp#L395)
- What happens:
	- L1 ICache bank accepts core request and converts it to internal bank request.
- Push/pop:
	- Push cache internal `pipe_req_` via `pipe_req_->push(bank_req)`.
	- Pop bank `core_req_port` via `core_req_port.pop()`.

7. `TRACE ... icache-rsp: ...`
- Code: [sim/simx/core.cpp L248](../sim/simx/core.cpp#L248)
- What happens:
	- `Core::fetch()` consumes icache response and finds original trace by tag.
- Push/pop:
	- Push `decode_latch_` via `decode_latch_.push(trace)`.
	- Pop `icache_rsp_ports[0]` via `icache_rsp_port.pop()`.
	- Release `pending_icache_` entry via `pending_icache_.release(tag)`.

8. `TRACE ... pipeline-decode: ...`
- Code: [sim/simx/core.cpp L294](../sim/simx/core.cpp#L294)
- What happens:
	- `Core::decode()` accepts trace into per-warp instruction buffer.
	- Warp is resumed if fetch stall condition is clear.
- Push/pop:
	- Push `ibuffers_[wid]` via `ibuffer.push(trace)`.
	- Pop `decode_latch_` via `decode_latch_.pop()`.

9. `DEBUG Src0 Reg: x6=...`
- Code: [sim/simx/execute.cpp L72](../sim/simx/execute.cpp#L72)
- What happens:
	- Source register value(s) are read from warp register file during operand fetch in emulator execution path.
- Push/pop:
	- No queue/latch push or pop.

10. `TRACE ... pipeline-ibuffer: ...`
- Code: [sim/simx/core.cpp L373](../sim/simx/core.cpp#L373)
- What happens:
	- `Core::issue()` selects ready instruction from per-warp ibuffer.
- Push/pop:
	- Push operand collector input `operands_[iw]->Input` via `push(trace, 1)`.
	- Pop selected per-warp `ibuffer` via `ibuffer.pop()`.

11. `TRACE ... pipeline-operands: ...`
- Code: [sim/simx/opc_unit.cpp L60](../sim/simx/opc_unit.cpp#L60)
- What happens:
	- Operand collector computes bank-conflict stall and schedules trace.
- Push/pop:
	- Push `OpcUnit::Output` via `Output.push(trace, 2 + stalls)`.
	- Pop `OpcUnit::Input` via `Input.pop()`.

12. `TRACE ... pipeline-dispatch: ...`
- Code: [sim/simx/dispatcher.cpp L100](../sim/simx/dispatcher.cpp#L100)
- What happens:
	- Dispatcher maps trace to block/lane batch and emits trace toward FU path.
- Push/pop:
	- Push `Dispatcher::Outputs[...]` via `output.push(new_trace, 1)`.
	- For non-partial case (this AUIPC case), pop `Dispatcher::Inputs[...]` via `input.pop()`.

13. `TRACE ... alu-unit: op=AUIPC, ...`
- Code: [sim/simx/func_unit.cpp L59](../sim/simx/func_unit.cpp#L59)
- What happens:
	- `AluUnit::tick()` classifies op and schedules completion with ALU delay.
- Push/pop:
	- Push `AluUnit::Outputs[iw]` via `output.push(trace, delay)` (`delay=2` for AUIPC).
	- Pop `AluUnit::Inputs[iw]` via `input.pop()`.

14. `TRACE ... pipeline-commit: ...`
- Code: [sim/simx/core.cpp L412](../sim/simx/core.cpp#L412)
- What happens:
	- `Core::commit()` retires completed trace, updates scoreboard/stats, deallocates trace.
- Push/pop:
	- Pop commit arbiter output `commit_arb->Outputs[0]` via `pop()` at [sim/simx/core.cpp L435](../sim/simx/core.cpp#L435).
	- Remove trace from `pending_instrs_` list.
	- No further stage push after commit for this instruction.

---

## Architectural takeaway

For this instruction, the log sequence is consistent with the expected stage progression:
- functional fetch/execute debug lines (`DEBUG`)
- then timing pipeline progression (`TRACE`) from schedule → icache req/rsp → decode → issue/operands/dispatch → ALU FU → commit.
