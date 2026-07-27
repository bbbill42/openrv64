# OpenRV64 3P physical size

## What was run, and when (UTC)

| Run                                 | Command                            | Started             | Finished            | Purpose                                      |
|-------------------------------------|------------------------------------|---------------------|---------------------|----------------------------------------------|
| Comparable functional-boundary map  | `make yosys-resources-core-sky130` | 2026-07-23 12:03:12 | 2026-07-23 12:29:18 | Direct comparison with the 2026-07-21 report |
| Detailed memory-system boundary map | `make yosys-resources-core-sky130` | 2026-07-23 12:31:52 | 2026-07-23 12:55:30 | Split L1D, L1I, TLB, PTW, and routing/AXI    |

The first start time is reconstructed from its 1,565.69-second Yosys runtime
and finish time. The second run has explicit command timestamps. Both runs used
Git `e282331ad333328b0c2b689ad13dd0a7014835a9` with a dirty working tree, so
the commit alone does not reproduce the live RTL snapshot.

| Setting            | Value                                                                                                |
|--------------------|------------------------------------------------------------------------------------------------------|
| Top                | `openrv64_top_3p`                                                                                    |
| Tool               | Yosys 0.66 (`86f2ddebc-dirty`) with ABC                                                              |
| Cell library       | `sky130_fd_sc_hd__tt_025C_1v80.lib`, TT, 25 C, 1.8 V                                                 |
| Library SHA-256    | `ec0e1067a35c8bf20b11e58d1e8ac53326067e4dac84a125cc1b917a3518d0d9`                                   |
| ABC constraints    | `sky130_fd_sc_hd__inv_2` input driver; 10 fF output load; no wire load                               |
| Constraint SHA-256 | `7bc97e5a90f50e8b3f7f46984b55595886869c3b0b9b09b8f752a7dc6574714b`                                   |
| Detailed artifacts | `sim/yosys/core-sky130/resources.{md,csv,json}`, `partitioned-yosys.log`, `partitioned-memories.rpt` |

The profile is RV64IM+A, EX0/EX1/MEM, three-wide dispatch and retirement,
eight retirement entries, eight LSU entries, full forwarding, relaxed tagged
hazards/WAW, posted stores, real branch resolution, a 32x3-bit bimodal
predictor plus RAS8, 16 KiB four-way L1I, 16 KiB four-way L1D, and a 256-bit
external interface. The issue-window experiment, trace-only state, scalar FPU,
vector unit, SoC peripherals, and testbench RAM are excluded.

## Bottom line

There is no single honest area number without defining the boundary:

| Boundary                 |       Standard-cell area | Detailed total | What it includes                                                       |
|--------------------------|-------------------------:|---------------:|------------------------------------------------------------------------|
| CPU-side logic           |         **2.404753 mm²** |         45.18% | Frontend, backend, GPR, execution, LSU, CSR/PMP, retirement            |
| Cacheless core           |         **3.080753 mm²** |         57.88% | CPU-side logic plus I/D TLBs, PTW, request routing, and AXI/CCX glue   |
| L1-integrated core logic |         **5.322836 mm²** |        100.00% | Cacheless core plus L1I/L1D control, tags, buffers, and prefetch logic |
| L1 data arrays           | **32 KiB, area unknown** |            n/a | Eight inferred 1R/1W SRAM banks; no mapped macro area                  |

The directly comparable, less-partitioned standard-cell result is
**5.086486 mm²**. The detailed total is **0.236350 mm² (4.65%)** larger
because ABC cannot optimize across the extra reporting boundaries. That is
reporting overhead, not added RTL. Use 5.086486 mm² for historical comparisons
and 5.322836 mm² for the block percentages below.

The detailed map contains 578,693 mapped cells. Sequential cell area is
2.182950 mm², or 41.01% of the detailed total. That high sequential fraction is
real in this mapping: cache tags, fill/store buffers, TLBs, the PTW PTE cache,
queues, and the GPR all remain standard cells unless explicitly listed as
inferred SRAM.

After these whole-core area runs, the divider was changed from eight to two
restoring steps per cycle and given a separate finalization cycle, then the
multiplier was reduced from eight to four shift/add bits per cycle and finally
changed to two radix-4 Booth digits per cycle. The isolated full RV64M map fell
from 0.119550 to 0.092983, then 0.070867, and now **0.065420 mm²**. The
whole-core area has not been rerun, so the tables below intentionally retain
the measured 12:55 snapshot rather than subtracting an unmeasured 0.054130 mm²
from EX0.

## Detailed block area

The rows are exclusive: retained child area is subtracted from its parent.
The percentages use the detailed 5.322836 mm² standard-cell total.

| Functional block           | Domain    |   Area (mm²) |       Total | Sequential (mm²) |       Cells |
|----------------------------|-----------|-------------:|------------:|-----------------:|------------:|
| L1D control/tags           | Memory    |     1.263340 |      23.73% |         0.706591 |     116,589 |
| L1I control/tags           | Memory    |     0.978742 |      18.39% |         0.477888 |      90,801 |
| Retirement                 | CPU       |     0.642817 |      12.08% |         0.175468 |      84,222 |
| CSR/PMP                    | CPU       |     0.355448 |       6.68% |         0.037168 |      51,704 |
| Page-table walker          | Memory/VM |     0.295252 |       5.55% |         0.235109 |      16,810 |
| Dispatch/hazards           | CPU       |     0.281520 |       5.29% |         0.046194 |      37,116 |
| Backend control/forwarding | CPU       |     0.260417 |       4.89% |         0.070468 |      37,041 |
| I/D TLBs                   | Memory/VM |     0.258723 |       4.86% |         0.107503 |      27,662 |
| Integer register file      | CPU       |     0.235505 |       4.42% |         0.051249 |      25,252 |
| LSU/MEM pipe               | CPU       |     0.229550 |       4.31% |         0.111409 |      21,837 |
| EX0 integer/M              | CPU       |     0.164465 |       3.09% |         0.030254 |      24,156 |
| Memory-system routing/AXI  | Memory/VM |     0.122026 |       2.29% |         0.057471 |      15,173 |
| Fetch/line buffers         | CPU       |     0.109017 |       2.05% |         0.041490 |      12,216 |
| EX1 integer/branch         | CPU       |     0.052333 |       0.98% |         0.011761 |       8,227 |
| Branch predictor           | CPU       |     0.046422 |       0.87% |         0.018863 |       5,839 |
| Frontend/core control      | CPU       |     0.018256 |       0.34% |         0.004061 |       2,668 |
| Decode, three lanes        | CPU       |     0.005413 |       0.10% |         0.000000 |         927 |
| Trap/redirect vector       | CPU       |     0.003590 |       0.07% |         0.000000 |         453 |
| AXI wrapper/tie-offs       | Boundary  |     0.000000 |       0.00% |         0.000000 |           0 |
| **Detailed total**         |           | **5.322836** | **100.00%** |     **2.182950** | **578,693** |

### What is actually in the large memory blocks

- **L1D control/tags:** four-way tags and metadata, eight fill-buffer lines,
  eight store-buffer lines, stride prefetch state/queue, request tracking,
  replacement state, and the native CCX client. Its four 512x64-bit data banks
  are excluded from the cell area.
- **L1I control/tags:** four-way tags and metadata, eight fill-buffer lines,
  prefetch and retirement-age state, replacement state, and the native CCX
  client. Its four 64x512-bit data banks are excluded.
- **PTW:** page-walk state, a 64-entry PTE cache, permission handling, and a CCX
  client.
- **I/D TLBs:** two 16-entry fully checked translation arrays.
- **Memory-system routing/AXI:** translation/request queues, PMP arbitration,
  cache/PTW CCX arbitration, response ownership, cancellation, and the residual
  256-bit AXI instruction path.

The L1 controller totals are large because only the bulk data arrays inferred
as SRAM. Tags, metadata, and wide fill/store buffers still map to standard-cell
flops and muxes. “The caches are RAM again” is true for 32 KiB of data, not for
all cache state.

## Inferred SRAM and whole-core physical projection

| Storage   | Banks | Inferred shape    |   Capacity |
|-----------|------:|-------------------|-----------:|
| L1I data  |     4 | 64x512-bit, 1R/1W |     16 KiB |
| L1D data  |     4 | 512x64-bit, 1R/1W |     16 KiB |
| **Total** | **8** | 262,144 bits      | **32 KiB** |

The synthesis flow asserts this geometry and fails if the eight data arrays
turn back into flops. It does not have SRAM Liberty or LEF views, so it cannot
measure their area or access time.

One public OpenRAM/SKY130 generation log for a 4 KiB
`128x256 1rw1r` macro reports a 902.9 by 672.1 um bounding box, or
0.6068 mm² per macro. Eight such rectangles would occupy **4.8547 mm²**.
This is only an order-of-magnitude proxy: its aspect ratio and port contract do
not match either current bank, and the public directory does not contain a
validated LEF/GDS for that generated result. See the
[SKY130 SRAM macro repository](https://github.com/efabless/sky130_sram_macros)
and its
[4 KiB generation log](https://raw.githubusercontent.com/efabless/sky130_sram_macros/main/sky130_sram_4kbyte_1rw1r_128x256_128/sky130_sram_4kbyte_1rw1r_128x256_128.log).

Using that proxy and the comparable 5.086486 mm² cell sum:

- cell area plus raw macro rectangles is about **9.94 mm²**;
- at 70% standard-cell utilization, the crude floorplan floor is about
  **12.12 mm²**;
- at 60% utilization, it is about **13.33 mm²**.

Those are not P&R results. Macro halos, routing channels, clock tree, power
grid, taps/fillers, congestion, and IO boundary can only increase the
floorplan, while a better SRAM compiler or fewer/larger banks can reduce the
macro term. A defensible current statement is therefore **5.09 mm² measured
cell area, 32 KiB unmapped SRAM, and roughly 12-14 mm² as an explicitly
speculative Sky130 floorplan scale**.

## Change since the 2026-07-21 measurement

The prior report used the same coarse functional boundaries and measured
2.808674 mm² with caches excluded. The current comparable-boundary run is
5.086486 mm²:

| Functional block                            | Previous (mm²) | Current (mm²) |                  Change |
|---------------------------------------------|---------------:|--------------:|------------------------:|
| Memory system, including current L1 control |       0.371832 |      2.686901 |    +2.315069 (+622.61%) |
| Retirement                                  |       0.699146 |      0.642817 |      -0.056329 (-8.06%) |
| Backend control/forwarding                  |       0.375060 |      0.260417 |     -0.114643 (-30.57%) |
| CSR/PMP                                     |       0.353881 |      0.355448 |      +0.001567 (+0.44%) |
| Dispatch/hazards                            |       0.291065 |      0.281928 |      -0.009137 (-3.14%) |
| Integer register file                       |       0.182192 |      0.235505 |     +0.053313 (+29.26%) |
| EX0 integer/M                               |       0.167477 |      0.164465 |      -0.003012 (-1.80%) |
| LSU/MEM pipe                                |       0.150705 |      0.229550 |     +0.078845 (+52.32%) |
| Fetch/line buffers                          |       0.095201 |      0.103442 |      +0.008241 (+8.66%) |
| EX1 integer/branch                          |       0.052465 |      0.052333 |      -0.000132 (-0.25%) |
| Branch predictor                            |       0.045421 |      0.046422 |      +0.001001 (+2.20%) |
| Frontend/core control                       |       0.015415 |      0.018256 |     +0.002841 (+18.43%) |
| Decode                                      |       0.005225 |      0.005413 |      +0.000188 (+3.59%) |
| Trap/redirect vector                        |       0.003590 |      0.003590 |   effectively unchanged |
| **Total**                                   |   **2.808674** |  **5.086486** | **+2.277812 (+81.10%)** |

The full number grew 81.1%, but that is almost entirely the integrated L1
memory subsystem. Removing each run's coarse memory-system bucket gives
2.436842 mm² previously and 2.399585 mm² now: the comparable CPU-side logic
actually **shrunk 1.53%**. Within it, retirement and backend reductions were
partly consumed by the eight-outstanding-entry MEM pipe and a larger GPR map.

## Read-only LSU projection

### Existing constraints

The present MEM lane is 0.229550 mm², 4.31% of the detailed integrated-core
logic and 9.55% of CPU-side logic. It already:

- admits and launches independent loads on consecutive cycles;
- tracks eight outstanding operations;
- stores a 402-bit issue payload in each queue slot;
- implements stores, atomics, posted-store ordering, and one-store forwarding;
- owns one of three 457-bit completion ports.

The current L1D accepts one request lookup per cycle. Its four data arrays are
four ways of one lookup, not four independent load ports; each inferred bank
has one read and one write port. A second read-only issue pipe connected through
the same L1D request port therefore does not create two-load-per-cycle hit
bandwidth.

### Area scenarios

These are engineering projections from the measured blocks, not synthesized
variants:

| Design                                                              |                  Added cell area | Added detailed core | Added CPU-side logic | Expected effect                                                           |
|---------------------------------------------------------------------|---------------------------------:|--------------------:|---------------------:|---------------------------------------------------------------------------|
| Second AGU/admission path, shared MEM queue and L1D port            |                **0.03-0.08 mm²** |            0.6-1.5% |             1.2-3.3% | Better scheduling and head-of-line behavior; still one cache lookup/cycle |
| Independent eight-entry load-only pipe, arbitrated into current L1D |                **0.12-0.20 mm²** |            2.3-3.8% |             5.0-8.3% | Absorbs bursts; sustained hits still serialize at L1D                     |
| Genuine two-load/cycle path with banked/multi-read L1D              | **0.30-0.70 mm²** plus SRAM cost |           5.6-13.2% |           12.5-29.1% | Two hits/cycle only on a conflict-free or truly multiported cache         |

The genuine two-load case needs more than another AGU:

1. a fourth issue destination or dual-admission MEM route;
2. a compact load queue or a second copy of the current wide queue;
3. a second translation/PMP lookup path for non-bare accesses;
4. two L1D tag/data reads per cycle, implemented by banking, replication, or a
   suitable multi-read SRAM macro;
5. two response slots and enough load-data alignment bandwidth;
6. another completion route, or arbitration against the current three ports;
7. dependency release/forwarding changes if results must be visible at the
   same peak rate.

The lower-cost architecture is a second AGU feeding a **shared compact load
queue**, followed by an explicitly banked L1D with a defined same-bank conflict
rule. Duplicating the current 402-bit-by-eight MEM payload store is the wrong
default. Duplicating the whole 1.263 mm² L1D controller is worse. The
0.30-0.70 mm² range assumes the cache is re-banked and selected structures are
duplicated; a naive duplicate-cache implementation can exceed it substantially.

## Cortex-A53 projection

A same-process comparison is unavailable. A published four-core Cortex-A53
physical study uses 32 KiB I-cache and 32 KiB D-cache per core plus a shared
2 MiB L2. A later 28 nm memory-on-logic implementation reports 2.2 mm² of logic
and 2.2 mm² of memory for the A53 design, implying roughly 0.55 mm² of logic per
core if the shared logic is divided evenly. That is an anchor, not a clean
cacheless-core measurement. See the
[A53 physical-design configuration](https://gtcad.gatech.edu/www/papers/lingjun-tcpmt22.pdf)
and the
[28/16 nm area table](https://gtcad.gatech.edu/www/papers/3665314.3670850.pdf).

If, explicitly as a heuristic, Sky130-to-28-nm effective standard-cell density
improves by 10-20x:

| OpenRV64 boundary projected to 28 nm   |  Projected area | Versus 0.55 mm² A53 logic anchor |
|----------------------------------------|----------------:|---------------------------------:|
| CPU-side logic                         | 0.120-0.240 mm² |                           22-44% |
| Cacheless core including VM/routing    | 0.154-0.308 mm² |                           28-56% |
| Full L1-integrated standard-cell logic | 0.254-0.509 mm² |                           46-93% |

This band is deliberately wide. It omits OpenRV64 SRAM area and P&R overhead,
while the A53 includes NEON/FPU and uses a commercial implementation flow. The
strongest supportable conclusion is that the OpenRV64 CPU datapath/control is
probably materially smaller than an A53 on the same process, but the current
L1 controllers and standard-cell buffer/tag state erase much of that advantage.

## Method and limits

The flow flattens logic inside retained reporting boundaries, preserves
qualifying cache data arrays as `$mem_v2`, maps all remaining logic to Sky130
HD cells, and subtracts retained child area from parents. It checks for exactly
four 16 KiB-class L1I banks and four L1D banks totaling 32 KiB, each 1R/1W.

The result is not die area and not signoff:

- no valid fully flattened map exists; the saved attempt still has 1,045,302
  unmapped `$lut` cells;
- hierarchy boundaries prevent cross-block optimization;
- there is no placement, routing, extraction, clock tree, power grid, macro
  halo, utilization target, or physical-only cell insertion;
- cache macro timing and area are not in the synthesis library;
- the working tree is dirty and must be captured before exact reproduction.
