# GDB debugging for Vortex SimX

## Scope
How to run SimX under `gdb` and place breakpoints in the simulator core pipeline (`sim/simx`).

## Files inspected
- [sim/simx/Makefile](../sim/simx/Makefile)
- [runtime/simx/Makefile](../runtime/simx/Makefile)
- [tests/kernel/common.mk](../tests/kernel/common.mk)
- [tests/regression/common.mk](../tests/regression/common.mk)
- [runtime/stub/vortex.cpp](../runtime/stub/vortex.cpp)
- [runtime/simx/vortex.cpp](../runtime/simx/vortex.cpp)
- [sim/simx/core.cpp](../sim/simx/core.cpp)
- [sim/simx/processor.cpp](../sim/simx/processor.cpp)
- [ci/blackbox.sh](../ci/blackbox.sh)

## Findings
- SimX debug symbols are enabled with `DEBUG` in [sim/simx/Makefile L44-L45](../sim/simx/Makefile#L44) (`-g -O0 -DDEBUG_LEVEL=$(DEBUG)`).
- SimX runtime driver debug symbols are enabled with `DEBUG` in [runtime/simx/Makefile L20-L21](../runtime/simx/Makefile#L20).
- Kernel tests run the simulator executable directly in [tests/kernel/common.mk L45-L46](../tests/kernel/common.mk#L45): `sim/simx/simx <program.bin>`.
- Regression/OpenCL tests run a host executable with `VORTEX_DRIVER=simx` and `LD_LIBRARY_PATH` in [tests/regression/common.mk L101-L102](../tests/regression/common.mk#L101), which goes through stub `dlopen` logic in [runtime/stub/vortex.cpp L58-L66](../runtime/stub/vortex.cpp#L58).
- In runtime mode, simulator execution starts asynchronously (`std::async`) in [runtime/simx/vortex.cpp L314-L327](../runtime/simx/vortex.cpp#L314), so breakpoint hits can occur on a worker thread.
- Useful SimX breakpoint anchors:
  - [sim/simx/processor.cpp L119](../sim/simx/processor.cpp#L119) `ProcessorImpl::run()`
  - [sim/simx/processor.cpp L126](../sim/simx/processor.cpp#L126) simulation tick
  - [sim/simx/core.cpp L205](../sim/simx/core.cpp#L205) `Core::tick()`
  - [sim/simx/core.cpp L218](../sim/simx/core.cpp#L218) `Core::schedule()`
  - [sim/simx/core.cpp L239](../sim/simx/core.cpp#L239) `Core::fetch()`
  - [sim/simx/core.cpp L271](../sim/simx/core.cpp#L271) `Core::decode()`
  - [sim/simx/core.cpp L302](../sim/simx/core.cpp#L302) `Core::issue()`
  - [sim/simx/core.cpp L389](../sim/simx/core.cpp#L389) `Core::execute()`
  - [sim/simx/core.cpp L403](../sim/simx/core.cpp#L403) `Core::commit()`

## Recommended workflows

### 1) Direct SimX executable debugging (simplest)
Use this path for `tests/kernel/*` programs.

1. Build simulator with symbols:
   - `make -C sim/simx DEBUG=1`
2. Build a kernel test binary (example):
   - `make -C tests/kernel/hello`
3. Run `gdb` on SimX executable:
   - `gdb --args ./sim/simx/simx ./tests/kernel/hello/hello.bin`
4. In `gdb`, add breakpoints (example):
   - `break Core::tick`
   - `break Core::issue`
   - `break ProcessorImpl::run`
   - `run`

### 2) Runtime driver path debugging (regression/opencl)
Use this when running host-side runtime tests that set `VORTEX_DRIVER=simx`.

1. Build runtime + simx with symbols:
   - `make -C runtime/simx DEBUG=1`
2. Build one host test with symbols (example):
   - `make -C tests/regression/basic DEBUG=1`
3. Launch host app in `gdb` with runtime env:
   - `gdb --args ./tests/regression/basic/basic`
4. In `gdb`, set env and pending breakpoints before `run`:
   - `set breakpoint pending on`
   - `set env VORTEX_DRIVER simx`
   - `set env LD_LIBRARY_PATH ./runtime:$LD_LIBRARY_PATH`
   - `break Core::tick`
   - `break ProcessorImpl::run`
   - `run`

Because the runtime loads the driver dynamically and runs simulation in an async worker thread, `set breakpoint pending on` is important.

## Blackbox helper path
`blackbox` can build debug binaries via `--debug=<level>` ([ci/blackbox.sh L69](../ci/blackbox.sh#L69), [ci/blackbox.sh L107](../ci/blackbox.sh#L107)).

Example:
- `./ci/blackbox.sh --driver=simx --app=demo --debug=1`

This is useful for trace logs, but for `gdb` it is usually easier to run one concrete simulator/test command directly.

## Practical breakpoint set for SIMX pipeline work
Start with:
- `break ProcessorImpl::run`
- `break Core::tick`
- `break Core::fetch`
- `break Core::issue`
- `break Core::commit`

Then narrow with conditions, e.g.:
- `break Core::issue if core_id_==0`

## Next steps
- Pick one target test (for example `tests/kernel/hello` or `tests/regression/basic`) and keep the command fixed while iterating.
- Rebuild with `DEBUG=1` after Makefile/config changes affecting SimX objects.
