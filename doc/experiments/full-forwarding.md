# Full general forwarding experiment

This document records full-forwarding experiments on the three-pipe OpenRV64
backend.  The objective is to measure the fixed-clock IPC benefit of removing
the existing same-pipe, one-cycle forwarding restriction.  The latest matched
rerun is first; older measurements are retained below as historical context.

This is an RTL simulation result, not a frequency claim.  The experimental
network deliberately favors coverage over physical topology so that it can
serve as an upper-bound functional model.

## Current matched rerun: branch bypass plus full forwarding

Date: 2026-07-20

The current persistent completed-result map is worth **5,693 cycles with the
live predictor** and **4,818 cycles with control flow made oracular**.  These
are incremental results on top of the dedicated producer-slot-qualified
EX0/EX1/MEM-to-branch completion bypass; that branch-only bypass remains
enabled in all four rows.

| Prediction                               | General full forwarding |     Cycles | Retired |        IPC | Delta from matched narrow row |
|------------------------------------------|------------------------:|-----------:|--------:|-----------:|------------------------------:|
| 32x3 bimodal + RAS8                      |                     off |     90,151 |  52,547 |     0.5829 |                     reference |
| 32x3 bimodal + RAS8                      |                  **on** | **84,458** |  52,547 | **0.6222** |           **-5,693 (-6.31%)** |
| Correct-path direction-and-target oracle |                     off |     78,752 |  52,547 |     0.6672 |                     reference |
| Correct-path direction-and-target oracle |                  **on** | **73,934** |  52,547 | **0.7107** |           **-4,818 (-6.12%)** |
| ARM gem5 HPI A53-class proxy             |                     n/a |     72,146 |  58,695 |     0.8136 |                     reference |

IPC rises by 6.74% in the live-predictor pair and 6.52% in the oracle pair.
The oracle-plus-full-forwarding result is only 1,788 cycles, or 2.48%, above
HPI at equal clock.  HPI executes 11.7% more ISA instructions, so matching its
same-work cycle count requires 0.7283 IPC from this RV64 stream rather than
matching HPI's raw 0.8136 IPC.

The mechanisms overlap modestly.  Relative to the normal narrow-forwarding
row, oracle plus full forwarding removes 16,217 cycles (17.99%) and reaches
0.7107 IPC.  Adding the isolated savings would predict 875 more saved cycles
than the combined run actually realizes.

### Current trace evidence

| Counter                           | Normal, narrow | Normal, full | Oracle, narrow | Oracle, full |
|-----------------------------------|---------------:|-------------:|---------------:|-------------:|
| Zero-issue cycles                 |         55,529 |   **50,344** |         44,503 |   **40,109** |
| First block: RAW pending          |         38,695 |   **24,583** |         38,966 |   **24,513** |
| First block: same-bundle RAW      |         14,035 |       14,094 |         14,365 |       14,310 |
| First block: completed-result RAW |              0 |        4,043 |              0 |        4,305 |
| Retirement head incomplete        |         41,132 |   **35,823** |         38,979 |   **33,775** |
| Completed behind retirement head  |         15,638 |       15,934 |         15,643 |       15,905 |
| Branch corrections                |          2,878 |        2,878 |          **0** |        **0** |

The main effect is not same-bundle forwarding: that count is essentially
unchanged.  The persistent map releases consumers after an older producer has
completed but cannot yet retire.  RAW-pending first blocks fall by 14,112
cycles normally and 14,453 cycles under the oracle, but overlap with other
stalls means only about 40% and 33% of those counter reductions respectively
become wall-clock savings.

`RELAX_WAW=1` permits multiple live writers, while `RELAX_HAZARDS=0` keeps this
experiment's architectural-register map deliberately conservative: a source
may consume the untagged full-forwarding value only when exactly one writer to
that register remains live.  The 4,043/4,305 completed-result blocks are the
remaining ambiguous or otherwise unavailable cases, not ignored hazards.  The
separate aggressive-hazard mode uses youngest-producer IDs to cover those
cases and is not enabled here.

All runs used the same current `sw/coremark-loop.elf` image and halted with
`a0=0x000000000a277880`.  The oracle replay consumed all 12,691 correct-path
control records and produced zero correction redirects.  The controlled RTL
configuration was:

```text
BP_TYPE=5, BIMODAL_ENTRIES=32, BIMODAL_COUNTER_BITS=3
RAS_ENABLE=1, RAS_DEPTH=8, RETIRE_DEPTH=8
COMPLETION_FORWARD_MASK=000
BRANCH_COMPLETION_FORWARD_MASK=111
RELAX_WAW=1, RELAX_HAZARDS=0
ISSUE_WINDOW=0, POSTED_STORES=1
FREE_BRANCHES=0, EQ_BRANCH_PAIRING=1
```

Only `ENABLE_FULL_FORWARDING` changes within each normal/oracle pair.  The
oracle additionally replaces direction and target prediction and suppresses
predictor stalls; it does not make branches free and does not remove their
EX0 occupancy or normal issue-group rules.

Current artifacts are:

- `sim/coremark-full-forward-normal-trace.csv`
- `sim/coremark-full-forward-normal-pipeline.txt`
- `sim/coremark-full-forward-oracle-trace.csv`
- `sim/coremark-full-forward-oracle-pipeline.txt`
- `sim/coremark-branch-forward-oracle.memh`

The focused register-map, dispatch, retirement-queue, and integrated backend
tests pass after the rerun.  Both performance runs are checksum-valid detailed
pipeline traces.  These remain fixed-clock results: the wide architectural
register result map and operand muxing must still survive synthesis and timing
closure before the IPC gain can be treated as a net implementation win.

## Historical 2026-07-19 result

| Configuration                                                  | ISA     | Retired instructions |      Cycles |          IPC | Same-work cycle comparison |
|----------------------------------------------------------------|---------|---------------------:|------------:|-------------:|----------------------------|
| ARM gem5 HPI A53-class reference                               | AArch64 |               58,695 |      72,146 | **0.813559** | reference                  |
| Current OpenRV64 1P, repeat-last predictor                     | RV64I   |               52,547 |     141,804 |       0.3706 | 1.966x HPI cycles          |
| Prior OpenRV64 3P, narrow local forwarding and precise stores  | RV64I   |               52,547 |     136,049 |       0.3862 | 1.886x HPI cycles          |
| Prior OpenRV64 3P, posted store but blanket memory interlock   | RV64I   |               52,547 |     129,010 |       0.4073 | 1.788x HPI cycles          |
| Prior OpenRV64 3P, non-overlapping loads pass posted store     | RV64I   |               52,547 |     122,223 |       0.4299 | 1.694x HPI cycles          |
| **Current OpenRV64 3P, plus covered store-to-load forwarding** | RV64I   |               52,547 | **122,223** |   **0.4299** | **1.694x HPI cycles**      |
| Prior OpenRV64 3P, precise stores plus full forwarding         | RV64I   |               52,547 |     130,963 |       0.4012 | 1.815x HPI cycles          |
| **Current 3P baseline plus full general forwarding**           | RV64I   |               52,547 | **117,418** |   **0.4475** | **1.628x HPI cycles**      |
| **Current 3P baseline plus oracle control flow**               | RV64I   |               52,547 | **101,167** |   **0.5194** | **1.402x HPI cycles**      |
| **Oracle control flow plus full general forwarding**           | RV64I   |               52,547 |  **96,326** |   **0.5455** | **1.335x HPI cycles**      |

Against the current posted-store/load-bypass baseline, full forwarding removes
4,805 cycles, or 3.93% of runtime, and raises IPC from 0.4299 to 0.4475.  The
separate oracle-control experiment removes 21,056 cycles, or 17.23%, and
raises IPC to 0.5194.  Enabling both mechanisms removes 25,897 cycles, or
21.19%, and reaches 0.5455 IPC.  All three diagnostic runs halted normally with final
`a0=0x000000000a277880`.

The result is real but small.  General forwarding is not the missing mechanism
that takes this workload to 0.9 IPC.

The HPI row is gem5's two-wide, in-order ARMv8-A performance model.  It is an
A53-class proxy, not a cycle-exact Cortex-A53 model or silicon measurement.
The two binaries execute the same C workload but do not retire the same ISA
instruction stream: AArch64 commits 6,148 more instructions, or 11.7%.  The
same-work cycle count is therefore the useful cross-ISA performance comparison.
IPC is primarily diagnostic within each ISA and should not be compared as if
the dynamic instructions were identical.

## What was simulated

The experiment adds `ENABLE_FULL_FORWARDING`, defaulting to zero.  When
enabled, a result is forwardable if it:

- comes from the current EX0, EX1, or MEM completion port, or from any
  completed but still-live retirement-queue entry;
- writes a nonzero architectural register;
- is not marked illegal and does not carry an exception.

The backend forms a valid bit and 64-bit value for each architectural register.
Dispatch uses that map in front of all six operand selectors: `rs1` and `rs2`
for each of the three oldest candidates.  A completed producer can therefore
feed either operand of an EX0, EX1, or MEM consumer, independent of the pipe
that produced it.

WAW exclusion remains unchanged, so there can be at most one outstanding
writer for an architectural register.  This makes the architectural-register
map unambiguous without adding register renaming.  In-order issue and in-order
retirement also remain unchanged.

Same-bundle RAW dependencies remain blocked deliberately.  The younger
instruction cannot consume an instruction that is only beginning execution in
the same cycle without a cascaded, combinational execution-unit path.  That is
not ordinary completion forwarding and was outside this experiment.

Relevant implementation points are:

- `rtl/core/backend/backend_3p.v`: builds the result map from three live
  completion ports and completed retirement entries;
- `rtl/core/retire/retire_queue_3p.v`: exposes completed, still-live results;
- `rtl/core/dispatch/reg_map_3p.v`: treats a matching general result as a
  qualified exception to a busy-source RAW stall;
- `rtl/core/dispatch/dispatch_3p.v`: selects forwarded data during operand
  capture;
- `AXI_3P_FULL_FORWARDING=1`: enables the experiment in the AXI 3P testbench.

## Directed validation

The integrated backend test includes a case that the old local bypass cannot
pass:

1. An older load is launched and its response is withheld.
2. A younger ALU instruction produces `x11 = 64` and completes behind that
   unresolved load, so it cannot retire.
3. The original one-cycle ALU-local completion window passes.
4. A still-younger load, fixed to the MEM pipe, consumes `x11 + 8`.
5. The test observes the dependent request at address 72 before the older load
   responds.
6. The younger load response is returned out of order with data `0x55`.
7. After the older response arrives, retirement remains ordered and the
   dependent load retires `x12 = 0x55`.

This proves both persistence beyond the local completion window and an
EX-to-MEM forwarding path.  The register-map unit test separately proves that
a completion-map match releases a cross-pipe RAW while the narrow local path
does not.

The following checks passed:

```text
make -B sim-reg-map-3p sim-dispatch-3p sim-retire-queue-3p sim-backend-3p
make -B sim
```

The complete regression reported no failures.  Existing Icarus sensitivity,
timescale, and intentionally dangling legacy-interface warnings remain.

## CoreMark-derived workload

The performance workload is `sw/coremark_loop.c`, the finite branch-heavy
state-machine workload used by the existing A53/HPI comparison.  It is not the
full CoreMark benchmark and does not produce a CoreMark/MHz score.

Both 3P measurements used:

- the same RV64I ELF and 256-bit memory image;
- the fixed 256-bit AXI core boundary and 16 MiB SoC RAM testbench;
- repeat-last branch prediction (`BP_TYPE=3`);
- pipelined, tagged LSU support;
- pipeline tracing for the entire run;
- a 250,000-cycle timeout, with normal EBREAK termination.

## Trace counter comparison

| Counter                              | Narrow forwarding | Full forwarding |             Delta |
|--------------------------------------|------------------:|----------------:|------------------:|
| Total cycles                         |           136,049 |         130,963 |   -5,086 (-3.74%) |
| Frontend empty                       |            55,099 |          53,685 |   -1,414 (-2.57%) |
| Frontend held                        |            40,256 |          38,192 |   -2,064 (-5.13%) |
| Dispatch empty                       |            28,444 |          29,151 |     +707 (+2.49%) |
| Dispatch nonempty, no issue          |            65,509 |          60,196 |   -5,313 (-8.11%) |
| Queued RAW indications               |            72,141 |          52,655 | -19,486 (-27.01%) |
| Queued WAW indications               |            35,733 |          34,829 |     -904 (-2.53%) |
| Queued read-port indications         |             1,586 |           1,402 |    -184 (-11.60%) |
| Queued barrier indications           |               490 |             394 |     -96 (-19.59%) |
| Retire queue nonempty, no retirement |            74,287 |          68,566 |   -5,721 (-7.70%) |
| Branch-predictor stall               |            21,255 |          20,319 |     -936 (-4.40%) |
| Redirect                             |             7,218 |           7,218 |                 0 |
| AXI wait                             |               184 |             112 |               -72 |

These counters are overlapping cycle indications.  The trace contains a
three-bit hazard mask, but the report increments `queued_raw` only once for a
cycle in which dispatch is nonempty and any RAW bit is set.  The same blocked
candidate may be counted on many consecutive cycles, and a RAW bit on candidate
one or two may be irrelevant because an older prefix candidate is already
blocked by WAW, unit readiness, ordering, or another RAW.  The counters are not
exclusive cycle buckets and must not be added to estimate runtime.

RAW indications fall substantially, but total cycles do not.  Removing one
hazard often reveals a WAW, ordered operation, unresolved load, retirement
head, or frontend bubble in the same interval.

More importantly, the remaining RAW counter does not mean that another bypass
wire can release the instruction.  Full forwarding releases every busy source
whose value has actually completed.  A remaining RAW means that the producer
has not completed yet, the producer and consumer are in the same issue bundle,
or an older prefix condition prevents useful issue.  Those are latency and
scheduling constraints, not missing completed-result connectivity.

## Was missing RAW forwarding the primary problem?

No.  This experiment is a direct counterfactual test of that hypothesis, and
the hypothesis does not survive it.

The experimental network makes every completed architectural result visible
to every pipe and keeps it visible until retirement.  If completed-but-hidden
RAW values were the primary limiter, this should have produced a large runtime
collapse.  Instead it removes 27.0% of RAW-indicated cycles but only 3.74% of
total cycles.  It closes 6.55% of the cycle gap to 0.9 IPC.

The RAW indications mix several different situations:

| Situation reported as RAW                               | Does this network solve it?      | Required mechanism                             |
|---------------------------------------------------------|----------------------------------|------------------------------------------------|
| Producer completed but has not retired                  | Yes                              | General completion forwarding                  |
| Producer is an ALU result completing now                | Yes                              | Live completion bypass                         |
| Producer is an unresolved load                          | No; the value does not exist yet | Lower load latency or useful independent issue |
| Producer is earlier in the same issue bundle            | No; it has not executed          | Cascaded execution, or issue it next cycle     |
| Younger candidate has a RAW after an older prefix block | Usually not causally useful      | Remove the older WAW/order/unit block first    |

The evidence does not yet support assigning one exclusive percentage to each
remaining mechanism because the trace flags overlap.  It does support a firm
ordering of hypotheses:

1. Completed-result connectivity is now measured and is secondary.
2. The hot loop is visibly serialized through load completion, ordered store
   completion, and ordered-head branch resolution.
3. Branch behavior is unchanged at 7,218 corrections, while the frontend is
   still empty for 53,685 cycles.
4. WAW remains indicated for 34,829 cycles because architectural destinations
   remain owned until retirement.

The next clean experiments should separately parameterize early ordinary
branch execution and store-buffer completion.  Those A/B runs are needed
before claiming which one is the largest exclusive source of lost cycles.

## Prior baseline: ordered posted-store completion

A second counterfactual was run with full forwarding disabled and was promoted
to the default 3P baseline before the load-bypass follow-up below.  It does
**not** launch stores early: a store still waits until it is the ordered
retirement head before presenting its memory request.  The store is marked
complete when the request handshake succeeds instead of waiting for the
eventual response.

The LSU retains the store tag and diagnostic metadata until the response
arrives and drains that response.  `store_inflight` continues to block younger
memory requests until the response, so this is narrower than a real store
buffer.  It isolates the cost of holding architectural retirement and the next
ordered branch behind the store response.

A late error is not ignored.  It is latched and delivered alone at the next
architectural boundary as an imprecise async abort.  An AXI/access error uses
the store-access-fault cause and a delayed page error uses store-page-fault.
`tval` contains the original store effective address; the exception PC is the
next unretired architectural frontier so it does not invite replay of the old
store.  Original store instruction and trace metadata are retained for
diagnostics.  The core cannot undo the already-retired store or younger state,
so this is visibility of failure, not precise recovery.

The defaults are now `AXI_3P_POSTED_STORES=1` and
`AXI_3P_FULL_FORWARDING=0`.

The default was rerun after adding the late-fault path, with pipeline trace
enabled.  It reproduced 129,010 cycles, 52,547 retirements, IPC 0.4073, final
`a0=0x000000000a277880`, and normal EBREAK termination.  The saved artifacts
are `sim/coremark-loop-3p-bp3-baseline-trace.csv` and
`sim/coremark-loop-3p-bp3-baseline-pipeline.txt`.

The integrated backend test additionally proves that the store retires before
the response, survives an intervening younger flush, and turns a delayed error
into a one-cycle store-access-fault abort with the original address and trace
metadata.  Normal retirement is held during abort delivery.  Both the directed
test and the complete regression pass:

```text
make -B sim-backend-3p
make sim
```

| Configuration                                           | Retired instructions |      Cycles |        IPC |                               Change from narrow 3P |
|---------------------------------------------------------|---------------------:|------------:|-----------:|----------------------------------------------------:|
| ARM gem5 HPI A53-class reference                        |               58,695 |      72,146 |   0.813559 | reference; posted-store 3P uses 1.788x these cycles |
| OpenRV64 1P                                             |               52,547 |     141,804 |     0.3706 |                                                 n/a |
| OpenRV64 3P, narrow forwarding and precise stores       |               52,547 |     136,049 |     0.3862 |                                      prior baseline |
| OpenRV64 3P, full forwarding only                       |               52,547 |     130,963 |     0.4012 |                                          +3.88% IPC |
| OpenRV64 3P, posted store with blanket memory interlock |               52,547 | **129,010** | **0.4073** |                                      **+5.46% IPC** |

Ordered posted stores remove 7,039 cycles, or 5.17% of runtime.  They produce a
larger gain than the complete forwarding network, despite leaving the RAW
behavior almost unchanged.  The posted-store run remains 1.788 times the HPI
reference's cycles.

| Trace counter                        | Narrow 3P | Ordered posted stores |            Delta |
|--------------------------------------|----------:|----------------------:|-----------------:|
| Total cycles                         |   136,049 |               129,010 |  -7,039 (-5.17%) |
| Frontend empty                       |    55,099 |                54,747 |    -352 (-0.64%) |
| Frontend held                        |    40,256 |                33,481 | -6,775 (-16.83%) |
| Dispatch nonempty, no issue          |    65,509 |                58,494 | -7,015 (-10.71%) |
| Queued RAW indication                |    72,141 |                71,101 |  -1,040 (-1.44%) |
| Queued WAW indication                |    35,733 |                35,026 |    -707 (-1.98%) |
| Retire queue nonempty, no retirement |    74,287 |                67,232 |  -7,055 (-9.50%) |
| Branch-predictor stall               |    21,255 |                16,589 | -4,666 (-21.95%) |
| Redirect                             |     7,218 |                 7,218 |                0 |

The same representative loop becomes:

| Instruction        | Narrow issue/complete | Ordered posted-store issue/complete |
|--------------------|----------------------:|------------------------------------:|
| `ld` at `0x49c`    |             410 / 414 |                           359 / 363 |
| `lw` at `0x4a0`    |             412 / 416 |                           361 / 365 |
| `lbu` at `0x4a4`   |             415 / 419 |                           364 / 368 |
| `addiw` at `0x4a8` |             417 / 418 |                           366 / 367 |
| `sw` at `0x4ac`    |             420 / 426 |                           369 / 371 |
| `bnez` at `0x4b0`  |             427 / 428 |                           372 / 373 |

From the first `ld` issue to branch issue, the body contracts from 17 cycles to
13.  Store issue to branch issue contracts from seven cycles to three.  The
branch still waits for the store to reach the head and for request acceptance,
but it no longer waits for the store response.

At 0.9 IPC this RV64I stream needs about 58,386 cycles.  Ordered posted stores
leave 70,624 cycles to remove and close 9.06% of the narrow-3P-to-0.9 cycle
gap.  This is stronger evidence than the forwarding run that store completion
is on the critical path, but it is still not close to sufficient by itself.

### Issue and retirement width

| Width counter              | Prior narrow/precise | Full forwarding only | Current posted-store baseline |
|----------------------------|---------------------:|---------------------:|------------------------------:|
| Zero instructions issued   |               93,953 |               89,347 |                        86,922 |
| One instruction issued     |               31,876 |               30,916 |                        31,868 |
| Two instructions issued    |                9,987 |               10,467 |                         9,979 |
| Three instructions issued  |                  233 |                  233 |                           241 |
| Zero instructions retired  |               94,123 |               89,037 |                        87,084 |
| One instruction retired    |               31,642 |               31,642 |                        31,642 |
| Two instructions retired   |                9,947 |                9,947 |                         9,947 |
| Three instructions retired |                  337 |                  337 |                           337 |

For both experiments, the entire cycle reduction appears as fewer
zero-retirement cycles.  The productive retirement-width distribution is
unchanged.  Full forwarding causes 480 additional two-wide issue cycles but no
additional three-wide issue cycles; posted stores leave the productive issue
distribution almost unchanged.  This is evidence that dependencies are only
one limiter; strict prefix issue and fixed-unit availability still constrain
width.

### Bus and predictor counters

| Counter               | Prior narrow/precise | Full forwarding only | Current posted-store baseline |
|-----------------------|---------------------:|---------------------:|------------------------------:|
| AXI fetch reads       |               39,518 |               38,093 |                        39,134 |
| AXI data reads        |               10,444 |               10,444 |                        10,444 |
| AXI RAM writes        |                3,251 |                3,251 |                         3,251 |
| Predictor allocations |               15,638 |               15,519 |                        15,638 |
| Taken predictions     |                6,467 |                6,364 |                         6,467 |
| Branch resolutions    |               12,691 |               12,691 |                        12,691 |
| Corrections           |                7,218 |                7,218 |                         7,218 |

The workload performs exactly the same number of data reads, writes, branch
resolutions, and corrections.  Forwarding changes scheduling and reduces
some repeated frontend activity; it does not improve branch accuracy.

## Interlock result: non-overlapping loads pass a posted store

The blanket `!store_inflight` request gate was relaxed.  The LSU now retains
the outstanding store's effective address and byte strobes.  A younger load
may launch while the B response is pending if its eight-byte-word address or
byte mask does not overlap the store.  An overlapping load remains blocked,
as do all later stores and serialized atomics.  There is still only one posted
store entry.

This is deliberately smaller than a store buffer.  It does not forward bytes
from a store to an overlapping load, merge stores, or distinguish cacheable
RAM from ordered MMIO.  The comparison is on effective addresses and is safe
for this Bare-mode identity-mapped run; a translated, cacheable implementation
must compare physical addresses after translation.  The existing translated
bus fallback remains serialized, so this optimization is realized only on the
tagged Bare AXI path.

The traced CoreMark-derived run completed normally with the same 52,547 RV64I
retirements and final `a0=0x000000000a277880`:

| Configuration                                    | Retired instructions |      Cycles |        IPC |      Change from preceding 3P baseline |
|--------------------------------------------------|---------------------:|------------:|-----------:|---------------------------------------:|
| ARM gem5 HPI A53-class reference                 |               58,695 |      72,146 |   0.813559 |                    cross-ISA reference |
| OpenRV64 1P                                      |               52,547 |     141,804 |     0.3706 |                                    n/a |
| OpenRV64 3P, precise stores                      |               52,547 |     136,049 |     0.3862 |                                    n/a |
| OpenRV64 3P, posted store with blanket interlock |               52,547 |     129,010 |     0.4073 |                                    n/a |
| **OpenRV64 3P, posted store with load bypass**   |           **52,547** | **122,223** | **0.4299** | **-6,787 cycles (-5.26%); +5.55% IPC** |

This moves 3P to 16.02% higher IPC than the current 1P run and reduces runtime
to 1.694 times the HPI reference's cycles.  Relative to the original 136,049
cycle narrow/precise 3P result, posted completion plus this interlock change
has removed 13,826 cycles.  That closes 17.80% of the cycle gap from that
starting point to 0.9 IPC.  The new run still needs 63,837 cycles removed to
reach the approximately 58,386-cycle 0.9-IPC target.

| Trace counter                        | Blanket interlock | Non-overlap load bypass |            Delta |
|--------------------------------------|------------------:|------------------------:|-----------------:|
| Total cycles                         |           129,010 |                 122,223 |  -6,787 (-5.26%) |
| Frontend empty                       |            54,747 |                  53,451 |  -1,296 (-2.37%) |
| Frontend held                        |            33,481 |                  29,150 | -4,331 (-12.94%) |
| Dispatch nonempty, no issue          |            58,494 |                  54,803 |  -3,691 (-6.31%) |
| Queued RAW indication                |            71,101 |                  67,746 |  -3,355 (-4.72%) |
| Queued WAW indication                |            35,026 |                  33,280 |  -1,746 (-4.99%) |
| Retire queue nonempty, no retirement |            67,232 |                  63,549 |  -3,683 (-5.48%) |
| Branch-predictor stall               |            16,589 |                  14,171 | -2,418 (-14.58%) |
| Redirect                             |             7,218 |                   7,218 |                0 |

The productive issue and retirement width counts are unchanged.  All 6,787
saved cycles disappear from the zero-width buckets: zero-issue cycles fall
from 86,922 to 80,135, and zero-retirement cycles fall from 87,084 to 80,297.
Data reads remain 10,444 and writes remain 3,251.  Fetch reads fall from 39,134
to 37,886, predictor allocations from 15,638 to 15,398, and taken predictions
from 6,467 to 6,419; branch resolutions and corrections remain exactly 12,691
and 7,218.

The representative loop at `0x8000049c` does not become shorter locally:

| Instruction        | Blanket-interlock issue/complete | Load-bypass issue/complete |
|--------------------|---------------------------------:|---------------------------:|
| `ld` at `0x49c`    |                        359 / 363 |                  355 / 359 |
| `lw` at `0x4a0`    |                        361 / 365 |                  357 / 361 |
| `lbu` at `0x4a4`   |                        364 / 368 |                  360 / 364 |
| `addiw` at `0x4a8` |                        366 / 367 |                  362 / 363 |
| `sw` at `0x4ac`    |                        369 / 371 |                  365 / 367 |
| `bnez` at `0x4b0`  |                        372 / 373 |                  368 / 369 |

Both take 13 cycles from the first `ld` issue to branch issue.  The four-cycle
absolute shift was accumulated before this instance.  The overall improvement
therefore accumulates outside that within-body interval--between iterations or
in other store-to-independent-load regions--and through downstream frontend
effects.  It does not shorten this particular loop body once its first load
has issued.

The directed backend test proves that a non-overlapping load can issue,
complete, and retire before the store response while a same-range load remains
blocked.  The 256-bit AXI unit and top-level regressions also pass.  Saved
artifacts are
`sim/coremark-loop-3p-bp3-store-load-bypass-trace.csv` and
`sim/coremark-loop-3p-bp3-store-load-bypass-pipeline.txt`.

## Current baseline: one-entry store-to-load forwarding

The LSU now also retains the posted store's shifted 64-bit write data.  When a
younger load addresses the same eight-byte word and every requested byte is
covered by the store strobes, the load completes locally from that retained
word.  The normal RV64I load datapath performs the byte shift and signed or
unsigned extension.  No AXI read is issued.  A partial overlap still waits for
the store response because correct completion would require merging store bytes
with a memory read.

This is a one-entry bypass, not a general store queue: there is still only one
outstanding posted store, no store merging, and no forwarding search.  A
configurable forwarding window qualifies eligible addresses;
`openrv64_top_3p` sets it to the 16 MiB platform RAM aperture, excluding ROM
and side-effecting MMIO.  The full regression initially caught an unqualified
version swallowing an MMIO read.  The qualified implementation passes that
AXI-to-SoC MMIO traversal test.  A production LSU still needs translated
physical comparison and real PMA/cacheability attributes rather than one range.

The directed backend test writes a nonzero GPR value with `sd`, launches a
same-address `ld` before the store response, proves that no memory request is
generated, and checks that the load retires the stored value.  The test still
checks non-overlapping load bypass and delayed posted-store error delivery.
The complete forced `make -B sim` regression passes, including the 256-bit AXI
RAM and MMIO paths.

CoreMark does not exercise the new bypass while the store response is pending:

| Configuration                             | Retired instructions |      Cycles |        IPC | AXI data reads |
|-------------------------------------------|---------------------:|------------:|-----------:|---------------:|
| Non-overlapping load bypass only          |               52,547 |     122,223 |     0.4299 |         10,444 |
| **Plus covered store-to-load forwarding** |           **52,547** | **122,223** | **0.4299** |     **10,444** |

Every performance, width, AXI, and predictor counter is identical.  The two
raw cycle traces are byte-for-byte identical with SHA-256
`5650072b16dff4f9b85bf79053623d8985a3bb850164e90b8fcb17389f1fec80`.
Thus the measured improvement is exactly zero: this workload has no dynamic
fully-covered store-to-load opportunity inside the one-response window.  The
saved forwarding artifacts are
`sim/coremark-loop-3p-bp3-store-load-forwarding-trace.csv` and
`sim/coremark-loop-3p-bp3-store-load-forwarding-pipeline.txt`.

## Current diagnostic reruns: full forwarding and oracle control flow

Both requested counterfactuals were rerun on the current baseline: posted
store completion, non-overlapping loads passing an outstanding store, and the
qualified one-entry store-to-load forwarding path all remain enabled.  Full
general forwarding was enabled only for the forwarding run.  It was disabled
for the branch-oracle run.

The control-flow oracle is a two-pass simulation jig.  A normal repeat-last
predictor pass records the actual direction and next PC of every control that
resolves on the correct path.  The replay pass feeds those records, in dynamic
order, to the frontend and forces predictor stalls off.  This is materially
different from suppressing redirects: wrong-path instructions never enter the
architectural stream.  The replay consumed all 12,691 resolved-control
records, produced zero correction redirects, and observed three additional
frontend control allocations younger than the terminating `ebreak`; those
never resolved and are not oracle records.

| Counter                     | Current 3P | Full forwarding | Oracle control flow | Oracle + forwarding |
|-----------------------------|-----------:|----------------:|--------------------:|--------------------:|
| Cycles                      |    122,223 |     **117,418** |         **101,167** |          **96,326** |
| Retired instructions        |     52,547 |          52,547 |              52,547 |              52,547 |
| IPC                         |     0.4299 |      **0.4475** |          **0.5194** |          **0.5455** |
| Zero-issue cycles           |     80,135 |          75,802 |              59,071 |              54,702 |
| One-issue cycles            |     31,868 |          30,916 |              31,884 |              30,932 |
| Two-issue cycles            |      9,979 |          10,467 |               9,971 |              10,459 |
| Three-issue cycles          |        241 |             233 |                 241 |                 233 |
| Frontend empty              |     53,451 |          52,464 |              25,732 |              29,149 |
| Frontend held               |     29,150 |          27,102 |              37,402 |              31,024 |
| Dispatch empty              |     25,332 |          25,921 |                 145 |               1,545 |
| Dispatch nonempty, no issue |     54,803 |          49,881 |              58,926 |              53,157 |
| Queued RAW indication       |     67,746 |          49,406 |              77,017 |              58,300 |
| Queued WAW indication       |     33,280 |          32,416 |              45,633 |              45,162 |
| Retire wait                 |     63,549 |          58,228 |              57,242 |              51,937 |
| BP stall                    |     14,171 |          13,363 |               **0** |               **0** |
| Correction redirect         |      7,218 |           7,218 |               **0** |               **0** |
| AXI fetch reads             |     37,886 |          36,667 |              23,059 |              22,379 |
| AXI data reads              |     10,444 |          10,444 |              10,444 |              10,444 |

Full forwarding removes 18,340 cycles carrying a RAW indication but only
4,805 total cycles.  The flags overlap and many RAW-held cycles are hidden
under other dependencies or retirement constraints, so the RAW count must not
be read as an additive cycle budget.  It modestly converts 952 one-issue
cycles into 488 more two-issue cycles while reducing idle issue cycles by
4,333.

The oracle result is more diagnostic.  Relative to baseline it removes 21,064
zero-issue cycles, while the counts of one-, two-, and three-wide issue are
almost unchanged.  Dispatch-empty time collapses from 25,332 cycles to 145,
but frontend-held time rises and the queue reports RAW on 76.13% and no issue
on 58.25% of the shorter run.  Perfect control flow therefore cures a large
frontend starvation component, then exposes the backend dependency and
ordered-head limits.  It does not make this implementation sustain wide issue.

Saved artifacts are:

- `sim/coremark-loop-3p-bp3-posted-full-forward-trace.csv` and
  `sim/coremark-loop-3p-bp3-posted-full-forward-pipeline.txt`;
- `sim/coremark-loop-3p-bp3-branch-oracle-trace.csv` and
  `sim/coremark-loop-3p-bp3-branch-oracle-pipeline.txt`;
- `sim/coremark-loop-3p-oracle-full-forward-trace.csv` and
  `sim/coremark-loop-3p-oracle-full-forward-pipeline.txt`;
- `sim/coremark-loop-branch-oracle.memh`, containing the 12,691 replay
  records.

The matched HPI/OpenRV64 100-instruction comparison, including a complete
cycle-by-cycle backend schedule, is in
`doc/experiments/hpi-openrv64-100-instructions.md`.

## A53-class HPI comparison

The saved HPI timing reference reports:

| HPI statistic                  |    Value |
|--------------------------------|---------:|
| Cycles                         |   72,146 |
| Committed AArch64 instructions |   58,695 |
| IPC                            | 0.813559 |
| Fetched instructions           |   72,934 |
| Committed branches             |   18,642 |
| Branch mispredictions          |    1,508 |
| Branch misprediction rate      |    8.09% |
| L1I demand misses              |       20 |
| L1D demand misses              |       14 |

The current load-bypass OpenRV64 baseline still takes 50,077 more cycles.
Stated in the useful direction, it takes 1.694 times the HPI reference's cycles
for the same source workload.  HPI's IPC is 1.89 times the OpenRV64 IPC,
despite HPI committing 11.7% more architectural instructions.  The older
full-forwarding-only result takes 1.815 times HPI's cycles.

The combined oracle-plus-forwarding run takes 24,180 more cycles than HPI,
or 1.335 times HPI's runtime.  It remains 37,940 cycles above the 0.9-IPC
target.  These are different gaps: the latter is the “almost 40k cycles” gap.

The branch figures are not strictly apples-to-apples because the ISAs and
dynamic branch streams differ, but the scale is still diagnostic.  OpenRV64
records 7,218 corrections across 12,691 resolutions, a 56.9% correction to
resolution ratio, and full forwarding changes neither number.  HPI combines a
BTB, indirect prediction, return-address stack, and local/global conditional
prediction; OpenRV64's repeat-last predictor does not separate unrelated
branch histories.  HPI also has an LSQ/store buffer and resolves ordinary
dependencies before architectural commit.  These are much larger differences
than the completed-result bypass fixed by this experiment.

An OpenRV64 result of 0.9 IPC would take approximately 58,386 cycles for its
52,547-instruction RV64I stream, 19.1% fewer cycles than HPI takes for the same
C workload.  Thus 0.9 remains a meaningful aggressive goal; reaching it
requires more than matching HPI's reported IPC because OpenRV64 also executes
fewer architectural instructions here.

## Representative hot loop

The important sequence in `scan_input` is:

```asm
80000498: add  a0,s2,a0
8000049c: ld   a4,8(sp)
800004a0: lw   a5,0(a0)
800004a4: lbu  a4,0(a4)
800004a8: addiw a5,a5,1
800004ac: sw   a5,0(a0)
800004b0: bnez a4,80000480
```

One representative traced iteration was:

| Instruction        | Narrow issue/complete | Full issue/complete |
|--------------------|----------------------:|--------------------:|
| `ld` at `0x49c`    |             410 / 414 |           402 / 406 |
| `lw` at `0x4a0`    |             412 / 416 |           403 / 407 |
| `lbu` at `0x4a4`   |             415 / 419 |           407 / 411 |
| `addiw` at `0x4a8` |             417 / 418 |           408 / 409 |
| `sw` at `0x4ac`    |             420 / 426 |           409 / 417 |
| `bnez` at `0x4b0`  |             427 / 428 |           418 / 419 |

The absolute cycle shift includes savings accumulated in preceding work.  From
the first `ld` issue to the branch issue, the local body contracts from 17
cycles to 16 cycles.

The `lw` benefits directly: it can consume the ALU-generated `a0` on the
producer's completion cycle instead of waiting for retirement.  The dependent
`lbu` cannot run before the `ld` data exists, so forwarding cannot remove its
true load latency.  The store then remains ordered and waits for its response;
the branch is classified as ordered control and cannot resolve until it
becomes the ordered head.  Those constraints dominate the loop after the RAW
bypass improves.

## Distance from 0.9 IPC

At 0.9 IPC, 52,547 retired instructions require approximately 58,386 cycles.
The current baseline is 63,837 cycles above that target.  Current-baseline
full forwarding leaves 59,032 cycles to remove and closes 7.53% of the gap.
Oracle control flow leaves 42,781 cycles and closes 32.98% of the gap.  Even
perfect prediction therefore reaches only 0.5194 IPC, not anything close to
0.9.

Combining oracle control flow with full forwarding leaves 37,940 cycles to
remove and closes 40.56% of the original baseline-to-0.9 gap.  The matched
trace comparison shows why it stalls at 0.5455: the dispatch queue remains
nonempty but issues nothing for over half the run, dominated by unresolved
producer latency, WAW ownership held to retirement, strict-prefix issue, and
retirement backpressure.

The next material mechanisms are therefore not more forwarding coverage:

1. Resolve ordinary branches speculatively before the retirement head while
   preserving age-correct recovery and precise exceptions.
2. Add a store buffer so a correctly checked store does not hold younger work
   through the complete external request/response sequence.
3. Revisit the remaining WAW ownership stalls only after branch/store
   serialization is measured; doing so requires versioned ownership or
   renaming rather than another data bypass.
4. Continue reducing load-use latency and frontend refill bubbles, neither of
   which can be forwarded away before the value or instruction exists.

## Physical implementation warning

The experimental network materializes a 32-entry by 64-bit architectural
result map and places a forwarded-value selection in front of six issue
operands.  That is convenient for simulation but is not a recommended physical
crossbar.  It may reduce Fmax by more than the measured 4.09% IPC gain on the
current baseline.

A production version should use explicit producer `{valid, rd, data}` buses
from the current completions plus a small completed-result buffer or CAM.  It
still requires up to six tag-compare and data-select paths, so synthesis and
placed/routed timing must decide whether same-cycle completion-to-dispatch
forwarding is viable.  At fixed clock on the current baseline, the experiment
predicts 0.4475 IPC.  Without timing closure, it does not establish a net
instructions-per-second improvement.

## Reproduction

Build and run the narrow-forwarding reference:

```sh
make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-loop-256.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    AXI_3P_PERF_ARGS= \
    AXI_3P_PERF_BP_TYPE=3 \
    AXI_3P_FULL_FORWARDING=0 \
    AXI_3P_TRACE_CSV=sim/coremark-loop-3p-bp3-full-forward-off-trace.csv \
    AXI_3P_TRACE_REPORT=sim/coremark-loop-3p-bp3-full-forward-off-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS='--around-pc 80000518'
```

Run the full-forwarding experiment:

```sh
make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-loop-256.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    AXI_3P_PERF_ARGS= \
    AXI_3P_PERF_BP_TYPE=3 \
    AXI_3P_FULL_FORWARDING=1 \
    AXI_3P_TRACE_CSV=sim/coremark-loop-3p-bp3-full-forward-on-trace.csv \
    AXI_3P_TRACE_REPORT=sim/coremark-loop-3p-bp3-full-forward-on-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS='--around-pc 80000518'
```

The saved readable reports are:

- `sim/coremark-loop-3p-bp3-full-forward-off-pipeline.txt`;
- `sim/coremark-loop-3p-bp3-full-forward-on-pipeline.txt`;
- `sim/coremark-loop-3p-bp3-full-forward-off-hot-loop.txt`;
- `sim/coremark-loop-3p-bp3-full-forward-on-hot-loop.txt`.

### Current-baseline reruns

The current full-forwarding result was produced with:

```sh
make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-loop-256.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    AXI_3P_PERF_ARGS=+expect_a0=000000000a277880 \
    AXI_3P_FULL_FORWARDING=1 \
    AXI_3P_TRACE_CSV=sim/coremark-loop-3p-bp3-posted-full-forward-trace.csv \
    AXI_3P_TRACE_REPORT=sim/coremark-loop-3p-bp3-posted-full-forward-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS=--around-pc=8000049c
```

Generate the correct-path oracle from a normal baseline pass:

```sh
make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-loop-256.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    'AXI_3P_PERF_ARGS=+expect_a0=000000000a277880 +branch_oracle_dump=sim/coremark-loop-branch-oracle.memh' \
    AXI_3P_FULL_FORWARDING=0 \
    AXI_3P_ORACLE_BRANCHES=0 \
    AXI_3P_TRACE_CSV=sim/coremark-loop-3p-bp3-oracle-capture-trace.csv \
    AXI_3P_TRACE_REPORT=sim/coremark-loop-3p-bp3-oracle-capture-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS=--around-pc=8000049c
```

Then replay the 12,691 captured records:

```sh
make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-loop-256.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    'AXI_3P_PERF_ARGS=+expect_a0=000000000a277880 +branch_oracle_load=sim/coremark-loop-branch-oracle.memh +branch_oracle_count=12691' \
    AXI_3P_FULL_FORWARDING=0 \
    AXI_3P_ORACLE_BRANCHES=1 \
    AXI_3P_TRACE_CSV=sim/coremark-loop-3p-bp3-branch-oracle-trace.csv \
    AXI_3P_TRACE_REPORT=sim/coremark-loop-3p-bp3-branch-oracle-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS=--around-pc=8000049c
```

Replay the same oracle with full forwarding enabled:

```sh
make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-loop-256.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    'AXI_3P_PERF_ARGS=+expect_a0=000000000a277880 +branch_oracle_load=sim/coremark-loop-branch-oracle.memh +branch_oracle_count=12691' \
    AXI_3P_FULL_FORWARDING=1 \
    AXI_3P_ORACLE_BRANCHES=1 \
    AXI_3P_TRACE_CSV=sim/coremark-loop-3p-oracle-full-forward-trace.csv \
    AXI_3P_TRACE_REPORT=sim/coremark-loop-3p-oracle-full-forward-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS=--around-pc=8000049c
```

Regenerate the matched 100-instruction HPI comparison:

```sh
python3 tools/compare_coremark_pipelines.py \
    --orv-trace sim/coremark-loop-3p-oracle-full-forward-trace.csv \
    --hpi-trace /tmp/openrv64-a53-minor-execute.log \
    --occurrence 54 \
    --count 100 \
    --output doc/experiments/hpi-openrv64-100-instructions.md
```
