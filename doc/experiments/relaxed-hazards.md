# Aggressively relaxed hazard experiment

Date: 2026-07-19

## Result

The conservative multiple-writer/read-port hazard area costs **2,251 cycles**, or
**2.58%**, on the annotated `-O2` CoreMark-derived workload.  Removing it raises
3P IPC from **0.6026** to **0.6186**.  This is measurable, but it is not the main
remaining performance deficit.

| Core/configuration                  | ISA instructions |     Cycles |        IPC |              Versus 3P baseline |
|-------------------------------------|-----------------:|-----------:|-----------:|--------------------------------:|
| OpenRV64 1P, BTFNT + RAS8           |           52,547 |    131,801 |     0.3987 |                  +44,599 cycles |
| OpenRV64 3P baseline                |           52,547 |     87,202 |     0.6026 |                       reference |
| **OpenRV64 3P, aggressive hazards** |       **52,547** | **84,951** | **0.6186** |             **-2,251 (-2.58%)** |
| gem5 HPI A53-class proxy            |           58,695 |     71,443 |   0.821564 | -13,508 cycles vs aggressive 3P |

All OpenRV64 rows use BTFNT, an eight-entry RAS, eight retirement entries,
full forwarding, relaxed WAW, posted stores, the same annotated `-O2` RV64
binary, and the 256-bit AXI/16 MiB RAM testbench.  The aggressive run halted
normally with `a0=0x000000000a277880`.

HPI is a cross-ISA A53-class proxy, not Cortex-A53 silicon.  Its IPC is not an
apples-to-apples instruction-efficiency comparison because the AArch64 binary
retires 6,148 more instructions.  The same-work cycle count is the useful
comparison.  Aggressive hazard handling closes 2,251 of the baseline's 15,759
cycle gap to HPI, or 14.3% of that gap.

## What “barely viable” means here

`RELAX_HAZARDS=1` is a functional upper-bound mode, not a proposed low-cost
implementation.  It makes three changes:

1. A 64-bit allocation ID identifies the youngest live producer of each
   architectural register.  The backend also retains a ready bit and its
   64-bit result.
2. A completion may satisfy a consumer only when its ID matches that youngest
   producer.  Completion from an older WAW producer is ignored.  Retirement
   clears ownership only when the retiring ID still owns the register.
3. The synthetic `MAX_READS_PER_REG` restriction is disabled.

This is 32 entries of producer identity and result state, plus matching and
operand-selection logic.  It is closer to a tiny result/rename table than a
two-wire bypass.  It is intentionally generous enough to determine whether
conservative ownership is hiding a large win.

The experiment does **not** ignore true hazards.  A consumer still waits when
the youngest producer has not completed.  A dependency on an instruction in
the same issue bundle still waits because there is no combinational ALU chain.
Issue is still a strict program-order prefix, so a blocked oldest instruction
still prevents ready younger instructions from issuing around it.  Ignoring
those rules would produce a wrong checksum rather than a performance bound.

## Trace comparison

The following buckets are exclusive classifications of the first non-issued
candidate.  Removing one block can expose a different block in the same cycle,
so the bucket deltas do not add up to the total cycle delta.

| Trace counter                 | Baseline | Aggressive |      Delta |
|-------------------------------|---------:|-----------:|-----------:|
| Cycles                        |   87,202 |     84,951 | **-2,251** |
| No instruction issued         |   49,994 |     46,943 |     -3,051 |
| Completed-result RAW block    |    4,801 |          0 |     -4,801 |
| Read-port block               |      128 |          0 |       -128 |
| Pending-result RAW block      |   25,353 |     26,969 |     +1,616 |
| Same-bundle RAW block         |   16,092 |     15,996 |        -96 |
| Barrier block                 |   11,382 |     11,214 |       -168 |
| Pipe conflict                 |    4,477 |      4,661 |       +184 |
| Pipe busy                     |    5,089 |      5,113 |        +24 |
| Retirement head incomplete    |   39,631 |     36,670 | **-2,961** |
| Completed entries behind head |   17,840 |     18,624 |       +784 |
| Frontend held                 |   24,342 |     23,123 |     -1,219 |
| Frontend empty                |   23,760 |     23,976 |       +216 |
| LSU outstanding               |   31,450 |     30,714 |       -736 |
| LSU order block               |    2,641 |      4,097 |     +1,456 |

The 4,801 completed-result blocks disappearing but only 2,251 total cycles
being saved is the useful conclusion.  Most removed stalls uncover an
unfinished producer, a same-bundle dependency, a unit/order constraint, or a
frontend bubble.  The increase in `raw_pending` is therefore a classification
shift, not evidence that producer latency became worse.

The synthetic read-port restriction accounts for only 128 first-block cycles
in the baseline.  This combined A/B run cannot assign an exact exclusive share
of the 2,251-cycle gain to it, but it plainly cannot explain most of the win.
The important part is selecting a completed youngest WAW producer safely.

## Correctness failure found by the experiment

The first full run was invalid: it reached only 149 architectural retirements,
redirected to address zero, and timed out at 250,000 cycles.  The producer ID
table itself selected the right completion.  A downstream operand mux then
applied an older rule that unconditionally gave a same-cycle retiring value
priority over the completion map.

The failing sequence was:

```asm
srli    a0,a5,30       # older a0 = 0x10, retiring
add     a0,s2,a0       # younger a0 = 0x8000ff90, completing
ld      a4,8(sp)
lw      a5,0(a0)       # must use the younger a0
```

The bad run issued the `lw` at address `0x10`.  The corrected run's trace shows
the same instruction issuing at `0x8000ff90`.  In aggressive mode, a valid
youngest-producer result now wins over an older retirement; the conservative
mode retains retirement priority because its rd-indexed completion map cannot
otherwise disambiguate WAW producers.

The integrated backend regression also holds retirement behind an unresolved
load, completes two writers to `x15`, and checks that a consumer issues from the
younger writer (`2`, yielding `x16=3`) before the load response arrives.

## Reproduction and artifacts

The aggressive mode is selected by `AXI_3P_RELAX_HAZARDS=1`.  A reproducible
run must name the CoreMark ELF as well as its derived image when using `-B`:

```text
make -B sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sw/coremark-loop.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    AXI_3P_PERF_ARGS=+expect_a0=000000000a277880 \
    AXI_3P_PERF_BP_TYPE=4 AXI_3P_BP_RAS_ENABLE=1 \
    AXI_3P_PERF_BP_RAS_DEPTH=8 AXI_3P_FULL_FORWARDING=1 \
    AXI_3P_RELAX_WAW=1 AXI_3P_RELAX_HAZARDS=1
```

Saved readable reports:

- baseline: `sim/hazard-relax/baseline-pipeline.txt`
- aggressive: `sim/hazard-relax/aggressive-fixed-pipeline.txt`

Saved raw traces:

- baseline: `sim/top-axi-3p-trace.csv`
- aggressive: `sim/hazard-relax/aggressive-fixed-trace.csv`
- intentionally retained failed run for the mux-priority diagnosis:
  `sim/hazard-relax/aggressive-trace.csv`
