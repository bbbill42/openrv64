# Non-inclusive coherent protocol and L2 boundary

## Decision

The two-hart and four-hart complexes use a coherence frontend between the
hart-facing CCX crossbar and the shared L2:

```text
private L1I/L1D endpoints
        |
        v
CCX line crossbar
        |
        v
coherent_protocol
  - independently tagged snoop-filter directory
  - probe issue and response tracking
  - write permission
  - ordering and future home atomics
        |
        v
non-inclusive l2_native
        |
        v
GenBus / AXI / timed DDR3
```

The L2 is not the coherence home.  It is a non-inclusive data cache behind the
home.  L2 replacement therefore has no relationship to private-cache
residency and does not require a probe or directory callback.

The directory remains necessary.  It is an independently tagged snoop filter,
not metadata attached to L2 set/way entries.  It records a conservative
superset of private I-cache and D-cache sharers for each resident directory
line.

## Initial private-cache state model

The initial protocol is Shared/Invalid with clean private lines:

- L1D is write-through and no-write-allocate.
- L1I and L1D may retain clean lines after the L2 evicts the corresponding
  line.
- A cacheable write probes every recorded D-cache sharer other than the
  write-through requester and waits for all acknowledgements before
  forwarding the write to L2.
- A directory entry may be replaced only after all recorded I-cache and
  D-cache sharers of the victim line acknowledge invalidation.
- Clean private eviction need not update the directory.  A stale sharer bit
  causes a harmless probe to a cache that no longer holds the line.
- Device traffic bypasses the directory and probe path.
- PTW traffic may use L2 but is never recorded as a private sharer.

The frontend records a private sharer before returning a successful fill to
the requesting cache.  Consequently, a directory miss means no private cache
can legally retain that line.

## Cross-hart fetches

No cross-hart data fetch is required while private lines are clean.  L2 or
memory remains authoritative, so a read always obtains data below the
coherence frontend.

Cross-hart data intervention becomes mandatory only if a later protocol adds
Modified or dirty private ownership.  That extension requires:

- one precise dirty owner instead of only clean sharer vectors;
- `READ_SHARED` and `READ_INVALIDATE` probes;
- a probe response capable of returning a full 512-bit line;
- arbitration between an owner response, L2 refill, store-buffer contents,
  and a concurrent invalidation;
- writing intervention data back to L2, or forwarding it directly while
  preserving a later writeback obligation; and
- directory transient states that prevent a second requester from observing
  the old owner or stale L2 data.

The coherent protocol definitions reserve the commands and data-response
encoding now.  The current frontend accepts only clean `ACK` responses and
reports any data-bearing response as a protocol error.

## Current operation sequences

### Private read or instruction fetch

1. Look up the physical line in the snoop-filter directory.
2. On a directory miss, choose an entry.
3. If the victim records private sharers, invalidate them and wait for every
   response.
4. Allocate the independently tagged directory entry.
5. Send the read to L2.
6. After a successful L2 response, record the requesting I-cache or D-cache
   sharer.
7. Return the response to the private cache.

### Cacheable write

1. Buffer the command and its tagged write-data beat.
2. Look up the line in the directory.
3. Invalidate every recorded D-cache sharer except the requester.  The
   write-through requester retains its newly updated clean copy.
4. Wait for every probe response.
5. Clear those D-cache sharer bits.
6. Forward the write to L2.
7. Return completion only after the L2 response.

Instruction-cache sharers are retained.  RISC-V instruction visibility still
uses local and remote `FENCE.I`; ordinary stores do not silently replace that
architectural protocol.

### Compatibility LR/SC path

The current architectural RV64A block performs AMO arithmetic locally and
marks both the read and write halves of its read/modify/write sequence.  At the
L1D/CCX boundary:

1. a marked read first issues `LR` to the home;
2. the home read establishes a 64-byte reservation and conservatively records
   the requesting L1D as a D-cache sharer;
3. after that response, L1D performs the ordinary cached lookup and ignores
   the line returned by the reservation transaction;
4. a cached hit supplies the architectural LR value, while a miss issues an
   ordinary shared `READ`, not a second `LR`;
5. a marked write invalidates the requester's local copy and is encoded as
   `SC`;
6. `req_lock` remains zero across the shared fabric;
7. any accepted coherent write to that line clears matching home
   reservations;
8. every SC attempt consumes the requester's home reservation;
9. a matching SC invalidates all recorded remote D-cache sharers, clears the
   complete D-sharer vector, is forwarded to L2 as an ordinary write, and
   returns
   `sc_success=1`; and
10. a non-matching SC consumes its tagged data beat, returns
   `sc_success=0`, and performs no L2 operation.

Reserve-first ordering is required.  Looking up the private line and creating
the home reservation afterward could pair a stale cached value with a fresh
reservation if another hart writes between those two events.  A conflicting
write after reservation creation instead finds the conservative sharer bit,
invalidates the private line, and clears both the home and local reservation.

The SC requester is excluded from the home probe mask.  Its L1D has already
completed a contractual local invalidation before SC issue, and it cannot
accept a redundant self-probe while its atomic access is stalled waiting for
the SC response.  Including it creates a local protocol deadlock.  This
exclusion does not preserve a requester copy: successful SC still clears all
D-sharer bits for the line.

The crossbar classifies SC as a write-data-bearing command.  L2 remains
unaware of reservations and sees only the successful underlying read or
write.

With `COHERENT_ATOMICS`, `SC_STATUS_IN_RDATA`, and
`COHERENT_RESERVATIONS` enabled, the L1D returns failed-SC status to RV64A,
the AMO engine restarts a failed decomposed AMO at its read half, and a direct
architectural LR creates a home reservation.  A D-cache probe acceptance also
clears the local reservation, so a later direct SC fails locally without
issuing a stale home request.

This remains a compatibility implementation, not a final home-atomic design.
The original AMO opcode, width, and `aq`/`rl` information are not carried to
the home; arithmetic still occurs in the local RV64A block.  Ordered same-line
AMOs and explicit LR reservation loss are verified.  Concurrent AMOs that
force the failed-SC retry path are not yet covered.

Reservation and cache ownership are deliberately separate in the current
clean S/I implementation.  There is no Exclusive or Modified owner.  If dirty
private ownership is added, an LR that encounters a dirty owner must receive
the owner's current data before the home can establish a reservation on the
observed value.  A read downgrade from Exclusive to Shared need not by itself
break the prior owner's reservation; any write, ownership transfer for write,
or invalidation must.  Those rules require data-bearing probes and explicit
owner/transient state and are not implemented here.

### Device request

The request goes directly to L2's bypass path.  The physical memory map must
not permit cacheable and device aliases to the same storage.

### Fence

The initial frontend allows one global transaction, so an accepted fence is
already behind all prior frontend traffic.  It forwards the fence to L2 and
waits for L2 completion.  This is stronger and slower than required.  A later
multi-transaction frontend must replace it with per-hart accounting.

## L2 requirements for the initial protocol

Basic clean S/I coherence does not require a new L2 controller.  The current
`l2_native.v` can remain the backend if the following contracts are locked
down with tests and assertions:

1. A write response is the L2 coherence point.  After the response, a later
   read accepted through the frontend must observe the written bytes.
2. A resident partial write updates the authoritative L2 line before
   completion.
3. A write miss or device write does not complete until the downstream write
   response is known.
4. A read response carries the original hart, transaction, source, beat, and
   error identity without rewriting.
5. `FENCE` completes only after older L2 MSHRs, writebacks, bypass requests,
   and queued responses have drained.
6. L2 may replace any line without consulting the coherence frontend.
7. L2 never assumes that its own eviction invalidates a private line.
8. The frontend submits only ordinary `READ`, `WRITE`, and `FENCE` operations;
   it consumes LR/SC reservations above L2 and forces the lock signal low.

The current L2 already implements most of this shape.  Before integration,
add directed regressions for read-after-partial-write, write-miss completion,
fence drain, and identity preservation through backpressure.

## Required L2 work

Required for initial integration:

- diagnose the existing full-line mismatch in `tb_core_complex.sv`;
- add explicit assertions for the write-response coherence point;
- add the frontend-to-L2 contract regressions above;
- document that L2 is non-inclusive and private-cache unaware; and
- retain device bypass and PTW generation behavior through the frontend.

Not required for initial integration:

- L2 sharer bits;
- L2 allocation or eviction probe hooks;
- L2 ownership state;
- data-bearing snoops;
- home LR/SC reservations inside L2; or
- per-hart fence state inside L2.

The coherent frontend now implements serialized LR/SC reservations.  A later
revision must either execute AMOs as home read/modify/write microsequences or
preserve enough operation metadata and failed-SC feedback to retry the current
decomposition.  Either design remains coherent only for masters routed
through this home; DMA and other external coherent agents require an expanded
system protocol.

## Later performance work

The current frontend deliberately permits one transaction globally.  Scaling
it requires per-line home entries rather than relaxing correctness:

- a synchronous SRAM-qualified directory lookup pipeline;
- multiple directory lookups and outstanding L2 transactions;
- same-line serialization with unrelated-line concurrency;
- per-hart response queues and ordering counters;
- independent probe transactions with unique IDs;
- conflict handling between directory victim invalidation and a request for
  that victim line; and
- measured directory geometry and replacement policy.

None of those changes require making L2 inclusive.
