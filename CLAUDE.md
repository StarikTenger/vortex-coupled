# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Vortex is a full-stack open-source RISC-V GPGPU (RV32IMAF / RV64IMAFD). The repo contains
RTL hardware sources, host runtime/driver software, GPU kernel software, multiple simulator
backends, and a regression/benchmark test suite. Most day-to-day iteration on this branch
happens in the **SimX** C++ cycle-level simulator (`sim/simx`).

This particular checkout (branch `coupling`) is mid-refactor of the SimX core pipeline,
specifically separating the **execute** and **commit** stages (computing values in execute,
writing them back to registers in commit) so that the timing model and the functional
emulator stay consistent. See `notes/` for working notes — `notes/my_thoughts.md` documents
a longer-term goal of extracting the Vortex SIMT core for integration with gem5, which is
the motivation behind much of this restructuring.

## Build

The build is driven by an autoconf-style `configure` script that generates a `build/`
directory (already present in this checkout, configured for XLEN=32, tooldir `~/tools`).

```sh
# one-time setup if rebuilding from scratch:
mkdir build && cd build
../configure --xlen=32 --tooldir=$HOME/tools     # or --xlen=64

# always source this before building/running (per new shell):
source ./ci/toolchain_env.sh

# build everything from the build/ directory:
make -s
```

Re-run `../configure` (no args) whenever you add new folders or edit Makefiles in the
source tree, to propagate changes into `build/`.

Targeted builds (run from `build/`):
- `make -C sim` — simulators (incl. SimX, `libsimx.so`)
- `make -C runtime` — host runtime drivers (`libvortex-<driver>.so`)
- `make -C kernel` — GPU kernel software / `libvortex.a`
- `make -C tests` — regression/benchmark tests
- `make clean-build` / `make clean` — clean build artifacts (clean also cleans third_party)

## Running and testing

Everything is driven through `ci/blackbox.sh` (gets copied with resolved env vars into
`build/`, so run it **from `build/`**):

```sh
./ci/blackbox.sh --help
./ci/blackbox.sh --driver=simx --app=sgemm --args="-n10"
./ci/blackbox.sh --cores=2 --driver=simx --app=vecadd
./ci/blackbox.sh --driver=simx --app=demo --rebuild=1   # force rebuild if HW config changed
```

Key `blackbox.sh` flags: `--clusters`, `--cores`, `--warps`, `--threads`, `--l2cache`,
`--l3cache`, `--driver` (`simx`|`rtlsim`|`opae`|`xrt`|`fpga`), `--debug=<level>`, `--perf`,
`--app`, `--args`, `--rebuild`, `--log`.

Run the full regression/OpenCL suites (from repo root):
```sh
make -C tests/regression run-simx
make -C tests/regression run-rtlsim
make -C tests/opencl run-simx
```

Run/build a single regression test directly:
```sh
make -C tests/regression/<test-name>             # build kernel + host binary
./ci/blackbox.sh --driver=simx --app=<test-name> --debug
```

`util/run-tests.sh` (run from `build/`) batch-runs the apps listed in its `apps=(...)` array
through `blackbox.sh --cores=4 --debug=0`, logging each to `blackbox_logs/<app>.log` and
printing PASS/CRASH/FAIL based on exit status.

### Creating a new regression test
Copy a similar folder under `tests/regression/` (each has `kernel.cpp` — GPU kernel code,
`main.cpp` — host code, `Makefile`). Then `../configure`, `make -C tests/regression/<name>`,
and run it via `blackbox.sh`.

### Debugging
- `--debug=<level>` on `blackbox.sh` produces a `run.log` trace (decoded instructions,
  register state, pipeline state); higher levels are more verbose.
- `./hw/scripts/trace_csv.py -t<simx|rtlsim> run.log -o trace.csv` sanitizes a trace into a
  UUID-sorted CSV for diffing functional vs. RTL execution (`diff trace_simx.csv trace_rtlsim.csv`).
- `util/compare-traces.sh <correct.log> <bad.log>` greps both logs for `TRACE` lines and opens
  them in `vimdiff`.
- `util/filter_trace.py` filters a debug trace down to a single warp's `Instr ... wid=N` blocks
  plus register-state dumps (currently hardcoded to `wid=3`; pipe a `run.log` through it).
- For RTL waveform debugging, `--driver=rtlsim`/`opaesim` generates `trace.vcd` (viewable in
  GTKWave); see `docs/debugging.md` for `TRACING_ALL`/scope-analyzer details.

## Architecture (SimX) — `sim/simx/`

SimX is a cycle-stepped C++ simulator with event-queued intra-cycle communication
(`SimPlatform` in `sim/common/simobject.h` ticks every object each cycle, then resolves
immediate/delta and registered/delayed events).

Top-down object hierarchy: `ProcessorImpl` → `Cluster`(s, share L2) → `Socket`(s, share L1
icache/dcache) → `Core`(s). Each `Core` has its own `Emulator`.

**The crucial split to keep in mind everywhere in this codebase:**
- **`Emulator`** (`emulator.cpp`/`.h`, `decode.cpp`, `execute.cpp`) is the *functional* engine:
  it owns architectural warp state (register files, `ibuffer`, `ipdom_stack`, `tmask`, `PC`,
  CSRs, ...), performs ISA-level fetch/decode/execute, and emits `instr_trace_t` records.
  It does **not** model detailed timing (no cache arbitration, no scoreboard policy, no FU
  latency scheduling).
- **`Core`** (`core.cpp`/`.h`) is the *timing* model: it owns the pipeline stages, scoreboard,
  dispatchers, function units, and memory-side adapters, and drives `instr_trace_t`s through
  them. Per-cycle stage order (note the reverse/pipelined call order) is
  `commit -> execute -> issue -> decode -> fetch -> schedule`, with `schedule` pulling the
  next trace from `Emulator::step()`.

Other key pieces under `sim/simx/`:
- `func_unit.cpp/.h` — functional units: `LsuUnit` (load/store, outstanding-tag tracking),
  `SfuUnit` (SIMT control ops: `TMC`/`WSPAWN`/`SPLIT`/`JOIN`/`BAR`, CSR ops), ALU/FPU/tensor units.
- `cache_sim.cpp/.h`, `cache_cluster.h`, `local_mem.cpp` — cache hierarchy simulation
  (L1 per-socket, L2 per-cluster, L3 processor-wide; see `docs/cache_subsystem.md`).
- `mem_sim.cpp/.h`, `mem_coalescer.cpp` — memory system / request coalescing.
- `dispatcher.cpp`, `opc_unit.cpp`, `operands.cpp`, `scoreboard.h`, `ibuffer.h` — issue-stage
  structures (operand collection, scoreboard hazard tracking, per-warp instruction buffers).
- `vec_unit.cpp`, `vopc_unit.cpp`, `voperands.cpp`, `tensor_unit.cpp` — vector/tensor extensions.
- `processor.cpp/.h`, `processor_impl.h` — top-level assembly and the global run loop
  (`ProcessorImpl::run` repeatedly ticks `SimPlatform` until clusters report completion).

SIMT divergence/reconvergence (`SPLIT`/`JOIN`/`TMC`/`WSPAWN`/`BAR`) is implemented in
`execute.cpp` and uses `warp.ipdom_stack` for control-flow reconvergence bookkeeping.

`notes/` contains a substantial set of architecture deep-dives (cache hierarchy, memory
request paths, instruction trace/decode flow, class interaction maps, gem5-integration
analysis) written following `notes/GUIDELINES.md` — check there before re-deriving things
like the LSU memory path or trace structure from scratch. Update `notes/README.md` when
adding a new note.

## Code style (C++)

Defined in `docs/coding_guidelines_cpp.md` and `.clang-format` (LLVM-based, 2-space indent,
no tabs, attached braces, no column limit):
- 2-space indentation, **no tabs**.
- K&R brace style: opening brace on same line, closing brace aligned with declaration start.
- One space after keywords (`if`, `for`, `while`, `switch`); no space before call parens;
  spaces around binary operators.
- Multi-line constructor initializer lists: one initializer per line, aligned under the colon.
- `//` for single-line comments; Doxygen-style (`///`, `@param`, `@return`) for public APIs.
- Preprocessor directives shifted left while preserving the indentation of the code they guard.

## Directory map (top-level)

- `hw/` — RTL sources (`rtl/core`, `rtl/cache`, `rtl/mem`, `rtl/fpu`, ...), synthesis scripts
  (`syn/`), unit tests (`unittest/`).
- `runtime/` — host runtime APIs; `stub` (driver-loading shim, `dlopen`s `libvortex-<driver>.so`
  based on `VORTEX_DRIVER` env var), plus per-backend drivers (`simx`, `rtlsim`, `opae`, `xrt`).
- `kernel/` — GPU-side kernel runtime/headers/linker scripts compiled against the RISC-V
  Vortex toolchain.
- `sim/` — simulator backends: `simx` (this branch's focus), `rtlsim`, `opaesim`, `xrtsim`,
  `common` (shared `SimPlatform`/`SimObject` event-sim kernel).
- `tests/` — `regression` (per-feature kernel+host test dirs), `opencl` (benchmarks), `kernel`,
  `riscv` (ISA conformance), `unittest`.
- `ci/` — `blackbox.sh` test runner, toolchain install/env scripts, `trace_csv.py`.
- `util/` — ad hoc developer scripts for this branch (`run-tests.sh`, `compare-traces.sh`,
  `filter_trace.py`).
- `notes/` — architecture/working notes (see above).
- `docs/` — project documentation (`index.md` is the table of contents).
