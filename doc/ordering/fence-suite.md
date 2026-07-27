# Sv39 fence correctness and microbenchmark report

Date: 2026-07-25 UTC

Status: **FAIL — the tested RTL is not fence-correct**

## Executive summary

The Sv39 fence suite ran nine independent directed cases against a delayed
external CCX/home model. Only `load; fence r,r; load` passed. The suite
observed direct external-ordering violations for `fence w,r`, `fence o,i`,
partial-line stores followed by `fence w,r`, and `FENCE.I`. Other store cases
failed because required stores never reached the external boundary. The
twelve-line pressure case stopped on an LSQ timeout after only one directed
store reached the boundary.

Both full-hierarchy atomic workloads failed on an unexpected posted-store
completion for an atomic LSQ entry. The lower-level serialized RV64A and
integrated atomic-context tests passed.

The microbenchmark completed, but its timing results characterize an
incorrect implementation. They must not be treated as acceptable fence
latencies.

## Scope

This report covers:

- ordinary `FENCE` predecessor/successor combinations for memory reads and
  writes;
- I/O predecessor and successor bits against a translated device page;
- merged partial stores;
- twelve posted stores to distinct lines;
- delayed L1D/CCX responses;
- empty and back-to-back fences;
- self-modifying code with `FENCE.I`;
- the existing bare and Sv39 full-hierarchy atomic workloads;
- the existing serialized and integrated atomic unit tests; and
- matched cache-hot fence microbenchmarks.

SATP replacement and `SFENCE.VMA` with outstanding loads, stores, PTW
requests, or speculative reads are deliberately out of scope. The bootstrap
executes one `SFENCE.VMA` to activate its initial page tables. Directed
workloads execute no translation fence.

## Tested state

The base repository state was:

```text
branch: main
HEAD:   6d91b0ebccc83ff312298be55a0e89c8e735c914
```

The worktree was not clean. It contained the fence-suite changes and
pre-existing unrelated edits. The commit hash is therefore a base reference,
not a sufficient reproduction identifier.

Toolchain and simulator:

```text
Verilator 5.050 2026-07-01 rev v5.050
riscv64-elf-gcc 15.2.0
```

The integrated configuration used:

- three-pipe core, mode 3 frontend and BP8;
- issue window and speculation window enabled;
- 16-entry retirement queue;
- posted stores enabled;
- L1D prefetch disabled;
- 16 KiB L1I and 16 KiB L1D;
- 256 KiB, eight-way L2;
- 16 MiB fixed-latency AXI SRAM; and
- no DDR timing model.

## Sv39 layout

Supervisor code executes through a non-identity mapping:

```text
VA 0x40000000..0x4003ffff -> PA 0x80000000..0x8003ffff, RWX
VA 0x40040000..0x40040fff -> PA 0x10000000..0x10000fff, RW device
```

The harness observes supervisor mode, Sv39 in `satp`, a translated instruction
fetch, and at least three PTW reads in every isolated case. Directed physical
addresses seen by the checker establish that the data accesses passed through
translation.

## External-boundary oracle

Selected physical requests terminate in a testbench CCX/home model instead of
the normal L2. The model delays every selected completion by 24 cycles. A
predecessor is complete only when the external model launches its tagged
response. A successor request reaching that boundary earlier is an ordering
failure.

Retirement, dispatch stalls, local L1D acceptance, and fence retirement counts
are coverage signals only. They are not used as the ordering oracle.

The coherent home is the architectural visibility boundary for cacheable
memory. Waiting for a later dirty-line DRAM writeback would test cache
replacement and writeback policy rather than visibility to other coherent
requesters. Device cases use the physical non-cacheable page at `0x10000000`.

Each directed case is a separate executable. A deadlock or missing store in
one case therefore cannot suppress later cases. After the software stop, the
harness continues servicing the external model for 4096 cycles plus the
response delay before checking transaction completeness.

## Directed correctness results

The aggregate command returned nonzero. One of nine cases passed.

| Case | Sequence                                  | Result | External observation                                                                                                                                                            |
|-----:|-------------------------------------------|--------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|    1 | store; `fence w,w`; store                 | FAIL   | The predecessor store and drain load completed, but the successor store never reached home. The zero violation mask is not a pass: required coverage was absent.                |
|    2 | store; `fence w,r`; load                  | FAIL   | The successor load reached home before the predecessor store completed. The predecessor store never appeared. Mask `0x002`.                                                     |
|    3 | load; `fence r,r`; load                   | PASS   | Two requests and two completions; mask `0x000`.                                                                                                                                 |
|    4 | load; `fence r,w`; store                  | FAIL   | The predecessor and drain loads completed, but the successor store never reached home.                                                                                          |
|    5 | I/O `o,o`, `o,i`, `i,i`, `i,o`            | FAIL   | `o,i` exposed its successor input early, mask `0x020`. Only five of eight expected device transactions appeared; three device stores were absent.                               |
|    6 | merged partial stores; `fence w,r`; load  | FAIL   | The successor load reached home before the partial-store line completed. The partial write never appeared, so its exact payload/strobe assertion was not reached. Mask `0x100`. |
|    7 | twelve stores; `fence w,r`; load          | FAIL   | Only the first directed store reached home before an LSQ timeout on a later store at PA `0x80010a40`.                                                                           |
|    8 | empty/back-to-back fences; observed store | FAIL   | Four ordinary fences retired and the drain load completed, but the terminal store never reached home.                                                                           |
|    9 | code store; `fence.i`; refetch            | FAIL   | Two instruction fetches reached home before the code store. Stale code returned `FENCEF+0x41`; mask `0x400`.                                                                    |

The violation-mask bits are:

```text
bit 0  w,w
bit 1  w,r
bit 2  r,r
bit 3  r,w
bit 4  o,o
bit 5  o,i
bit 6  i,i
bit 7  i,o
bit 8  partial-line predecessor
bit 9  twelve-line pressure predecessor set
bit 10 FENCE.I code-store completion
```

Coverage failures and violation masks are separate. A zero mask means no
observed successor crossed an incomplete predecessor; it does not pass a test
when a required request never reached the boundary.

## Atomic results

| Target                | Result | Observation                                                                                        |
|-----------------------|--------|----------------------------------------------------------------------------------------------------|
| `sim-atomic-sv39`     | FAIL   | LSQ assertion: unexpected posted-store completion for atomic tag 4; the entry had `access_sent=0`. |
| `sim-atomic-soc`      | FAIL   | Same assertion class for atomic tag 4 in the bare workload.                                        |
| `sim-exec-lsu-rv64-a` | PASS   | Serialized RV64A LSU test passed.                                                                  |
| `sim-atomic-context`  | PASS   | Integrated LR/SC, AMO, WFI-hint, and AMO-fault-context test passed.                                |

The two full-hierarchy failures show that the current posted-store completion
contract is inconsistent with atomic LSQ bookkeeping. The common assertion
does not by itself prove that both failures have one root cause.

## Microbenchmark results

The benchmark measured 1024 cache-hot iterations of matched no-fence and
fenced loops.

| Fence | Baseline total | Fenced total | Baseline cycles/iteration | Fenced cycles/iteration | Increment |
|-------|---------------:|-------------:|--------------------------:|------------------------:|----------:|
| `r,r` |          2,398 |       10,248 |                    2.3418 |                 10.0078 |    7.6660 |
| `r,w` |          4,103 |        9,223 |                    4.0068 |                  9.0068 |    5.0000 |
| `w,r` |          6,148 |       12,292 |                    6.0039 |                 12.0039 |    6.0000 |
| `w,w` |          8,186 |       11,268 |                    7.9941 |                 11.0039 |    3.0098 |

Raw simulator output:

```text
PERF_FENCE_SV39_RESULTS iters=1024 rr_none=2398 rr=10248 rw_none=4103 rw=9223 wr_none=6148 wr=12292 ww_none=8186 ww=11268
```

These are fixed-latency simulation cycles. They are not silicon latency,
frequency, or DRAM performance measurements. More importantly, fence timing
is not meaningful as a quality metric until the corresponding correctness
cases pass.

## Interpretation

### Observed facts

- The selected `r,r` ordering case completes correctly.
- Several store instructions retire without the required store ever becoming
  visible at the external home boundary.
- `w,r`, `o,i`, the partial-store case, and `FENCE.I` have direct ordering
  violations at the external boundary.
- The pressure case has a forward-progress failure.
- Both full-hierarchy atomic workloads encounter a posted-store completion
  that the LSQ does not consider outstanding.

### Root-cause inference

The dominant pattern is consistent with fence completion being insufficiently
coupled to posted-store drain and external store completion. `FENCE.I`
additionally appears to permit instruction invalidation/refetch before the
older code store is externally complete.

This is an inference, not a complete root-cause proof. The missing ordinary
stores, atomic completion assertion, uncached-device losses, and pressure
timeout may include multiple defects across LSQ completion bookkeeping, L1D
store-buffer draining, and fence control.

## Reproduction

Run the complete suite, including the benchmark:

```sh
make fence-sv39-suite
```

The target continues after failed subtests and returns nonzero if any
correctness or atomic test fails.

Run only correctness and atomic tests:

```sh
make check-fence-sv39
```

Run one directed case:

```sh
make sim-fence-sv39-case FENCE_CASE=3
```

Run only the microbenchmark:

```sh
make bench-fence-sv39
```

The case-number map is in `sw/fence/README.md`. Add `+fence_trace` to the
underlying `sim-core-3p-ccx-l2` arguments when per-request boundary traces are
needed.

## Required follow-up

1. Define one tagged posted-store completion contract from L1D/CCX through
   the LSQ, including atomic ownership and cancellation rules.
2. Make each ordinary `FENCE` predecessor mask wait for the relevant external
   completions before allowing matching successors to reach the home.
3. Drain older executable-memory stores before I-cache invalidation and
   post-`FENCE.I` refetch.
4. Repair uncached/device store completion and rerun all four I/O bit
   combinations independently if needed.
5. Repair pressure-path forward progress and require all twelve lines to
   complete before the successor load.
6. Rerun this suite before interpreting fence microbenchmark deltas.
7. Add the separate SATP/`SFENCE.VMA` outstanding-traffic suite after ordinary
   fence completion is reliable.
