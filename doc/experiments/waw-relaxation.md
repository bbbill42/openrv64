# Ordered WAW relaxation

Date: 2026-07-19

## Result

The three-pipe core now permits multiple outstanding writers to the same
architectural register.  Retirement remains in order, and simultaneous
retirement writes use program order: the youngest retiring lane supplies the
final GPR value.

This is a useful improvement, but it is not the main remaining HPI gap.

| Core/configuration                                      | Instructions |     Cycles |        IPC |      Delta from strict WAW |
|---------------------------------------------------------|-------------:|-----------:|-----------:|---------------------------:|
| OpenRV64, BTFNT + RAS8, full forwarding, strict WAW     |       52,547 |     93,624 |     0.5613 |                  reference |
| OpenRV64, BTFNT + RAS8, full forwarding, relaxed WAW    |       52,547 | **91,216** | **0.5761** | **-2,408 cycles (-2.57%)** |
| OpenRV64, oracle branches, full forwarding, strict WAW  |       52,547 |     84,308 |     0.6233 |                  reference |
| OpenRV64, oracle branches, full forwarding, relaxed WAW |       52,547 | **81,699** | **0.6432** | **-2,609 cycles (-3.09%)** |
| gem5 HPI A53-class reference                            |       58,695 |     72,146 |   0.813559 |        cross-ISA reference |

The relaxed normal-predictor result remains 19,070 cycles above HPI.  With
prediction made oracular, OpenRV64 remains 9,553 cycles above HPI.  HPI executes
6,148 more architectural instructions, so IPC and raw instruction count are
cross-ISA comparisons; cycle count compares completion of the same CoreMark
workload.

The workload result and checksum remained correct:

```text
a0=000000000a277880 halted=1 retired=52547
```

## Correctness erratum found by compiler scheduling

A later alias-annotated compiler schedule exposed a bug that the original
binary and directed tests did not cover.  Two completed WAW producers of `a5`
retired together while a younger store consumed `a5`.  The ordered GPR bypass
correctly selected the youngest retiring value (`2`), but the rd-indexed full
forwarding map overwrote it with the older producer (`44`).  The store silently
corrupted memory and a later load exposed the wrong checksum.

The fix gives ordered same-cycle GPR retirement bypass priority over completion
maps.  This does not add the conservative extra stall that would result from
waiting one more cycle.  The formerly failing annotated `-O2` binary now passes:

| Configuration                                               | Instructions |     Cycles |        IPC | Checksum |
|-------------------------------------------------------------|-------------:|-----------:|-----------:|----------|
| BTFNT + RAS8, full forwarding, relaxed WAW, annotated `-O2` |       52,547 | **87,202** | **0.6026** | correct  |

`tb_backend_3p.sv` now contains the exact two-writer/retiring-consumer store
regression.  The broader producer-identity limitation remains: consumers still
wait while several non-retiring writers own one architectural register because
an rd-only completion map cannot select the youngest writer safely.

## What was changed

The old scoreboard used one busy bit per architectural register.  That bit
cannot represent two writers: retirement of the older writer would clear the
bit while the younger writer is still outstanding.  Simply disabling the WAW
test would therefore be incorrect.

The relaxed implementation uses a small outstanding-writer count per
architectural register:

- a destination allocation increments its register's count;
- ordered retirement decrements the count;
- another destination may allocate regardless of a nonzero count;
- a consumer may use the normal GPR value when the count is zero;
- a consumer may use the existing completion forwarding paths when exactly one
  writer remains;
- a consumer stalls while two or more writers remain because an rd-indexed
  forwarding map cannot identify the youngest producer.

This is not register renaming.  It removes false destination serialization
without inventing producer identity.  Supporting consumers behind several live
writers would require age-tagged values or renamed physical destinations.

The three-write GPR bank also now gives a duplicate destination to the youngest
retirement lane.  Since retirement lanes are an ordered contiguous prefix,
this produces the same final state as three sequential writes.

The relaxed behavior is the default for the 3P hierarchy and remains selectable
with `RELAX_WAW=0` or `AXI_3P_RELAX_WAW=0` for comparison.

## Local trace effect

In the previously matched 100-instruction `state_transition` window, relaxing
WAW is much more visible than in the whole run:

| Measurement                    | Strict WAW |    Relaxed WAW |        HPI |
|--------------------------------|-----------:|---------------:|-----------:|
| Matched call cycles            |        241 |        **209** |        148 |
| Matched call IPC               |      0.548 |      **0.632** |      0.912 |
| Selected 100-instruction span  | 183 cycles | **156 cycles** | 121 cycles |
| Local 100-instruction IPC      |      0.546 |      **0.641** |      0.826 |
| Queued-no-issue cycles in span |        100 |         **70** |         44 |

For example, consecutive independent overwrites of `a2` can now start on
successive cycles rather than waiting for each older value to retire.  The
remaining RAW count is still high because true load-use chains remain, and
because a consumer behind two live WAW producers is deliberately classified as
an ambiguous RAW rather than a WAW.

The compiler really did help the HPI trace in at least one important sequence:
it scheduled an independent `orr` between a pointer load and its dependent byte
load.  That hides part of the load latency.  This is observed scheduling in the
AArch64 binary, not an architectural feature on which a core should depend.

## Branch pairing is a separate restriction

Strict-prefix issue and branch termination are different rules:

- strict prefix means candidate 1 can issue only if candidate 0 issues, and
  candidate 2 only if candidates 0 and 1 issue;
- the branch barrier additionally makes a branch the last allocation in its
  issue group.

The current core can pair an ordinary older instruction with a following branch
when routing puts the older instruction on EX1 or MEM and the branch on EX0.
It cannot pair a branch with a younger predicted-path instruction.  The HPI
trace repeatedly does the latter.

The oracle relaxed-WAW trace contains 10,784 conditional-branch issue cycles.
On 6,360 of them, at least one younger queued instruction was otherwise
hazard-free and had a free physical pipe; on 2,688 of those cycles, two younger
instructions were otherwise eligible.  Those are opportunity counts, not a
cycle-saving estimate: downstream dependencies, retirement, and frontend
behavior overlap them.

Dropping the barrier is currently incorrect.  A redirect clears the frontend
and dispatch queue, but it does not age-squash already allocated retirement
entries or execution-pipe work.  A younger instruction issued beside a
mispredicted branch could therefore complete and retire from the wrong path.

There are two credible implementations:

1. **Non-speculative same-cycle pairing.** Resolve the conditional branch as it
   issues and allow younger lanes only when direction and target were predicted
   correctly.  A misprediction still issues only through the branch.  This
   preserves the current simple backend, but puts branch compare/target checking
   on the younger-lane issue and allocation timing path.
2. **Speculative pairing with age squash.** Allocate predicted-path younger work
   unconditionally, then kill every younger retirement, scoreboard, execution,
   and LSU entry on redirect.  This has a cleaner issue timing path but adds a
   real speculative backend, including rollback of writer counts and suppression
   or cancellation of memory side effects.

For the current core, the first option is the contained experiment.  It should
initially cover only aligned conditional branches and must gate on both direction
and target correctness.  The second option is justified only if the late branch
path fails timing or broader speculative issue becomes an architectural goal.

## Reproduction

Normal prediction:

```sh
make -B sim/top_axi_3p_tb.vvp \
    AXI_3P_BP_TYPE=4 AXI_3P_BP_RAS_ENABLE=1 AXI_3P_BP_RAS_DEPTH=8 \
    AXI_3P_RETIRE_DEPTH=8 AXI_3P_COMPLETION_FORWARD_MASK=0 \
    AXI_3P_FULL_FORWARDING=1 AXI_3P_RELAX_WAW=1 \
    AXI_3P_POSTED_STORES=1 AXI_3P_ORACLE_BRANCHES=0
vvp sim/top_axi_3p_tb.vvp \
    +memh=sim/coremark-loop-256.memh +max_cycles=250000 \
    +expect_a0=000000000a277880 \
    +pipeline_trace=sim/coremark-loop-3p-btfnt-ras8-full-forward-relaxed-waw-trace.csv
```

Oracle prediction uses `AXI_3P_ORACLE_BRANCHES=1` and:

```text
+branch_oracle_load=sim/coremark-loop-branch-oracle.memh
+branch_oracle_count=12691
```

Readable traces:

- `sim/coremark-loop-3p-btfnt-ras8-full-forward-relaxed-waw-pipeline.txt`
- `sim/coremark-loop-3p-oracle-full-forward-relaxed-waw-pipeline.txt`
