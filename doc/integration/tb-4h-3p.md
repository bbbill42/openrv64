# Four-hart 3P shared-Sv39 and atomic integration

## Validation record: 2026-07-27 UTC

- Repository base: `fa83b59`, plus the uncommitted implementation described
  here.
- Four-hart top: `tb/tb_4h_3p.sv`.
- Verilator runtime worker budget: `--threads 4` for four instantiated harts.
  This enforces the requested one-thread-per-hart ratio.  Verilator may still
  schedule generated partitions dynamically; it does not promise permanent
  hart-to-host-thread affinity.
- Verilator compile parallelism: `-j 32`.
- Invocation rule: run the outer `make` without `-j`.  The target owns its
  32-way generated-C++ build; an inherited outer jobserver made that nested
  build effectively serial in the observed environment.
- Workloads: finite CoreMark-derived parser loop and a directed RV64A
  turn-taking test.  No CoreMark score is claimed.

Commands run:

```sh
make sim-4h-3p-sv39
make sim-4h-3p-shared-sv39
make sim-4h-3p-shared-sv39 CORE_4H_3P_L1D_PREFETCH_ENABLE=0
make sim-4h-3p-bare
make sim-4h-3p-bare CORE_4H_3P_L1D_PREFETCH_ENABLE=0
make sim-4h-3p-atomic-sv39
make sim-4h-3p-shared-suite
make sim-ccx-4h-l1d-directory-l2
make sim-exec-lsu-rv64-a sim-atomic-context
make sim-core-3p-ccx-l2-vm
```

All commands passed.  The complete-core results were:

The final four-hart Verilation rebuilt 147 generated C++ files in 42.392 s
wall time; Verilator reported 27.841 s CPU on the configured 32 compile
threads.

| Test | SATP arrangement | Cycles | Completion cycles, harts 0..3 | Retired, harts 0..3 | CCX requests, harts 0..3 | L2 memory R/W |
| --- | --- | ---: | --- | --- | --- | ---: |
| `sim-4h-3p-sv39` | four roots, same VA maps to separate physical prefixes | 66,320 | 62,574 / 64,102 / 65,119 / 65,309 | 56,324 / 54,796 / 53,779 / 53,589 | 1,542 / 1,541 / 1,542 / 1,541 | 155 / 16 |
| `sim-4h-3p-shared-sv39` | one shared root, hart-indexed private pages | 67,825 | 66,368 / 66,778 / 66,788 / 66,798 | 54,036 / 53,626 / 53,616 / 53,606 | 1,593 / 1,574 / 1,574 / 1,566 | 58 / 44 |
| `sim-4h-3p-atomic-sv39` | one shared root and one shared atomic line | 24,228 | 23,148 / 23,156 / 23,164 / 23,172 | 2,470 / 2,462 / 2,454 / 2,446 | 593 / 593 / 593 / 593 | 11 / 3 |

### L1D prefetch comparison: 2026-07-27 UTC

The shared-root workload was rebuilt and run with the L1D next-line prefetcher
both enabled and disabled.  Both models used four Verilator runtime threads.
The build directory includes `pf0` or `pf1` and the speculative-load address
window, so changing either elaboration setting cannot accidentally reuse an
incompatible model.

| L1D prefetch | Test completion | Hart completion cycles, 0..3 | Completion mean / spread | CCX requests, 0..3 | L2 memory R/W |
| --- | ---: | --- | ---: | --- | ---: |
| on (default) | 67,825 | 66,368 / 66,778 / 66,788 / 66,798 | 66,683 / 430 | 1,593 / 1,574 / 1,574 / 1,566 | 58 / 44 |
| off | 67,587 | 66,548 / 66,558 / 66,568 / 66,578 | 66,563 / 30 | 1,549 / 1,549 / 1,549 / 1,549 | 51 / 44 |

Disabling prefetch reduced final test completion by 238 cycles (0.351%) and
mean hart completion by 120 cycles (0.180%).  This was not a uniform speedup:
hart 0 finished 180 cycles later, while harts 1 through 3 each finished 220
cycles earlier.  The more defensible result is that prefetch increased
contention and completion skew in this globally serialized four-hart home.  It
added 111 CCX requests and seven backing-memory reads without improving the
tail.

The reported retired-instruction totals are not suitable for this comparison.
A hart spins at its completion label until the last mailbox becomes visible,
so an earlier-finishing hart accumulates extra loop retirements.  The
prefetch-on run's larger completion skew therefore also produced a larger
retirement count.

### Bare-address comparison: 2026-07-27 UTC

The same shared workload also ran in S-mode with `satp` left Bare.  Code and
data retain the same physical addresses and cache indices as the shared-Sv39
image.  The bare build moves the speculative-load eligibility window from
virtual `0x40000000` to physical `0x80000000`; the build path includes that
base in its identity.

| Address mode | L1D prefetch | Test completion | Hart completion cycles, 0..3 | Completion mean / spread | CCX requests, 0..3 | L2 memory R/W |
| --- | --- | ---: | --- | ---: | --- | ---: |
| Sv39 | off | 67,587 | 66,548 / 66,558 / 66,568 / 66,578 | 66,563 / 30 | 1,549 / 1,549 / 1,549 / 1,549 | 51 / 44 |
| Bare | off | 67,247 | 66,208 / 66,218 / 66,228 / 66,238 | 66,223 / 30 | 1,542 / 1,542 / 1,542 / 1,542 | 47 / 44 |
| Sv39 | on | 67,825 | 66,368 / 66,778 / 66,788 / 66,798 | 66,683 / 430 | 1,593 / 1,574 / 1,574 / 1,566 | 58 / 44 |
| Bare | on | 67,526 | 65,979 / 66,479 / 66,489 / 66,499 | 66,361.5 / 520 | 1,595 / 1,566 / 1,566 / 1,559 | 54 / 44 |

With prefetch disabled, removing Sv39 saved exactly 340 cycles per hart and
seven accepted CCX requests per hart.  The shared L2 reduced those 28 PTW
requests to four additional backing-memory reads.  Bare mode was 0.503%
faster at final test completion.

Direct handshake counters reject a store-fast-path explanation for this
workload.  Both the Bare and Sv39 prefetch-off runs allocated 3,255 stores per
hart, accepted 3,255 stores per hart through the tagged PMP/L1D fast path, and
accepted zero stores through the serial fallback.  In Bare mode,
`translation_bypass_i` marks each LSQ store translated at allocation and
copies its virtual address into the physical-address field; it does not send
the store through the translation state machine.  This evidence is narrower
than a general correctness proof: it does not exercise uncached stores,
atomics, PMP rejection, or every redirect/backpressure interleaving.

Within Bare mode, disabling prefetch saved 279 final-completion cycles
(0.413%) and 138.5 mean hart-completion cycles (0.209%).  It removed 118 CCX
requests and seven backing-memory reads.  This independently reproduces the
Sv39 result: current L1D prefetching causes small contention and completion
skew, not bus saturation.

An initial Bare run used the virtual speculative-load base and completed in
about 75,000 cycles.  That run is invalid as an address-mode comparison:
physical Bare loads fell outside the eligibility window, disabling
issue-window load speculation.  It is intentionally excluded from the tables.

The atomic run reached counter value 256.  Each hart completed exactly 64
successful SC operations after 257 LRs.  SC failures were zero.  Every
successful write invalidated three remote L1D copies: each hart accepted 192
probes and observed 192 reservation-clear events.  The final suite run reported
5.069 s aggregate CPU on four threads and 1.283 s wall time for this atomic
test.  Its shared-root test reported 31.383 s aggregate CPU on four threads
and 7.893 s wall time.  The earlier separate-root run reported 28.933 s
aggregate CPU on four threads.

The lower-level four-L1D directory test passed at cycle 113,615 after 2,048
randomized rounds, 8,192 ordinary operations, 2,113 stores, and 128 atomics.
The serialized RV64A LSU test, integrated atomic-context test, and one-core
Sv39 CCX/L2/AXI/banked-DDR3 regression also passed.  The last completed in
55,846 cycles with `a0=0x000000000a277880`.

## Instantiated hierarchy

```text
4 x openrv64_rv64_top_3p
  - fixed HART_ID = 0, 1, 2, 3
  - mhartid wired through the CSR path
  - private L1I and L1D
  - coherent reservation-clear input from its L1D probe endpoint
        |
        v
openrv64_ccx_line_crossbar
        |
        v
openrv64_ccx_coherent_protocol
  - independently tagged D/I sharer directory
  - one 64-byte LR reservation record per hart
  - one globally active home transaction
        |                         ^
        |                         |
        |                4 x independent L1D
        |                invalidate/ACK slots
        v
256 KiB shared l2_native
        |
        v
fixed-latency 512-bit line-memory model
```

All interrupt inputs are tied low.  There is no CLINT, PLIC, platform bus, AXI
bridge, or timed DDR model in `tb_4h_3p`.  This intentionally bypasses the
current single-hart interrupt-platform problem; it does not solve it.

## Address-space tests

### Separate roots

All harts start at physical `0x80000000`, read their actual `mhartid`, and
select one of four Sv39 roots.  The same supervisor virtual range beginning at
`0x40000000` maps to a different 1 MiB physical prefix:

| Hart | Supervisor physical prefix | Root page table |
| ---: | ---: | ---: |
| 0 | `0x80000000` | `0x80020000` |
| 1 | `0x80100000` | `0x80120000` |
| 2 | `0x80200000` | `0x80220000` |
| 3 | `0x80300000` | `0x80320000` |

The test checks independent root fetches, physical prefixes, mailbox values,
retirement from all harts before first completion, and absence of home/probe
protocol errors.

### Shared root

All harts install identical SATP mode and PPN bits, naming the root at physical
`0x80020000`.  One three-level Sv39 table maps the 128 KiB range
`0x40000000-0x4001ffff` to `0x80000000-0x8001ffff`.

Code and read-only data are shared.  Four adjacent private pages at virtual
addresses `0x40002000`, `0x40003000`, `0x40004000`, and `0x40005000` provide
separate stacks, sinks, and completion records.  The workload derives the
page address from `mhartid`; the page table itself is not hart-specific.

## Atomic test and coherence contract

The counter is a 32-bit word at virtual `0x40001080`, initially zero.  Every
hart repeatedly executes `lr.w.aq`.  Only the hart satisfying
`counter % 4 == mhartid` attempts `sc.w.rl`, so successful stores advance the
counter in the exact hart order 0, 1, 2, 3.  Each hart stops after the counter
reaches 256 and records its completion and success count in its private page.

This is a shared-copy invalidation test, not an SC-contention test.  Zero SC
failures are expected under the deterministic turn rule: non-eligible harts
read and retain the line but do not attempt SC.  The meaningful coherence
evidence is the exact 768 remote probes, three per successful write, and 192
probe-driven reservation clears observed by each hart.

A coherent LR uses two phases:

1. L1D issues LR to the home before admitting the cached lookup.
2. The home establishes the hart's 64-byte reservation and conservatively
   records the L1D as a sharer.
3. L1D ignores the home-returned data and performs its normal cache lookup.
4. A resident clean hit supplies the architectural value.  A miss issues an
   ordinary shared read because the reservation already exists.

Reserve-first order is required.  Lookup-first could pair stale private data
with a new home reservation if another hart wrote between the lookup and
reservation transaction.

Any coherent write to the line clears matching home reservations.  Probe
acceptance clears the target hart's local architectural reservation before ACK.
SC first invalidates the requester's local copy, so the home excludes that
requester from the remote probe mask.  A redundant self-probe deadlocks: the
requester's L1D is waiting for its SC response and therefore cannot service a
probe whose ACK is required to produce that response.  After remote ACKs, a
successful SC clears the complete directory D-sharer vector and writes L2.

Reservation and ownership are separate.  The current private data state is
clean Shared/Invalid; there is no Exclusive or Modified owner and no
cache-to-cache data forwarding.  Adding dirty ownership later requires
data-bearing probes and a rule that an LR observes forwarded current data
before its reservation is established.

The assembly contains `.aq` and `.rl` encodings, but the current compatibility
path does not preserve the original AMO operation or `aq`/`rl` metadata at the
home.  This run therefore does not validate acquire/release ordering.

## Bugs exposed by the complete-core runs

- `HART_ID` reached the CCX bus but not the CSR implementation, so every core
  originally observed `mhartid == 0`.
- A full posted-store buffer could hold the shared L1 port while waiting for
  home progress, preventing an incoming probe from draining.  Posted-store
  admission is now gated when the buffer is full.
- A cache-hit LR originally had no point at which to create the home
  reservation.  The reserve-first two-phase path fixes that without hiding
  broken invalidation behind home-returned data.
- Probing the SC requester created the local circular wait described above.
  The home now probes only remote sharers and still clears all sharer metadata
  after successful SC.

## Scope limits

This proves four complete cores can execute concurrently through Sv39 and the
shared CCX/L2 hierarchy, and that the directed atomic schedule causes real
remote L1D invalidation.  It does not prove:

- scalable coherent throughput; the home serializes globally;
- dirty ownership, cache-line forwarding, Exclusive/Modified states, or
  writeback;
- concurrent SC failure/retry or AMO retry under active contention;
- acquire/release, fence, or general RISC-V memory-model litmus behavior;
- L1I coherence or executable-data modification;
- DMA or external coherent-master interaction;
- interrupt routing, secondary-hart release, OpenSBI/Linux boot, AXI, or timed
  DDR behavior in the four-hart hierarchy; or
- fixed host affinity between one Verilator worker and one RTL hart.
