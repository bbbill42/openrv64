# Tagged L1D milestone — 2026-07-25

## What was run, and when (UTC)

This report compares three Sky130/Yosys snapshots:

| Snapshot            | Started             | Finished            | Command                                                                                                                                                    | Meaning                                                            |
|---------------------|---------------------|---------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------|
| `pre-microtlb`      | 2026-07-23          | 2026-07-23          | `make yosys-resources-core-sky130`                                                                                                                         | Frozen pre-microTLB reference                                      |
| `post-microtlb`     | 2026-07-25          | 2026-07-25          | `RESOURCE_JOBS=1 make yosys-resources-core-sky130`                                                                                                         | Frozen state before the global-tag L1D rewrite                     |
| `tagged-l1d-260725` | 2026-07-25 22:40:26 | 2026-07-25 23:52:08 | `RESOURCE_JOBS=32 SOURCE_ROOT=/tmp/openrv64-tagged-l1d-final2.XWpSr3 make yosys-resources-core-sky130 YOSYS_CORE_RESOURCE_DIR=sim/yosys/tagged-l1d-260725` | Global 3-bit request tags and synchronous tag-indexed overlay SRAM |

The first two rows are frozen under `sim/yosys/baselines/`. The final output
is under `sim/yosys/tagged-l1d-260725/`.

The live tree changed during an initial 21:57 UTC elaboration, so that attempt
was aborted and preserved as `sim/yosys/tagged-l1d-260725-mixed-aborted`. A
second frozen attempt was aborted and preserved as
`sim/yosys/tagged-l1d-260725-reuse-aborted` after review found a same-cycle
tag-reuse priority bug; its area result is invalid. A third attempt was
aborted as `sim/yosys/tagged-l1d-260725-async-aborted` when its memory report
showed that the shared write-through register had produced an asynchronous
read port. A fourth attempt was stopped as
`sim/yosys/tagged-l1d-260725-collision-aborted` after review found that
same-cycle read/write collision data could be incorrectly marked valid after
tag reuse. A fifth pre-ABC attempt was stopped as
`sim/yosys/tagged-l1d-260725-attr-aborted` to add explicit block-RAM
inference attributes matching the L1 arrays. The valid run reads only the
corrected frozen `/tmp/openrv64-tagged-l1d-final2.XWpSr3/rtl` snapshot. Its sorted
relative-path/content manifest SHA-256 is
`617ff873b5746b3e2aaa248a1c721880bcd12f9db2d89a723d255daf699f5356`;
the Git commit at capture was
`6d91b0ebccc83ff312298be55a0e89c8e735c914`.

## Configuration and limits

- Top: `openrv64_top_3p`.
- Tool: Yosys 0.66 with ABC.
- Cell library: Sky130 HD TT, 25 C, 1.8 V.
- Profile: RV64IM+A, three-wide frontend/retirement, eight retirement entries,
  eight LSU request IDs, posted stores, L1I and L1D enabled, trace and the
  issue-window experiment disabled.
- L1I and L1D data arrays remain inferred SRAM. No SRAM Liberty/LEF library is
  present, so their area is excluded.
- These are mapped standard-cell estimates, not placed-and-routed area.
- `post-microtlb` is a snapshot name, not a causal claim. Most of its growth
  over `pre-microtlb` came from the L1D, not the microTLB alone.

## Frozen baseline

| Metric                     | `pre-microtlb` | `post-microtlb` |                   Change |
|----------------------------|---------------:|----------------:|-------------------------:|
| Mapped standard-cell logic |   5.420559 mm² |    7.377359 mm² |  +1.956800 mm² (+36.10%) |
| Sequential cell area       |   2.260897 mm² |    2.799187 mm² |  +0.538290 mm² (+23.81%) |
| L1D control/tags           |   1.301794 mm² |    2.941520 mm² | +1.639726 mm² (+125.96%) |
| Inferred cache SRAM        |         32 KiB |          32 KiB |                unchanged |

The L1D accounted for 83.80% of the total mapped-logic growth between those
snapshots.

## Design change

The old interface made request ownership part of the L1D tag:

- 3-bit LSU tag plus one owner bit;
- nine normal-response queue entries;
- sixteen tag-indexed demand waiters;
- a 512-bit line overlay, 64-bit byte mask, and 3-bit word selector copied
  independently into both the normal-response queue and demand-waiter table.

The new interface uses the 3-bit LSU tag as the global request identity:

- eight IDs and eight normal-response entries;
- pipe versus serial ownership is control metadata outside the tag;
- the response queue and miss waiters carry only the tag or MSHR index;
- each tag owns one 576-bit `{line, byte-mask}` overlay entry;
- the overlay payload is an unreset synchronous 8x576 1R/1W inferred memory;
- resettable control metadata is eight valid bits plus eight 3-bit word
  selectors;
- one unreset 576-bit last-write bypass preserves the resident-load latency;
- every bypass-served response also launches the SRAM read, so a stalled
  response remains valid if a later overlay write replaces the bypass;
- a same-tag SRAM read/write collision invalidates the read-output metadata,
  forcing a clean refetch before that output can replace the bypass;
- the SRAM output and response selection are held under backpressure.

The duplicated overlay arrays held 14,475 standard-cell state bits before
muxing: `9 * (512 + 64 + 3) + 16 * (512 + 64 + 3)`. The new canonical payload
is 4,608 inferred-memory bits plus 32 bits of resettable per-tag control
metadata and one 576-bit unreset last-write bypass. The SRAM's 576-bit
registered read is absorbed into its synchronous read port. This removes
13,867 of 14,475 overlay-related standard-cell state bits before accounting
for the associated mux reduction: 95.80%.

This deliberately does **not** remove the per-MSHR aggregate overlay. Multiple
request tags can merge into one miss, and the aggregate is needed to install
the correct final cacheline after later stores.

## Functional validation

The following passed on the tagged-L1D RTL:

| Command                        | Result                         |
|--------------------------------|--------------------------------|
| `make -B sim-l1d-demand-mshr`  | PASS                           |
| `make -B sim-l1d-store-order`  | PASS                           |
| `make -B sim-l1d-store-buffer` | PASS                           |
| `make -B sim-l1d-prefetch`     | PASS                           |
| `make -B sim-l1-cache`         | PASS                           |
| `make -B sim-lsq`              | PASS                           |
| `make -B sim-ccx-bus`          | PASS, including native CCX L1I |
| `git diff --check`             | PASS                           |

The store-buffer regression specifically covers a posted store immediately
followed by a resident load and checks the forwarded value and both completion
channels. After freezing the measurement source, `sim-l1d-store-buffer` and
`sim-l1d-demand-mshr` were also rebuilt with every RTL input taken directly
from `/tmp/openrv64-tagged-l1d-final2.XWpSr3/rtl`; both passed. This ties the two
overlay-sensitive results to the measured manifest rather than to the moving
live worktree.

After the map completed, the live L1D was split from
`rtl/cache/l1/l1d/l1d.v` into `rtl/core/cache/l1/l1d/{array,ccx,lsu_if,mshr,l1d}.v`.
The split tree retains the global LSU tags and synchronous overlay RAM.
`sim-l1d-store-buffer`, `sim-l1d-demand-mshr`, and `sim-ccx-bus` were rebuilt
against that live source after the move and passed. The area numbers below
still identify the frozen pre-split manifest; the later source split has not
been remeasured.

## Area result

### Direct result

| Metric                       | `post-microtlb` | `tagged-l1d-260725` |                  Change |
|------------------------------|----------------:|--------------------:|------------------------:|
| Mapped standard-cell logic   |    7.377359 mm² |        7.123870 mm² |  -0.253489 mm² (-3.44%) |
| Sequential cell area         |    2.799187 mm² |        2.598475 mm² |  -0.200712 mm² (-7.17%) |
| L1D control/tags             |    2.941520 mm² |        2.415963 mm² | -0.525557 mm² (-17.87%) |
| L1D sequential cell area     |    1.187503 mm² |        0.842902 mm² | -0.344600 mm² (-29.02%) |
| L1D mapped cells             |         360,401 |             304,671 |       -55,730 (-15.46%) |
| L1D share of mapped logic    |          39.87% |              33.91% | -5.96 percentage points |
| Inferred cache SRAM          |          32 KiB |              32 KiB |               unchanged |
| Request-overlay inferred RAM |            none |          4,608 bits |             +4,608 bits |

The retained L1D module shrank by 0.525557 mm², 17.87%. That is the useful
result for the rewrite. The saving includes removed flip-flops and associated
mux and enable logic, not just the 4,608 payload bits moved into RAM. The RAM
macro's physical area is unknown in this flow.

The whole hierarchy shrank by only 0.253489 mm² because other work changed
between the snapshots. In particular, L1I grew by 0.265999 mm². The total-core
number is an observed snapshot delta, not a causal estimate of the tag rewrite.

### Per-block snapshot delta

| Block                      | `post-microtlb` | `tagged-l1d-260725` |    Area delta | Percent delta | Final share |
|----------------------------|----------------:|--------------------:|--------------:|--------------:|------------:|
| L1D control/tags           |    2.941520 mm² |        2.415963 mm² | -0.525557 mm² |       -17.87% |      33.91% |
| L1I control/tags           |    1.114388 mm² |        1.380386 mm² | +0.265999 mm² |       +23.87% |      19.38% |
| Backend control/forwarding |    0.655281 mm² |        0.660816 mm² | +0.005535 mm² |        +0.84% |       9.28% |
| Retirement                 |    0.634960 mm² |        0.634960 mm² |     unchanged |         0.00% |       8.91% |
| I/D TLBs                   |    0.323259 mm² |        0.323259 mm² |     unchanged |         0.00% |       4.54% |
| Dispatch/hazards           |    0.299771 mm² |        0.299771 mm² |     unchanged |         0.00% |       4.21% |
| Page-table walker          |    0.294914 mm² |        0.294914 mm² |     unchanged |         0.00% |       4.14% |
| CSR/PMP                    |    0.292752 mm² |        0.293787 mm² | +0.001035 mm² |        +0.35% |       4.12% |
| Integer register file      |    0.232785 mm² |        0.232785 mm² |     unchanged |         0.00% |       3.27% |
| Fetch/line buffers         |    0.182037 mm² |        0.182037 mm² |     unchanged |         0.00% |       2.56% |
| Memory-system routing/AXI  |    0.142303 mm² |        0.141725 mm² | -0.000578 mm² |        -0.41% |       1.99% |
| EX0 integer/M              |    0.109372 mm² |        0.109372 mm² |     unchanged |         0.00% |       1.54% |
| EX1 integer/branch         |    0.052747 mm² |        0.052747 mm² |     unchanged |         0.00% |       0.74% |
| Branch predictor           |    0.043559 mm² |        0.043559 mm² |     unchanged |         0.00% |       0.61% |
| Shared L2 TLB              |    0.029876 mm² |        0.029876 mm² |     unchanged |         0.00% |       0.42% |
| Frontend/core control      |    0.018833 mm² |        0.018909 mm² | +0.000076 mm² |        +0.41% |       0.27% |
| Decode                     |    0.005413 mm² |        0.005413 mm² |     unchanged |         0.00% |       0.08% |
| Trap/redirect vector       |    0.003590 mm² |        0.003590 mm² |     unchanged |         0.00% |       0.05% |

## Synthesis runtime

The completed map used one pre-ABC whole-hierarchy checkpoint followed by 23
retained-module workers with a 32-job limit. Wall time was 71m22s, user time
105m19s, and system time 5m18s. The L1D worker was the critical worker at
2,959.85 s (49m20s); the next slowest was L1I at 357.40 s.

The earlier parallel-wrapper validation used 3,526.1 s for its L1D worker.
The tagged L1D therefore mapped 566.3 s faster, a 16.06% reduction or 1.19x
speedup. This is real but insufficient to make Yosys generally
multithreaded: ABC is still single-threaded within the dominant L1D module.
Increasing `RESOURCE_JOBS` beyond the 23 retained modules cannot reduce this
critical path. Further wall-time improvement requires partitioning L1D
internally or changing the mapper.

## Inferred memories

The completed pre-ABC report contains exactly one `tag_overlay_mem_q`:

| Memory              |           Shape | Ports |           Clocked read |    Bits | Reset |
|---------------------|----------------:|------:|-----------------------:|--------:|------:|
| L1D request overlay |           8x576 | 1R/1W | yes, `RD_CLK_ENABLE=1` |   4,608 |  none |
| L1D data arrays     | 32 banks, 64x64 | 1R/1W |                    yes | 131,072 |  none |
| L1I data arrays     | 4 banks, 64x512 | 1R/1W |                    yes | 131,072 |  none |

The overlay carries both `ram_style="block"` and
`syn_ramstyle="block_ram"`. The summarizer rejects the run unless this group
contains exactly one synchronous 8x576 1R/1W memory, so an accidental fallback
to asynchronous distributed state is a hard reporting failure.

Total inferred memory grew from 295,784 to 300,392 bits, exactly the 4,608-bit
overlay. Cache data SRAM remains 262,144 bits (32 KiB). SRAM physical area is
not included because this flow has no SRAM macro Liberty/LEF data.

## Output identity

- `resources.json` SHA-256:
  `ab6acc95dccec3bbc0995bdee5ac7e0267a35fca8b5fbec3799d65f7fd3da1fd`
- `partitioned-stat.json` SHA-256:
  `cea6b66bd34c7ab0bd5df6dc4f6dc88ea605538639fe54c9d4dbfb93f4c783e5`
- `partitioned-memories.rpt` SHA-256:
  `f972881e1c71208bba8814a37e40808e040f123b4e338f32c01d6b70a595e2b9`

## Attribution

The L1D retained-module delta against `post-microtlb` is the useful measurement
for this change. The whole-core delta may also contain unrelated dirty-tree
work performed after the frozen baseline. The per-block table shows exactly
which retained modules differ, and the frozen RTL manifest records the final
source state. It would be false precision to attribute the entire whole-core
delta to the tag rewrite.
