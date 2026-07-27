# CoreMark-derived compiler scheduling

Date: 2026-07-19

## Result

The useful compiler change is alias information, not a generic scheduling
tune.  `state_transition()` now states that its volatile input stream and
transition-counter array are disjoint.  GCC can consequently place a byte load
and pointer update between a counter load and its dependent increment/store.

With the normal BTFNT + RAS8 configuration, eight retirement entries, full
forwarding, relaxed WAW, and posted stores, the canonical `-O2` RV64 run is:

| Configuration                  | Instructions |     Cycles |        IPC |         Cycle delta |
|--------------------------------|-------------:|-----------:|-----------:|--------------------:|
| Original `-O2` source          |       52,547 |     91,216 |     0.5761 |           reference |
| `-O2` plus truthful `restrict` |       52,547 | **87,202** | **0.6026** | **-4,014 (-4.40%)** |
| `-O3` plus truthful `restrict` |       51,923 | **85,925** | **0.6043** | **-5,291 (-5.80%)** |

All three rows use the same work and expected checksum.  The annotated runs
halt with `a0=0x000000000a277880`.  `-O3` saves a further 1,277 cycles over the
annotated `-O2` binary, primarily by executing 624 fewer instructions; it only
moves IPC from 0.6026 to 0.6043.  `-O2` remains the default so the architectural
comparison is not silently changed by an optimizer-level change.

The same binaries were also run on 1P with BTFNT + RAS8 and a full cycle trace:

| 1P configuration               | Instructions |  Cycles |    IPC |     Cycle delta |
|--------------------------------|-------------:|--------:|-------:|----------------:|
| Original `-O2` source          |       52,547 | 132,438 | 0.3968 |       reference |
| `-O2` plus truthful `restrict` |       52,547 | 131,801 | 0.3987 |   -637 (-0.48%) |
| `-O3` plus truthful `restrict` |       51,923 | 130,033 | 0.3993 | -2,405 (-1.82%) |

The alias annotation saves only 0.48% on the single pipeline, versus 4.40% on
3P.  This supports the mechanism: the annotation exposes independent work, but
1P has no second issue lane with which to overlap it.

## The source-level contract

The only persistent source change is:

```c
state_transition(const volatile uint8_t **input,
                 uint32_t *restrict transition_count)
{
    const volatile uint8_t *restrict cursor = *input;
```

This is valid for the benchmark: `input` addresses the local cursor variable,
the cursor points into the immutable parser input, and `transition_count`
points to a separate local counter array.

Before the annotation, a representative counter update is ordered as:

```asm
lw      counter
addiw   counter,1
sw      counter
lbu     next_byte
addi    cursor,1
```

After the annotation GCC emits:

```asm
lw      counter
lbu     next_byte
addi    cursor,1
addiw   counter,1
sw      counter
```

The volatile byte accesses remain ordered with respect to each other.  GCC is
only allowed to move the non-aliasing counter work around them.  This fills a
real load-use gap without changing the algorithm or hand-writing assembly.

## Generic scheduling was hostile to strict-prefix issue

The head-of-line issuer changes what “latency hiding” means.  Moving a memory
operation earlier can put it at the oldest queue position; if it then waits for
the MEM pipe or a source operand, younger ready ALU work cannot issue around it.
That failure is visible in the measured variants:

| RV64 compiler variant, original source | Instructions | Cycles |    IPC |  Versus baseline |
|----------------------------------------|-------------:|-------:|-------:|-----------------:|
| GCC `-O2` default tune                 |       52,547 | 91,216 | 0.5761 |        reference |
| `-mtune=generic-ooo`                   |       52,547 | 93,307 | 0.5632 |    +2.29% cycles |
| `-mtune=sifive-7-series`               |       52,419 | 96,319 | 0.5442 |    +5.59% cycles |
| selective scheduling passes            |       51,891 | 91,261 | 0.5686 | effectively flat |
| `-O3`, without alias annotation        |       51,923 | 90,327 | 0.5748 |    -0.97% cycles |

The scheduling target for the current core is therefore not “start every load
as early as possible.”  It is “avoid putting an unready operation at the oldest
position, and place independent ALU/address work between a load and its use.”
The alias annotation succeeds because it exposes exactly such local independent
work.  It cannot hide the opening pointer-load to byte-load chain because that
basic block has no independent operation to move into the gap.

## Fair HPI comparison

Because `sw/coremark_loop.c` is shared, the HPI proxy was rebuilt with the same
annotation and matching optimization levels.

| Optimization       | Core        | Instructions | Cycles |      IPC | OpenRV64 cycle gap |
|--------------------|-------------|-------------:|-------:|---------:|-------------------:|
| `-O2` + `restrict` | OpenRV64 3P |       52,547 | 87,202 |   0.6026 |  +15,759 (+22.06%) |
| `-O2` + `restrict` | gem5 HPI    |       58,695 | 71,443 | 0.821564 |          reference |
| `-O3` + `restrict` | OpenRV64 3P |       51,923 | 85,925 |   0.6043 |  +18,206 (+26.89%) |
| `-O3` + `restrict` | gem5 HPI    |       58,815 | 67,719 | 0.868515 |          reference |

The old HPI `-O2` result was 72,146 cycles.  The annotation improves HPI by
703 cycles (0.97%), versus 4,014 cycles (4.40%) on OpenRV64.  `-O3` gives HPI a
much larger scheduling/control-flow gain than it gives OpenRV64, so it is the
best absolute result for both cores but makes the architectural gap larger.

HPI remains a cross-ISA A53-class proxy, not Cortex-A53 silicon.  Architectural
instruction counts and IPC are therefore descriptive; cycle count compares
completion of the same C workload under the same compiler alias contract.

## Forwarding bug exposed by the new schedule

The first relaxed-WAW run of the annotated binary halted with the wrong
checksum.  The first divergent architectural value was a later load of `44`
instead of `2`, but memory-request tracing located the actual corruption at an
earlier store:

```asm
lbu     a5,1(a5)       # older a5 = 44
addiw   a5,a3,1        # younger a5 = 2
sw      a5,4(a1)       # must consume 2
```

Both WAW producers retired together.  The GPR bank's same-cycle bypass selected
the younger retirement lane correctly, but the rd-indexed full-forward map then
overrode it with the older completed value.  The fix makes ordered retirement
the highest-priority forwarding source.  The integrated backend regression now
checks that the store launches with `2`, and the full benchmark passes.

This is also the boundary of the current forwarding design.  More useful WAW
forwarding requires the consumer to select the youngest older producer by
identity or age.  Broadcasting only `valid + architectural rd + data` cannot
disambiguate several live producers.  Until producer identity is added, the
writer-count scoreboard still blocks consumers behind multiple non-retiring
writers.

## Saved artifacts

- OpenRV64 `-O2` trace:
  `sim/compiler-schedule/coremark-loop-restrict-relaxed-waw-fixed-trace.csv`
- OpenRV64 `-O3` trace:
  `sim/compiler-schedule/coremark-loop-restrict-o3-relaxed-waw-fixed-trace.csv`
- OpenRV64 1P original/annotated traces and readable reports:
  `sim/compiler-schedule/coremark-loop-*-1p-trace.csv` and
  `sim/compiler-schedule/coremark-loop-*-1p-pipeline.txt`
- HPI `-O2` report and trace:
  `sim/a53/gem5-hpi-restrict-o2/`
- HPI `-O3` report and trace:
  `sim/a53/gem5-hpi-restrict-o3/`

The HPI runs use `MinorTrace`; the OpenRV64 runs use the versioned 3P cycle CSV
with queue, issue, completion, retirement-GPR, and LSU request/response fields.
