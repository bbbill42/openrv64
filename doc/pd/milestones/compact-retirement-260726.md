# Compact tag-indexed retirement milestone — 2026-07-26

## What was run, and when (UTC)

This report reuses the last valid full-core map and measures the changed
retirement boundaries independently.

| Run                    | Started             | Finished            | Command / source                                                                                                                                           | Purpose                                                   |
|------------------------|---------------------|---------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------|
| Full-core reference    | 2026-07-25 22:40:26 | 2026-07-25 23:52:08 | `RESOURCE_JOBS=32 SOURCE_ROOT=/tmp/openrv64-tagged-l1d-final2.XWpSr3 make yosys-resources-core-sky130 YOSYS_CORE_RESOURCE_DIR=sim/yosys/tagged-l1d-260725` | Last valid complete functional-boundary map               |
| Compact ordering queue | 2026-07-26 05:55:55 | 2026-07-26 05:55:57 | Isolated Sky130 map of `openrv64_retire_queue_3p`, depth 8, ID width 10                                                                                    | Ordering/control area and timing                          |
| Compact record bank    | 2026-07-26 05:54:14 | 2026-07-26 05:54:27 | Isolated Sky130 map of `openrv64_retire_records_3p`, 8 x `{130,281}`, trace disabled                                                                       | Canonical payload storage area and timing                 |
| Compact commit         | 2026-07-26 05:55:55 | 2026-07-26 05:55:58 | Isolated Sky130 map of `openrv64_retire_3p`, metadata 130, result 281                                                                                      | Architectural-commit area and timing                      |
| RTL regressions        | 2026-07-26          | 2026-07-26          | `make -B sim-retire-queue-3p sim-retire-3p sim-backend-3p sim-top-3p`                                                                                      | Queue, commit, integrated backend, and selectable 3P core |

The compact maps used Git `e23485a0720cbc79f4108ca9fa5189b26824d957`
with a dirty working tree. The changed retirement RTL is therefore identified
by this report and the working-tree diff, not by the commit alone.
Raw compact-map logs and JSON statistics are under
`/tmp/openrv64-retire-compact-260726/{queue,records,commit}`. That directory is
temporary; the numerical results needed to interpret the milestone are
preserved below.

All maps used:

| Setting                    | Value                                                                        |
|----------------------------|------------------------------------------------------------------------------|
| Yosys                      | 0.66 (`86f2ddebc-dirty`)                                                     |
| Cell library               | Sky130 HD, TT, 25 C, 1.8 V                                                   |
| Liberty SHA-256            | `ec0e1067a35c8bf20b11e58d1e8ac53326067e4dac84a125cc1b917a3518d0d9`           |
| ABC constraints SHA-256    | `7bc97e5a90f50e8b3f7f46984b55595886869c3b0b9b09b8f752a7dc6574714b`           |
| Input driver / output load | `sky130_fd_sc_hd__inv_2` / 10 fF                                             |
| Physical scope             | Mapped cells only; no placement, routing, CTS, wire load, or SRAM macro area |

The common isolated flow was:

```text
read_verilog -sv -DSYNTHESIS -Irtl ...
chparam ...
hierarchy -check -top ...
proc
flatten -noscopeinfo
opt
memory -nomap
opt
techmap
opt
dfflibmap -liberty <sky130-liberty>
abc -liberty <sky130-liberty> -constr synth/sky130/abc.constr
clean -purge
stat -liberty <sky130-liberty> -json
```

## Result

The retirement block is approximately half its prior mapped size:

| Metric             | Last full build retirement | Compact retirement |                      Change |
|--------------------|---------------------------:|-------------------:|----------------------------:|
| Standard-cell area |               0.634960 mm² |   **0.291296 mm²** | **-0.343665 mm² (-54.12%)** |
| Sequential area    |               0.177470 mm² |   **0.069126 mm²** | **-0.108344 mm² (-61.05%)** |
| Mapped cells       |                     86,260 |         **45,979** |       **-40,281 (-46.70%)** |

This is a retained-boundary replacement comparison:

- old: `openrv64_retire_queue_3p` plus `openrv64_retire_3p`;
- new: `openrv64_retire_queue_3p`,
  `openrv64_retire_records_3p`, and `openrv64_retire_3p`.

It is not a current full-core build. Holding every other block at the last
valid full-build value projects mapped logic from 7.123870 to
**6.780205 mm²**, a **0.343665 mm² or 4.82%** whole-core reduction.
Retirement falls from 8.91% of that full build to about **4.30%** of the
projected total.

The same substitution projects CPU-side logic, excluding L1 controllers,
TLBs, PTW, and memory routing, from 2.537746 to **2.194082 mm²**:
**-13.54%**. This projection does not credit the backend for eliminating the
old depth-wide completed-result forwarding scan, so it is conservative with
respect to this change. It is not conservative with respect to unrelated RTL
changes after the frozen full build.

## Retirement sub-blocks

| Compact sub-block                            |             Area | New retirement | Projected full core |  Sequential area |      Cells |
|----------------------------------------------|-----------------:|---------------:|--------------------:|-----------------:|-----------:|
| Canonical allocation/result records          |     0.267801 mm² |         91.93% |               3.95% |     0.065823 mm² |     42,318 |
| Ordering, IDs, valid/complete, squash        |     0.014847 mm² |          5.10% |               0.22% |     0.003303 mm² |      1,997 |
| Prefix commit and architectural side effects |     0.008648 mm² |          2.97% |               0.13% |     0.000000 mm² |      1,664 |
| **Compact retirement total**                 | **0.291296 mm²** |    **100.00%** |           **4.30%** | **0.069126 mm²** | **45,979** |

The remaining cost is overwhelmingly the multiport record bank, not ordering
or commit control.

## Projected block sizing from the last full build

Only the retirement row is replaced by a current isolated measurement. Every
other row is copied from `tagged-l1d-260725`. Percentages use the projected
6.780205 mm² mapped-cell total.

| Functional block                |   Projected area | Projected total | Measurement status                                                             |
|---------------------------------|-----------------:|----------------:|--------------------------------------------------------------------------------|
| L1D control/tags                |     2.415963 mm² |          35.63% | Last full build                                                                |
| L1I control/tags                |     1.380386 mm² |          20.36% | Last full build                                                                |
| Backend control/forwarding      |     0.660816 mm² |           9.75% | Last full build; does not include expected shrink from the new forwarding path |
| I/D TLBs                        |     0.323259 mm² |           4.77% | Last full build                                                                |
| Dispatch/hazards                |     0.299771 mm² |           4.42% | Last full build                                                                |
| Page-table walker               |     0.294914 mm² |           4.35% | Last full build                                                                |
| CSR/PMP                         |     0.293787 mm² |           4.33% | Last full build                                                                |
| **Retirement**                  | **0.291296 mm²** |       **4.30%** | Current isolated replacement                                                   |
| Integer register file           |     0.232785 mm² |           3.43% | Last full build                                                                |
| Fetch/line buffers              |     0.182037 mm² |           2.68% | Last full build                                                                |
| Memory-system routing/AXI       |     0.141725 mm² |           2.09% | Last full build                                                                |
| EX0 integer/M                   |     0.109372 mm² |           1.61% | Last full build                                                                |
| EX1 integer/branch              |     0.052747 mm² |           0.78% | Last full build                                                                |
| Branch predictor                |     0.043559 mm² |           0.64% | Last full build                                                                |
| Shared L2 TLB                   |     0.029876 mm² |           0.44% | Last full build                                                                |
| Frontend/core control           |     0.018909 mm² |           0.28% | Last full build                                                                |
| Decode, three lanes             |     0.005413 mm² |           0.08% | Last full build                                                                |
| Trap/redirect vector            |     0.003590 mm² |           0.05% | Last full build                                                                |
| **Projected mapped-cell total** | **6.780205 mm²** |     **100.00%** | Mixed full-build baseline plus current retirement                              |

The last full build also preserved 16 KiB each of L1I and L1D data arrays,
32 KiB total, plus a 4,608-bit L1D request-overlay memory as inferred SRAM.
Their physical macro area is not included above.

Useful boundary totals from the same projection are:

| Boundary                 | Projected mapped-cell area | Includes                                                                   |
|--------------------------|---------------------------:|----------------------------------------------------------------------------|
| CPU-side logic           |           **2.194082 mm²** | Frontend, backend, GPR, execution, CSR/PMP, retirement                     |
| Cacheless core logic     |           **2.983856 mm²** | CPU-side logic plus TLBs, PTW, shared L2 TLB, and memory routing           |
| L1-integrated core logic |           **6.780205 mm²** | Cacheless core plus L1I/L1D controllers, tags, buffers, and prefetch logic |
| L1 cache data SRAM       |   **32 KiB, area unknown** | 16 KiB L1I plus 16 KiB L1D inferred memories; no selected macro views      |

## Representation change

The old queue stored a complete allocation packet and then copied another
complete execution packet back into the same slot:

```text
old per entry:
  valid1 + complete1 + ID10 + allocation metadata415 + completion457
  = 884 bits
  = 7,072 bits at depth 8
```

The new queue and record bank store:

```text
new per entry, physical area profile:
  valid1 + complete1 + ID10
  + allocation record130
  + completion-only record281
  = 423 bits
  = 3,384 bits at depth 8
```

That is **3,688 fewer resident state bits (-52.15%)** before mux and enable
logic. The payload alone falls from 872 to 411 bits per entry, -52.87%.

The 130-bit allocation record contains PC, instruction, architectural
source/destination addresses, dependency/order flags, memory/control flags,
and the old/new physical tags. The 281-bit completion record contains only
CSR/return/exception intent, decoded exception flags, result data, and next
PC. PC, instruction, source/destination fields, physical tags, and trace ID
are no longer copied through completion.

The 64-bit trace ID is stored once in a separate allocation-only bank when
`ENABLE_TRACE=1`; that raises trace-enabled resident state to 487 bits per
entry, still 44.91% below the old 884-bit representation. The physical area
profile sets `ENABLE_TRACE=0`, so trace storage is absent.

The ordering queue now emits three slot selectors. Those selectors read the
single canonical record bank. Full forwarding uses the existing
youngest-owner map plus live completion overlay; it no longer scans and
exports every completed 457-bit retirement entry.

## Timing

These are isolated ABC endpoint estimates with no wire load. They are useful
for comparing the retained blocks, not for claiming core frequency.

| Boundary              |            Last full build |  Compact map |                Change |
|-----------------------|---------------------------:|-------------:|----------------------:|
| Ordering / queue      |                   4.177 ns | **3.354 ns** |   -0.824 ns (-19.72%) |
| Canonical record bank | n/a; embedded in old queue | **1.585 ns** | New explicit boundary |
| Commit logic          |                   1.793 ns | **1.719 ns** |    -0.073 ns (-4.10%) |

The first compact queue implementation still counted retained squash entries
with a depth-wide ID/valid scan. It mapped at 4.363 ns. Replacing that scan
with ring distance from `head` through the resolving branch slot reduced the
queue estimate to 3.354 ns.

Do not add the three numbers and call the sum a clock period. The full path
can cross retained boundaries, and only a current full timing run can identify
the actual critical endpoint and routing burden.

## Memory implementation limit

The canonical record bank is deliberately forced to registers for this
measurement. Its current contract is three asynchronous reads and up to three
completion plus three allocation writes per cycle. No ordinary 1R/1W or
1R/1W-dual-port SRAM macro implements that.

Allowing Yosys to preserve this as an arbitrary `$mem_v2` would make the cell
area appear smaller while silently moving the dominant cost into an
unavailable multiport macro. That would be false accounting.

The next structural reduction is completion banking/backpressure:

1. interleave slots across banks so a three-entry allocation prefix writes at
   most one entry per bank;
2. arbitrate same-bank completion collisions and use the execution units'
   existing completion backpressure;
3. register or pipeline retirement reads if a synchronous SRAM macro is
   required;
4. remeasure the bank-conflict rate before accepting new bubbles.

Until that work exists, this is a compact multiport register file, not
macro-qualified SRAM.

## Validation and known failure

Passed:

- `sim-retire-queue-3p`: full depth, allocation-time completion,
  out-of-order completion, partial retirement, flush, selective recovery,
  modular ID wrap, and exact trace-bank selection;
- the same queue/record test at `DEPTH=16`;
- `sim-retire-3p`: three-wide prefix commit, exception boundary, IRQ, CSR,
  return, and dependency release;
- `sim-backend-3p`: full-forwarding backend, precise store queue, page/PMP
  faults, retry, SATP ordering, and retirement;
- `sim-top-3p`: selectable 3P core fetch/retire and ordered store;
- `git diff --check`.

`sim-top-axi-3p` compiled through all changed retirement/debug interfaces, then
failed at runtime with:

```text
FATAL: tb/tb_top_axi_3p.sv:365: unsupported native CCX command
```

That failure is in the concurrently changing cache/CCX path. It is not evidence
against retirement correctness, but it means there is no clean current
full-system regression or full-core area snapshot to claim here.
