# simx runtime overview

## High-level flow
- Host apps link against the stub runtime (libvortex.so) and call `vx_dev_open`.
- `vx_dev_open` in [runtime/stub/vortex.cpp](runtime/stub/vortex.cpp#L58-L112) chooses the driver via `VORTEX_DRIVER` (default: simx) and `dlopen`s the corresponding `libvortex-<driver>.so`.
- The simx driver exports `vx_dev_init`, which fills a callback table; the stub stores these function pointers and uses them to service all runtime API calls.
- Device creation happens inside `vx_dev_init`: it allocates a `vx_device` object (the simx device) and returns its handle to the stub via the `dev_open` callback.

## Key components
- [runtime/simx/vortex.cpp](runtime/simx/vortex.cpp): Defines `vx_device`, the simx device implementation. It owns the architectural model (`Arch`), main memory `RAM`, the execution engine `Processor`, a global memory allocator, device control registers (DCRs), and bookkeeping for performance counters.
- [runtime/common/callbacks.inc](runtime/common/callbacks.inc): Implements `vx_dev_init` for simx (and other software drivers). It wires the runtime callback table to the `vx_device` methods: device open/close, mem alloc/copy, DCR access, kernel start, and ready wait.
- [sim/simx/processor.cpp](sim/simx/processor.cpp) and [sim/simx/processor.h](sim/simx/processor.h): Implement the simulated processor. Internally uses `ProcessorImpl` to build clusters, caches, memory simulator, and the simulation platform.
- [sim/simx](sim/simx) directory: Contains the detailed pipeline, caches, memory system, and execution units used by the processor model (e.g., clusters, vector units, cache simulator, memory coalescer, dispatcher, etc.).

## Initialization steps (simx path)
1) Host calls `vx_dev_open` (stub)
   - Loads `libvortex-simx.so` and calls its `vx_dev_init` [runtime/stub/vortex.cpp](runtime/stub/vortex.cpp#L58-L112).
   - `vx_dev_init` allocates `vx_device` and returns it via the `dev_open` callback [runtime/common/callbacks.inc](runtime/common/callbacks.inc#L20-L49).

2) `vx_device` construction
   - Builds the architecture description (`Arch`) using configured NUM_THREADS/WARPS/CORES/CLUSTERS constants.
   - Creates `RAM` and `MemoryAllocator` for global memory and attaches RAM to the processor.
   - Constructs `Processor` with the architecture; inside, `ProcessorImpl` initializes the simulation platform and hardware model: clusters, L3 cache, memory simulator, and interconnects [sim/simx/processor.cpp](sim/simx/processor.cpp#L18-L90).
   - If VM is enabled, sets up page tables and virtual memory helpers.

3) Device ready
   - `vx_device::init` currently returns 0 (no extra work), so availability is immediate after construction.

## Running a kernel
1) Host uploads kernel and arguments via runtime API; data is stored in the simulated RAM managed by `vx_device` (upload/download routes through RAM with alignment and ACL handling) [runtime/simx/vortex.cpp](runtime/simx/vortex.cpp#L142-L240).
2) Host calls `vx_start`
   - `vx_device::start` programs DCRs with kernel entry and argument addresses and launches `Processor::run()` asynchronously [runtime/simx/vortex.cpp](runtime/simx/vortex.cpp#L301-L334).
3) Simulation loop
   - `ProcessorImpl::run` resets the simulation platform, then repeatedly ticks `SimPlatform` until all clusters report completion, aggregating performance stats during the run [sim/simx/processor.cpp](sim/simx/processor.cpp#L120-L149).
4) Completion
   - Host waits via `vx_ready_wait`; perf counters can be dumped on close. Memory is freed through the callbacks.

## Build and artifacts
- `libvortex-simx.so` (runtime driver) is built in [runtime/simx/Makefile](runtime/simx/Makefile). It depends on `libsimx.so` from [sim/simx](sim/simx) and installs alongside other runtime libs.
- The stub runtime loads `libvortex-simx.so` at run time; no static linking is required for the application.

## How to trace or modify
- To observe high-level lifecycle, add logs in the stub around `vx_dev_open` [runtime/stub/vortex.cpp](runtime/stub/vortex.cpp#L58-L112) and inside `vx_device::start` [runtime/simx/vortex.cpp](runtime/simx/vortex.cpp#L301-L334).
- For micro-architectural behavior, instrument `ProcessorImpl::run` and the units in [sim/simx](sim/simx) (e.g., dispatcher, cache_sim, vec_unit).

## Quick mental model
- Stub selects driver → simx driver constructs `vx_device` → `Processor` builds full simulated SoC → host uploads kernel/args → `vx_start` kicks off `Processor::run()` → `SimPlatform` ticks clusters/caches/memory until halt.
