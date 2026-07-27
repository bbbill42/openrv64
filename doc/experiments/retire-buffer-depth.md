# Sixteen-entry retirement-buffer experiment

## Result

Doubling the three-pipe retirement queue from eight to sixteen entries produces
no CoreMark performance improvement.  This is true both with the original
same-pipe forwarding and with all three live completion bypasses enabled.

| Completion forwarding | Retirement depth |  Cycles |    IPC | Maximum occupancy | Capacity blocks |
|-----------------------|-----------------:|--------:|-------:|------------------:|----------------:|
| Same-pipe only        |                8 | 103,978 | 0.5054 |                 6 |               0 |
| Same-pipe only        |               16 | 103,978 | 0.5054 |                 6 |               0 |
| All live ports        |                8 |  95,192 | 0.5520 |                 7 |              16 |
| All live ports        |               16 |  95,192 | 0.5520 |                 7 |               0 |

Every run retires 52,547 instructions, halts normally, and returns
`a0=0x000000000a277880`.  BTFNT plus the eight-entry RAS remains fixed at
14,153 allocations, 12,691 resolutions, and 3,362 corrections.

The eight-entry and sixteen-entry runs have identical issue and retirement
width distributions in both forwarding configurations.  In the same-pipe
case the complete per-cycle architectural schedule is unchanged.  In the
all-live case, sixteen cycles previously classified as retirement-capacity
blocks become MEM-pipe-busy blocks; they still cannot issue, so total runtime
and the schedule remain unchanged.

## What the parameter means

`RETIRE_DEPTH=16` permits up to sixteen issued but unretired instructions.  It
does not change the three-instruction issue and retirement widths.  Results
may still complete out of order, but only the maximal contiguous completed
prefix retires.

This remains an in-order issue machine.  `dispatch_issue_3p` requires every
older candidate in the current group to issue before a younger candidate can
issue.  The retirement queue is therefore storage behind issue, not a
sixteen-entry associative scheduler.  A larger queue helps only when enough
independent younger work can issue while a slow older instruction remains
unretired.  It cannot look around a RAW, WAW, barrier, or busy-pipe stall at the
dispatch head.

CoreMark never creates the required occupancy:

| Configuration | Occupancy 0-5 cycles | Occupancy 6 cycles | Occupancy 7 cycles | Occupancy 8-16 cycles |
|---------------|---------------------:|-------------------:|-------------------:|----------------------:|
| Same-pipe     |              103,970 |                  8 |                  0 |                     0 |
| All-live      |               95,168 |                  8 |                 16 |                     0 |

Consequently, an eight-entry queue is not the active window limit.  Current
dependency handling, strict-prefix issue, serialization, and physical-pipe
availability stop the machine first.

## Cost

At the time of the experiment, one retirement entry held the full allocation
and completion packets. The 2026-07-26 compact-record rewrite supersedes that
representation. The area profile now stores 423 logical state bits per entry:
10 dynamic-ID bits, valid/complete, a 130-bit allocation record, and a 281-bit
completion-only record. Eight additional entries therefore add 3,384 resident
bits before pointer, decode, completion-update, and routing overhead. A
trace-enabled build adds one 64-bit allocation-only trace value per entry.
Slot tags also widen from three to four bits through dispatch and execution.

That cost buys zero cycles on this workload.  Keep the depth parameter for
future workloads with genuinely long, overlappable execution, but retain
eight entries as the default.  A sixteen-entry queue should be reconsidered
only after issue can expose and execute a window that regularly fills the
existing eight entries.

## Implementation and verification

`RETIRE_DEPTH` is propagated through `openrv64_top_3p`,
`openrv64_rv64_top_3p`, and the AXI performance testbench.  Count and slot
widths derive from the selected depth.  `AXI_3P_RETIRE_DEPTH` controls the
simulation build, and `PERF_CONFIG` records the elaborated depth and forwarding
mode.

The retirement-queue test now fills every selected slot before checking full
backpressure, flush, out-of-order completion, and contiguous retirement.  Both
depths pass:

```sh
make -B sim-retire-queue-3p
iverilog -g2012 -Wall -Irtl \
    -Ptb_retire_queue_3p.DEPTH=16 \
    -o /tmp/openrv64-retire16-tb.vvp \
    rtl/core/retire/retire_queue_3p.v \
    rtl/core/retire/retire_records_3p.v \
    tb/tb_retire_queue_3p.sv
vvp /tmp/openrv64-retire16-tb.vvp
```

The measured all-live CoreMark run is reproducible with:

```sh
make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-loop-256.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    AXI_3P_PERF_BP_TYPE=4 \
    AXI_3P_PERF_BP_RAS_ENABLE=1 \
    AXI_3P_PERF_BP_RAS_DEPTH=8 \
    AXI_3P_RETIRE_DEPTH=16 \
    AXI_3P_COMPLETION_FORWARD_MASK=7 \
    AXI_3P_FULL_FORWARDING=0 \
    AXI_3P_PERF_ARGS=+expect_a0=000000000a277880 \
    AXI_3P_TRACE_CSV=sim/coremark-loop-3p-btfnt-ras8-live-forward-retire16-trace.csv \
    AXI_3P_TRACE_REPORT=sim/coremark-loop-3p-btfnt-ras8-live-forward-retire16-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS=--around-pc=8000049c
```

The corresponding depth-sixteen same-pipe artifacts are
`sim/coremark-loop-3p-btfnt-ras8-retire16-trace.csv` and
`sim/coremark-loop-3p-btfnt-ras8-retire16-pipeline.txt`.
