# Cycle and pipeline trace

The existing `dbg_pc` and `dbg_instr` outputs are last-writeback indicators.
They cannot prove pipeline timing: a held instruction repeats, a loop reuses a
PC, and a flushed instruction never appears at writeback. The optional trace
interface adds a unique fetch ID and exposes each pipeline boundary every
cycle.

## Generate a trace

```sh
make sim-top-trace
```

This writes:

- `sim/openrv64-cycle.csv`: stable, machine-readable `openrv64-cycle-v1` rows.
- `sim/openrv64-pipeline.txt`: utilization summary, cycle timeline,
  per-instruction timing, and architectural retire log.

Paths can be overridden without changing the testbench:

```sh
make sim-top-trace \
  TRACE_CSV=/tmp/run.csv \
  TRACE_REPORT=/tmp/run.pipeline.txt
```

To run a flat software binary at `0x80000000` in a 64 KiB RAM and trace it:

```sh
make sim-sw-trace SW_BIN=sw/test.bin
```

This writes `sim/sw-test-trace.csv` and `sim/sw-test-pipeline.txt`. The software
bench fails on an exception or timeout and, for `sw/test.bin`, verifies that
the return loop is reached with `a0=100`. Forwarding and predictor experiment
controls are described in [forwarding.md](forwarding.md).

An existing CSV can be rendered or filtered directly:

```sh
python3 tools/pipeline_trace.py sim/openrv64-cycle.csv \
  --start-cycle 40 --end-cycle 90 --max-cycles 0
```

## RTL interface

Set `ENABLE_TRACE=1` on `openrv64_top`. When it is zero, all trace outputs are
constant zero, and the fetch trace-ID sidecar is not elaborated; synthesis can
remove the remaining trace ID path and counters.

The five-bit stage vectors use bit `0=IF`, `1=ID`, `2=EX`, `3=MEM`, and
`4=WB`. The same ordering is used by the 64-bit slices in `trace_ids` and
`trace_pcs`, and the 32-bit slices in `trace_instrs`. For example, the execute
UID is `trace_ids[2*64 +: 64]`.

| Output                                                           | Meaning                                                                                 |
|------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| `trace_cycle`                                                    | Rising-edge count since reset deassertion.                                              |
| `trace_valid[4:0]`                                               | The corresponding stage owns an instruction ID.                                         |
| `trace_stall[4:0]`                                               | Valid instruction neither advances nor flushes this cycle.                              |
| `trace_flush[4:0]`                                               | Stage is invalidated this cycle. Payload outputs are masked.                            |
| `trace_advance[4:0]`                                             | Stage completes a local step or downstream handoff.                                     |
| `trace_ids[319:0]`                                               | Unique dynamic instruction ID per stage; zero when invalid.                             |
| `trace_pcs[319:0]`                                               | PC per stage; zero when invalid.                                                        |
| `trace_instrs[159:0]`                                            | Instruction word per stage; zero when invalid or while IF still waits for its response. |
| `trace_events[7:0]`                                              | Redirect, trap, IRQ, MRET, SRET, restart, halt, reset.                                  |
| `trace_stall_causes[7:0]`                                        | RAW, WAW, scoreboard, IF memory, data memory, execute, frontend held, serializing.      |
| `trace_retire_valid`                                             | WB entry is consumed, including a faulting instruction.                                 |
| `trace_retire_arch`                                              | Instruction completed without an exception.                                             |
| `trace_retire_exception`                                         | Instruction generated an exception.                                                     |
| `trace_retire_cause`                                             | Exception cause when `trace_retire_exception` is set.                                   |
| `trace_retire_next_pc`                                           | Sequential or resolved next PC carried by WB.                                           |
| `trace_retire_rd_write`, `trace_retire_rd`, `trace_retire_wdata` | Architectural GPR update; writes to x0 are suppressed.                                  |

Bit-number constants are in `rtl/core/trace/trace-defs.v` and form part of the
trace ABI.

The IF slot covers the fetch transaction or resident-line replay. A miss can
assert `trace_advance[IF]` once when memory returns and again when the fetched
word is accepted by ID; a resident hit skips the memory-return phase. The UID
remains unchanged across those steps. ID through WB use `advance` for the
downstream handoff. A fresh UID is allocated whenever a fetch PC is accepted,
including a resident replay; it is not reused if that dynamic fetch is later
redirected or flushed.

## CSV and cosimulation contract

`tb/openrv64_cycle_trace.sv` samples the trace pins on the falling edge, after
the preceding rising-edge state update has settled. It writes one flat CSV row
per active-reset cycle. Hexadecimal vectors have no `0x` prefix; `cycle`, the
boolean retire fields, and `retire_rd` are decimal. Every row carries the
literal schema value `openrv64-cycle-v1`.

Cosimulation should compare architectural state only when
`trace_retire_valid` is set:

1. If `trace_retire_exception=1`, compare the trap cause and do not apply a GPR
   write.
2. Otherwise require `trace_retire_arch=1`, advance the reference model by one
   instruction, and compare PC, instruction, next PC, and any reported GPR
   write.
3. Use the UID only for timing correlation. It is intentionally not
   architectural state.

The CSV is also suitable for cocotb or Verilator, but file output is not
required there: those harnesses can sample the same top-level pins directly.

## Reading utilization

The report separates three quantities that should not be conflated:

- `occupied`: cycles in which a stage contains any valid dynamic instruction;
- `completed`: occupied cycles attributed to UIDs that eventually reached the
  retire boundary, including exceptions;
- `not_done`: occupied cycles attributed to wrong-path, flushed, or unfinished
  UIDs.

`IPC` counts only non-exception architectural retirement. A high occupied
percentage with low completed occupancy is wasted speculative work, while high
stall counts with high completed occupancy identify latency rather than wrong
path. The per-instruction table gives exact cycle ranges, so a multi-cycle EX or
MEM residency is directly visible rather than reconstructed from writeback
timestamps.

## Three-pipe causal trace

`sim-top-axi-3p-perf` always enables the 3P pipeline trace and writes the path
selected by `AXI_3P_TRACE_CSV`. Its current schema is
`openrv64-3p-cycle-v2`; `tools/pipeline_trace_3p.py` continues to read saved
`openrv64-3p-cycle-v1` files.

Unlike v1, v2 includes the program-ordered dispatch queue as an explicit `Q`
stage. The stage order is therefore `F`, `D`, `Q`, physical-pipe `I`, `C`,
and `R`. A queued UID, PC, and instruction can now be followed directly to
the first issue gate that stopped it. `I` remains physical pipe order
(`EX0`, `EX1`, `MEM`), while `Q` and `candidate_fire` remain program order.

The current v2 writer also includes packed retirement GPR write-valid, rd, and
data fields plus LSU request/response tag, address, write-data, strobe, and
read-data fields.  These make silent data corruption diagnosable even when the
retired PC/instruction stream is identical.  Packed lane 0 occupies the least
significant slice, matching the RTL buses.  Older saved v2 files without these
diagnostic suffix columns remain readable because the report uses the stable
causal/stage subset.

When the suffix columns are present, the readable pipeline window appends
`MEMR`, `MEMW`, `MEMRESP`, and `WB<lane>` events with their tags and data.  It
therefore shows the request that corrupted memory and the later load response
without requiring a separate CSV script.

The raw hazard masks remain in the CSV because simultaneous hazards are useful
diagnostics, but they are not cycle attribution. `block_lane` names the first
program-ordered candidate which did not issue and `block_reason` gives one
exclusive cause. The numeric reason ABI is:

| Value | Name              | Meaning                                                                                            |
|------:|-------------------|----------------------------------------------------------------------------------------------------|
|     0 | `none`            | Every presented candidate issued, or the queue was empty.                                          |
|     1 | `raw_pending`     | A source producer exists but has not completed.                                                    |
|     2 | `raw_bundle`      | The source is produced by an older candidate issuing in the same bundle.                           |
|     3 | `raw_completed`   | The producer completed, but the general forwarding map is disabled or did not release this source. |
|     4 | `waw_pending`     | An unfinished older instruction owns the destination.                                              |
|     5 | `waw_bundle`      | An older candidate in the same issue bundle claims the destination.                                |
|     6 | `waw_completed`   | A completed, unretired instruction still owns the destination.                                     |
|     7 | `read_port`       | The per-register read-port limit rejected the candidate.                                           |
|     8 | `barrier`         | A hard-order instruction prevented allocation.                                                     |
|     9 | `retire_capacity` | The retirement queue capacity gate prevented allocation.                                           |
|    10 | `pipe_conflict`   | An older same-cycle candidate already claimed the selected pipe.                                   |
|    11 | `pipe_busy`       | The selected execution pipe was not ready.                                                         |
|    12 | `invalid_pipe`    | Dispatch selected no implemented execution pipe.                                                   |
|    13 | `unknown`         | The candidate failed despite all instrumented gates passing. This should remain zero.              |

When multiple hazard bits apply to the same candidate, the exclusive reason
uses the table order: RAW, WAW, read-port, barrier, retirement capacity, pipe
conflict, then pipe readiness. The original masks remain beside it so the
secondary conditions are not lost.

Additional v2 fields expose:

- candidate source/destination registers, source-use bits, pipe selections,
  hazard-free and fire masks;
- existing-producer versus same-bundle RAW masks, completed-producer RAW/WAW
  masks, and which source operand caused RAW;
- retirement head readiness and the bitmap of completed live entries, making
  completion behind an unfinished head directly countable;
- control flush/redirect state;
- frontend resident and pending line masks, bus request occupancy, and the
  current/following-line hit state;
- LSU request/response handshakes, occupied and sent tag slots, posted-store
  state, and store/order interlock state.

The simulation also prints `PERF_DISPATCH`, `PERF_BRANCH_BLOCK`, `PERF_BLOCK`,
`PERF_RETIRE_BLOCK`, `PERF_FRONTEND`, and `PERF_LSU`. `PERF_DISPATCH` counts
successful `valid && ready` transfers into the physical EX0, EX1, and MEM
pipes; unlike the legacy `PERF issued` field, it does not count a valid held
during pipe backpressure more than once. `PERF_DISPATCH_BLOCK` counts those
backpressured cycles separately for EX0, EX1, and MEM. In issue-window mode the
three pipes are independent and more than one may increment in a cycle; in
strict mode only the exclusive first candidate blocked directly by pipe
backpressure increments. Same-bundle pipe conflicts are not pipe-busy events.
`PERF_BRANCH_BLOCK pipe_full` counts cycles in which an otherwise selectable
conditional branch cannot transfer because EX0 is not ready. It excludes
dependency, barrier, retirement-capacity, and same-bundle pipe-conflict stalls.
`PERF_BLOCK` is the exclusive first-nonissued-candidate distribution. The
renderer labels the old counts as overlapping observations and reports the
exclusive distribution separately.

Useful anchors include a retired PC, a dynamic UID, an absolute cycle, or the
first occurrence of a block reason:

```sh
python3 tools/pipeline_trace_3p.py sim/run.csv --around-uid 12ab
python3 tools/pipeline_trace_3p.py sim/run.csv --start-cycle 50000
python3 tools/pipeline_trace_3p.py sim/run.csv \
  --block-reason raw_completed --before 4 --rows 20
```
