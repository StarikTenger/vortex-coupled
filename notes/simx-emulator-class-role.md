# Role of `Emulator` in SimX

This note explains what the `Emulator` class is responsible for in SimX, where it fits in the core pipeline, and what state and behaviors it owns.

## Short answer

`Emulator` is the **functional execution engine per core**. It owns warp architectural state, performs ISA-level fetch/decode/execute, and emits `instr_trace_t` records that the core pipeline consumes for timing simulation.

- Interface definition: [sim/simx/emulator.h](../sim/simx/emulator.h)
- Main control flow: [sim/simx/emulator.cpp](../sim/simx/emulator.cpp)
- Decoder implementation: [sim/simx/decode.cpp](../sim/simx/decode.cpp)
- ISA execution implementation: [sim/simx/execute.cpp](../sim/simx/execute.cpp)
- Consumer in pipeline: [sim/simx/core.cpp](../sim/simx/core.cpp)

---

## Where it sits in the SimX design

Inside each `Core`, `emulator_` is the producer for the front of the pipeline.

- `Core::schedule()` calls `emulator_.step()` each cycle.
- If `step()` returns a trace, the core pushes it into fetch/decode latches and later issue/execute/commit stages.

So the separation is:

- `Emulator`: **what instruction does** (functional semantics)
- `Core`/ports/caches/latches: **when instruction advances** (timing/structure/hazards)

See the `Core` member and stage flow in [sim/simx/core.h](../sim/simx/core.h) and [sim/simx/core.cpp](../sim/simx/core.cpp).

---

## Core responsibilities of `Emulator`

## 1) Owns per-warp architectural state

`Emulator` owns `warps_` (`warp_t`) with:

- integer register file (`ireg_file`)
- floating register file (`freg_file`)
- per-warp instruction micro-buffer (`ibuffer`)
- divergence/reconvergence stack (`ipdom_stack`)
- thread mask (`tmask`)
- current `PC`
- floating-point CSR (`fcsr`)
- per-warp instruction UUID counter

Definition: [sim/simx/emulator.h](../sim/simx/emulator.h)

This is effectively the architectural machine state for functional execution.

## 2) Schedules runnable warps

`step()` selects one active and non-stalled warp, fetches/decodes if needed, executes one instruction, and returns `instr_trace_t*`.

Key behavior:

- tracks `active_warps_` and `stalled_warps_`
- supports suspend/resume hooks used by the core pipeline
- applies delayed warp-spawn activation logic (`wspawn_`)

Implementation: [sim/simx/emulator.cpp](../sim/simx/emulator.cpp)

## 3) Performs instruction fetch/decode

For a warp with empty micro-buffer:

- fetches raw 32-bit instruction (`fetch()` / `icache_read()`)
- decodes binary encoding into `Instr` objects (`decode()` in decode.cpp)
- pushes decoded micro-ops into warp `ibuffer`

Decoder maps opcode/funct fields to:

- FU class (`FUType`)
- operation enum (`OpType`)
- immediate arguments
- source/destination registers

Decode logic: [sim/simx/decode.cpp](../sim/simx/decode.cpp)

## 4) Executes ISA semantics and generates traces

`execute()` in [sim/simx/execute.cpp](../sim/simx/execute.cpp):

- reads source operand values from reg files for active lanes (`tmask`)
- applies opcode semantics (ALU/branch/LSU/FPU/SFU/vector, etc.)
- updates next PC/thread mask/divergence state
- prepares destination values/side effects
- creates and fills `instr_trace_t` with metadata (`cid`, `wid`, `PC`, regs, `fu_type`, `op_type`, etc.)

That trace is the handoff object to timed pipeline stages.

## 5) Provides memory-side functional accessors

`Emulator` exposes functional data/instruction memory accesses:

- `icache_read()` for instruction fetch payload
- `dcache_read()` / `dcache_write()` for loads/stores
- AMO reservation/check helpers

It routes accesses through MMU and local/shared memory rules as needed.

Implementation: [sim/simx/emulator.cpp](../sim/simx/emulator.cpp)

## 6) Implements CSR-visible architectural behavior

`get_csr()` / `set_csr()` implement architectural and performance CSR behavior seen by executed instructions, including:

- thread/warp/core IDs
- active masks
- floating-point CSRs (`fflags`, `frm`, `fcsr`)
- cycle/instruction counters and selected perf counters
- SATP plumbing when VM is enabled

Implementation: [sim/simx/emulator.cpp](../sim/simx/emulator.cpp)

## 7) Coordinates control operations

`Emulator` handles core control-style operations at functional level:

- barriers (`barrier()` local/global behavior)
- warp spawn (`wspawn()`)
- trap-like test hooks (`trigger_ecall()`, `trigger_ebreak()`)
- stdout MMIO write aggregation (`writeToStdOut()` / `cout_flush()`)

Implementation: [sim/simx/emulator.cpp](../sim/simx/emulator.cpp)

---

## What `Emulator` does *not* own

`Emulator` does not model detailed timing structures itself:

- no cache pipeline timing arbitration
- no issue scoreboard policy in core front-end
- no functional unit latency network scheduling

Those are modeled by `Core`, latches, dispatchers, ports, and units.

So `Emulator` is the functional truth source; `Core` is the timing/throughput model.

---

## End-to-end per-cycle interaction

1. `Core::schedule()` calls `emulator_.step()`.
2. `step()` returns one `instr_trace_t*` for a runnable warp.
3. Core temporarily suspends that warp until decode capacity allows progress.
4. Core fetch/decode/issue pipeline advances the trace with cache/scoreboard timing.
5. Core resumes the warp when decode accepts it.

This handshake keeps ISA correctness in `Emulator` while preserving timing realism in the core pipeline.

---

## Practical mental model

If you are debugging SimX:

- Use `Emulator` to answer: “What should this instruction do architecturally?”
- Use `Core` to answer: “Why did it take this many cycles / where did it stall?”

That split is the key design role of `Emulator`.
