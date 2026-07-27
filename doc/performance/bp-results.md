# Branch-predictor results

## Modes 7 and 8 update

Date: 2026-07-25

Matched current-tree CoreMark runs validate the two larger predictors. All
three rows retire 52,547 instructions, halt with
`a0=0x000000000a277880`, and report no predictor-record overflow.

| Mode | Direction predictor                                                     |     Cycles |        IPC | Corrections | Cycle delta from mode 6 |
|-----:|-------------------------------------------------------------------------|-----------:|-----------:|------------:|------------------------:|
|    6 | 256x3 gshare, 8-bit history                                             |     70,030 |     0.7503 |       1,658 |               reference |
|    7 | 512x3 gshare, 9-bit history                                             |     68,194 |     0.7706 |       1,348 |         -1,836 (-2.62%) |
|    8 | 2048x3 global + 512x10 local history + 1024x3 local PHT + 512x2 chooser | **65,577** | **0.8013** |     **732** |     **-4,453 (-6.36%)** |

Mode 7 removes 310 corrections (18.7%) relative to mode 6. Mode 8 removes
926 (55.9%). Relative to mode 7, mode 8 saves another 2,617 cycles (3.84%)
and 616 corrections (45.7%).

The mode-8 total separates into 729 conditional-direction corrections and
three cold BTB misses. In the matched cache-hierarchy run, the new target
counters report 737 accepted BTB lookups, 734 hits, three misses, and zero
wrong targets; the RAS reports 737 lookups and 737 hits. Lookup counts include
wrong-path predictor activity and therefore need not equal retired control
counts. The performance harness emits this breakdown as `PERF_BP_TARGET`.

The controlled configuration used `RETIRE_DEPTH=16`, issue and speculation
windows enabled, fetch alternate lookaside mode 3, full forwarding disabled,
and the current adaptive two-stream L1D prefetch configuration. These are
cycle-model results on the current in-flux cache/backend tree. They do not
establish clock frequency.

Mode 7 fixes its gshare geometry at 512 three-bit entries and nine history
bits. Mode 8 uses an 11-bit speculative global history, a 512-entry ten-bit
local-history table, a 1024-entry three-bit local PHT, and a 512-entry two-bit
chooser initialized weakly global. Its direction payload is 1.875 KiB;
resettable valid vectors raise direction state to 2.375 KiB. BTB256 and RAS8
are unchanged.

Direct Yosys checks report zero structural problems and retain the large
mode-7 and mode-8 arrays as three and six memory cells respectively; only the
small checkpoint structures expand into registers. That is necessary but not
sufficient for a physical implementation. The mode-8 local prediction path
serializes a local-history read and local-PHT read before chooser selection,
and the RTL's lookup/training accesses require a concrete macro-port plan.
Post-layout timing may erase some or all of the simulated cycle gain.

Directed tests cover fixed mode-7 geometry, cold BTFNT, tournament component
disagreement and chooser training, tagged out-of-order resolution, selective
rollback, and integrated scalar-core execution. `sim-exec-bp` and the complete
`sim-bp-context` modes 0 through 8 pass.

The matched performance command is:

```sh
make sim-prefetch-3p-perf \
    PREFETCH_ENGINE=verilator \
    PREFETCH_FETCH_ALT_LOOKASIDE=3 \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-predictor-sweep.bin \
    AXI_3P_PERF_MEMH=sim/coremark-predictor-sweep.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    'AXI_3P_PERF_ARGS=+expect_a0=000000000a277880' \
    AXI_3P_PERF_PIPELINE_TRACE=0 \
    AXI_3P_PERF_BP_TYPE=8 \
    AXI_3P_RETIRE_DEPTH=16 \
    AXI_3P_ISSUE_WINDOW=1 \
    AXI_3P_SPECULATION_WINDOW=1 \
    AXI_3P_POSTED_STORES=1
```

## Original mode-6 result

Date: 2026-07-20

## Result

The new selectable predictor improves the current 3P CoreMark-derived loop
from **90,151 to 86,267 cycles** and from **0.5829 to 0.6091 IPC** with general
full forwarding disabled. That is **3,884 cycles (4.31%)**. Backend correction
redirects fall from 2,878 to 1,658, a 42.4% reduction. The predictor closes
34.1% of the 11,399-cycle gap between the 32x3 predictor and the matched
direction-and-target oracle.

With the existing full-forwarding experiment enabled, the new predictor
reaches **80,449 cycles and 0.6532 IPC**, versus 84,458/0.6222 for 32x3. The
gain composes cleanly: 4,009 cycles (4.75%). It does not reach the oracle or
the A53-class HPI reference. Prediction was one real bottleneck, not the only
bottleneck.

### Comparison table

All OpenRV64 rows execute the same checksum-valid RV64 image and retire 52,547
instructions with `a0=0x000000000a277880`. Every performance run enabled a
cycle-level pipeline trace. "Full fwd" is the separate completed-result
forwarding experiment; the normal branch-only EX0/EX1/MEM bypass remains on in
all 3P rows.

| Machine                      | Predictor                        | Full fwd | Retired |      Cycles |        IPC | Backend corrections | Delta from matching 32x3 |
|------------------------------|----------------------------------|---------:|--------:|------------:|-----------:|--------------------:|-------------------------:|
| OpenRV64 1P                  | 32x3 bimodal + RAS8              |      n/a |  52,547 |     131,894 |     0.3984 |         not counted |                reference |
| OpenRV64 1P                  | **256x3 gshare + BTB256 + RAS8** |      n/a |  52,547 | **131,251** | **0.4004** |         not counted |        **-643 (-0.49%)** |
| OpenRV64 3P                  | 32x3 bimodal + RAS8              |      off |  52,547 |      90,151 |     0.5829 |               2,878 |                reference |
| OpenRV64 3P                  | **256x3 gshare + BTB256 + RAS8** |      off |  52,547 |  **86,267** | **0.6091** |           **1,658** |      **-3,884 (-4.31%)** |
| OpenRV64 3P                  | direction-and-target oracle      |      off |  52,547 |      78,752 |     0.6672 |                   0 |        -11,399 (-12.64%) |
| OpenRV64 3P                  | 32x3 bimodal + RAS8              |       on |  52,547 |      84,458 |     0.6222 |               2,878 |                reference |
| OpenRV64 3P                  | **256x3 gshare + BTB256 + RAS8** |       on |  52,547 |  **80,449** | **0.6532** |           **1,658** |      **-4,009 (-4.75%)** |
| OpenRV64 3P                  | direction-and-target oracle      |       on |  52,547 |      73,934 |     0.7107 |                   0 |        -10,524 (-12.46%) |
| ARM gem5 HPI A53-class proxy | model predictor                  |      n/a |  58,695 |      72,146 |     0.8136 |                 n/a |      cross-ISA reference |

The HPI row is not Cortex-A53 silicon and its raw IPC is not directly
comparable: the AArch64 stream executes 11.7% more instructions. At equal
clock, matching its 72,146 cycles with the RV64 stream requires 0.7283 IPC.
The new realistic 3P rows remain 19.6% above HPI cycles without full
forwarding and 11.5% above with it. The full-forwarding oracle is still 1,788
cycles above HPI.

The 1P result is intentionally included, but its blocking 64-bit memory path
and five-stage in-order backend differ from the 3P AXI system. The target table
nearly eliminates 1P predictor holds (1,458 to 6 cycles), yet total execution
improves by only 643 cycles because that backend cannot turn most recovered
frontend bandwidth into additional issue throughput.

## What was implemented

`BP_TYPE=6` selects a synthesizable advanced predictor while leaving modes 0
through 5 intact:

- a 256-entry, three-bit saturating direction table;
- eight bits of speculative global branch history, XORed with `PC[9:2]`
  (gshare indexing);
- BTFNT prediction for invalid/cold direction entries;
- a separate 256-entry direct-mapped indirect-target table with a 16-bit tag
  and 64-bit target;
- the existing parameterized RAS, with RAS priority for RISC-V x1/x5 return
  hints;
- a 16-entry ordered in-flight control queue carrying the exact PHT index,
  pre-branch history checkpoint, predicted-target-valid bit, and target;
- speculative history advance at decode allocation and checkpoint-plus-actual
  recovery on redirect;
- resolution-time saturating-counter and JALR-target training;
- target comparison qualified by the resolving control's queue record; and
- sticky queue-overflow reporting plus decode backpressure before overflow.

Direct conditional and JAL targets still come from predecode/decode and do not
waste BTB capacity. Non-return JALR uses the BTB. A cold indirect miss is
admitted once, holds younger decode until it resolves, and installs a BTB
entry. Returns deliberately do not fall back to the BTB when the RAS is empty,
because a return-site PC does not uniquely identify a dynamic return target.

The ordered record is not optional bookkeeping. The former RAS path retained
one untagged outstanding target, which allowed a younger return target to be
compared against an older direct-control resolution. The 32x3 baseline shows
144 such extra `control_redirect` cycles: total control redirects are 3,022
while backend corrections are 2,878. Mode 6 has 1,658 of each, so the tagged
record removes the false-target case as well as improving direction and JALR
target prediction.

### Nominal state cost

At the default parameters the new mode contains about 24,142 bits of
direction, target, history, and in-flight-record state, before the RAS; RAS8
adds roughly another 523 bits. About 20,736 bits are the BTB target/tag/valid
array. These are logical state-bit counts, not a cell-area or timing result.
The current RTL uses asynchronous array reads. A physical implementation
should infer or instantiate small SRAM/register-file macros and then verify the
PC-to-prediction timing path; a flop-expanded Sky130 synthesis would badly
overstate the sensible implementation area.

This is a conventional compact predictor, not TAGE or a large tournament
predictor. There is no chooser, path history, perceptron, set associativity, or
elaborate replacement policy. That is deliberate: 256 gshare entries plus a
tagged indirect table and RAS are the useful middle ground before predictor
complexity starts outrunning this core.

## Trace comparison

The controlled 3P pair changes only `BP_TYPE` and its associated table
parameters.

| Counter                            | 32x3 bimodal | 256x3 gshare + BTB |               Delta |
|------------------------------------|-------------:|-------------------:|--------------------:|
| Cycles                             |       90,151 |         **86,267** |          **-3,884** |
| IPC                                |       0.5829 |         **0.6091** |         **+0.0262** |
| Correct-path control resolutions   |       12,691 |             12,691 |                   0 |
| Backend corrections                |        2,878 |          **1,658** | **-1,220 (-42.4%)** |
| All control redirects              |        3,022 |          **1,658** | **-1,364 (-45.1%)** |
| Predictor-stall observation cycles |        5,224 |             **36** |          **-5,188** |
| Zero-issue cycles                  |       55,529 |         **51,606** |          **-3,923** |
| Frontend held                      |       23,517 |         **21,487** |          **-2,030** |
| RAW-pending first block            |       38,695 |         **38,416** |                -279 |
| Retirement head incomplete         |       41,132 |         **40,965** |                -167 |
| Fetch AXI reads                    |       25,433 |             26,049 |                +616 |

The important distinction is between predictor events and wall-clock gain.
Removing 1,364 redirects and 5,188 predictor-stall observations saves 3,884
cycles, not their sum. Redirect recovery, fetch refill, backend RAW stalls,
and retirement waits overlap. Once control flow improves, the decoded queue is
occupied more often and exposes more of the existing backend pressure. In the
new trace, RAW-pending and retirement-head counts barely move; they are the
next-order limit, not evidence that the predictor did nothing.

The remaining gap to the narrow oracle is 7,515 cycles (9.54% of oracle
cycles). Some of that is the remaining 1,658 corrections, but the oracle also
has perfect targets and suppresses all predictor interlocks. Even perfect
prediction does not make a branch free: normal EX0 use, issue-group rules, and
retirement still apply.

## Controlled configuration

The matched narrow runs used:

```text
sw/coremark-loop.elf, -O2, RV64I, -mno-relax
BP_TYPE=5 or 6
RAS_ENABLE=1, RAS_DEPTH=8
BIMODAL=32 entries x 3 bits
GSHARE=256 entries x 3 bits
BTB=256 entries, 16-bit tag, 64-bit target
INFLIGHT_DEPTH=16
RETIRE_DEPTH=8
COMPLETION_FORWARD_MASK=000
BRANCH_COMPLETION_FORWARD_MASK=111
ENABLE_FULL_FORWARDING=0
RELAX_WAW=1, RELAX_HAZARDS=0
ISSUE_WINDOW=0, POSTED_STORES=1
FREE_BRANCHES=0, EQ_BRANCH_PAIRING=1
```

The full-forwarding pair changes only `ENABLE_FULL_FORWARDING=1`. The oracle
rows force correct direction and target, suppress target mismatch and
predictor stalls, and still retain ordinary branch execution cost.

## Validation and artifacts

Directed validation covers cold BTFNT behavior, speculative-history recovery,
counter training, cold and warm indirect calls, BTB target retraining, RAS
priority, matching and mismatching targets, queue-full backpressure with no
overflow, and the old false RAS-target comparison. Integration tests cover the
scalar context path and the 3P 256-bit AXI/16 MiB SoC path.

Commands:

```sh
make -j128 sim-exec-bp sim-bp-context
make -B sim-top-axi-3p AXI_3P_BP_TYPE=6

yosys -q -p 'read_verilog -sv -Irtl rtl/core/exec/bp/bp.v; \
    hierarchy -check -top openrv64_exec_bp -chparam BP_TYPE 6; \
    proc; memory_dff; memory_collect; check'

make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-loop-eqpair.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-eqpair.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    'AXI_3P_PERF_ARGS=+expect_a0=000000000a277880' \
    AXI_3P_PERF_BP_TYPE=6 \
    AXI_3P_FULL_FORWARDING=0 \
    AXI_3P_TRACE_CSV=sim/bp-gshare256-btb256-trace.csv \
    AXI_3P_TRACE_REPORT=sim/bp-gshare256-btb256-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS=--around-pc=8000049c
```

Saved traces and readable reports:

- `sim/bp-bimodal32x3-trace.csv` and
  `sim/bp-bimodal32x3-pipeline.txt`;
- `sim/bp-gshare256-btb256-trace.csv` and
  `sim/bp-gshare256-btb256-pipeline.txt`;
- `sim/bp-gshare256-btb256-full-forward-trace.csv` and
  `sim/bp-gshare256-btb256-full-forward-pipeline.txt`;
- `sim/bp-coremark-1p-bimodal32x3-trace.csv` and its report; and
- `sim/bp-coremark-1p-gshare256-btb256-trace.csv` and its report.

The predictor's ordered scalar resolution record matches the normal 1P and 3P
paths (`ISSUE_WINDOW=0`, `FREE_BRANCHES=0`) and is assertion-checked in
simulation. The diagnostic free-branch path may resolve out of order, and the
experimental issue-window path can retire more than one control while the
predictor still has only one scalar resolution port. Neither is a supported
combination with mode 6 yet. If either experiment becomes architectural, the
predictor/backend interface needs decode-time instruction IDs and multi-wide
resolution rather than weakening the ordering check.
