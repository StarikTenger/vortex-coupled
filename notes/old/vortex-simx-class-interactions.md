# Vortex SimX class interactions and simulation model

## Scope
Explain how the main SimX classes interact, and determine whether the simulator is clocked or event-based.

## Files inspected
- [sim/simx/core.h](../sim/simx/core.h)
- [sim/simx/core.cpp](../sim/simx/core.cpp)
- [sim/simx/emulator.h](../sim/simx/emulator.h)
- [sim/simx/emulator.cpp](../sim/simx/emulator.cpp)
- [sim/simx/func_unit.cpp](../sim/simx/func_unit.cpp)
- [sim/simx/socket.cpp](../sim/simx/socket.cpp)
- [sim/simx/cluster.cpp](../sim/simx/cluster.cpp)
- [sim/simx/processor.cpp](../sim/simx/processor.cpp)
- [sim/common/simobject.h](../sim/common/simobject.h)

## Key classes and responsibilities

### `Core`
- Declared in [sim/simx/core.h L44](../sim/simx/core.h#L44).
- Owns pipeline state, scoreboard, dispatchers, function units, and memory-side adapters/coalescers.
- Per-cycle stage order is explicit in [sim/simx/core.cpp L205-L214](../sim/simx/core.cpp#L205):
  - `commit -> execute -> issue -> decode -> fetch -> schedule`
- Sends I-cache requests via core ports in [sim/simx/core.cpp L263](../sim/simx/core.cpp#L263).

### `Emulator`
- Declared in [sim/simx/emulator.h](../sim/simx/emulator.h).
- Implements warp-level SIMT architectural behavior (`warps_`, `tmask`, `ipdom_stack`, barriers, `wspawn`) in [sim/simx/emulator.h L47-L58](../sim/simx/emulator.h#L47).
- Produces one instruction trace at a time through [sim/simx/emulator.cpp L152](../sim/simx/emulator.cpp#L152) (`step()`).
- Handles warp control semantics (including global barrier callback to socket/cluster) in [sim/simx/emulator.cpp L250-L277](../sim/simx/emulator.cpp#L250).

### `LsuUnit` and `SfuUnit`
- `LsuUnit` converts trace memory metadata into LSU request batches and tracks outstanding read completions in [sim/simx/func_unit.cpp L175-L338](../sim/simx/func_unit.cpp#L175).
- `SfuUnit` applies SIMT control op effects (`WSPAWN`, `BAR`, etc.) and resumes stalled warps when appropriate in [sim/simx/func_unit.cpp L346-L407](../sim/simx/func_unit.cpp#L346).

### `Socket` and `Cluster`
- `Socket` builds per-socket L1 icache/dcache complexes and wires each `Core` to them in [sim/simx/socket.cpp L19-L113](../sim/simx/socket.cpp#L19).
- `Cluster` builds sockets and L2 cache, and handles cross-core barrier release within cluster scope in [sim/simx/cluster.cpp L18-L157](../sim/simx/cluster.cpp#L18).

### `ProcessorImpl`
- Top-level assembly and run loop owner.
- Instantiates memory sim, L3 cache, clusters, and interconnect wiring in [sim/simx/processor.cpp L18-L74](../sim/simx/processor.cpp#L18).
- Global simulation advance loop is in [sim/simx/processor.cpp L119-L136](../sim/simx/processor.cpp#L119), calling [sim/simx/processor.cpp L126](../sim/simx/processor.cpp#L126) each iteration.

### `SimPlatform`
- Simulation kernel defined in [sim/common/simobject.h L377](../sim/common/simobject.h#L377).
- `tick()` executes each object’s `do_tick()`, processes immediate events, then registered events in [sim/common/simobject.h L426-L444](../sim/common/simobject.h#L426).
- Immediate (delta-cycle) event handling: [sim/common/simobject.h L488](../sim/common/simobject.h#L488).
- Cycle-advanced registered events: [sim/common/simobject.h L505](../sim/common/simobject.h#L505).

## How they interact (data/control flow)
1. `ProcessorImpl::run()` drives global progression by repeated platform ticks.
2. Each tick, `Core::tick()` advances its pipeline stages in fixed stage order.
3. `Core::schedule()` pulls one instruction trace from `Emulator::step()` and stalls that warp until decode/commit progression allows resume.
4. Functional units consume traces:
   - `LsuUnit` issues memory ops and waits on response tags.
   - `SfuUnit` applies SIMT control (`tmc/split/join/wspawn/bar`) and manages warp release timing.
5. `Socket`/`Cluster` provide cache/memory hierarchy plumbing and barrier fan-in/fan-out.

## SIMT divergence/reconvergence path
- Control instructions are decoded/executed in `execute.cpp` `WctlType` cases:
  - [sim/simx/execute.cpp L1335](../sim/simx/execute.cpp#L1335) (`TMC`)
  - [sim/simx/execute.cpp L1342](../sim/simx/execute.cpp#L1342) (`WSPAWN`)
  - [sim/simx/execute.cpp L1346](../sim/simx/execute.cpp#L1346) (`SPLIT`)
  - [sim/simx/execute.cpp L1381](../sim/simx/execute.cpp#L1381) (`JOIN`)
  - [sim/simx/execute.cpp L1399](../sim/simx/execute.cpp#L1399) (`BAR`)
- `SPLIT/JOIN` use `warp.ipdom_stack` for reconvergence bookkeeping in [sim/simx/execute.cpp L1348-L1395](../sim/simx/execute.cpp#L1348).

## Is it clocked or event-based?
Short answer: **both**, with a cycle-first execution model.

- **Clocked outer model:**
  - `ProcessorImpl::run()` repeatedly calls platform tick (one global cycle step per iteration) in [sim/simx/processor.cpp L119-L136](../sim/simx/processor.cpp#L119).
  - `SimPlatform::fire_registered_events()` advances `cycles_` in [sim/common/simobject.h L505-L521](../sim/common/simobject.h#L505).
- **Event-based transport inside each cycle:**
  - Ports and callbacks schedule delayed packet transfers/events (`push(..., delay)`, scheduled events) via [sim/common/simobject.h L401-L419](../sim/common/simobject.h#L401).
  - Immediate delta events are resolved during a cycle in [sim/common/simobject.h L488-L503](../sim/common/simobject.h#L488).

So SimX is best described as a **cycle-stepped simulator with event-queued communication**.

## Practical implication for notes from gem5 integration work
- If integrating with gem5, you must account for both aspects:
  - cycle ownership (`tick` progression), and
  - delayed port/event semantics (intra/inter-cycle message timing).
