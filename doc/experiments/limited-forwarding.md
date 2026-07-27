# Limited live-completion forwarding

## Result

A current-cycle completion bypass is a useful middle point between the old
same-ALU-pipe bypass and the experimental full forwarding map.  On the fixed
CoreMark configuration, forwarding all three live completion ports reduces
runtime from 103,978 to 95,192 cycles and raises IPC from 0.5054 to 0.5520.
It captures 84.9% of the full-forwarding cycle reduction without retaining or
searching completed values in the retirement queue.

The cheapest useful tier is MEM-only forwarding.  One tagged 64-bit result
source reduces runtime to 99,359 cycles and raises IPC to 0.5289.  It beats the
two-source ALU-only configuration, which reaches 100,501 cycles and 0.5229
IPC.  Therefore the recommended implementation order is:

1. keep the source mask parameterized;
2. enable MEM completion forwarding first if wiring or timing is constrained;
3. enable all three completion sources if the completion-to-dispatch path
   closes timing;
4. do not promote the retirement-queue-wide full forwarding experiment.

This result does not justify historical forwarding storage.  The remaining
1,568-cycle difference between all-live and full forwarding is only 1.65% of
the all-live runtime and requires a much broader structure.

## Fixed experiment

All runs use exactly the same RV64 CoreMark image and microarchitectural
configuration except for the forwarding controls:

- `sw/coremark-loop.elf`, converted to `sim/coremark-loop-256.memh`;
- 52,547 retired instructions and final `a0=0x000000000a277880`;
- three-pipe `openrv64_top_3p` and the 256-bit AXI RAM interface;
- posted stores, non-overlapping load bypass, and covered same-address
  store-to-load forwarding enabled;
- BTFNT branch prediction with the eight-entry RAS;
- no branch oracle and no predictor changes;
- `ENABLE_FULL_FORWARDING=0` for every limited-forwarding row.

The branch counters are identical in every limited run: 14,153 allocations,
12,691 resolutions, 3,856 taken predictions, and 3,362 corrections.  The
performance differences below are consequently forwarding results, not a
branch-prediction change.

| Forwarding mode           |      Source mask |     Cycles | Saved cycles | Runtime reduction |        IPC | Share of full-forwarding gain |
|---------------------------|-----------------:|-----------:|-------------:|------------------:|-----------:|------------------------------:|
| Same-pipe baseline        |            `000` |    103,978 |            0 |             0.00% |     0.5054 |                          0.0% |
| ALU completions only      |            `011` |    100,501 |        3,477 |             3.34% |     0.5229 |                         33.6% |
| MEM completion only       |            `100` |     99,359 |        4,619 |             4.44% |     0.5289 |                         44.6% |
| All live completions      |            `111` | **95,192** |    **8,786** |         **8.45%** | **0.5520** |                     **84.9%** |
| Full completed-result map | separate control |     93,624 |       10,354 |             9.96% |     0.5613 |                        100.0% |

The full-map row is retained as an upper bound, not as the proposed
implementation.  Its result map includes completed values held in the
retirement queue as well as the current completion ports.

## Why this boundary

The causal baseline trace contains 18,989 cycles whose oldest blocked
candidate has a RAW dependency on a producer that has already completed but
not retired.  Reconstructing producer lifetime from issue, completion, and
retirement events gives this completion-age distribution:

| Cycles since producer completion | Completed-RAW blocks | Cumulative share |
|---------------------------------:|---------------------:|-----------------:|
|                                0 |               15,701 |           82.69% |
|                                1 |                1,010 |           88.00% |
|                                2 |                  273 |           89.44% |
|                                3 |                  369 |           91.38% |
|                      4 through 7 |                1,028 |           96.80% |
|                     8 through 10 |                  608 |          100.00% |

Thus 82.7% of this visible completed-RAW condition occurs in the exact cycle
that the producer's registered completion payload is already present.  A live
completion bypass captures that dominant case without adding a result buffer,
a retirement-queue CAM, or per-register historical data.

The age-zero producer-to-consumer paths explain the source-mask result:

| Producer to consumer path | Source operand | Blocks |
|---------------------------|----------------|-------:|
| MEM to EX0                | `rs1`          |  4,833 |
| MEM to EX1                | `rs1`          |  2,784 |
| EX1 to EX0                | `rs1`          |  2,201 |
| EX0 to MEM                | `rs2`          |  2,144 |
| MEM to MEM                | `rs1`          |  1,440 |
| EX1 to EX0                | `rs2`          |  1,312 |
| EX0 to MEM                | `rs1`          |    755 |
| EX1 to MEM                | `rs2`          |    224 |
| EX1 to MEM                | `rs1`          |      8 |

MEM supplies 9,057 of the 15,701 age-zero opportunities, versus 6,644 from
the two ALU ports.  That is why a single MEM result source outperforms two ALU
sources on this workload.

These counts are causal block classifications, not additive cycle savings.
Removing one RAW block changes scheduling and exposes other constraints.  The
measured counters show that explicitly:

| Oldest-candidate block  | Baseline | ALU-only | MEM-only | All-live | Full map |
|-------------------------|---------:|---------:|---------:|---------:|---------:|
| RAW, producer pending   |   26,409 |   27,809 |   26,409 |   27,801 |   27,801 |
| RAW, producer completed |   18,989 |   12,329 |   11,620 |    4,232 |        0 |
| WAW, producer completed |    3,434 |    5,788 |    7,402 |    9,756 |   11,252 |
| Serialization barrier   |   11,311 |   10,594 |   10,160 |    9,399 |    8,663 |
| Pipe conflict           |    4,237 |    3,421 |    4,237 |    3,421 |    3,429 |
| Pipe busy               |    3,631 |    3,847 |    3,640 |    3,856 |    5,536 |

All-live forwarding removes 14,757 of the baseline's completed-RAW block
classifications, but many become WAW, pending-RAW, or structural stalls.  That
is why eliminating 77.7% of the completed-RAW count yields an 8.45% runtime
reduction rather than a proportional reduction.

## RTL shape

`COMPLETION_FORWARD_MASK[2:0]` selects the registered completion payloads from
EX0, EX1, and MEM respectively:

|     Mask | Enabled sources                 |
|---------:|---------------------------------|
| `3'b000` | old same-pipe ALU bypass only   |
| `3'b011` | EX0 and EX1 completion payloads |
| `3'b100` | MEM completion payload only     |
| `3'b111` | all three completion payloads   |

Each enabled source carries `{valid, rd[4:0], data[63:0]}`.  Dispatch compares
the selected live tags against the six candidate source operands.  A match
both releases the scoreboard RAW interlock and selects that live value during
operand capture.  The ordinary `write_busy` ownership bit remains asserted
until retirement, so precise architectural ownership and WAW handling are
unchanged.

Exception-producing, illegal, x0-writing, and flushed completion payloads are
not eligible.  This is a completion-to-dispatch bypass: it does not create an
unregistered combinational ALU-to-ALU cascade.  Values that are no longer on a
selected completion port remain blocked until retirement unless they hit the
pre-existing same-pipe bypass.

The hardware cost is still real.  With a constant MEM-only mask, synthesis can
reduce the structure to one tag compare and one 64-bit selection per operand.
All-live requires up to three tag comparisons and a three-source selection for
each of six operands.  No frequency or area claim should be made until this
path is synthesized and timed.

## Verification

Directed tests cover both sides of the contract:

- `tb_reg_map_3p` proves that a live MEM completion releases a RAW consumer
  assigned to a different pipe;
- `tb_dispatch_3p` proves that the issued consumer captures the forwarded
  `0xcafef00ddeadbeef` value rather than stale GPR data;
- `tb_backend_3p` checks the integrated backend;
- every CoreMark configuration retires 52,547 instructions, halts normally,
  and returns the expected checksum in `a0`.

The directed command is:

```sh
make -B sim-reg-map-3p sim-dispatch-3p sim-backend-3p
```

Run a limited-forwarding CoreMark point with:

```sh
make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-loop-256.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    AXI_3P_PERF_BP_TYPE=4 \
    AXI_3P_PERF_BP_RAS_ENABLE=1 \
    AXI_3P_PERF_BP_RAS_DEPTH=8 \
    AXI_3P_COMPLETION_FORWARD_MASK=7 \
    AXI_3P_FULL_FORWARDING=0 \
    AXI_3P_PERF_ARGS=+expect_a0=000000000a277880 \
    AXI_3P_TRACE_CSV=sim/coremark-loop-3p-btfnt-ras8-live-completion-forward-trace.csv \
    AXI_3P_TRACE_REPORT=sim/coremark-loop-3p-btfnt-ras8-live-completion-forward-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS=--around-pc=8000049c
```

Use mask `4` for MEM-only, mask `3` for ALU-only, and mask `0` for the
same-pipe baseline.  The saved readable reports use the corresponding
`mem-completion-forward`, `alu-completion-forward`, and
`live-completion-forward` names under `sim/`.
