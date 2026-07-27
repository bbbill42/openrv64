# Sixteen-entry issue window

Updated: 2026-07-21

## Merged selective-speculation RTL result

The issue window now has a second, separately selectable control mode:
`ENABLE_SPECULATION_WINDOW=1` / `AXI_3P_SPECULATION_WINDOW=1`. It reuses the
same sixteen entries and decode-time producer IDs; there is not a parallel
ROB beside the old issue window. Those monotonically increasing IDs now also
provide the age tags for branch recovery.

The checksum-running CoreMark-derived comparison is:

| Machine/configuration                                          | ISA instructions |     Cycles |        IPC | Delta from matched non-spec window |
|----------------------------------------------------------------|-----------------:|-----------:|-----------:|-----------------------------------:|
| OpenRV64 1P, 256x3 gshare/BTB/RAS8                             |           52,547 |    131,251 |     0.4004 |               not the same backend |
| 3P strict-prefix, 256x3, full forwarding                       |           52,547 |     80,449 |     0.6532 |                  -12,137 (-13.11%) |
| 3P issue window, retirement-held correction                    |           52,547 |     92,586 |     0.5675 |                          reference |
| **3P merged 16-entry speculation window**                      |       **52,547** | **79,313** | **0.6625** |              **-13,273 (-14.34%)** |
| **Merged window + early direct JAL**                           |       **52,547** | **78,838** | **0.6665** |              **-13,748 (-14.85%)** |
| Repeat-last (RTL type 3) + released conditional control        |           52,547 |     96,357 |     0.5453 |                    +3,771 (+4.07%) |
| **32x3 bimodal (RTL type 5) + serialized conditional control** |       **52,547** | **74,113** | **0.7090** |              **-18,473 (-19.95%)** |
| BP6 merged window + released conditional control               |           52,547 |     71,078 |     0.7393 |                  -21,508 (-23.23%) |
| 3P strict-prefix, direction/target oracle, full forwarding     |           52,547 |     73,934 |     0.7107 |                  -18,652 (-20.15%) |
| **3P merged window, direction/target oracle**                  |       **52,547** | **71,123** | **0.7388** |              **-21,463 (-23.18%)** |
| gem5 HPI A53-class proxy                                       |           58,695 |     72,146 |     0.8136 |                cross-ISA reference |

Except for the explicitly labeled repeat-last and 32x3 rows, the non-oracle 3P
speculation-window rows use the same 256-entry, three-bit gshare predictor,
256-entry tagged indirect-target table, RAS8, posted stores, 16-entry
retirement queue, native 256-bit AXI fabric, and 16 MiB RAM. All halted with
`a0=0x000000000a277880`. The window itself always uses exact producer-tag
wakeup and captured values; the command-line full-forwarding and relaxed-hazard
switches are retained to match the strict 3P comparison, but the window does
not use the strict path's untagged rd-indexed bypass as its dependency model.

Selective speculation removes 3,866 of the non-speculative window's 4,010
issued-but-not-retired instructions, a 96.4% reduction. The total issued count
falls from 56,557 to 52,691. Retirement-head-incomplete cycles fall from
48,458 to 39,620, completed-behind-head cycles from 26,313 to 19,039, and
frontend-held cycles from 22,331 to 15,320. Window memory-order/control blocks
fall from 47,202 to 20,859 cycles. These counters overlap and are not an
additive attribution, but they show that retirement-held correction and the
blanket load-behind-branch rule were the concrete regressions.

The important negative result for the original merged path was that it was
**not** a dramatic gain over the existing strict 3P path. It beat the matched
realistic strict core by only 1,136 cycles (1.41%). Most of that 13,273-cycle
improvement merely repaired the original issue window's deliberately bad
retirement-held correction model. It still left a conditional branch waiting
for operands as a hard frontier; the released-control row below removes that
restriction.

Treating legal aligned direct JAL as deterministic, rather than holding it at
the retirement head as a persistent barrier, removes another 475 cycles
(0.60%) and raises IPC from 0.6625 to 0.6665. The workload retires 449 JALs, so
the aggregate gain is about 1.06 cycles per JAL. Zero-issue cycles fall by 535,
no-eligible cycles by 1,242, and no-issue cycles involving a hard-order blocker
by 1,264. The correction count remains 1,658. This row is 6,692 cycles (9.28%)
behind HPI at equal clock. The existing oracle row predates this direct-JAL
relaxation and has not been re-run as a matched comparison.

Releasing an operand-blocked conditional branch as an issue frontier is the
material change. Under BP6, younger replayable work now issues while that
branch waits; stores, atomics, MMIO, and loads outside the explicit RAM
aperture remain held. This removes 7,760 cycles (9.84%) relative to the
direct-JAL row and 8,235 cycles (10.38%) relative to the original merged
window. Accepted zero-issue cycles fall from 41,491 to 33,420; window cycles
with no eligible instruction fall from 30,886 to 18,197; and cycles containing
a hard blocker fall from 52,796 to 14,368. These counters overlap and are not
an additive attribution.

The released-control run records 1,657 corrections and 57,450 accepted issues,
4,901 more than the direct-JAL run. That is predominantly real wrong-path
execution, not oracle behavior. Nevertheless it finishes 45 cycles (0.06%)
ahead of the older oracle run and 1,068 cycles (1.48%) ahead of the HPI
equal-clock cycle count. The HPI comparison remains cross-ISA: HPI retires
58,695 instructions at 0.8136 IPC, while OpenRV64 retires 52,547 at 0.7393 IPC.

The earlier 96,357-cycle row was mislabeled. `BP_TYPE=3` selects the
repeat-last predictor; the number 3 is the selector value, not the counter
width. The actual 32-entry, three-bit bimodal predictor is `BP_TYPE=5`. The
repeat-last run records 6,489 corrections over 13,444 resolutions, which
explains its poor result but says nothing about the 32x3 table.

The corrected 32x3 run also uses serious branch resolution: replayable data
work may pass an operand-blocked conditional branch, but a younger conditional
branch cannot issue until every older conditional branch has issued and
resolved. This prevents wrong-path branches from redirecting or training the
predictor ahead of an older unresolved branch without turning the older branch
back into a frontier for independent ALU work.

With that rule, the actual 32x3 configuration takes 74,113 cycles at 0.7090
IPC and records 2,878 corrections over 12,742 resolutions. It is 10,345 cycles
(12.25%) faster than the older strict-prefix 32x3/full-forwarding run, only
1,967 cycles (2.73%) behind the HPI equal-clock cycle count, and 3,035 cycles
(4.27%) behind the existing BP6 released-control run. The 2,878 corrections
exactly match the old strict 32x3 run, so the serialized-control path does not
show the previous apparent correction cascade.

This is not an isolated measurement of serialization itself. There is no valid
pre-serialization, released-control BP5 run: the run that was supposed to fill
that role used repeat-last. The 10,345-cycle comparison therefore combines the
merged speculation window, early JAL/control behavior, and serialization. The
BP6 comparison also combines predictor differences with control policy because
that older BP6 trace allowed multiple unresolved conditionals. The corrected
trace and rendered pipeline report are
`sim/issue-window/coremark-bp5-bimodal32x3-serialized-control-trace.csv` and
`sim/issue-window/coremark-bp5-bimodal32x3-serialized-control-pipeline.txt`.

With direction and target prediction made oracular in the merged window,
cycles fall by another 8,190 (10.33%) from 79,313 to 71,123 and IPC rises from
0.6625 to 0.7388. This is 2,811 cycles (3.80%) faster than the matched strict
oracle and 1,023 cycles (1.42%) below the HPI proxy's cycle count at equal
clock. The HPI IPC remains higher because its AArch64 stream contains 58,695
instructions, 11.7% more than the RV64 stream. The oracle result is a bound on
the present branch predictor and recovery cost, not a realizable configuration.

### Recovery and safety contract

- A ready conditional branch resolves in EX0 and redirects immediately.
- The issue window and retirement queue retain the branch and every older
  entry, discard younger entries, and rebuild architectural-register ownership
  from the survivors.
- Retirement order follows the surviving ring entries rather than assuming
  consecutive numeric IDs. IDs never rewind, so late wrong-path completions
  cannot match newly allocated instructions in reused physical slots.
- The gshare checkpoint queue resolves associatively by instruction ID. A
  correctly resolved younger branch may wait for older records, while committed
  history advances only at the ordered checkpoint head.
- Ordinary loads may pass unresolved branches only when their awakened
  effective address lies inside `SPEC_LOAD_BASE`/`SPEC_LOAD_SIZE`. The fixed 3P
  wrapper maps this to the 16 MiB RAM aperture. The check uses the actual
  forwarded base operand, not its stale decode-time placeholder.
- Stores, atomics, MMIO reads, system operations, fences, and faulting hard
  operations remain non-speculative. Wrong-path RAM responses are drained and
  discarded by their stale instruction IDs.

This is functional speculative out-of-order issue with in-order retirement,
not a complete production OoO backend. There is no physical-register rename
file, store queue, memory-dependence predictor, or cache cancellation protocol.
The associative wakeup, checkpoint search, and recovery-time owner rebuild are
RTL experiments and have not been placed or timing-closed. The RAS is cleared
conservatively on recovery rather than checkpointed.

Artifacts:

- `sim/issue-window/issue-window16-gshare-trace.csv`
- `sim/issue-window/issue-window16-gshare-pipeline.txt`
- `sim/issue-window/spec-window16-gshare-trace.csv`
- `sim/issue-window/spec-window16-gshare-pipeline.txt`
- `sim/issue-window/strict-oracle-current-trace.csv`
- `sim/issue-window/strict-oracle-current-pipeline.txt`
- `sim/issue-window/spec-window16-oracle-trace.csv`
- `sim/issue-window/spec-window16-oracle-pipeline.txt`
- `sim/issue-window/coremark-current-retire-oracle.memh`

Reproduction adds `AXI_3P_SPECULATION_WINDOW=0` or `1` to the existing
performance command:

```text
make -B sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sw/coremark-loop.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    AXI_3P_PERF_ARGS=+expect_a0=000000000a277880 \
    AXI_3P_PERF_BP_TYPE=6 AXI_3P_RETIRE_DEPTH=16 \
    AXI_3P_FULL_FORWARDING=1 AXI_3P_RELAX_WAW=1 \
    AXI_3P_RELAX_HAZARDS=1 AXI_3P_ISSUE_WINDOW=1 \
    AXI_3P_SPECULATION_WINDOW=1 \
    AXI_3P_TRACE_CSV=sim/issue-window/spec-window16-gshare-trace.csv \
    AXI_3P_TRACE_REPORT=sim/issue-window/spec-window16-gshare-pipeline.txt
```

The oracle must match the exact current ELF. A previously saved file retained
12,691 records but its second target was `0x80000518` while the current binary
requires `0x80000504`; replaying it timed out after only 39 retirements. Build
the oracle from the checksum-valid retirement trace, whose order remains
architectural even when branches resolve out of order:

```text
python3 tools/branch_oracle_from_trace.py \
    sim/issue-window/spec-window16-gshare-trace.csv \
    sim/issue-window/coremark-current-retire-oracle.memh \
    --expect-count 12691
```

Then add the following to the performance command:

```text
AXI_3P_ORACLE_BRANCHES=1 \
'AXI_3P_PERF_ARGS=+expect_a0=000000000a277880 +branch_oracle_load=sim/issue-window/coremark-current-retire-oracle.memh +branch_oracle_count=12691'
```

## Original non-speculative executable RTL result

The replay projection below has now been tested against a selectable RTL
implementation.  The first conservative implementation is checksum-correct,
but it does **not** reproduce the projected speedup:

| Model/configuration                        | ISA instructions |     Cycles |        IPC |    Versus measured 3P |
|--------------------------------------------|-----------------:|-----------:|-----------:|----------------------:|
| OpenRV64 1P, BTFNT + RAS8                  |           52,547 |    131,801 |     0.3987 |               +46,850 |
| Measured aggressive-hazard 3P              |           52,547 |     84,951 |     0.6186 |             reference |
| **16-entry issue-window RTL**              |       **52,547** | **99,891** | **0.5260** | **+14,940 (+17.59%)** |
| Falsified pre-RTL replay (historical only) |           52,547 |     68,332 |     0.7690 |        not comparable |
| gem5 HPI A53-class reference               |           58,695 |     72,146 |     0.8136 |               -12,805 |

The RTL run used BTFNT, RAS8, full forwarding, relaxed WAW, aggressive
producer-tagged hazards, posted stores, a 16-entry retirement queue, the
256-bit AXI/16 MiB RAM testbench, and full cycle tracing.  It halted normally
with `a0=0x000000000a277880`.  It issued 58,641 instructions; the excess over
the 52,547 architectural instructions is younger work later discarded at a
retirement-time branch correction.

This result **falsifies the replay's 0.769 headline as a prediction of the
implemented window**.  It is retained below only as a record of the failed
model, not as a valid performance comparison.  The replay resolved branches
early and did not
charge wrong-path instructions against execution capacity.  The RTL follows
the chosen simpler recovery rule: a conditional branch may execute when its
operands are ready, but resolution and correction become architectural only
when the branch retires.  Memory also remains program ordered, and every load
or store is held behind an older live branch so a wrong-path MMIO read cannot
escape.  Those are not small modeling details on this parser.

### What the new trace says

The cycle trace now records issue-window aggregates separately from the legacy
strict-prefix candidate fields:

| Window observation                       | Cycles |  Share |
|------------------------------------------|-------:|-------:|
| At least one unissued entry resident     | 80,506 | 80.59% |
| All 16 entries occupied                  |  7,656 |  7.66% |
| Unissued entries but no eligible entry   | 36,007 | 36.05% |
| At least one true producer wait          | 71,716 | 71.79% |
| At least one hard-control ordering block | 63,364 | 63.43% |
| At least one memory-order/control block  | 52,349 | 52.41% |
| Retirement head incomplete               | 49,164 | 49.22% |

The counts overlap.  Average window state is more revealing than capacity:
6.940 unissued entries are resident, 3.067 have ready operands, only 0.616 are
eligible under all ordering rules, and 0.586 actually issue per cycle.  The
window is rarely full, so increasing it beyond sixteen cannot fix this result.
The next experiment must change speculation/ordering semantics—not capacity.

Allowing RAM/cacheable loads past unresolved branches is plausible once the
core has memory attributes and a squashable cache request path.  Allowing
arbitrary reads in the present uncached AXI/MMIO path is not architecturally
safe, so this implementation does not silently take that shortcut.

### Implemented structure and rollback

`ENABLE_ISSUE_WINDOW=0` remains the default and selects the original
strict-prefix `dispatch_3p` path without source changes.  The Makefile switch
is `AXI_3P_ISSUE_WINDOW=1`; the window currently requires
`AXI_3P_RETIRE_DEPTH=16`.

The separate path contains:

- a registered post-decode issue stage;
- decode-time instruction/retirement ID and slot allocation;
- sixteen resident entries that remain allocated through in-order retirement;
- youngest-producer ID ownership per architectural register;
- exact-ID completion wakeup and persistent captured operand values;
- oldest-ready selection for fixed EX0/control, EX1/RV64M, MEM, and two
  flexible base-ALU positions;
- ordered memory issue and non-speculative MMIO protection;
- retirement-time branch resolution and full younger-state squash;
- dedicated trace counters and a focused oldest-ready/WAW unit test.

The legacy EX0/EX1 architectural-register local bypass is disabled only on the
tagged window path.  Leaving it enabled caused a younger `addiw a4` completion
to overwrite the correctly tagged older `li a4` value consumed by `sllw`.
That bypass has no producer ID and is therefore unsafe once WAW producers may
execute out of order.  The original dispatch path retains it.

Saved artifacts:

- `sim/issue-window/rtl-window16-trace.csv`
- `sim/issue-window/rtl-window16-pipeline.txt`

### Replay-only free and perfect branch sensitivity

The conservative RTL above remains unchanged.  A separate scheduler mode was
added to `tools/issue_window_experiment.py` to answer a stronger counterfactual
question: what if control prediction is perfect and conditional branches
have no dependency or execution cost?

The source is the checksum-valid oracle trace
`sim/coremark-loop-3p-oracle-full-forward-relaxed-waw-trace.csv`.  In the free
mode, a conditional branch:

- is known to be on the correct path because the source run used the recorded
  direction-and-target oracle;
- completes when admitted to the sixteen-entry window, even if its source
  operands are unavailable;
- consumes no EX0 or issue slot and creates no issue barrier;
- still consumes decode/window capacity and retires in program order.

This is deliberately stronger than a realizable branch predictor or branch
unit.  It is an event-scheduler sensitivity test, not checksum-executing RTL.
Because the executable RTL result falsified this scheduler's absolute timing
model, the cycle and IPC columns below are **not hardware bounds or performance
predictions**.  Only differences between rows under the same failed model are
reported for diagnostic use.

| Sixteen-entry replay mode                           | Replay cycles | Replay IPC | Internal delta |
|-----------------------------------------------------|--------------:|-----------:|---------------:|
| Ordinary oracle-fed branches                        |        61,424 |     0.8555 |      reference |
| **Conditional branches perfect and free**           |    **60,648** | **0.8664** |       **-776** |
| Conditional branches plus JAL/JALR perfect and free |        60,646 |     0.8665 |           -778 |

The model eliminated execution cost for 10,784 conditional branches.  Making
the 1,907 JAL/JALR instructions free as well saved only two more cycles.  Within
this replay only:

- changing from the non-oracle source/model to the oracle source/model changes
  the replay output by about 6,908 cycles, but that mixes source traces and is
  not a measured saving from the real 99,891-cycle RTL path;
- after the replay already assumes oracle prediction, removing branch operand
  and EX0 occupancy changes its own result by 776 cycles;
- no valid conclusion about absolute IPC, distance from 0.9 IPC, or the real
  RTL bottleneck follows from the 60,648-cycle output.

The 776-cycle internal delta is evidence only about how this scheduler model
accounts branch execution occupancy.  A checksum-running RTL experiment is
required to quantify the real machine.

Artifacts:

- `sim/issue-window/oracle-window16.json`
- `sim/issue-window/free-perfect-branches-window16.json`
- `sim/issue-window/free-perfect-control-window16.json`

Reproduction:

```text
PYTHONDONTWRITEBYTECODE=1 python3 tools/issue_window_experiment.py \
    sim/coremark-loop-3p-oracle-full-forward-relaxed-waw-trace.csv \
    --capacity 16 --free-perfect-branches \
    --json sim/issue-window/free-perfect-branches-window16.json
```

Focused and compatibility checks:

- `make -B sim-dispatch-window-3p`: passed;
- `make -B sim-dispatch-3p`: passed;
- `make -B sim-backend-3p`: passed;
- `make -B sim-top-axi-3p`: passed with the default path;
- window-enabled 256-bit AXI SoC flow: passed;
- window-enabled traced CoreMark-derived run: correct checksum and halt.

RTL reproduction:

```text
make -B sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sw/coremark-loop.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    AXI_3P_PERF_ARGS=+expect_a0=000000000a277880 \
    AXI_3P_PERF_BP_TYPE=4 AXI_3P_BP_RAS_ENABLE=1 \
    AXI_3P_PERF_BP_RAS_DEPTH=8 AXI_3P_RETIRE_DEPTH=16 \
    AXI_3P_FULL_FORWARDING=1 AXI_3P_RELAX_WAW=1 \
    AXI_3P_RELAX_HAZARDS=1 AXI_3P_ISSUE_WINDOW=1 \
    AXI_3P_TRACE_CSV=sim/issue-window/rtl-window16-trace.csv \
    AXI_3P_TRACE_REPORT=sim/issue-window/rtl-window16-pipeline.txt
```

## Falsified pre-RTL replay (historical record)

The following table records the estimate made before the issue window existed
in RTL.  The checksum-valid RTL result above later falsified its absolute cycle
and IPC prediction.  These rows must not be used as current comparisons:

| Model/configuration                                |     Cycles |        IPC |              Versus measured 3P |
|----------------------------------------------------|-----------:|-----------:|--------------------------------:|
| Measured aggressive-hazard 3P                      |     84,951 |     0.6186 |                       reference |
| Issue-around-head selection only                   |     82,742 |     0.6351 |                 -2,209 (-2.60%) |
| 16 decoded entries, still strict-prefix issue      |     70,541 |     0.7449 |               -14,410 (-16.96%) |
| **Falsified barely-viable-hazard + window replay** | **68,332** | **0.7690** |     **historical model output** |
| gem5 HPI A53-class reference                       |     72,146 |   0.813559 | not comparable to failed replay |

The 68,332-cycle result is not merely unproven: the implemented window ran in
99,891 cycles at 0.5260 IPC.  The replay deleted frontend backpressure that the
RTL did not eliminate, omitted wrong-path execution occupancy, resolved
branches under different timing, and did not enforce the RTL's rule that
memory waits behind a live branch.  It therefore cannot predict the
implemented window.

Inside the failed model, associative oldest-ready selection accounted for
2,209 of its claimed 16,619-cycle saving and synthetic frontend decoupling
accounted for the rest.  The RTL result demonstrates that the latter mechanism
was modeled incorrectly.

## What was modeled

`tools/issue_window_experiment.py` consumes the checksum-valid full trace from
the aggressive-hazard CoreMark run.  It extracts all 52,547 committed dynamic
instructions and their actual operand metadata and issue-to-completion
latencies.  Median measured latency is one cycle for ALU operations, four for
loads, and two for stores in the source trace.

The counterfactual scheduler retains:

- true RAW dependencies using the youngest older producer;
- producer identity across WAWs;
- two general ALU pipes and one MEM issue per cycle;
- at most three live LSU entries;
- program-ordered issue among memory instructions;
- stores completing architecturally only at the in-order retirement head;
- persistent ordering for jumps/system/fence operations;
- conditional branches resolving early but ending their issue group;
- three-wide in-order retirement with hard-operation group boundaries;
- the measured branch/control, wrong-path-fetch, refill, and other intrinsic
  frontend gaps.

The window scans the oldest sixteen admitted instructions and selects the
oldest ready combination that can be matched onto EX0, EX1, and MEM.  It may
skip unfinished older instructions, but it may not invent operands, reorder
memory requests, or commit out of order.

## Combination with barely-viable hazards

This is not an additional multiplicative optimization that should be applied
to the 68,332-cycle result.  The replay already models the `RELAX_HAZARDS=1`
policy used to produce its source trace:

- each consumer depends on the youngest older producer of its architectural
  source register;
- a source becomes usable when that exact producer completes, rather than when
  it retires;
- a younger WAW may allocate without waiting for the older writer to retire;
- there is no synthetic per-register read-port limit;
- a true pending RAW, including a same-cycle bundle dependency, still blocks.

Consequently, **68,332 cycles / 0.7690 IPC was the combined barely-viable-hazard
plus 16-entry-window replay output**.  It is retained to document the failed
hypothesis, not as an estimate.  The separately measured 2,251-cycle relaxed-
hazard result remains real; the replay-attributed 16,619-cycle window saving
does not.

## Why the calibration failed

With observed per-instruction delivery times and the strict-prefix policy, the
model produces 84,935 cycles, only 16 cycles below the measured 84,951.  This
agreement was partly by construction because the replay reused measured
delivery times and dynamic latencies.  The later RTL mismatch proves that this
calibration did not validate the counterfactual de-backpressure transform.

There are two feed models:

1. **Observed feed** never makes a future correct instruction visible before it
   appeared in the existing trace.  Oldest-ready issue occurs on 5,648 cycles,
   but total completion time does not improve because the trace has already
   baked the original frontend backpressure into later delivery times.  This is
   a deliberately pessimistic replay variant, not a hardware bound.
2. **De-backpressured feed** removes 16,672 fetch-held cycles classified as
   backend pressure while retaining 6,451 predictor/control hold cycles.  Its
   own feed clock pauses whenever the modeled window is full, so it does not
   assume an unlimited upstream instruction FIFO.  This produces the 68,332
   cycle output after applying the 16-cycle calibration offset.  The RTL result
   later falsified this feed transformation.

As a robustness check, replaying the older conservative 3P trace (87,202
measured cycles) converges on 68,397 cycles / 0.7683 IPC for the same 16-entry
window.  That is only 65 cycles away from the 68,332-cycle result above.  The
selection-only delta is also similar (2,081 versus 2,209 cycles), so the
failed replay output is not materially dependent on whether the source trace
used the normal or aggressively relaxed hazard policy.  That consistency does
not make the model accurate.

The optimistic model skips the oldest instruction on 6,880 cycles, reaches a
maximum skip distance of fourteen, and is feed-full for only 48 cycles.  Its
backend has 22,568 non-issue cycles, versus 28,840 for a strict scheduler under
the same feed assumptions.

The result failed because it replays only committed instructions:
wrong-path fetch time remains in the delivery gaps, but wrong-path instructions
do not consume modeled execution slots.  It also reuses measured memory
latencies rather than recomputing AXI contention after rescheduling.  The only
defensible interpretation is historical and model-internal:

- approximately **2.2k cycles / +0.0165 replay IPC** was the internal modeled
  effect of oldest-ready selection alone;
- **68.3k cycles / 0.769 replay IPC** was the failed output after deleting
  backend-driven frontend holds;
- neither number bounds the real RTL result.  The measured implementation is
  **99,891 cycles / 0.5260 IPC**.

## Failed-model window-size sensitivity

| Capacity | Projected cycles | Projected IPC | Cycle saving |
|----------|-----------------:|--------------:|-------------:|
| 8        |           73,765 |        0.7124 |       11,186 |
| **16**   |       **68,332** |    **0.7690** |   **16,619** |
| 32       |           68,284 |        0.7695 |       16,667 |

Sixteen entries are effectively saturated inside this replay: thirty-two
entries change its output by only another 48 cycles.  These are not RTL cycle
savings.  Eight entries change the same failed model by 5,433 cycles.
This is qualitatively different from the prior 16-entry retirement-buffer
experiment, which changed storage only behind strict-prefix issue and saved
zero cycles.

## Reproduction

```text
python3 tools/issue_window_experiment.py \
    sim/hazard-relax/aggressive-fixed-trace.csv \
    --capacity 16 \
    --json sim/issue-window/window-16.json
```

Sensitivity results are saved as `sim/issue-window/window-{8,16,32}.json`.
