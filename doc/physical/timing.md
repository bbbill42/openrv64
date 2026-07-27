# OpenRV64 3P physical timing

## What was run, and when (UTC)

| Run                                         | Command                                                                                                            | Started             | Finished            | Primary artifacts                             |
|---------------------------------------------|--------------------------------------------------------------------------------------------------------------------|---------------------|---------------------|-----------------------------------------------|
| Detailed whole-core partition screen        | `make yosys-resources-core-sky130`                                                                                 | 2026-07-23 12:31:52 | 2026-07-23 12:55:30 | `sim/yosys/core-sky130/partitioned-yosys.log` |
| RV64I and RV64M timing cuts                 | `make yosys-timing-alu LIBERTY=sim/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib ABC_CONSTR=synth/sky130/abc.constr`       | 2026-07-23 12:29:49 | 2026-07-23 12:30:16 | `sim/yosys/alu/*.rpt`                         |
| Frontend replay/predecode cuts              | `make yosys-timing-frontend-sky130`                                                                                | 2026-07-23 12:30:20 | 2026-07-23 12:30:24 | `sim/yosys/frontend/*.rpt`                    |
| Post-change RV64M and isolated-divider cuts | `make yosys-timing-alu-rv64m LIBERTY=sim/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib ABC_CONSTR=synth/sky130/abc.constr` | 2026-07-23 13:21:34 | 2026-07-23 13:21:47 | `sim/yosys/alu/rv64m-{pipeline,divide}.rpt`   |
| Four-bit multiplier RV64M cuts              | `make yosys-timing-alu-rv64m LIBERTY=sim/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib ABC_CONSTR=synth/sky130/abc.constr` | 2026-07-23 13:37:23 | 2026-07-23 13:37:33 | `sim/yosys/alu/rv64m-{pipeline,divide}.rpt`   |
| PMP identical-flow before/after cuts        | Direct Yosys Sky130 mapping of `openrv64_rv64i_pmp`                                                                | 2026-07-23 13:38:08 | 2026-07-23 13:43:21 | `sim/yosys/pmp/{old-8entry,new-16entry}.rpt`  |
| Four-bit Booth RV64M cuts                   | `make yosys-timing-alu-rv64m LIBERTY=sim/pdk/sky130_fd_sc_hd__tt_025C_1v80.lib ABC_CONSTR=synth/sky130/abc.constr` | 2026-07-23 14:16:29 | 2026-07-23 14:16:39 | `sim/yosys/alu/rv64m-{pipeline,divide}.rpt`   |
| Booth generic-depth endpoints               | Yosys generic mapping plus `ltp -noff`                                                                             | 2026-07-23 14:16:58 | 2026-07-23 14:17:02 | `/tmp/openrv64-booth4-ltp.rpt`                |

All runs used Git `e282331ad333328b0c2b689ad13dd0a7014835a9`
with a dirty working tree. They characterize the live snapshot, not the clean
commit by itself.

| Setting            | Value                                                              |
|--------------------|--------------------------------------------------------------------|
| Tool               | Yosys 0.66 (`86f2ddebc-dirty`) with ABC                            |
| Cell library       | `sky130_fd_sc_hd__tt_025C_1v80.lib`, TT, 25 C, 1.8 V               |
| Library SHA-256    | `ec0e1067a35c8bf20b11e58d1e8ac53326067e4dac84a125cc1b917a3518d0d9` |
| Constraint SHA-256 | `7bc97e5a90f50e8b3f7f46984b55595886869c3b0b9b09b8f752a7dc6574714b` |
| Input driver       | `sky130_fd_sc_hd__inv_2`                                           |
| Output load        | 10 fF                                                              |
| Wire load          | None                                                               |

## Bottom line

There is no supportable core-frequency claim. The original unsanitized
whole-core pre-layout screen found:

- **118.694 ns** through the old PMP permission evaluation;
- **27.807 ns** through the four-bit-per-cycle Booth multiplier:
  **36.0 MHz reciprocal**;
- **18.037 ns** in L1D control before SRAM access timing is even included:
  **55.4 MHz reciprocal**;
- **17.143 ns** through the isolated post-change divider:
  **58.3 MHz reciprocal**;
- **11.427 ns** in the MEM queue/payload path: **87.5 MHz reciprocal**.

The old PMP result is structurally superseded. Under an identical isolated
module flow, the PMP rewrite reduced the path from **120.506 ns** to
**8.096 ns**. The current critical path is `bus_size_i` to `bus_allow_o`;
the stored-address trailing-one scan no longer exists. This is not a whole-core
rerun, so it does not establish a new core limit.

The normal RV64I ALU cut is 4.758 ns and the full frontend replay cut is
6.080 ns. Quoting their reciprocals as “core frequency” would be false.

The reciprocal values below are only `1 / path_delay`. They omit setup,
clock-to-Q, uncertainty, and wires and are not achieved frequencies.

## Every retained functional path

This table includes every retained module that produced an ABC path. It is
sorted by delay, including the ugly outliers rather than selecting only
representative paths.

| Retained block/module                |          Delay |  Reciprocal | ABC start -> end                                                            |
|--------------------------------------|---------------:|------------:|-----------------------------------------------------------------------------|
| CSR/PMP, original and now superseded | **118.694 ns** |     8.4 MHz | `pmpaddr_q[0][4]` -> `pmp_bus_allow_o`                                      |
| EX0 integer/M, current dedicated cut |  **27.807 ns** |    36.0 MHz | `mul_multiplier_q[1]` -> `result_q[63]` in the generic-depth endpoint check |
| L1D control/tags                     |  **18.037 ns** |    55.4 MHz | `req_addr_i[8]` -> internal mux                                             |
| LSU/MEM pipe                         |  **11.427 ns** |    87.5 MHz | `send_head_q[1]` -> internal mux                                            |
| EX1 integer/branch                   |       9.487 ns |   105.4 MHz | `complete_payload_q[157]` -> internal mux                                   |
| Page-table walker                    |       9.007 ns |   111.0 MHz | `level_q[0]` -> next-state/DFF control                                      |
| Dispatch/hazards                     |       8.492 ns |   117.8 MHz | `retire_rd_addr_3p_i[3]` -> internal mux                                    |
| Backend control/forwarding           |       8.147 ns |   122.7 MHz | `allocation_meta[679]` -> `train_alloc_next_pc[63]`                         |
| Frontend/core control                |       7.161 ns |   139.6 MHz | `fetch_decode_bus[238]` -> `icache_prefetch_unpredicted_addr[63]`           |
| I/D TLB instance                     |       6.034 ns |   165.7 MHz | `fill_asid_i[14]` -> internal mux                                           |
| L1I control/tags                     |       5.925 ns |   168.8 MHz | `retire_age_addr_i[46]` -> `aged_q[219]` next state                         |
| Fetch/line buffers                   |       5.810 ns |   172.1 MHz | `consume_pc_q[7]` -> internal mux                                           |
| Branch predictor                     |       4.895 ns |   204.3 MHz | `resolve_pc_i[2]` -> internal mux                                           |
| Retirement queue                     |       4.086 ns |   244.8 MHz | `complete_slot_i[3]` -> internal mux                                        |
| Direct-target prefix adder           |       3.749 ns |   266.8 MHz | `sub_i` -> `result_o[63]`                                                   |
| Integer register file                |       3.377 ns |   296.1 MHz | `write_addr_i[4]` -> PRF bank next state                                    |
| Memory-system routing/AXI            |       2.983 ns |   335.3 MHz | `fetch_state_q[3][1]` -> internal mux                                       |
| Decode lane                          |       1.838 ns |   544.2 MHz | `instr_i[2]` -> `imm_o[30]`                                                 |
| Retirement control                   |       1.793 ns |   557.8 MHz | `queue_result_i[606]` -> `cause_o[3]`                                       |
| Trap/redirect vector                 |       0.945 ns | 1,058.1 MHz | `redirect_i` -> `vector_target_o[3]`                                        |

The `openrv64_core_bus` and `openrv64_top_3p` wrappers mapped to no local
combinational path after their retained children were separated. The EX0 row
uses the post-change dedicated RV64M cut; the 12:31 whole-core run's old
72.469 ns divider row was superseded by the 14:16 rerun. The CSR/PMP row is
also historical; the isolated PMP result below supersedes its logic but not
the whole-core measurement.

These are local paths within retained hierarchy. The boundaries can cut a
longer end-to-end path, so the list is a lower-fidelity timing screen, not
whole-core STA. Conversely, the hierarchy boundaries also prevent global
optimization and can make local mapping pessimistic.

## Why the worst paths are bad

### PMP: 120.506 ns to 8.096 ns in the identical isolated cut

The old checker evaluated eight entries combinationally for three access
clients. For every NAPOT entry it counted trailing ones across the encoded
address, created a variable region size and mask, computed bounds, compared the
access interval, and preserved first-match priority.

The replacement implements 16 entries with 4 KiB grain and OFF/NAPOT modes.
CSR address writes precompute each entry's inclusive lower and exclusive upper
bounds. Requests perform fixed parallel interval comparisons followed by an
explicit first-match priority selection. Unsupported TOR and NA4 mode writes
WARL-coerce to OFF.

With the same Yosys, Liberty, driver, load, and ABC constraints, this changes:

| PMP cut              |        Delay | Reciprocal | Mapped cell area |
|----------------------|-------------:|-----------:|-----------------:|
| Old 8-entry checker  |   120.506 ns |    8.3 MHz |     0.301637 mm² |
| New 16-entry checker | **8.096 ns** |  123.5 MHz |     0.251922 mm² |

That is a 93.3% path reduction and 16.5% cell-area reduction despite doubling
the entry count. These are isolated pre-layout module numbers. A new
whole-core partition run is still required to determine the integrated path.

### RV64M: divider reduced to 17.143 ns; Booth multiply now 27.807 ns

The divider originally used `DIV_BITS_PER_CYCLE=8`, placing eight restoring
compare/subtract steps in one cycle. It now uses two steps per cycle: 32
full-width iteration cycles followed by a separate finalization cycle. Result
valid therefore arrives 33 cycles after acceptance for ordinary full-width
division. Divide-by-zero and signed-overflow cases remain immediate.

The isolated divider cut fell from 67.873 ns to **17.143 ns**, a 74.7%
reduction. The multiplier consumes four multiplier bits per cycle as two
overlapping radix-4 Booth digits: 16 cycles for RV64 and eight for RV64W. An
initial correction converts Booth's signed interpretation of a top-set
unsigned multiplier back to the required unsigned magnitude.

Relative to the naive four-bit shift/add implementation, Booth reduced the
full RV64M cut from 29.704 to **27.807 ns** (6.4%) and its isolated cell area
from 0.070867 to **0.065420 mm²** (7.7%). This is an improvement, not timing
closure. Negative Booth partial generation, partial-product combination,
128-bit accumulation, and final signed correction still contain
carry-propagating logic.

The new generic-depth path runs from `mul_multiplier_q[1]` to `result_q[63]`;
the previous longest path began at unreachable counter bit
`mul_bits_left_q[7]`. The obvious unreachable-state artifact is therefore gone,
although only constrained STA can establish sensitizability for the exact
technology-mapped path. Further divider work is not justified before the
multiplier and L1D.

### L1D: 18.037 ns

The L1D request address reaches tag/buffer lookup, hit/miss selection, request
ownership, and next-state muxing in one local cone. The data SRAM remains an
uncharacterized `$mem_v2`, so 18.037 ns does **not** include macro access,
setup, or routing.

Pipeline request classification and tag lookup, then register hit/miss and
buffer selection before response construction. A second load port will worsen
this path unless banking and conflict handling create two explicit, shallow
lookup lanes.

### MEM queue: 11.427 ns

`send_head_q` selects one of eight wide 402-bit payload records and feeds
address/store/load decoding, ordering, and completion logic. The pointer-to-wide
mux is the structural problem. A second LSU should not duplicate this shape.
Store compact per-entry fields, compute effective addresses before queueing
where legal, and register the selected entry before request construction.

### EX1, PTW, dispatch, and backend: 8-9.5 ns

- EX1 feeds a field of the held 457-bit completion payload back through local
  selection/bypass logic. Narrow bypass state to `{valid, rd, data, flags}`.
- PTW next-state control combines walk level, PTE-cache result, permissions,
  PMP handoff, and response state. Add a registered boundary around cache/PTE
  interpretation or request launch.
- Dispatch carries retirement register-address changes through dependency
  ownership/ready-state updates. Parallelize match vectors and register release
  state rather than cascading priority decisions.
- Backend allocation metadata reaches branch-training next-PC generation.
  Separate allocation/ownership bookkeeping from predictor training payload
  construction.

## Explicit ALU timing cuts

The harness primary inputs stand in for launching register outputs, and primary
outputs stand in for capturing logic. Cell delay and configured IO
driver/loading are included; clock-to-Q, setup, uncertainty, and interconnect
are not.

### RV64M

| Cut                                                 |         Delay | Reciprocal | Critical path                                                  |
|-----------------------------------------------------|--------------:|-----------:|----------------------------------------------------------------|
| Full RV64M unit, four-bit Booth multiply            | **27.807 ns** |   36.0 MHz | `mul_multiplier_q[1]` -> `result_q[63]` in generic-depth check |
| Full RV64M unit, naive four-bit multiply            |     29.704 ns |   33.7 MHz | iteration/control -> result state; unsanitized                 |
| Isolated divider, current                           | **17.143 ns** |   58.3 MHz | `div_dividend_q[63]` -> internal mux                           |
| Full RV64M unit, eight-bit multiply/two-bit divide  |     42.773 ns |   23.4 MHz | `mul_bits_left_q[6]` -> `result_q[63]`                         |
| Full RV64M unit, original eight-bit multiply/divide |     67.873 ns |   14.7 MHz | `div_divisor_q[0]` -> `result_q[62]`                           |

The divider-only harness makes multiplication unreachable and maps its
otherwise structurally retained recovery path with a one-bit chunk so ABC
cannot report multiplication as the isolated-divider critical path.

### RV64I

| Cut            |                 Delay |  Reciprocal |
|----------------|----------------------:|------------:|
| Full RV64I ALU |              4.758 ns |   210.2 MHz |
| ADD            |              4.591 ns |   217.8 MHz |
| AUIPC          |              4.456 ns |   224.4 MHz |
| SUB            |              3.426 ns |   291.9 MHz |
| ADDW           |              2.969 ns |   336.8 MHz |
| SUBW           |              2.911 ns |   343.5 MHz |
| SLT            |              1.894 ns |   527.9 MHz |
| SLL            |              1.691 ns |   591.5 MHz |
| SRL            |              1.682 ns |   594.4 MHz |
| SLTU           |              1.658 ns |   603.3 MHz |
| SRA            |              1.528 ns |   654.5 MHz |
| SRLW           |              1.353 ns |   739.2 MHz |
| SLLW           |              1.341 ns |   745.6 MHz |
| SRAW           |              1.281 ns |   780.5 MHz |
| OR             |              0.245 ns | 4,085.8 MHz |
| XOR            |              0.227 ns | 4,412.3 MHz |
| AND            |              0.149 ns | 6,690.8 MHz |
| LUI            | no combinational path |         n/a |

The full ALU includes operation selection and result muxing. LUI reduces to
wiring in this harness.

## Explicit frontend cuts

| Cut                    |    Delay |  Reciprocal | Critical path                           |
|------------------------|---------:|------------:|-----------------------------------------|
| Full resident replay   | 6.080 ns |   164.5 MHz | `if_id_pc_i[2]` -> `replay_instr_o[30]` |
| Resident replay lookup | 2.698 ns |   370.7 MHz | `target_pc_i[3]` -> `instr_o[1]`        |
| Predecode offset       | 0.690 ns | 1,450.1 MHz | `instr_i[4]` -> `immediate[2]`          |

Full replay includes direct-target addition, resident tag lookup, line
selection, and output selection. It is slower than lookup alone but still far
behind multiply, L1D, divide, and MEM in the repair order.

## Repair order

| Priority | Cone                     | Required action                                                               | Reason                                               |
|---------:|--------------------------|-------------------------------------------------------------------------------|------------------------------------------------------|
|        1 | RV64M multiply           | Add carry-save accumulation and stage final correction                        | Booth is implemented, but the cut remains 27.8 ns    |
|        2 | L1D lookup/control       | Stage lookup and response; define banking before a second LSU                 | 18.0 ns before SRAM timing                           |
|        3 | MEM queue                | Compact entries and register queue read                                       | 11.4 ns; second LSU otherwise duplicates the problem |
|        4 | EX1/PTW/dispatch/backend | Narrow feedback buses and add state boundaries                                | Four independent 8-9.5 ns cones                      |
|        5 | PMP integration          | Rerun the whole-core partition; stage only if the integrated path requires it | Isolated cut is now 8.096 ns                         |
|        6 | Frontend/normal ALU      | Optimize after the above                                                      | Neither currently limits the core                    |

## Interpretation limits and required next flow

This is pre-layout cell-delay characterization, not signoff STA:

- ABC reports `WireLoad = none`;
- there is no SDC clock, IO budget, generated-clock definition, clock
  uncertainty, or audited false/multicycle exception;
- setup, hold, clock-to-Q, skew, jitter, and slew propagation are absent;
- retained hierarchy cuts cross-boundary paths;
- inferred L1 SRAMs have no Liberty timing;
- there is no placement, routing, extraction, CTS, congestion, or SI analysis.

A credible frequency requires SRAM/register-file macros, a fully flattened or
physically partitioned netlist, explicit SDC, placed-and-routed extraction, and
STA. PMP is structurally repaired but needs a whole-core rerun. The multiply
chunk remains the largest measured logic cut, and the divider is now in the
same pre-layout range as L1D.
