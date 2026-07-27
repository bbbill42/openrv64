# Sky130 functional area of the current 3P core

Measured 2026-07-20 with Yosys 0.66 and the repository's
`sky130_fd_sc_hd__tt_025C_1v80` Liberty file. The numbers below are mapped
standard-cell area, not generic RTL cell counts.

## Result

The normal-flow, category-partitioned core is **2,819,708 um^2** of Liberty
cell area. Sequential cells account for **788,165 um^2**, or **27.95%**.
The categories are exclusive and sum to 100%.

| Functional block           |   Area (um^2) |   Core size | Sequential area (um^2) | Mapped cells |
|----------------------------|--------------:|------------:|-----------------------:|-------------:|
| Retirement                 |       681,084 |      24.15% |                189,231 |       90,357 |
| Backend control/forwarding |       425,081 |      15.08% |                111,307 |       60,961 |
| MMU + 256-bit AXI          |       371,832 |      13.19% |                176,365 |       40,033 |
| CSR/PMP                    |       351,576 |      12.47% |                 37,168 |       51,551 |
| Dispatch/hazards           |       273,995 |       9.72% |                 46,194 |       36,647 |
| Integer register file      |       182,192 |       6.46% |                 49,648 |       26,723 |
| EX1 integer/M              |       168,786 |       5.99% |                 32,957 |       24,783 |
| LSU/MEM pipe               |       149,234 |       5.29% |                 68,293 |       15,817 |
| Fetch/line buffers         |        95,201 |       3.38% |                 40,964 |        9,473 |
| EX0 integer/branch         |        52,497 |       1.86% |                 13,113 |        8,030 |
| Branch predictor           |        45,430 |       1.61% |                 18,863 |        5,389 |
| Frontend/core control      |        13,985 |       0.50% |                  4,061 |        1,633 |
| Decode, three lanes        |         5,225 |       0.19% |                      0 |          858 |
| Trap/redirect vector       |         3,590 |       0.13% |                      0 |          453 |
| Fixed AXI wrapper          |             0 |       0.00% |                      0 |            0 |
| **Total**                  | **2,819,708** | **100.00%** |            **788,165** |  **372,708** |

The first-order conclusion is that the small branch predictor is not an area
problem. The predictor, including its direct-target adder, is 1.61%. The large
structures are the eight-entry, wide retirement state; backend forwarding and
allocation control; the MMU/AXI transport; CSR/PMP; and dispatch/hazard logic.

The memory-side logic is split deliberately. `LSU/MEM pipe` is the execution
pipe, atomics, posted-store state, and store-to-load forwarding. `MMU + 256-bit
AXI` is the I/D translation, page-table walker, request tracking, and external
AXI master. Together they are 18.48% of this map, before any cache or SRAM is
added.

## Configuration

This is the current high-performance experiment profile, not the conservative
parameter defaults:

- top: `openrv64_top_3p`, EX0/EX1/MEM, 256-bit AXI;
- RV64IM+A, eight-entry retirement buffer, posted stores;
- full forwarding and relaxed tagged hazards/WAW;
- normal branch issue/resolution (`FREE_BRANCHES=0`); free branches are an
  oracle experiment and are not part of this baseline;
- 32-entry, 3-bit bimodal predictor, four-entry update queue, RAS depth 8;
- predecode targets enabled;
- 16-entry issue-window experiment disabled;
- trace hardware disabled;
- FPU, cache, SoC peripherals, and the 16 MiB testbench RAM excluded.

### Performance result for this configuration

On the archived 16,617-instruction CoreMark-shaped stall probe, this exact
real-branch configuration completes in **23,535 cycles**, or **0.7061 IPC**.
The trace is
`sim/test-coremark-stall-3p-bimodal32x3-real-branches-trace.csv`.

The previously quoted **0.7132 IPC** is not a baseline result. It is a BTFNT
run with `FREE_BRANCHES=1`. Its matched BTFNT run with normal branch
issue/resolution takes 24,304 cycles, or 0.6837 IPC. Free-branch results remain
useful as upper-bound experiments, but must not be used as current-core
performance.

## Method

The synthesis flow keeps only functional reporting boundaries. It flattens
everything inside each block before normal constrained ABC mapping. The
retained hierarchy is:

```text
openrv64_top_3p
  core frontend/control
    fetch
    predictor and direct-target adder
    three decoders
    CSR/PMP
    trap vector
    MMU and 256-bit AXI
    backend control/forwarding
      dispatch/hazards
      integer GPR
      EX0
      EX1/M
      LSU/MEM
      retirement queue and retirement control
```

Yosys reports recursive area for a hierarchical module. The summarizer walks
the retained instance tree and subtracts the recursive child areas from each
parent, producing mutually exclusive direct categories. Repeated instances,
such as the three decode lanes, are counted once per instance.

Run it with:

```sh
make yosys-resources-core-sky130
```

Generated detailed reports are under `sim/yosys/core-sky130/`, including CSV
and JSON forms of the table.

## Limits and failed flat-map cross-check

The absolute 2.820 mm^2 total is conservative because retained category
boundaries prevent optimization across blocks. A fully flattened cross-check
was attempted, but no valid flat Sky130 total was obtained:

- normal ABC mapping produced a 105 MiB BLIF and remained in global FRAIG/DCH
  for an impractical amount of time;
- ABC's fast flow mapped the logic but failed during buffer sizing with a
  fanout-free-node error;
- a custom `strash; dretime; map` attempt left 1,045,302 `$lut` cells, so its
  apparent 704,408 um^2 area counted essentially only flops and is invalid.

The 704,408 um^2 value must not be used. The table above is normalized to the
complete, normal-flow partition map.

There are additional physical caveats:

- inferred tables, queues, TLBs, and the register file are flops and logic;
  no SRAM or register-file macros are mapped;
- the result has no placement, routing, extracted parasitics, clock tree,
  power grid, taps/fillers, physical buffers, macro halos, or utilization
  margin;
- the result is therefore logical-area composition at the TT 25 C, 1.8 V
  Liberty corner, not die size or a placed-and-routed area claim.
