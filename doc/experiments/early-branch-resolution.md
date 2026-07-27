# Early conditional-branch resolution

This experiment removes the retirement-head execution gate from valid,
32-bit-aligned conditional branches in the three-pipe backend. Branches now
issue when their operands and EX0 are ready, resolve and redirect immediately,
complete into the retirement queue, and still retire in architectural order.

Jumps, systems, fences, illegal instructions, fetch faults, and conditional
branches with a potentially misaligned target remain ordered-head operations.

## Why the existing recovery path is sufficient

Three properties make this first implementation safe without a general ROB
rollback mechanism:

1. Issue remains a strict in-order prefix.
2. A conditional branch terminates its issue group, so no younger instruction
   issues beside it.
3. Branch direction and target resolve on the issue edge.

Consequently, a correction redirect cannot have younger work in execution or
the retirement queue. The existing redirect clears younger dispatch/frontend
state while preserving older and branch retirement entries. Correctly
predicted branches simply leave their completed entry to retire normally.

## CoreMark-derived results

All runs used `sw/coremark-loop.elf`, the 256-bit AXI/16 MiB RAM testbench, and
full pipeline tracing. Each completed with the expected
`a0=0x000000000a277880` and normal `ebreak` halt.

| Configuration                                     |  Before | Early branch |      Cycles removed | IPC before |  IPC after |
|---------------------------------------------------|--------:|-------------:|--------------------:|-----------:|-----------:|
| Current 3P, repeat-last predictor, forwarding off | 122,223 |  **114,007** |   **8,216 (6.72%)** |     0.4299 | **0.4609** |
| Oracle control flow plus full forwarding          |  96,326 |   **84,308** | **12,018 (12.48%)** |     0.5455 | **0.6233** |

The combined diagnostic run is now 12,162 cycles above the 72,146-cycle HPI
reference, or 1.169 times HPI runtime. The 0.9-IPC target is 58,386 cycles, so
25,922 cycles remain.

## Combined-run trace movement

These counters overlap and must not be added.

| Counter                     | Oracle + forwarding before | Plus early branch |   Delta |
|-----------------------------|---------------------------:|------------------:|--------:|
| Total cycles                |                     96,326 |            84,308 | -12,018 |
| Frontend empty              |                     29,149 |            30,702 |  +1,553 |
| Frontend held               |                     31,024 |            21,293 |  -9,731 |
| Dispatch empty              |                      1,545 |             4,860 |  +3,315 |
| Dispatch nonempty, no issue |                     53,157 |            40,640 | -12,517 |
| Queued RAW indication       |                     58,300 |            53,525 |  -4,775 |
| Queued WAW indication       |                     45,162 |            42,244 |  -2,918 |
| Retire wait                 |                     51,937 |            42,473 |  -9,464 |
| Two-wide issue cycles       |                     10,459 |            13,387 |  +2,928 |
| Three-wide issue cycles     |                        233 |               177 |     -56 |

The change removes backend serialization and exposes more genuine frontend
emptiness. It also substantially increases two-wide issue. Remaining RAW,
WAW, and retirement-wait exposure confirms that early branches were a major
problem but not the only one.

The trace directly shows branches issuing before retirement head. For example,
the branch at `0x80000470` issues at cycles 71, 81, 91, and 101 with four
retirement entries occupied and no retirement on those issue cycles.

## Validation and artifacts

- `make -B sim-backend-3p`: passed.
- Ordinary predictor run: 7,218 correction redirects, correct final state.
- Oracle run: all 12,691 records consumed, zero corrections, three expected
  unresolved allocations younger than terminating `ebreak`.
- `sim/coremark-loop-3p-early-branch-trace.csv`
- `sim/coremark-loop-3p-early-branch-pipeline.txt`
- `sim/coremark-loop-3p-early-branch-oracle-full-forward-trace.csv`
- `sim/coremark-loop-3p-early-branch-oracle-full-forward-pipeline.txt`

