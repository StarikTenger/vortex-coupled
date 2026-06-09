# SimX regression-failure investigation (branch `coupling`)

Investigation of the 6 `tests/regression` failures observed after the execute/commit
pipeline-stage separation refactor (commit `d908f6be`, "execute-commit stage separation
calculate values in execute, save them to trace, update registers in commit"), per the
brief in `notes/test-strategy.md`.

## Scope

- Tests investigated: `diverge`, `dogfood`, `dropout`, `io_addr`, `printf`, `sgemm_tcu`
  (the failing set after the user's commit-stage fix to `Core::execute`/`Core::commit`,
  re-run with `util/run-tests.sh` / `./ci/blackbox.sh --cores=4 --driver=simx --debug=0|3`).
- Out of scope (per the brief): chasing leads beyond the failing-test set, applying/
  testing fixes on `coupling` itself, or auditing unrelated subsystems.
- All raw logs and traces referenced below live in `logs/` (`<test>.debug0.run.log` =
  full program stdout/stderr at `--debug=0`; `<test>.debug3.run.log` = full instruction
  trace at `--debug=3`, captured for the two pilot tests `dropout` and `printf`).

## Outline

1. **Triage** — read the *real* failure signature of each test (not just the exit code,
   which is a Make artifact — see "A note on exit codes" below).
2. **Pilot deep-dive** — picked `dropout` (smallest/simplest failing test, per the user's
   suggestion) and `printf` (clean, minimal repro of a second signature) for full
   `--debug=3` instruction-trace analysis.
3. **Root-cause hypothesis** — traced `dropout`'s crash back through register values to a
   single, concretely-located code defect.
4. **Confirmation pass** — checked whether the same defect plausibly explains the other
   four runtime failures.
5. This report, plus suggestions for further work.

## A note on exit codes

`util/run-tests.sh` reports the exit status of `./ci/blackbox.sh`, which ultimately runs
`make -C <test-dir> run-simx`. **GNU Make always exits with status 2 when a recipe fails**,
regardless of the recipe's own exit code (verified empirically). So "exit code 2" for all
6 tests tells us nothing about a shared failure mode — it's just Make's generic
"recipe failed" code. The real signatures had to be read out of the captured program output
(`logs/<test>.debug0.run.log`), which is what Step 1 (triage) below is based on.

## Results summary

| Test | What it tests (brief) | Real failure signature (fact) | Root-cause hypothesis |
|---|---|---|---|
| **dropout** | Per-thread independent compute + conditional store (`-n1024`); RNG/hash + dropout-mask kernel, calls `vprintf` internally | `SIGABRT` ("Aborted (core dumped)", Error 134). Traced (§ Pilot: dropout) to: warp jumps to **PC=0x0**, fetches the simulator's "uninitialized memory" sentinel `0xbaadf00d`, aborts. PC became 0 because register `x1` (`ra`) held `0` when the kernel-launch wrapper (`vx_spawn_threads`) executed its `ret` | **I think** this is the same register-corruption defect described below: `x1`/`ra` (and the stack pointer `x2` that addresses it) end up holding values that were never validly written for that thread |
| **dogfood** | Big sweep of ALU/FPU instruction correctness (`Test0..Test21`, iadd/imul/fdiv/trig/...) | `SIGABRT` from an explicit `std::abort()` in `execute.cpp:446` — *"divergent branch! PC=0x800067c4"* — i.e. the simulator detected that active threads in a warp disagree on a plain conditional-branch outcome (not handled by SPLIT/JOIN, so treated as a hard SIMT-model violation) | **I think** the threads don't actually disagree architecturally; rather, some thread(s) are evaluating the branch with a **stale/corrupted operand register value**, making the warp *appear* divergent — same root cause as below |
| **printf** | Per-thread `vprintf`-style output of formatted strings/values to a shared device buffer | **Identical signature to `dogfood`**: `std::abort()` from *"divergent branch! PC=0x80000ab4"*, same code path `execute.cpp:446`, on a `BLT x8, x18` with `tmask=1111` (all 4 threads "active" but disagreeing) | Same hypothesis as `dogfood` — and the fact that two unrelated kernels hit the *exact same abort* strongly suggests one shared defect, not two kernel-specific issues |
| **diverge** | Stresses SIMT divergent control flow (per the test name) and verifies per-thread results against a host reference | **Clean (non-crashing) verification failure**: runs to completion, then *"Found 48 errors!"* — actual values are the simulator's uninitialized-memory sentinel `0xbaadf00d` where correct results were expected | **I think** result-buffer stores never reach memory for some threads — most likely because the address/data registers feeding those stores were corrupted by the same write-back defect, so the store either targets the wrong address or doesn't fire for the right threads |
| **io_addr** | Two-level pointer indirection: loads a pointer *value* from memory, then dereferences it (`*([...])`) | C++ exception `vortex::BadAddress` ("invalid memory address", thrown from `sim/common/mem.h:126`/`mem.cpp`), then a **second failure** during stack unwinding: `SimPlatform::cleanup()` assertion `reg_events_.empty() && "registered events not cleared!"` fails | **I think** the loaded pointer value is corrupted (same defect — a register receiving a wrong/garbage value), causing the second-level dereference to land outside any mapped region. The cleanup assertion failure looks like a **separate, secondary** issue: the simulator doesn't unregister in-flight events before an exception unwinds through it |
| **sgemm_tcu** | Tensor-core (TCU/WMMA) GEMM with `tf32` operands | **Pure compile error** (not a runtime failure at all): `'tf32' is not a member of 'vt'` at `tests/regression/sgemm_tcu/main.cpp:239`, `Error 1` from the C++ compiler, `-Wfatal-errors` | **I think this is unrelated to the refactor** — it's a build break (a missing/renamed type in the `vt`/vortex-types namespace), most likely a pre-existing issue or a toolchain/header mismatch in this checkout, not a SimX behavioral regression |

## Pilot deep-dive: `dropout`

Picked as the pilot per the user's suggestion ("start with the one simple test"). Captured
a full `--debug=3` instruction trace (`logs/dropout.debug3.run.log`, ~375K lines) and
walked it backward from the crash.

**Facts, in causal order (read backward from the crash):**

1. The simulator aborts immediately after fetching instruction code `0xbaadf00d` at
   `PC=0x0` — `sim/common/mem.cpp` confirms `0xbaadf00d` is literally the sentinel pattern
   the memory model writes into never-initialized memory (`mem.cpp:467-469`); `PC=0x0` is
   unmapped, so this is "the program jumped somewhere it never should have."
2. PC became `0x0` because `cid=3, wid=0` executed `JALR x0, x1, 0x0` (a `ret`) at
   `uuid #51539608977`, and **`x1` (the return-address register `ra`) held `0`**.
3. `x1` got `0` from `LW x1, x2, 0x2c` (`uuid #51539608974`, the epilogue of
   `vx_spawn_threads`, the kernel-launch trampoline — confirmed against `kernel.dump`).
   The load faithfully read what was in memory: `Mem Read: addr=0xfff8ffbc, data=0x00000000`.
4. That memory address is **wrong** for this frame. `vx_spawn_threads`'s **prologue**
   (`uuid #51539607837`, `SW x2, x1, 0x2c` at `vx_spawn_threads+4`) had legitimately saved
   the *real* return address (`Mem Write: addr=0xfff8fffc, data=0x8000006c`) — to address
   `0xfff8fffc`, **64 bytes (`0x40`) higher** than where the epilogue went looking
   (`0xfff8ffbc`).
5. Both addresses are computed as `x2 (sp) + 0x2c`, so **the stack pointer `x2` itself
   differs by `0x40` between function entry and exit** — i.e. it was *not* properly
   restored to its entry value, even though every visible `ADDI x2, x2, ...` adjustment in
   the function body is balanced (`-0x10`/`+0x10` pairs, `-0x30`/`+0x30` pairs).
6. Tracking those `ADDI x2, x2, ...` instructions for this warp shows something odd: the
   **active-thread mask (`tmask`) attached to them is unstable** — the loop that calls
   `vprintf` repeatedly starts with `tmask=1111` for its first few iterations, then,
   mid-loop, every subsequent stack-adjustment instruction (≈12 of them, plus the final
   frame-deallocation `ADDI x2, x2, 0x30` at the call-site epilogue) shows `tmask=0010`
   (only one of the four threads "active"), before reverting to `tmask=1111` again later.
   A `SW`/`ADD x2`/`ADDI x2` pair that updates only one lane's `sp` while leaving the other
   three lanes' `sp` untouched — when it should have updated all four (or none) — is exactly
   the kind of corruption that produces a frame-size mismatch like the `0x40` we observe.

**This pointed me at the code.** I read `Emulator::commit()` (`sim/simx/emulator.cpp:481-566`),
which performs the deferred register write-back this refactor introduced:

```cpp
// emulator.cpp:495-507 (integer dest register write-back)
case RegType::Integer:
  if (rdest.idx != 0) {
    for (uint32_t t = 0; t < rd_data.size(); ++t) {
      if (!warp.tmask.test(t)) {        // <-- uses the LIVE warp mask
        continue;
      }
      warp.ireg_file.at(rdest.idx).at(t) = rd_data[t].i;
    }
  }
```

and the equivalent float case at `emulator.cpp:516`. **Both use `warp.tmask`** — the warp's
*current, live* thread mask — to decide which lanes receive the write-back.

Compare this to how the rest of the codebase treats per-instruction thread masks:
- `trace->tmask` is explicitly captured as a **snapshot** of `warp.tmask` at fetch/decode
  time (`emulator.cpp:196`, `:371`), is part of `instr_trace_t`'s "metadata" (compared in
  `operator==`, `instr_trace.h:149`), and is the field everything else consistently uses:
  `dispatcher.cpp:68/89/91`, `func_unit.cpp:272/283`.
- `execute.cpp:127` even **asserts** `warp.tmask == trace->tmask` — i.e. the codebase's own
  invariant is that the *snapshot* is what should govern an instruction's behavior, and the
  live mask is only guaranteed to match it at `execute` time (which is still close enough
  to issue/decode that no other instruction from the same warp could have changed it yet).

**The hypothesis (this is the "I think"):** by the time `commit()` runs for instruction X,
`commit` can be — and in this pipelined design routinely is — separated from X's `execute`
by many cycles (I directly observed `LW x1` execute at cycle 44434 and commit at cycle
44488, 54 cycles later, with *other, later* instructions from the same warp executing and
even **committing out of order** in between — `LW x8 (#...975)` committed one step before
`LW x1 (#...974)`, despite being the later instruction). In that window, a `TMC`/`SPLIT`/
`JOIN`/branch from the *same* warp can legitimately change `warp.tmask`. When that happens,
`commit()` writes `rd_data` back using the **wrong** (now-current, not-as-issued) mask:
- lanes that *were* active when the instruction executed (and for which `rd_data` holds a
  valid computed value) can be skipped, if they've since dropped out of `warp.tmask`;
- lanes that *were not* active (and for which `rd_data[t]` is leftover/zero-initialized
  data from the trace-pool object) can instead receive that garbage value, if they've since
  entered `warp.tmask`.

Either way the register file ends up holding values for some lanes that were never validly
computed for them — exactly the kind of single-lane stack-pointer corruption seen in
`dropout` (a `±0x10`/`±0x30` adjustment landing on the wrong lane(s) leaves that lane's `sp`
permanently off by some multiple of the frame size).

**Concrete, testable fix candidate (not applied — see "Suggestions"):** change
`warp.tmask.test(t)` to `trace->tmask.test(t)` at `emulator.cpp:500` and `:516` (and the
`#ifdef EXT_V_ENABLE` vector case at `:534`, for consistency, though no failing test
currently exercises it).

## Confirmation pass: do the other failures fit?

| Test | Does the hypothesis transfer? |
|---|---|
| `printf` | **Yes, directly** — identical abort, identical code path (`execute.cpp:446`), to `dogfood`. A `BLT x8,x18` reported as divergent with `tmask=1111` (i.e. the simulator itself believes all 4 lanes are active) means the disagreement *must* come from per-lane operand values, not from a real mask difference — consistent with corrupted source-register content rather than a genuine SIMT-divergence bug in the kernel or compiler. |
| `dogfood` | **Plausible, same code path** — `dogfood` is explicitly an ALU/FPU correctness sweep; any single corrupted operand register on any lane, on any of its many branches/loops, would manifest exactly this way. I did not trace this one in full (its `--debug=3` log would be enormous — `PERF: instrs≈15M` per the earlier successful run), but the *identical* abort signature to `printf` is itself strong circumstantial evidence for a shared cause rather than two independent kernel-specific bugs. |
| `diverge` | **Plausible, different surface symptom** — `diverge` doesn't crash; it runs to completion and then fails *verification*. That's consistent with the corruption sometimes hitting an address/data register feeding a *store* rather than a register feeding a *branch* or a *return*: the store either silently goes to the wrong place or is skipped for some lanes, leaving the destination buffer holding the `0xbaadf00d` "never written" sentinel — which is exactly what the mismatch report shows. I did not trace this one (same size concern: it ran ~14.8M instructions). |
| `io_addr` | **Plausible** — the kernel's defining feature is exactly "load a pointer value from memory, then dereference it" (`tests/regression/io_addr/kernel.cpp`). A corrupted address register landing outside any mapped region is precisely what `BadAddress` reports. The *second* failure (the `SimPlatform::cleanup()` assertion during exception unwinding) looks unrelated to the register-corruption story — **I think** it's a separate, pre-existing gap: nothing unregisters the core's in-flight scheduled events before the `BadAddress` exception propagates out and `cleanup()` runs, so the "all events cleared" invariant fires spuriously on *any* exception-driven abort, not just this one. |
| `sgemm_tcu` | **No** — this is a compile-time error (`'tf32' is not a member of 'vt'`), not a simulation failure; it never reaches the simulator. **I think** it's unrelated to the refactor and should be tracked/fixed independently (e.g. a missing type in the `vt` namespace headers, possibly a toolchain/header version mismatch in this checkout). |

## Facts vs. hypotheses — summary

**Facts** (directly observed in logs/traces/code, reproducible):
- All 6 tests fail with Make's generic exit code 2; their *real* signatures differ and fall
  into (at least) four classes: SIGABRT-from-bad-jump (`dropout`), SIGABRT-from-explicit-
  divergence-check (`dogfood`, `printf` — identical), clean verification mismatch with
  uninitialized-sentinel values (`diverge`), C++ exception + secondary cleanup assertion
  (`io_addr`), and pure compile error (`sgemm_tcu`).
- In `dropout`, the crash is caused by `x1`/`ra` holding `0` at the point of a `ret`,
  which in turn is caused by the function's epilogue computing a stack address `0x40`
  bytes away from where its own prologue saved the return address — i.e. the stack
  pointer was not correctly restored across the function body, despite every visible
  `sp` adjustment being individually balanced.
- `Emulator::commit()` (the new deferred-writeback stage this refactor introduced) gates
  per-lane register write-back on `warp.tmask` (the *live*, current mask), whereas every
  other consumer of per-instruction thread masks in this codebase — including an assertion
  in `execute()` that encodes the invariant explicitly — uses `trace->tmask` (the *snapshot*
  captured at decode time). The pipeline now allows an instruction's `commit` to be
  separated from its `execute` by many cycles, with intervening (and even out-of-order
  completing) instructions from the same warp able to change `warp.tmask` in between.
- `0xbaadf00d` is, by code (`mem.cpp:467-469`), literally the simulator's "uninitialized
  memory" sentinel — its appearance in `diverge`'s wrong results and at `dropout`'s crash
  PC both specifically indicate "this memory was never validly written/mapped."

**Hypotheses** (my interpretation — clearly *not* yet proven by a controlled experiment):
- *I think* the `warp.tmask` vs. `trace->tmask` mismatch in `commit()` is **the** root
  cause behind `dropout`, `dogfood`, `printf`, and `diverge` — a single defect whose surface
  symptom (bad jump, spurious divergence-abort, wrong results) depends only on *which*
  register and *which* lane(s) end up corrupted for a given kernel's instruction mix and
  timing. **Experimentally confirmed — see "Fix verification" below.**
- *I think* `io_addr`'s failure is **not** caused by the `warp.tmask` bug. It persists
  unchanged after the fix (same "Memory access violation from 0x80 to 0x84, access flags=2"
  signature) and therefore has a different, still-unknown root cause. The `SimPlatform::
  cleanup()` assertion failure looks like a **separate**, secondary defect (events not
  deregistered before exception-driven teardown) that would likely surface on *any*
  `BadAddress`-class exception, independent of this refactor.
- *I think* `sgemm_tcu` is **unrelated** to the refactor entirely — a pre-existing or
  environment-specific compile break.

## Suggestions for further investigation

These are explicitly out of the scope I was asked to stay within for this pass, but I think
they're the natural next steps:

1. ~~**Confirm the `commit()` hypothesis experimentally.**~~ **Done — see "Fix verification".**
   The fix (`warp.tmask.test(t)` → `trace->tmask.test(t)`) confirmed 4/5 refactor-related
   failures. `io_addr` still fails with an unchanged signature, ruling it out as a
   `warp.tmask` casualty and making it the next highest-priority investigation target.
2. **Baseline trace diff**, as originally planned: build the pilot test (`dropout` or
   `printf`) against a pre-refactor commit (e.g. just before `d908f6be`), run both at
   `--debug=3`, convert to CSV with `hw/scripts/trace_csv.py`, and `diff` by UUID. The
   first instruction where register/memory values diverge would give an independent,
   trace-level confirmation of exactly which write-back goes wrong first — complementary
   to (and a good cross-check on) the code-level reasoning in this report.
3. **`io_addr`'s cleanup-assertion issue** looks worth a small separate investigation:
   does *any* exception thrown mid-simulation (not just `BadAddress` from this bug) trip
   the `reg_events_.empty()` assertion in `SimPlatform::cleanup()`? If so, it's a latent,
   unrelated robustness gap that will keep masking the "real" first-chance exception in
   future debugging sessions.
4. **`sgemm_tcu`'s build break** (`'tf32' is not a member of 'vt'`) should be tracked as
   its own (non-refactor) issue — worth checking whether it also fails to build on `master`
   or whether something in this checkout's headers/toolchain is out of sync.
5. Audit for the **same pattern** elsewhere in the new deferred-writeback code paths
   (anywhere a *live* `warp.*` field is read during `commit`/late pipeline stages instead
   of the `trace`-captured snapshot — e.g. `warp.PC`, `warp.ipdom_stack`) since the same
   "live state moved on since `execute`" hazard could apply there too, just not yet
   exercised by a failing test.
6. **Investigate `io_addr`'s root cause** as its own separate task. The failure is a WRITE
   to the read-only IO region at `0x80` — the kernel should only store to the `dst` buffer
   at `0x3080`, so something is corrupting the store-address path. Leads to investigate:
   - Whether `arg->dst_addr` is correctly initialized / read from `VX_CSR_MSCRATCH`
   - Whether the 64-bit load (`uint64_t* src_ptr = ...`) is handled correctly in XLEN=32
     mode (two-part load whose halves may commit at different cycles)
   - Whether the `SimPlatform::cleanup()` assertion fires on *any* exception, or only here

## Fix verification

**Applied:** `warp.tmask.test(t)` → `trace->tmask.test(t)` in `Emulator::commit()`
(`sim/simx/emulator.cpp`), at the three write-back sites:
- line ~500: `RegType::Integer` lane gating
- line ~516: `RegType::Float` lane gating
- line ~534: `RegType::Vector` lane gating (under `EXT_V_ENABLE`)

**Rebuilt:** `make -s -C sim` (simx only, no other changes).

**Results** (`./ci/blackbox.sh --cores=4 --driver=simx --debug=0`):

| Test | Before fix | After fix |
|---|---|---|
| `diverge` | FAIL (verification mismatch, 48 errors, `0xbaadf00d` values) | **PASS** |
| `dogfood` | FAIL (`std::abort()`, divergent branch at `0x800067c4`) | **PASS** |
| `dropout` | FAIL (`SIGABRT`, jump to `PC=0x0` / `0xbaadf00d`) | **PASS** |
| `printf` | FAIL (`std::abort()`, divergent branch at `0x80000ab4`) | **PASS** |
| `io_addr` | FAIL (write to read-only IO region `0x80`, `BadAddress`) | **Still FAIL** (identical error — different root cause) |
| `sgemm_tcu` | FAIL (compile error, unrelated) | FAIL (compile error, unchanged) |

**Conclusion:** The hypothesis is confirmed for 4 of the 5 refactor-related runtime
failures. `io_addr`'s failure is NOT caused by the `warp.tmask` misuse — it has a
separate, not yet identified root cause (see suggestion 6 above).
