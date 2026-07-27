# Speculation and frontend lookaside sizing

Date: 2026-07-24

## CoreMark-derived sizing experiment

The experimental issue/speculation window was tested at 16, 32, and 64
entries while varying the fetch alternate-lookaside context count. These are
bare physical-address runs; Sv39 was disabled. Every run retired 52,547
instructions, produced `a0=0x000000000a277880`, and passed.

The issue-window depth is currently tied to retirement depth, so the columns
below change both structures. They are not pure scheduler-window comparisons.

`CORE_3P_CCX_L2_PAIR_STACK_DEPTH` also controls the number of mode-3
alternate-sector lookaside contexts. The branch-pair stack itself reached only
one saved entry and reported no overflow in these runs. The measured effect
from increasing this parameter therefore came from additional lookaside
residency, not deeper request queuing.

| Lookaside contexts |              Window/retire 16 |          Window/retire 32 |          Window/retire 64 |
|-------------------:|------------------------------:|--------------------------:|--------------------------:|
|                  2 |     70,877 cycles, 0.7414 IPC | 71,437 cycles, 0.7356 IPC | 71,398 cycles, 0.7360 IPC |
|                  4 | **70,629 cycles, 0.7440 IPC** | 70,844 cycles, 0.7417 IPC | 70,818 cycles, 0.7420 IPC |
|                  8 | **70,629 cycles, 0.7440 IPC** | 70,874 cycles, 0.7414 IPC | 70,848 cycles, 0.7417 IPC |

Increasing the lookaside from two to four contexts removed 248 cycles at
window 16, 593 cycles at window 32, and 580 cycles at window 64. It recovered
most of the additional-window regression, but the controlled four-context
comparison still favored the 16-entry window by 215 cycles over 32 entries
and by 189 cycles over 64 entries.

| Counter                        | Contexts | Window 16 | Window 32 | Window 64 |
|--------------------------------|---------:|----------:|----------:|----------:|
| Lookaside restart hits         |        2 |     1,042 |       879 |       884 |
| Lookaside restart hits         |        4 |     1,220 |     1,202 |     1,208 |
| Lookaside restart hits         |        8 |     1,220 |     1,233 |     1,239 |
| Exposed next-line stash stalls |        4 |       131 |        69 |        69 |
| Exposed next-line stash stalls |        8 |       131 |       181 |       181 |

Eight contexts added restart hits for the 32- and 64-entry configurations,
but those runs gained 112 exposed next-line stash-stall cycles and finished
30 cycles slower than the corresponding four-context runs. More lookaside
hits are therefore not automatically useful; residency policy and whether the
preview covers enough instructions matter.

The external-memory measurements were invariant across the sweep: 42 DDR
commands and 41 L1D request-wait cycles. The observed differences are
frontend/speculation interactions rather than DDR backpressure.

## Configuration

The controlled runs used:

```text
CoreMark-derived bare RV64I workload, no Sv39
BP_TYPE=6
FETCH_ALT_LOOKASIDE=3
ISSUE_WINDOW=1
SPECULATION_WINDOW=1
RETIRE_DEPTH=16, 32, or 64
PAIR_STACK_DEPTH=2, 4, or 8
POSTED_STORES=1
L1D prefetch distance=2, maximum distance=8
L1D prefetch queue=8, outstanding=8
L2 MSHR entries=16
GenBus read/write depth=8/8
DDR3 timing model enabled
```

## Decision

Keep the current default lookaside depth for now. This is a configuration
decision, not a claim that two contexts performed best: four contexts were
measurably faster on this workload. Before changing the default, test more
control-flow workloads and obtain area and frontend timing results.

If sizing is revisited, four contexts are the supported performance candidate.
Eight contexts have no demonstrated benefit here, and windows larger than 16
still have no demonstrated CoreMark benefit.
