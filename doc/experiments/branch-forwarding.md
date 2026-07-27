# ALU/MEM completion forwarding to conditional branches

## Result

A dedicated branch-only bypass is worth keeping. On the current full CoreMark
loop image it reduced execution from **93,874 to 90,151 cycles** and raised IPC
from **0.5598 to 0.5829**. That is 3,723 cycles, or 3.97%, with no general live
completion network and no completed-result map enabled.

| Configuration                 |          Cycles | Retired |              IPC | RAW-pending first blocks | Retire-head incomplete |
|-------------------------------|----------------:|--------:|-----------------:|-------------------------:|-----------------------:|
| Branch bypass off (`000`)     |          93,874 |  52,547 |           0.5598 |                   43,457 |                 45,697 |
| EX0/EX1/MEM to branch (`111`) |          90,151 |  52,547 |           0.5829 |                   38,695 |                 41,132 |
| Delta                         | -3,723 (-3.97%) |       0 | +0.0231 (+4.13%) |                   -4,762 |                 -4,565 |

The enabled run issued 4,852 conditional branches with at least one bypassed
operand, covering 6,080 operands. The predictor behavior did not change:
12,691 conditional resolutions and 2,878 corrections occurred in both runs.
The architectural result was `a0=0x000000000a277880` in both runs.

These are fixed-clock RTL-simulation results. They do not include the frequency
cost of the additional completion-to-dispatch path.

## Controlled configuration

Both runs used the same rebuilt `sim/coremark-loop-eqpair.memh` workload and:

```text
BP_TYPE=5                         # 32-entry, 3-bit bimodal
BP_RAS_ENABLE=1
BP_RAS_DEPTH=8
RETIRE_DEPTH=8
RELAX_WAW=1
RELAX_HAZARDS=0
COMPLETION_FORWARD_MASK=000      # general live bypass off
ENABLE_FULL_FORWARDING=0         # completed-result map off
ENABLE_ISSUE_WINDOW=0            # strict six-entry FIFO
ENABLE_POSTED_STORES=1
ENABLE_EQ_BRANCH_PAIRING=1
FREE_BRANCHES=0
```

Only `BRANCH_COMPLETION_FORWARD_MASK` changed from `000` to `111`. Both runs
enabled the detailed pipeline trace. Artifacts are:

- `sim/coremark-branch-forward-off-trace.csv`
- `sim/coremark-branch-forward-off-pipeline.txt`
- `sim/coremark-branch-forward-on-trace.csv`
- `sim/coremark-branch-forward-on-pipeline.txt`

## RTL mechanism

The execution lanes already expose three registered completion channels. The
new path reuses each channel's valid bit, architectural destination, and 64-bit
result. It does not cascade a combinational ALU result into a same-cycle
consumer and does not retain arbitrary completed values.

Relaxed WAW makes an `rd` match alone unsafe. For example, if two live
instructions both write x15, completion of the older writer must not release a
branch waiting for the younger value. The backend therefore keeps the
retirement slot of the youngest allocated writer for each architectural
register. A completion can assert branch-forward valid only when:

```text
completion valid
and completion writes a nonzero rd without an exception
and source is enabled by BRANCH_COMPLETION_FORWARD_MASK
and youngest_owner_valid[rd]
and completion_slot == youngest_owner_slot[rd]
```

At the default eight-entry retirement depth this adds a three-bit owner slot
per architectural register, not a 64-bit instruction-ID table. Allocation is
ordered youngest-last. Retirement clears ownership only if its slot is still
the recorded owner, so retirement of an older WAW producer leaves the younger
owner intact.

Dispatch treats that producer-qualified match as a legal RAW exception only
for conditional branches. The matching value has final operand-mux priority,
including over an untagged general forwarding entry, and is captured in the
normal EX0 issue payload. It therefore feeds both the BEQ/BNE issue-pairing
comparison and the actual branch execution operand. Ordinary ALU, LSU, jump,
and system candidates cannot consume this path.

`BRANCH_COMPLETION_FORWARD_MASK` is exposed through `openrv64_top_3p`; `111`
is the default and `000` removes it for A/B tests.

## What the counters say

The direct effect is the 4,762-cycle reduction in `raw_pending`. Secondary
effects are expected because releasing a branch changes queue and frontend
timing:

| Counter                    |    Off |     On |  Delta |
|----------------------------|-------:|-------:|-------:|
| Queued no issue            | 43,116 | 38,043 | -5,073 |
| Frontend held              | 26,593 | 23,517 | -3,076 |
| Fetch reads                | 25,768 | 25,433 |   -335 |
| Useful BEQ/BNE issue pairs |  3,693 |  3,596 |    -97 |
| Branch corrections         |  2,878 |  2,878 |      0 |

The small drop in same-bundle equality pairs is not a regression by itself;
the bypass changes when branches reach the head and how neighboring work is
grouped. Total cycles and RAW pressure improve substantially.

## Timing risk

This is much narrower than full forwarding, but it is not free. The branch
path is:

```text
registered completion data
  -> three-source rd match / 64-bit operand select
  -> BEQ/BNE equality compare
  -> pairing/barrier decision
  -> candidate issue valid
```

The owner-slot qualification is in the backend valid generation and adds a
small tag comparison; the 64-bit data selection remains in dispatch. Yosys
elaboration, process lowering, optimization, and structural checks pass with
no errors, but that is not a placed-and-routed timing result. If this path
misses timing, the first containment choice is to keep it for branch execution
but remove it from the same-cycle BEQ/BNE pairing decision; that preserves much
of the RAW benefit at the cost of some bundle opportunities.

A parameter-controlled full-core generic-techmap A/B gives the following
structural estimate with the full and general forwarding networks disabled:

| Metric            | Bypass off | Bypass on |           Delta |
|-------------------|-----------:|----------:|----------------:|
| Generic cells     |    470,798 |   479,804 | +9,006 (+1.91%) |
| Flops             |     23,985 |    24,112 |   +127 (+0.53%) |
| Generic mux cells |    210,606 |   217,164 |          +6,558 |

The 127 flops are exactly the expected 31 nonzero-register owner-valid bits and
32 three-bit retirement-slot tags. The combinational cost is less trivial:
dispatch must select three possible 64-bit completion values for each of two
operands at each of three candidate positions. Generic Yosys cells are not
Sky130 area and say nothing reliable about routed delay, but this result rules
out describing the feature as merely three control wires.

## Validation

Directed RTL tests cover:

- EX1-to-BEQ value forwarding;
- MEM-to-BNE value forwarding;
- the pairing comparator using the forwarded rather than stale GPR value;
- branch-qualified data taking priority over a stale untagged same-rd map;
- branch-only validity not releasing an ordinary ALU consumer; and
- relaxed-WAW acceptance of the youngest completion while rejecting the older
  same-rd completion.

The dispatch test, backend tests in both conservative and aggressive hazard
modes, AXI 3P branch-predictor regression, and Yosys structural check pass.
