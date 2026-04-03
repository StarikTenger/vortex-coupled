# Notes Directory

This directory contains technical notes documenting the Vortex architecture, SimX simulator design, and implementation details. Each note is self-contained and follows the [GUIDELINES.md](GUIDELINES.md).

## Architecture & System Overview

- [cache-hierarchy-and-memory-system.md](cache-hierarchy-and-memory-system.md) — Multi-level cache hierarchy (L1/L2/L3), cache types, connections, and memory system topology.
- [vortex-structure.dot](vortex-structure.dot), [vortex-structure.svg](vortex-structure.svg) — Visual representations of Vortex system hierarchy (clusters, sockets, cores, warps).
- [vortex-simx-class-interactions.md](vortex-simx-class-interactions.md) — Key class relationships and object graphs in SimX.

## Memory Path & Timing Analysis

- [lsu-tick-memory-hierarchy-path.md](lsu-tick-memory-hierarchy-path.md) — Detailed path of memory requests starting from `LsuUnit::tick()` through local memory, DCache, L2, L3, and DRAM. Includes queue topology, object ownership, and caveats.
- [timing-vs-functional-accesses.md](timing-vs-functional-accesses.md) — Separation between timing-aware cache ports (SimPorts) and functional memory access (emulator direct read/write).
- [icache-dcache-operation-and-timing.md](icache-dcache-operation-and-timing.md) — ICache and DCache operation, miss/hit logic, and timing characteristics.
- [trace-sw-single-warp-icache-dcache-path.md](trace-sw-single-warp-icache-dcache-path.md) — Concrete trace of a single warp through ICache and DCache, with cycle-by-cycle details.
- [memrsp-definition-and-usage.md](memrsp-definition-and-usage.md) — `MemRsp` structure, tag handling, and how responses propagate through memory system.

## Instruction & Execution

- [simx-instruction-representation-and-decode.md](simx-instruction-representation-and-decode.md) — Instruction trace representation, decoder entry points, and decode flow.
- [simx-emulator-class-role.md](simx-emulator-class-role.md) — Role of `Emulator` class: functional execution, warp state, ISA semantics, and separation from timing pipeline.

## Core & Pipeline

- [core-constructor-arguments.md](core-constructor-arguments.md) — Core constructor parameters and their roles.
- [gdb-simx-debugging.md](gdb-simx-debugging.md) — Debugging techniques for SimX using GDB, breakpoints, and inspection.

## Integration & Future Directions

- [gem5-vortex-extraction-first-plan.md](gem5-vortex-extraction-first-plan.md) — Plan for integrating Vortex SimX with gem5 simulator.
- [gem5-integration-filetree-findings.md](gem5-integration-filetree-findings.md) — File tree analysis for gem5 integration.
- [gem5-simt-core-boundaries.md](gem5-simt-core-boundaries.md) — SIMT core boundary considerations for gem5 integration.
- [trace-line-source-mapping.md](trace-line-source-mapping.md) — Mapping trace events back to source code lines.

## Work Notes & Reference

- [my_thoughts.md](my_thoughts.md) — Ad-hoc observations and working thoughts (less formal).
- [notebooklm-report.md](notebooklm-report.md) — Summary report or analysis output (reference material).
