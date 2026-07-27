# Coherent CCX variants

## Scope and repository boundary

The existing one-hart and generated transport-only complex remain unchanged.
The coherent work is additive:

```text
rtl/complex/2h/ccx.v       fixed two-hart variant
rtl/complex/4h/ccx.v       fixed four-hart variant
rtl/complex/coherent/      implementation shared by two and four harts
```

The first implementation includes the probe control plane and a separate
non-inclusive coherent protocol frontend.  The selected design uses an
independently tagged snoop-filter directory in front of the existing L2.
See `ccx-coherent-protocol.md` for the frontend/L2 boundary.

The one-hart implementation does not use these modules.  The shared coherent
modules reject hart counts other than two and four.

## Current invariants

- Directory residency is independent of L2 residency.
- A directory victim with recorded sharers is not reused until every recorded
  I-cache and D-cache copy acknowledges invalidation.
- A directory bit is removed only after the corresponding probe ACK.
- Probe identity, command, cache selection, and line address remain stable
  until each target accepts the probe.
- Probe addresses are aligned to the 64-byte coherence granule.
- The initial tracker permits one active invalidation.
- The coherent frontend is the home and currently serializes all traffic.
- Four-hart request arbitration is round-robin.  The next-hart pointer advances
  only when the home accepts a request; a stalled or failed transaction never
  times out into a second grant for the same line.
- Each four-hart L1D probe endpoint has its own one-entry request/response
  storage.  Its timeout is a protocol-error watchdog only: it cannot fabricate
  an ACK or revoke ownership without a completed L1D invalidation.
- A private sharer is recorded before its successful fill response is exposed.
- I-cache and D-cache sharers are distinct.
- Private lines remain clean; cross-hart data fetch is not yet legal.

## Cleanup and implementation ledger

Items below are deliberately not hidden behind compatibility behavior.

### Existing baseline

- [ ] Diagnose the `tb_core_complex.sv` full-line data mismatch.  It reproduces
  in the existing one-hart AXI and four-hart Wishbone targets, so it is not
  evidence against the new coherent control plane.
- [ ] Rename or clearly label the existing `wrapper_nh.v` complex as
  transport-only once downstream users have migrated.
- [ ] Keep the existing one-hart regressions as the compatibility baseline.

### Private-cache endpoints

- [x] Add one independent bounded probe request/response slot to each of the
  four CCX4 L1D probe lanes.  This is production RTL, although the complete
  request/home/L2 wrapper integration remains pending.  ACK is withheld until
  the matching L1D invalidation completes.
- [ ] Add the corresponding independent probe endpoint to each L1I.
- [x] Invalidate resident matching L1D lines and ACK absent lines.
- [x] Treat a targeted L1D probe as a generation boundary for matching demand
  MSHRs, prefetch MSHRs, and fill state.  Old responses are consumed by
  transaction ID but cannot reinstall the invalidated generation.
- [x] Make targeted L1D invalidation independent of unrelated demand MSHRs,
  store-buffer occupancy, and retirement response backpressure.
- [x] Break the serialized-home circular wait: targeted snoops do not force
  the target's unrelated store buffer to drain, so all four private store
  buffers may wait on the home while still servicing probes.
- [ ] Define clean-eviction notification only if measurements show stale
  directory bits produce material probe traffic.

### Coherent L2 and home

- [x] Separate the coherent frontend from the non-inclusive L2 backend.
- [x] Add an independently tagged I/D snoop-filter directory.
- [x] Invalidate recorded private copies before directory replacement.
- [ ] Replace or qualify the current combinational snoop-filter arrays with a
  synchronous SRAM-friendly lookup pipeline before making frequency or area
  claims.
- [ ] Lock down the current L2 write-response coherence point with assertions
  and directed tests.
- [x] Integrate `coherent_protocol.v` between the line crossbar and
  `l2_native.v` in the focused four-L1D testbench.
- [ ] Move that integration into the production 2h/4h complex wrappers.
- [ ] Add per-hart response queues so one stalled hart cannot block unrelated
  responses.
- [ ] Replace global serialization with bounded per-line home transactions
  after the one-transaction invariants are proven.
- [ ] Keep MMIO/device requests outside L2 allocation and directory updates.
- [ ] Allow PTW requests to allocate in L2 without becoming private sharers.
- [ ] Remove the earlier L2-indexed directory-control prototype after the fixed
  2h/4h wrappers use the independently tagged frontend.

### Writes, atomics, and ordering

- [ ] Preserve LR, SC, AMO operation, width, and `aq`/`rl` from the core
  through the private-cache endpoint.
- [x] Mark a direct architectural LR at the L1D boundary when
  `COHERENT_RESERVATIONS` is enabled.  The default remains the original local
  reservation behavior for single-hart systems.
- [x] Translate the existing L1D atomic marker into a reserve-first home LR
  followed by an ordinary cached read, and translate the marked write into SC,
  while keeping the fabric lock signal low.
- [x] Execute LR/SC reservation validation at the coherent home.
- [ ] Move AMO arithmetic to the home, or carry the original AMO opcode to it.
  The compatibility path still computes the AMO result in the local RV64A
  block before issuing SC.
- [x] Add one reservation record per hart and define the initial reservation
  granule as one 64-byte line.
- [x] Clear matching reservations on conflicting writes and consume the
  requester's reservation on every SC attempt.
- [ ] Clear reservations on per-hart reset/disable without resetting unrelated
  harts.
- [x] Return failed-SC status to the architectural LSU and restart a
  decomposed AMO from its read half when `SC_STATUS_IN_RDATA` and
  `COHERENT_ATOMICS` are enabled.  The retry never reuses the stale computed
  write value.
- [ ] If dirty private ownership is ever added, implement data-bearing
  `READ_SHARED` and `READ_INVALIDATE` probes before enabling it.
- [ ] Replace globally draining L2 fences with per-hart outstanding-operation
  accounting.
- [ ] Connect architectural `FENCE` to actual L1D store and request drains.
- [ ] Keep `FENCE.I` local; perform remote instruction synchronization through
  software notification and remote `FENCE.I`.

### Reset, SoC, and software

- [ ] Define a per-hart reset/online handshake that clears directory bits only
  after the corresponding private caches can no longer return hits.
- [x] Instantiate four cores with fixed `mhartid` values zero through three in
  the focused `tb_4h_3p` integration harness.  This is not yet a production
  four-hart SoC wrapper.
- [ ] Parameterize platform CLINT and PLIC integration for the selected hart
  count.
- [ ] Replace the single-hart OpenSBI device tree with generated 1/2/4-hart
  descriptions.
- [ ] Stop forcing hart zero in the OpenSBI trampoline.
- [ ] Add secondary-hart release and boot synchronization.
- [ ] Reuse the AXI and timed-DDR3 path below the new coherent L2.

### Verification gates

- [ ] Probe/refill race with ACK withheld until the refill cannot install.
- [x] Sequential read/read/write/read visibility through four real L1Ds, the
  directory frontend, and the shared L2.
- [x] Same-line full-width writes simultaneously queued by all four harts.
- [ ] Same-line writes with disjoint byte lanes.
- [x] Non-inclusive directory eviction with mixed I-cache and D-cache sharers.
- [x] Directed LR/SC success, repeated-SC failure, and reservation loss after
  an intervening write.
- [x] Every implemented 64-bit AMO arithmetic operation through four local
  RV64A engines under globally quiescent atomic phases.
- [x] A held LR is broken by another hart's forced invalidation; the later SC
  fails locally without issuing a home SC.
- [x] Four complete cores share one SATP and one atomic line while enforcing
  modulo-four turn taking.  Every successful write invalidates the other three
  retained L1D copies.  This schedule does not force SC failure.
- [ ] Concurrent LR/SC and AMO contention, 32-bit AMOs, and an observed
  failed-SC AMO retry.
- [ ] Acquire/release message-passing and full-fence litmus tests.
- [ ] Per-hart reset during an otherwise idle system and during queued traffic.
- [ ] Four real cores through OpenSBI and timed DDR3.

## Four-L1D integration test

`tb/tb_ccx_4h_l1d_directory_l2.sv` instantiates:

```text
four LSU-side request agents plus four local RV64A engines
  -> four openrv64_l1d_ccx instances
  -> openrv64_ccx_line_crossbar
  -> openrv64_ccx_coherent_protocol
  -> openrv64_ccx_4h_l1d_probe_cluster (reverse snoop path)
  -> openrv64_ccx_l2_native
  -> fixed-latency line-memory model
```

Run it with:

```sh
make sim-ccx-4h-l1d-directory-l2
```

The directed sequence proves:

- harts 0 and 1 can retain clean copies of one line while harts 2 and 3 use
  unrelated lines through the same L2;
- a repeat access hits in private L1D;
- a write from a non-sharer invalidates exactly the recorded sharers;
- the directory does not forward the write to L2 before both real L1D
  invalidation handshakes complete;
- a probed hart reloads the new value from L2 without a backing-memory read;
  and
- a later sharer set containing harts 0 and 3 is also invalidated correctly;
- all four store buffers can drain concurrently while their writes fight over
  the same line, with accepted home commands following strict round-robin
  order;
- sixteen lines each survive four shared readers, four contending writers,
  and four ordered 64-bit AMOADD operations; and
- a snoop clears a held local LR reservation, making the subsequent SC fail
  without reaching the home.

The randomized phase then runs 2,048 rounds by default: 8,192 ordinary
operations over an eight-page (32 KiB) window, including 2,048 stores, plus 64
64-bit AMOs rotating across all four harts.  The preceding directed phase adds
64 shared reads, 64 contended stores, and 64 AMOs over sixteen lines, plus one
store used to break a held LR.  Addresses, word lanes, payloads, and AMO
operations are varied from a deterministic xorshift seed; use `+seed=<decimal>`
with the compiled simulation to replay another stream.

Two independent scoreboards check the result:

- a tag scoreboard records every accepted LSU/L1D request and matches the
  normal or posted response by hart and tag, including read data; and
- a home-order scoreboard compares every L2 command/data beat with the write
  expected from that hart, applies byte strobes to reference memory in actual
  home acceptance order, and checks later home reads against that state.

The random round still uses four distinct lines and at most one buffered
writer.  The separate directed phase removes that restriction for one line:
four writers are queued before all four store buffers are released together.
The home remains globally serialized, so this proves deadlock freedom and
round-robin acceptance for the current one-transaction design, not
cross-line concurrency.

AMOs are ordered one at a time in this test.  The existing local RV64A block
reduces an AMO to a marked read and marked write.  With coherent mode enabled,
the L1D adapter encodes those halves as LR and SC, the directory checks the
reservation, and the crossbar treats SC as a write-data-bearing command.  A
failed SC is returned to RV64A, which restarts the AMO from its read half.
That retry path is implemented but this test does not yet force two
simultaneous AMOs to observe it.

This is not yet a four-core test.  The four agents drive the LSU-side contract
below the core memory channel; they do not instantiate decode, translation, or
the LSQ.  The backing store is deterministic, not timed DDR3.  The L1D probe
endpoint is production RTL in `rtl/complex/coherent/l1d_probe_endpoint.v` and
the fixed four-way cluster is in `rtl/complex/4h/ccx.v`.  L1I still lacks the
corresponding endpoint.

The home does not probe a recorded requester for its own write.  An ordinary
write-through store retains the requester's newly updated clean D-cache copy
and invalidates only other recorded sharers.  SC is different: the requester
invalidates locally before issue, the home probes only remote sharers, then
clears the complete D-sharer vector.  A redundant self-probe would deadlock
behind the requester's stalled SC response.  Targeted L1D invalidation may
preempt unrelated private work, while a matching detached miss is consumed
and reissued across the invalidation generation boundary.

## Validation snapshot

Run on 2026-07-27 UTC from repository revision `fa83b59` plus the uncommitted
changes described above:

```sh
make sim-ccx-4h-l1d-directory-l2
make sim-exec-lsu-rv64-a sim-atomic-context
make sim-core-3p-ccx-l2-vm
```

The four-L1D test passed at cycle 113,615 with 16 directed ping-pong lines,
8,192 randomized ordinary operations, 2,113 total stores after setup and
directed phases, and 128 AMOs.  The serialized RV64A LSU test and integrated
atomic-context test passed.  The one-core Sv39 CCX/L2/AXI/banked-DDR3
regression passed at 55,846 cycles with the expected result
`a0=0x000000000a277880`.
