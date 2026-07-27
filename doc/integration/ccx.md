# Core-complex hart integration

This document defines what an OpenRV64 hart and its private caches must provide
to integrate with the shared core complex.  It covers the northbound coherent
boundary.  AXI4 and WISHBONE remain external transports below the complex and
are not hart-facing protocols.

The native northbound CCX data interface is fixed at 512 bits: one transfer
beat is exactly one 64-byte cache line.  A requester may issue a burst covering
multiple consecutive cache lines.  Such a burst remains a sequence of 512-bit
line beats; CCX never packs multiple cache lines into one beat.  Consequently,
the native CCX line size is fixed at 64 bytes rather than parameterized
independently from the interface width.

The generated core complex now accepts the same native command, write-data,
and response channels exposed by the private L1I/L1D endpoints.  It carries
full cache lines and multi-line bursts into the shared L2 and straps each port
to `HART_ID_BASE + port_index`.  It is not yet coherent with multiple enabled
private L1 caches.  Adding an invalidation wire alone is not sufficient:
coherent integration also requires explicit operation intent, probe
acknowledgement, transient-state handling, atomic execution at the home agent,
and real memory-barrier completion.

## Current limitations

The compatibility core-memory port exports only `valid`, `ready`, `write`,
address, write data, byte strobes, read data, and error.  It has no transaction
ID, access size, requester type, memory attributes, or ordering information.
Consequently, `rtl/complex/protocol/hart_legacy_adapter.v` can emit only:

- `READ` or `WRITE`;
- `kind=LEGACY`;
- `order=NONE`;
- a constant integration-selected attribute; and
- an eight-byte transfer.

That adapter remains in the standalone legacy protocol wrappers.  It is not
used by `openrv64_core_complex_nh`; its 64-bit scalar channel does not implement
the native 512-bit cache-line contract.

Other current restrictions are:

- `rtl/core/exec/lsu/rv64-a.v` still keeps LR/SC reservations inside the hart.
  AMOs retain the local read/compute/write implementation but now mark both
  memory phases for private-L1 bypass and local serialization.  The marker is
  not forwarded as `ccx_req_lock`, and the shared L2 performs no exclusion.
  This is a one-hart-only bring-up mechanism, not an atomic protocol.
- The decoder accepts RV64A `aq` and `rl` bits, but the core currently discards
  them because the legacy memory path is blocking and strictly ordered.
- `rtl/cache/l1/l1.v` is physically tagged, hit-pipelined, write-through, and
  no-write-allocate.  Its separate lookup/physical address inputs allow VIPT
  L1I operation; L1D ties them together.  Resident reads sustain one request
  and response per cycle; misses and uncached accesses serialize the
  lower-memory port.  Tagged cacheable L1D stores may instead enter an ordered
  byte-masked line FIFO.  Back-invalidation drains accepted lookups, responses,
  and that store FIFO before modifying tags.
- L1I fill/prefetch slots and L1D fill/store buffers default to eight
  cachelines.  Their depths are parameterized.  The fill slots do not yet make
  the private caches nonblocking: each demand backend still has one active CCX
  miss and lacks transaction-ID-indexed MSHRs.
- The shared native L2 accepts `READ`, `WRITE`, and a drain-style `FENCE`.
  Dormant compatibility logic can still consume a marked read/write pair, but
  the native core path never emits that marker.  LR, SC, and explicit AMO
  operations still fail.  It does not track private-cache sharers or emit
  probes.
- `openrv64_ccx_l2_native` consumes and produces native 512-bit cache-line
  beats.  Its command queue feeds a lookup/hit pipeline, and parameterized
  per-line MSHRs permit multiple outstanding misses, same-line request merging,
  and resident hits while unrelated fills are outstanding.  The default
  configuration has eight MSHRs, eight waiters per MSHR, sixteen command
  entries, and sixteen response entries.  Every command entry has a tagged
  one-beat write-data slot containing the 512-bit line, 64 byte enables, and
  protocol-error state.  This lets data for a later write be accepted while
  the head write is stalled, without reordering command issue.  Multi-line
  writes refill that slot one beat at a time as the command advances.
  PTE-visible cache lines additionally carry an eight-bit generation. A
  `FENCE` request with `kind=PTE` advances the current generation after
  draining older L2 work.
- The L2-to-bus-abstraction boundary is also fixed at 512 bits.  A fill,
  writeback, or uncached bypass is one size-6 neutral-bus request; width
  conversion happens below that boundary in `genbus_interface`.  For example,
  one L2 request becomes eight AXI beats on a 64-bit external AXI port.  It is
  not broken into eight scalar requests above the bus abstraction.
- The native L2 is split into one SRAM-inference boundary per way.  Each way
  has a synchronous read port and one full-line write port for its data and tag
  arrays; data and tags are not reset.  Valid bits remain separate metadata.
  Fill, merged-store replay, and resident-store writes share the port with
  fixed priority, and a blocked lower-priority pipeline stage is held.
  Victim lines and refill data are captured in MSHRs rather than requiring
  extra SRAM read ports.  Technology-specific SRAM macro selection and timing
  remain physical-implementation work, but the RTL no longer assumes
  combinational or arbitrarily multiported L2 storage.
- `HART_ID` now reaches both native CCX identity and the `mhartid` CSR on the
  three-pipe top.  The generated complex has 1-16 native hart ports and checks
  their strapped IDs, but it does not instantiate or coherently probe the
  private caches.

## Required hart request contract

A native hart endpoint must preserve the following fields through translation,
PMP checking, and private-cache lookup:

| Field | Meaning |
| --- | --- |
| `valid/ready` | Decoupled request acceptance.  Payload remains stable until accepted. |
| `hart_id` | Physical source hart, matching the hart's `mhartid`. |
| `source_id` | At least instruction cache, data cache, or PTW. |
| `txn_id` | Requester transaction identity, not reused until its response is drained. |
| `op` | Read, write, LR, SC, AMO function, or fence. |
| `lock` | Reserved compatibility field. The native one-hart core path drives zero; it is not an atomic contract. |
| `order` | None, acquire, release, or acquire-release. |
| `attr` | Per-request cacheable, device, idempotent, and executable attributes. |
| `size` | Sub-line access size for atomics and uncached operations; cache-line transfers imply 64 bytes. |
| `addr` | Physical start address.  Cache-line operations are 64-byte aligned. |
| `burst_len` | Number of additional consecutive cache lines; zero requests one line. |
| `wdata/wstrb` | One 512-bit cache-line beat and 64 byte enables. |

The response must return `hart_id`, `source_id` or an equivalent uniquely
routed identity, `txn_id`, one 512-bit cache-line data beat, `beat_index`,
`last`, error, and SC success.

The native CCX response carries `hart_id`, `source_id`, and `txn_id`.
The standalone legacy wrappers still lack `source_id` and therefore remain
valid only for their single merged requester.

The PTW bounds an active CCX request or response with
`CCX_TIMEOUT_CYCLES` (65,536 cycles by default, zero to disable). A timeout
completes the originating translation as a precise instruction, load, or
store access fault. If the command was accepted before the timeout, the PTW
retains a transaction tombstone and will not reuse its fixed transaction ID
until a possible late response has been drained. The timeout does not turn a
blocking PTE read into an imprecise or asynchronous abort.

## Cache-line transport and bursts

The interface above CCX is cache-line based.  Scalar execution loads and stores
terminate at the private-cache or hart-endpoint boundary; they are not expanded
into a 64-bit CCX datapath.  A cacheable miss, refill, eviction, intervention,
or prefetch moves one complete 64-byte line on each accepted CCX beat.

The native burst contract is:

- `burst_len=0` requests one cache line;
- `burst_len=N` requests `N+1` consecutive cache lines beginning at `addr`;
- line `i` has address `addr + 64*i`;
- each request-data or response-data beat carries exactly one line;
- response beats may return out of line-address order, so `beat_index` is
  authoritative and the requester must track all `N+1` responses;
- `last` identifies the highest-numbered line (`beat_index=burst_len`), not
  necessarily the last response to arrive;
- backpressure applies independently to every line beat; and
- different tagged bursts may be interleaved, but beats remain identifiable by
  `hart_id`, `source_id`, and `txn_id`.

A burst is complete only after every declared response beat has been accepted;
observing `last` alone is insufficient.  It is not an atomic multi-line
operation and does not reserve or lock all of its lines.  The L2 expands it
into individual home operations so each line is independently looked up,
merged, probed, ordered, and faulted.  Arbitration may occur between its line
operations so a long burst cannot monopolize CCX.

All lines declared by one burst must be physically contiguous and use the same
operation, ordering mode, and PMA attributes.  The requester splits a burst
where translation is not physically contiguous or attributes change.  CCX is
not constrained by AXI's 4 KiB rule; the southbound adapter splits an external
AXI burst as necessary.

Read, refill, and prefetch operations consume no request-data beats and return
one 512-bit response beat per line.  Line writeback or other line writes supply
one 512-bit request-data beat per line with a corresponding 64-bit byte mask.
Atomics, fences, and side-effecting device operations require `burst_len=0`.
For a sub-line atomic or uncached access, `addr` and `size` select bytes within
the 512-bit beat and only those data lanes are meaningful.

The command and line-data channels must be independently backpressured.  An
implementation may accept a burst descriptor only when it has reserved enough
tracking state, but it must not require buffering the entire burst's data before
the first line can progress.

The current shared L2 is not limited to one outstanding transaction: distinct
line misses occupy distinct MSHRs and requests to one outstanding line can
merge into its waiter list.  Private endpoints may still begin with one
outstanding demand transaction.  When endpoint concurrency is enabled, it must
additionally ensure that:

- canceled speculative reads are drained and their tags are not reused early;
- stores and atomics cannot be canceled after becoming globally visible;
- same-address load/store dependencies compare translated physical addresses,
  including aliases;
- response errors remain associated with the initiating instruction; and
- separate requester paths cannot reorder operations across a fence.

## Per-request physical memory attributes

Cacheability cannot be a constant property of a hart port.  The endpoint must
derive PMA attributes from the final physical address and attach them to every
request.

Every line in a burst must have the same attributes.  The endpoint must split
the request before a PMA boundary rather than applying the first line's
attributes to the rest of the burst.

Device and non-cacheable operations must:

- bypass private and shared-cache allocation;
- never join a cache-line fill or merge queue;
- not be speculated, combined, or replayed when that could repeat a side
  effect;
- use the required stronger ordering; and
- disable store-to-load forwarding unless the region explicitly permits it.

A posted device write is not implicitly a pre-barrier.  Software which relies
on all older writes reaching the device first must execute the required write
barrier before issuing it.  A later implementation may provide a CSR policy
which forces selected device writes to wait for the older-store drain, but that
is an optional stronger mode rather than the base ordering rule.  The current
RTL leaves device and non-cacheable writes blocking while this PMA and barrier
policy is not yet wired.

## Current posted-store contract

`openrv64_l1d_ccx` implements the first cacheable store buffer at the private
L1 boundary:

- `STORE_BUFFER_LINES` defaults to eight entries and is configurable from one
  through sixteen;
- every entry is one aligned 64-byte address, 512 data bits, and 64 byte
  enables;
- a scalar CPU store occupies its addressed lane without forcing L1 to read or
  merge the other bytes;
- FIFO order is retained and each drain is one CCX line write with `size=6`;
- marked atomic, uncached, and device operations are not posted in this
  revision; the single-hart atomic marker is not forwarded as a CCX/L2 lock;
- an external invalidation is acknowledged only after the FIFO becomes empty;
  and
- the separate ordered store-response channel carries the eventual CCX error.

The 3P backend has a four-entry pre-retire store queue. Core-bus request capture
does not complete a store: the tagged response must first prove translation,
PMP, and L1D FIFO admission. Page and PMP faults are therefore precise and
replay the original store PC. Once admitted, L1D may drain the cache-line write
after core retirement. A later physical-drain failure is beyond the precise
store boundary and needs a separate machine-check policy. The default
eight-entry L1D FIFO can absorb stores from the four-entry core queue while
continuing to drain earlier committed lines.

PMP remains an access-permission check.  PMA describes the behavior of an
allowed physical target; one does not replace the other.

## Atomic execution and reservations

LR, SC, and AMOs must execute at the coherence home for the addressed granule,
which is initially the shared L2 controller.  The hart must send the original
operation rather than exposing an inferred sequence of reads and writes.

The home agent must provide the following behavior:

1. LR reads the value and establishes a reservation for the requesting hart.
2. SC occupies one position in the home order, tests the reservation, performs
   the store only on success, and returns explicit success status.
3. An AMO performs its read, calculation, and write as one indivisible home
   operation and returns the old value.
4. Conflicting writes, AMOs, successful SCs, and other implementation-defined
   reservation-loss events clear affected reservations.
5. A hart reset or removal clears that hart's reservation state.

A 64-byte L2-line reservation granule is a conservative initial choice.  It may
produce more failed SC operations than a word-sized granule, but it keeps
reservation invalidation aligned with the first coherence implementation.

Initially, atomics should bypass the private L1.  The home agent invalidates
all private copies, including a possibly stale copy in the requesting hart,
then performs the operation and returns its result.  A later ownership-based
L1 protocol may execute atomics while holding a line exclusively, but that is
not required for the first coherent version.

The atomic still uses the 512-bit CCX data path.  Its physical address and size
select the 32- or 64-bit operand lane, the returned old value occupies that
lane, and the remaining response-line bits have no architectural meaning.

### Current one-hart AMO bring-up

The implemented temporary path is narrower than the required final contract:

1. The hart retains its local AMO ALU and marks the decomposed `READ` and
   `WRITE` phases only on the hart-to-L1D interface.
2. Before the read, L1D drains older posted stores and invalidates its resident
   copy. Both phases bypass L1 lookup/allocation and remain non-posted.
3. L1D records one non-evictable `atomic_active` line from read admission
   through write completion. Prefetch generation and issue pause during that
   interval. Read error also terminates the interval.
4. L1D records the line in a 16-entry, evictable `atomic_hot` directory.
   Atomic-hot lines do not train the address-stream prefetcher and cannot be
   generated or launched as prefetch candidates. A matching cache
   invalidation removes the hint.
5. The first presentation of each marked phase advances L1D's eight-bit
   speculation epoch. Queued and completed speculative reads are removed;
   already-issued prefetches drain as discarded responses. An architectural
   read-miss buffer from the old epoch drains its stale response and reissues
   with a new transaction ID rather than completing from it.
6. The CCX request is still an ordinary unmarked read or write. No L2/home
   ownership is acquired, so this sequence is atomic only under the explicit
   assumption that there is one hart and no coherent DMA writer.

`atomic_active` and `atomic_hot` are deliberately different states.
`atomic_active` is future snoop correctness state: a probe for that line must
retry, wait, or be NACKed until the RMW commits or aborts. `atomic_hot` is only
prefetch history and may be evicted. Neither state is equivalent to MESI
Exclusive, which describes clean ownership rather than an in-progress RMW.
The current RTL has no probe/ACK channel, so the active state is not yet
externally enforceable.

LR and SC do not use this local AMO marker. LR/SC remain single-hart-local
until the home implements real reservations. The current AMO path also does
not preserve `aq`/`rl` and does not replace the explicit home-executed
LR/SC/AMO protocol specified above.

## Private-cache probe protocol

Every private cache that can retain a physical line needs a decoupled probe
request and response path.  The minimum write-through protocol is:

```text
probe:      valid ready probe_id command line_addr
probe_resp: valid ready probe_id ack
```

`INV` is the only required initial command.  An L1 receiving it must:

- accept it immediately or place it in a bounded probe queue even while a CPU
  access, refill, or lower-level access is outstanding;
- invalidate a resident matching line;
- poison or cancel a matching transient refill so the line cannot be installed
  after the acknowledgement;
- acknowledge an absent line as a successful no-op; and
- assert acknowledgement only after the line can no longer produce a hit.

The probe path must not depend on completion of the transaction that is blocked
waiting for that probe.  In particular, an L2 eviction or store cannot wait for
an L1 acknowledgement while that L1 refuses the probe until its L2 refill
completes.  The current idle-only invalidation acceptance in `l1.v` must
therefore be replaced or fronted by a queue.

For an inclusive L2, a line may not be replaced until all recorded private
copies acknowledge invalidation.  A write may not become visible or complete
to its requester until conflicting private copies have been invalidated.

## Directory identity and policy

The recommended directory tracks instruction and data caches independently.
For 16 harts this is a 32-bit I/D sharer vector per L2 line.  That allows a D$
store to preserve or update its own D$ copy while targeting remote D$ copies
and whichever I$ copies the selected instruction-cache policy requires.

A smaller per-hart sharer vector is possible if one per-hart probe endpoint
fans every probe into both L1s and returns one combined acknowledgement.  It is
correct but causes avoidable invalidations and cannot distinguish the source
cache.

For the initial clean, write-through L1, directory information may be
conservative.  An L1 clean eviction need not immediately send a `PutS`; a stale
sharer bit merely causes a harmless probe to an absent line.  Exact ownership
becomes mandatory when private caches can contain dirty data.

## Instruction-cache behavior

If the L2 is described as inclusive, I-cache lines must participate in its
replacement probe protocol.  Whether every data store also snoops instruction
caches is a system policy choice, but tracking I$ and D$ separately keeps that
choice explicit.

Hardware I-cache coherence does not remove the architectural role of
`FENCE.I`.  The issuing hart must still:

1. wait until its older data writes are visible at the required coherence
   point;
2. invalidate its private I$ and resident frontend instruction state; and
3. restart instruction fetch after invalidation completes.

Cross-hart code modification additionally requires the software-defined remote
hart notification and remote `FENCE.I` sequence.

## Fences and ordering

Pipeline serialization alone is not memory-barrier completion.  The core must
turn architectural ordering operations into a request/drain contract visible
to the complex.

The first implementation may conservatively order more strongly than RVWMO:

- a release operation waits until older memory operations from that hart have
  completed at the required point;
- an acquire operation prevents younger memory operations from issuing until
  the acquire completes;
- `FENCE` waits for all older reads, writes, and atomics, sends a CCX fence
  token, and prevents younger memory operations from passing it; and
- `FENCE.I` performs the data-side drain before local instruction invalidation.

For the implemented L1D FIFO, a data-side drain means both the byte-masked
store FIFO and its core-bus tag FIFO are empty.  Merely enqueueing all older
stores is not fence completion.  The current execution path does not yet wire
architectural fences to this drain condition.

The existing two-bit CCX `order` field is sufficient for `aq` and `rl`.
Supporting selective `FENCE` predecessor and successor sets later will require
either additional fields or a deliberately documented full-fence
implementation.

Fences constrain the issuing hart.  They must not stop unrelated harts or
unrelated coherence granules merely because the first L2 controller happens to
be globally serialized.

## PTW and TLB integration

The PTW is a native coherent client with `source=PTW` and `kind=PTE`; there is
no scalar-memory or AXI backend on the walker. It PMP-checks the original
8-byte PTE access, then directly emits one aligned 512-bit CCX line read with
the `CACHEABLE|IDEMPOTENT` attributes. It retains `pte_addr[5:3]` and selects
that 64-bit lane from the returned line. A PTW request therefore allocates in
L2 but never allocates a private L1 line or becomes a private-cache sharer.

Both the generic 1P core and native 3P core expose this PTW CCX client. The
residual AXI read path in the 3P core is only for structural cacheless
instruction fetch.

The native 3P path places a shared 256-entry, four-way L2 TLB between its
separate 16-entry fully associative L1 ITLB/DTLB and the walker. The default
geometry is 64 sets. Four packed 131-bit payload banks are indexed in parallel,
and only those four selected entries are compared; Yosys retains four memory
cells rather than expanding the payload into a 256-entry CAM. Reset and
shootdown clear separate valid bits without resetting the payload banks.

Only 4 KiB leaves enter the L2 TLB. Superpage leaves bypass it and may remain
in an L1 TLB. The hierarchy is neither inclusive nor exclusive: walk fills
may duplicate an entry in the requesting L1 and L2, but an eviction at one
level never back-invalidates the other. The shared blocking walker guarantees
that an L2-miss fill cannot race another translation fill for the same tag.
L2 lookup arbitration is LSU first, demand fetch second, and speculative
instruction prefetch last. `L2_TLB_ENTRIES` and `L2_TLB_WAYS` are propagated
through the 3P core, public tops, and platform.

`SFENCE.VMA` and a successful writable `satp` CSR access make the PTW issue
`FENCE + kind=PTE + order=ACQ_REL` on CCX. Before either instruction executes,
the 3P backend waits for every older store's translation/PMP/L1D-admission
response.
The walker then terminates any active walk, drains an already accepted PTE
response, and blocks new walks until the fence response returns. Core fetch,
prefetch admission, and LSU admission remain blocked for that entire interval,
including when the selected translation mode is Bare. At L2, a PTE lookup may
hit only a line carrying the current eight-bit PTE generation. Advancing the
generation therefore invalidates stale PTE observations without scanning every
L2 set. A stale matching dirty line is selected as the victim, written back,
and refilled before the PTE read completes.

The same `satp`/`SFENCE.VMA` initiating pulse advances the L1D speculation
epoch. This is separate from the PTE generation: it prevents a data prefetch
or read-miss response issued before the translation barrier from becoming
post-barrier L1D state. Old prefetch responses are consumed and dropped. The
single architectural L1D RMB is consumed and reissued; it is never silently
lost or completed from the old response.

The generation deliberately wraps after 256 shootdowns. A surviving line from
an entire generation wrap can become falsely current; this is accepted for the
first implementation and must be replaced by a wider generation or a physical
flush before shootdown-storm workloads are supported.

This matters even though the page walker is logically inside a hart: a PTE may
have been written through another hart's data cache.  A future write-back D$
also makes it possible for the newest PTE value to reside only in a private
cache, requiring normal coherent intervention.

The present PTW uses Svade-style fault-on-clear Accessed and Dirty bits.
Hardware A/D-bit updates, if added, must be atomic coherent read-modify-write
operations at the same home agent as RV64A atomics.

The walker is still blocking, but now contains a demand-filled non-leaf PTE
cache.  The default is 64 entries arranged as 16 four-way sets.  Each entry
holds a 53-bit physical PTE tag, the 64-bit PTE, its tree level, valid state,
and per-set recency.  This is 7,808 state bits (976 bytes) before control
registers.  `PTW_PTE_CACHE_ENTRIES` is propagated through the core and top
wrappers; zero disables the cache.  Nonzero configurations use four ways and
must provide a power-of-two number of sets.

The current generic RTL maps these shallow associative arrays to flops and
multiplexers under Yosys; it does not infer an SRAM.  Treat 976 bytes as the
logical state budget, not the current physical area.  A physical
implementation should replace each way with an explicit synchronous
register-file or SRAM wrapper and pipeline the lookup as required by timing.

Only a valid non-leaf PTE actually consumed by a walk is installed.  Hits
bypass CCX for that tree level.  Replacement first selects an invalid way,
then prefers to evict a lower-level non-leaf PTE, and finally selects the
oldest hit/fill within that level.  Thus root-level entries receive explicit
retention weight.  Misses remain ordinary `source=PTW`, `kind=PTE` L2
requests; this cache stores individual PTEs rather than duplicating L2 lines.

`SFENCE.VMA` clears every non-leaf PTE-cache valid bit and terminates an
overlapping walk.  An already-issued physical PTE transaction may be drained,
but its value is not consumed, no later level is requested, and the aborted
walk cannot refill either the PTE cache or a TLB. The same initiating edge
clears ITLB, DTLB, and the shared L2 TLB and takes priority over a simultaneous
PTW fill or L2-to-L1 refill. PTW fetch-ahead remains unimplemented.
`kind=PTE` identifies the L2 object class; `source=PTW` independently
identifies the response destination.

`SFENCE.VMA` invalidates the local TLB and prevents an overlapping stale walk
from refilling it.  Remote TLB shootdown is not an L2 probe operation; software
must request it through a per-hart interrupt mechanism.

## Current first coherent implementation

The first implementation should retain the current write-through,
no-write-allocate L1D and use Shared/Invalid state only.  The existing
Exclusive and Modified metadata must not become authoritative until ownership
is implemented.

The required sequence is:

1. A cacheable L1 miss requests a 512-bit line beat, or a multi-line burst when
   the endpoint has a valid contiguous prefetch/refill request.
2. Every returned line independently records the requesting endpoint as a
   sharer in the independently tagged home directory.
3. A write-through store invalidates every conflicting remote D-cache copy and
   waits for all acknowledgements.  Its requester retains the newly updated
   clean copy.
4. The L2 updates its byte-selected data and returns completion to the source.
5. A home-directory replacement invalidates all recorded private copies before
   reusing the directory entry.  L2 is non-inclusive and may replace data
   independently.
6. A coherent LR first establishes a home reservation and then performs the
   ordinary cached L1D lookup.  SC invalidates the requester locally, probes
   remote sharers, and conditionally writes L2.  The compatibility AMO path
   still computes locally and uses those LR/SC phases.
7. Device and non-cacheable requests bypass allocation and merging and never
   form multi-line bursts.

This requires only clean invalidation acknowledgements.  It does not require
cache-to-cache data transfer, dirty interventions, upgrades, or ownership
handoff.

The existing four-bit `op` field already uses fourteen of sixteen encodings for
architectural reads, writes, atomics, and fence.  Future cache-coherence
messages such as `GetS`, `GetM`, `Upgrade`, `PutS`, and `PutM` must not be
forced into the remaining encodings.  Either add a separate coherence-command
field or widen and restructure the request protocol before implementing a
write-back private cache.

## Later write-back L1 requirements

A write-back private L1 additionally requires:

- shared-read and exclusive-read/acquire requests;
- ownership upgrades;
- clean and dirty eviction notifications;
- downgrade and data-request probes;
- probe responses carrying a complete dirty line;
- one authoritative owner in the directory;
- transient states for fills, upgrades, interventions, and eviction races; and
- separate or otherwise deadlock-free request, response, probe, and probe-data
  flow control.

These mechanisms should not be introduced into the first write-through
coherence implementation unless measurement or another integration requirement
justifies them.

## Non-memory hart integration

Instantiating actual cores in the complex, rather than accepting external core
memory ports, also requires:

- one `HART_ID` parameter per core, passed both to CCX and the `mhartid` CSR;
- per-hart machine and supervisor software, timer, and external interrupts;
- boot-hart and secondary-hart reset/release policy;
- per-hart debug and halt selection; and
- removal of directory sharers and reservations on per-hart reset or powerdown.

DMA engines and other external memory writers are a separate system boundary.
They require either a coherent ingress into the home agent or a documented
non-coherent software cache-maintenance contract.  The AXI/WISHBONE master-only
southbound interface cannot observe writes that bypass the complex.

## Verification requirements

Coherence must be verified with integrated harts and enabled L1s, not only with
direct CCX or L2 testbench transactions.  At minimum, tests must cover:

- one hart reading a line after another hart writes it;
- one-line requests and multi-line bursts under request and response
  backpressure;
- partial-hit bursts in which some lines hit L2 and others require refill;
- burst splitting at physical-attribute changes and at the southbound AXI
  4 KiB boundary;
- simultaneous writes to the same word and to different words in one line;
- a store or L2 eviction probing an L1 with a matching refill in progress;
- false or stale directory sharer bits;
- LR/SC success without interference and failure after a conflicting write;
- every AMO against competing ordinary loads and stores;
- acquire/release message-passing and full-fence litmus tests;
- `FENCE.I` after self-modifying code;
- coherent PTW observation of PTE writes; and
- hart reset while it owns a reservation or appears in a sharer vector.
