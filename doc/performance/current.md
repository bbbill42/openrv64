# Current performance baseline

Date: 2026-07-26

This document records the best-known configuration currently used for the
CoreMark-derived loop and 64 KiB STREAM experiments. "Best-known" describes
the selected knobs; it does not mean the resulting performance is good or
globally optimal. No exhaustive parameter sweep was performed.

These are cycle-model results, not frequency measurements. The CoreMark
workload is the finite branch-heavy loop in `sw/coremark_loop.c`, not the full
CoreMark suite, and it does not produce a valid CoreMark/MHz score.

## Configuration

The main configuration is BP8, the fetch carousel, confidence gate zero, the
issue/speculation window enabled, and retirement depth 16. The bare CoreMark
run replaces the cache/DDR3 hierarchy with one-cycle instruction/data SRAM.
The SoC CoreMark and all STREAM runs use Sv39 and the full
L1I/L1D -> CCX -> L2 -> AXI -> banked-DDR3 path.

| Area                               | Setting                                                     |
|------------------------------------|-------------------------------------------------------------|
| Direction/target predictor         | `BP_TYPE=8`, BTB256, RAS8                                   |
| Fetch mode                         | alternate lookaside mode 3                                  |
| Fetch carousel                     | enabled (`FETCH_CAROUSEL=1`)                                |
| Fetch confidence gate              | disabled (`CONFIDENCE_GATE=0`, or `fc0`)                    |
| Lookaside pair-stack depth         | 2                                                           |
| Completion forwarding              | mask 0                                                      |
| Branch forwarding                  | mask 1                                                      |
| Full forwarding                    | disabled                                                    |
| WAW relaxation                     | enabled (`RELAX_WAW=1`)                                     |
| General hazard relaxation          | disabled                                                    |
| Issue window                       | enabled (`ISSUE_WINDOW=1`)                                  |
| Speculation                        | enabled (`SPECULATION_WINDOW=16`)                           |
| Issue-window depth                 | tied to retirement depth: 16 entries                        |
| Retirement depth                   | 16 (`rd16`)                                                 |
| Physical registers                 | 31                                                          |
| Posted stores                      | enabled                                                     |
| L1I / L1D                          | 16 KiB / 16 KiB                                             |
| L2                                 | 256 KiB, 8-way, 8 merge entries                             |
| Shared L2 TLB                      | 256 entries, 4-way                                          |
| GenBus read/write buffering        | 4 / 4                                                       |
| L1D prefetch                       | enabled, 2 streams, initial distance 1                      |
| Adaptive prefetch                  | enabled, maximum distance 4                                 |
| Prefetch queue/outstanding/reserve | 4 / 4 / 2                                                   |
| DDR3 queues                        | 8 read / 8 write / 16 command                               |
| Memory timing model                | 0, banked DDR3 enabled                                      |
| Backing RAM                        | 16 MiB                                                      |
| Sv39 speculative-load aperture     | base `0x40000000`; 128 KiB for CoreMark, 256 KiB for STREAM |

`ISSUE_WINDOW` and `SPECULATION_WINDOW` are enable controls in the RTL; the
actual issue-window depth is `RETIRE_DEPTH`. Any nonzero speculation value
enables the same mechanism. The value 16 is retained in the build tag and
performance report to identify the requested configuration.

The repository build tag calls WAW relaxation `rw1`. Retirement depth is
`rd16`; referring to this configuration as `rw16` is ambiguous and does not
match the Make variable names.

## Results

### CoreMark-derived loop

| Environment                                   |     Cycles | Retired |        IPC |
|-----------------------------------------------|-----------:|--------:|-----------:|
| One-cycle magic SRAM, bare physical addresses | **48,652** |  52,547 | **1.0801** |
| 3P SoC, Sv39 and banked DDR3                  | **56,146** |  52,570 | **0.9363** |

The SoC costs 7,494 cycles, or 15.4% relative to the magic-SRAM run. It also
retires 23 Sv39 bootstrap instructions, so this is close but not a perfectly
identical instruction-stream comparison.

### STREAM

STREAM's "kernel cycles" are measured by the workload between its cycle
counter reads. "Stop cycles" and IPC are the harness totals through
`stream_measure_end`, including 536 or 537 cycles of Sv39 boot and setup.
Payload rate counts one read plus one write for copy/scale, and two reads plus
one write for add/triad.

| Workload     | Kernel cycles | Stop cycles | Retired |    IPC | Payload |   Payload rate |
|--------------|--------------:|------------:|--------:|-------:|--------:|---------------:|
| STREAM copy  |    **38,539** |      39,075 |  20,522 | 0.5252 | 128 KiB | 3.4010 B/cycle |
| STREAM scale |    **38,788** |      39,324 |  41,002 | 1.0427 | 128 KiB | 3.3792 B/cycle |
| STREAM add   |    **92,142** |      92,679 |  43,052 | 0.4645 | 192 KiB | 2.1338 B/cycle |
| STREAM triad |    **92,333** |      92,870 |  59,436 | 0.6400 | 192 KiB | 2.1293 B/cycle |

At 1 GHz, B/cycle has the same numeric value as GB/s. This is only a scaling
identity; these simulations do not establish a 1 GHz implementation.

## RD16 effect

RD16 is materially better than RD8 for CoreMark and scale. It does not repair
the two-input STREAM kernels.

| Workload           | RD8 cycles | RD16 cycles |      RD16 delta |
|--------------------|-----------:|------------:|----------------:|
| CoreMark, Sv39 SoC |     65,670 |      56,146 | -9,524 (-14.5%) |
| STREAM copy        |     38,792 |      38,539 |    -253 (-0.7%) |
| STREAM scale       |     44,904 |      38,788 | -6,116 (-13.6%) |
| STREAM add         |     92,664 |      92,142 |    -522 (-0.6%) |
| STREAM triad       |     92,236 |      92,333 |     +97 (+0.1%) |

This is why RD16 is now the project default. When the issue window is enabled,
changing retirement depth also changes issue-window capacity.

## RD32 experiment

RD32 was rerun with every other reported control unchanged: BP8, mode 3,
carousel 1, confidence gate 0, pair stack 2, issue window enabled,
speculation value 16, posted stores, two adaptive prefetch streams, Sv39, and
banked DDR3. RD32 improves CoreMark modestly but does not improve STREAM as a
class.

| Workload             | RD16 cycles | RD32 cycles |     RD32 delta |  RD32 IPC/rate |
|----------------------|------------:|------------:|---------------:|---------------:|
| CoreMark, magic SRAM |      48,652 |  **47,588** | -1,064 (-2.2%) |     1.1042 IPC |
| CoreMark, Sv39 SoC   |      56,146 |  **55,398** |   -748 (-1.3%) |     0.9490 IPC |
| STREAM copy, kernel  |      38,539 |  **38,533** |    -6 (-0.02%) | 3.4016 B/cycle |
| STREAM scale, kernel |      38,788 |  **38,782** |    -6 (-0.02%) | 3.3797 B/cycle |
| STREAM add, kernel   |      92,142 |  **92,279** |  +137 (+0.15%) | 2.1306 B/cycle |
| STREAM triad, kernel |      92,333 |  **92,256** |   -77 (-0.08%) | 2.1311 B/cycle |

RD32 STREAM stop cycles were 39,053, 39,302, 92,800, and 92,777 for
copy, scale, add, and triad respectively. Separate full-result runs of all
four kernels passed with `STREAMOK`, Sv39 active, and the DDR3-overlap
assertion.

The CoreMark gain is not a clean frontend or prediction improvement. Relative
to RD16, the RD32 SoC run reduces dispatch-nonempty/no-issue cycles from
20,546 to 19,932 and retirement-head-incomplete cycles from 21,883 to 21,505.
However, frontend-empty cycles increase from 25,855 to 26,488, direction
corrections increase from 789 to 857, and the RAS changes from 780/780/0/0 to
888/824/64/0 (lookups/hits/misses/wrong targets). The magic run shows the same
direction: 927 direction corrections and 144 RAS misses at RD32, versus 732
and zero at RD16. RD32 therefore exposes more speculative control-flow
pressure even while its larger window reduces total runtime.

The STREAM changes are below 0.2% and non-monotonic. In particular, add gets
slower even though its late/dropped prefetch counters fall from 1,431/585 to
1,301/513. That is further evidence that retirement-window capacity is not
the limiting resource for the two-input kernels. RD16 remains the default;
the small workload-dependent RD32 gain has not been weighed against its
additional state and implementation cost.

## Remaining holes

### Two-input STREAM is not fixed end to end

The two-stream prefetch implementation is present and active. Add and triad
issue about twice as many prefetches as copy, which is the expected signature
for tracking both input arrays:

| Counter                         |   Copy |    Add |  Triad |
|---------------------------------|-------:|-------:|-------:|
| Kernel cycles                   | 38,539 | 92,142 | 92,333 |
| L1D line reads                  |  1,028 |  2,061 |  2,060 |
| L1D line writes                 |  1,024 |  1,024 |  1,024 |
| DDR commands                    |  2,065 |  3,094 |  3,094 |
| Prefetch issued                 |  1,027 |  2,059 |  2,058 |
| Prefetch late                   |    311 |  1,431 |  1,329 |
| Prefetch dropped                |      0 |    585 |    586 |
| Retirement head incomplete      | 24,007 | 67,621 | 61,601 |
| Load at retirement head         | 13,238 | 56,539 | 50,504 |
| Memory access in flight at head | 22,416 | 64,712 | 58,502 |

Detection is therefore fixed; throughput is not. Add and triad still sustain
only about 2.13 B/cycle, 37% below copy. The current backend has a four-entry
load queue, and the unified LSQ exposes one translation/L1D launch port. The
assembly issues four loads from A followed by four loads from B. Four A loads
can occupy the entire load queue before the B group enters, so the demand side
cannot keep both groups live together when the prefetched lines are late.

The high late/drop counts confirm that prefetch timeliness is not hiding this
limit. Increasing retirement/issue-window capacity from 8 to 16 barely moves
add and triad because the load queue and single L1D launch port remain
unchanged. The next controlled experiment should enlarge the load queue to at
least eight entries before adding a second physical cache port; that separates
queue-capacity failure from true single-port bandwidth failure.

### CoreMark still has frontend and backend loss

The RD16 SoC run reaches 0.9363 IPC, but remains 7,494 cycles behind the
one-cycle-SRAM result. Its major non-exclusive counters are:

| Counter                                       | Cycles | Fraction of SoC run |
|-----------------------------------------------|-------:|--------------------:|
| Frontend empty                                | 25,855 |               46.1% |
| Fetch refill wait                             | 24,048 |               42.8% |
| Retirement queue nonempty, no retirement      | 21,883 |               39.0% |
| Dispatch nonempty, no issue                   | 20,546 |               36.6% |
| Window RAW-stall cycles                       | 10,982 |               19.6% |
| Completed instructions behind retirement head | 11,208 |               20.0% |

The memory hierarchy itself reports only 68 cycles of explicit DDR read-timing
blockage. Likewise, only 827 frontend-empty cycles coincide with an external
L1I miss, while 23,607 are pending with no external miss. Treating
`refill_wait=24048` as time blocked on DDR3 reads would be wrong. The
frontend's pending/carousel/refill handoff remains a distinct hole.

Target prediction is not the remaining control-flow problem: the SoC run has
zero target corrections, BTB 737/734/3/0 and RAS 780/780/0/0
(lookups/hits/misses/wrong targets). It still has 789 direction corrections.

The SoC memory details are six PTW reads, 42 DDR read bursts, four write
bursts, 46 total DDR commands, and 68 explicit read-timing wait cycles.
Instruction and data aliases were verified under supervisor-mode Sv39.

## RD16 default

Retirement depth now defaults to 16 consistently in the 3P backend/core/top
hierarchy, platform wrapper, magic/SoC/AXI testbenches, and the corresponding
Make configurations. STREAM, pointer-chase, and the OpenSBI 3P platform
already selected 16 explicitly. Tests may still override the parameter for
directed depth-specific coverage.

## Validation and provenance

Both CoreMark environments completed with
`a0=0x000000000a277880`. Separate RD16 full-result runs of all four STREAM
kernels completed with `a0=0x53545245414d4f4b` (`STREAMOK`). Every SoC run
reported Sv39 active and passed the banked-DDR3 overlap assertion.

The worktree was dirty, so the commit alone is not sufficient provenance.
The hashes below identify the explicitly configured RD16 measurement
snapshot. The later RD16 default-only patch changed parameter-initializer
hashes in the hierarchy and testbenches, but not the explicitly elaborated
behavior used for these measurements. `sim-backend-3p` and `sim-top-3p` pass
after that patch.

```text
commit 78dd1823c990c2bf184cf0dc38b0fd78d4e43309
94553e822417b8229f7350a6a9893829f0fbe9704044ec36f7e53f5e970e2fa0  rtl/core/fetch/fetch_3w.v
aeb0c0be2abea924fa48f2acfe8a1acc5f746eae488387234381faabd5d5f1d3  rtl/core/rv64_top_3p.v
6f8efc770442d42e29059f809981c523589ac650d410f774201ab8955a1b8e96  rtl/core/cache/l1/l1d/l1d.v
0ca06acde412571ce85ed97492d8ca334c5b641af381a19a504f7f14c6518476  tb/tb_top_3p_soc.v
25587cab1a0e73b3db20898a3a19914b04545b17c516e30a09f3bdde6d2fd68b  sw/coremark_loop.c
b40da41e47aeeb9f459cf5d120ad3d6426bcdc7dd034fffc6b6c0173bc1cec73  sw/stream/stream.S
```

The accepted CoreMark SoC run used `sim-core-3p-ccx-l2` directly. The
`sim-core-3p-ccx-l2-vm` wrapper hard-codes retirement depth 16 and a nonzero
speculation enable, so it is behaviorally equivalent for those controls but
reports `speculation_window=1` rather than the requested build tag value 16.
