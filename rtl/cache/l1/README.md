# OpenRV64 L1 cache

`openrv64_l1_cache` is a pipelined, physically tagged, set-associative L1.  Its
request and response channels are decoupled: `req_ready_o` accepts a request,
while `resp_valid_o` returns the ordered result under independent response
backpressure.  It accepts separate lookup and physical addresses: tying them
together gives PIPT operation, while L1I uses virtual page-offset bits for its
set/beat and the translated address for its tag and refill.  The L1I wrappers
default to four ways, 16 KiB, and 64-byte lines; the shared cache and L1D retain
their eight-way module defaults.  The integrated CCX core uses 16 KiB and four
ways for both L1I and L1D.  `L1I_CACHE_BYTES` and `L1D_CACHE_BYTES` expose
those capacities at the core and production top levels.  `CACHE_BYTES`
accepts power-of-two capacities from 1 KiB through 32 KiB.

## Policy

- read allocate, one 64-bit refill request per line beat;
- parallel way reads and tag compare with a registered selected-way response;
- one accepted and one completed resident read hit per cycle after fill;
- ordered one-entry response buffering with arbitrary response backpressure;
- write-through and no-write-allocate;
- successful write hits update the resident word when the lower-memory request
  is accepted; the CCX L1D endpoint may satisfy that acceptance by reserving a
  byte-masked posted-store entry;
- failed refills never validate a partial line;
- round-robin replacement, preferring invalid ways and then retired-path lines
  marked `aged_q`;
- `req_cacheable_i=0` sends a request directly through the cache instance;
- `ENABLE=0` on `openrv64_l1`, `openrv64_l1i`, or `openrv64_l1d` elaborates a
  transparent wire-through path with no tag or data arrays.

The line data arrays contain no dirty state.  With the CCX L1D endpoint, bytes
which have not reached the lower level are owned by the store FIFO rather than
represented as Modified cache lines.

The shared cache defaults to its blocking refill state machine.  Setting
`DETACH_READ_MISSES=1` instead exports tagged cacheable read misses and accepts
independent full-line fills.  This leaves tag/data lookup and replacement in
the shared module while an outer policy controller owns MSHRs and lower-level
transaction IDs.  L1D uses this mode; L1I retains the blocking refill port.

## Physical storage

Each way's data store is one synchronous, full-width, one-read/one-write
inferred RAM.  Store byte enables are merged with the registered resident word
before the full-width write, so synthesis does not split a way into eight
byte-wide memories.  The integrated 16 KiB caches therefore infer:

- L1I: four 64x512-bit RAMs;
- L1D: four 512x64-bit RAMs.

The RAM contents are deliberately not reset; validity metadata suppresses
uninitialized data.  Tags, validity, replacement, aging, and reserved
coherence metadata remain standard-cell logic because the current same-cycle
parallel tag lookup and bulk invalidation contract does not fit a simple
synchronous SRAM without another lookup stage.

The Sky130 resource flow preserves these eight data arrays as `$mem_v2` cells
and reports their 262,144-bit capacity separately.  This repository has no
SRAM Liberty/LEF macro library, so their physical area and timing remain
unknown until a macro generator/library and Yosys memory mapping are selected.
Expanding them into flip-flops is not a valid cache-area estimate.

## Reserved coherence metadata

Each line carries a two-bit `mesi_q` field (`I=00`, `S=01`, `E=10`, `M=11`)
and a configurable `dirty_timestamp_q`.  `WRITEBACK_TIMEOUT_CYCLES` defaults to
128; `DIRTY_TIMESTAMP_WIDTH` therefore defaults to 8 bits, is capped at 16
bits, and may be overridden as long as the timeout fits.  These are stubs for a
later coherence controller: `valid_q` is still authoritative, a successful
refill records `E/0`, and reset, replacement, or invalidation records `I/0`.
The current write-through path never creates `M` or a nonzero dirty timestamp
because its lower-level copy is current when a store completes.

## Inclusion contract

Inclusion is a hierarchy property, not something an L1 can guarantee by
itself.  A lower inclusive cache must hold every line resident in this L1 and
must issue `invalidate_valid_i` before it evicts that line.  It holds the
request until `invalidate_ready_o`; `invalidate_all_i` clears every line and a
deasserted `invalidate_all_i` invalidates the line containing
`invalidate_addr_i`.  Invalidation has priority over a new upstream request.

## Specializations

`l1i/l1i.v` removes requester write inputs.  `l1d/l1d.v` retains the complete
read/write interface.  Both keep the same downstream interface so platforms
can select cached or cacheless builds without changing bus wiring.

## Frontend integration

The 256-bit frontend instantiates `openrv64_l1i_ccx` as a VIPT cache.  A demand
virtual address indexes L1I while the ITLB produces the physical tag and CCX
address; Bare and ITLB-hit launches avoid a serialized translation state.
Translation misses first use the shared 256-entry, four-way L2 TLB; only an L2
miss uses the shared PTW. The L2 caches 4 KiB leaves and refills ITLB on a hit;
superpages bypass it. The TLB hierarchy is non-inclusive and non-exclusive,
with independent replacement and global shootdown of all levels. Every
architectural demand is PMP checked. Fetch owns one current 256-bit line plus
the immediately following line needed for boundary-crossing bundles, with
only one cache request in flight. Cache residency and speculative work belong
to L1I.

The cache hit datapath is pipelined; misses, writes, and uncached operations
still serialize the pipeline while they use the blocking lower-memory port.  A
64-byte miss issues exactly one aligned 512-bit native CCX read with `size=6`
and `burst_len=0`.  The requested 256-bit frontend half is then selected from
the resident 64-byte line.  With L1I enabled, instruction traffic does not use
AXI.  `FENCE.I` invalidates both the L1I and the three-wide fetcher's bridge
lines; an invalidation waits until accepted lookups and responses have drained.

L1I has eight best-effort virtual fill/prefetch/aging slots by default.
`FILL_BUFFER_LINES` sets this capacity from two through sixteen;
`PREFETCH_SLOTS` remains an override-compatible alias.  Accepting a conditional
branch queues both its direct target and fallthrough, collapses same-line and
already-pending duplicates, and translates each path through the demand-priority
ITLB/PTW/PMP service.  Speculative faults are discarded.  Once the branch
retires, the losing path is marked as a preferred replacement victim; aging
does not invalidate a resident line.  Demand lookup always has priority over
starting another prefetch lookup or fill.

The generic 64-bit frontend is unchanged.  Set `ENABLE_L1I=0` on the 256-bit
AXI top-level path for a direct, single-request cacheless fetch path.

`rtl/openrv64_l1i_top.v` is the standalone integration boundary.  It accepts
virtual and translated physical demand addresses, exposes the private
speculative translation service, and presents the read-only native CCX command
and response channels.  The standalone top and testbench parameterize cache
capacity, associativity, and speculative slot count; their defaults are 16 KiB,
four ways, and eight slots.  Override them with `L1I_TOP_CACHE_BYTES`,
`L1I_TOP_WAYS`, and `L1I_TOP_PREFETCH_SLOTS` on `make sim-l1i-top`.  The target
builds the current CoreMark-derived binary as 512-bit lines and replays a
checked-in 128-instruction dynamic excerpt through this top twice; every
returned instruction is checked, and the warm replay must issue no CCX fills.

## Data integration

The scalar LSU enters `openrv64_l1d_ccx` only after translation and PMP
checking.  The cache retains its 64-bit internal SRAM/refill datapath, while
the backend converts a cacheable miss into one aligned 512-bit native CCX read
with `size=6` and `burst_len=0`.  The returned line enters the shared cache
through its detached full-line fill port; a CPU load returns the selected
64-bit word after that installation is complete.

`DEMAND_MSHRS` defaults to three. `FILL_BUFFER_LINES` and
`STORE_BUFFER_LINES` both default to eight cachelines and accept values from
one through sixteen. Each demand MSHR owns one unique aligned line, a lower-half
CCX transaction ID, returned data, speculation epoch/replay state, and the
aggregate older-store overlay used for installation. Same-line misses merge
onto that entry while retaining independent requester tags, selected words,
and per-request store snapshots. A younger same-line store updates only the
aggregate installation overlay, not the already-captured response of an older
load. Different-line responses may return out of order and match by transaction
ID.

Each L1D store entry contains an aligned 64-byte address, 512 data bits, and 64
byte enables. Consecutive stores to the newest undrained line merge bytewise
into that record; later bytes overwrite earlier bytes and the enables are
ORed. Combination is deliberately limited to the FIFO tail so stores cannot
move across an intervening store to another line. Downstream L2 or memory
performs the final masked merge.

A tagged, cacheable, unlocked store completes to the shared L1 after merging
into or reserving a FIFO entry.  The resident word is updated on a hit; a miss
remains no-write-allocate.  Draining starts when occupancy reaches
`STORE_BUFFER_DRAIN_WATERMARK` (four by default), then continues in FIFO order.
A partial newest entry stays open for further adjacent stores until it becomes
full, ceases to be the tail, reaches `STORE_BUFFER_TIMEOUT_CYCLES` (1024 by
default), or must drain for invalidation, an uncached same-line access, or a
locked request.
Each entry drains as one aligned CCX write with `size=6` and `burst_len=0`.
The independent `store_resp_*` channel reports drain completion and error in
FIFO order.  The core bus retains the original LSU tags in a matching FIFO, so
a store may retire at request admission without losing a later asynchronous
access fault.

Store draining is nonblocking with respect to earlier store responses. Each
FIFO entry retains issued, completed, error, and CCX transaction-ID state.
The drain selector may issue the oldest unissued entry while older entries
remain in flight. Responses match by transaction ID and may arrive out of
order, but entries are still reported and reclaimed from the FIFO head. An
issued entry is no longer mergeable; later same-line stores allocate a younger
entry and retain their order.  A cacheable load CAMs all retained same-line
entries in FIFO age order and snapshots their complete 64-byte data/mask
overlay when entering L1.  Newer bytes win.  The snapshot merges into both the
scalar response and any refill line before installation, so draining and
reclaiming the FIFO cannot expose a stale resident line.  Barriers, locked
requests, invalidation, and uncached same-line aliases retain explicit drain
behavior.

The L1D endpoint also contains a deliberately small address-stream prefetcher.
It trains on accepted cacheable, unlocked loads after aligning them to
64-byte lines.  `PREFETCH_STREAMS` defaults to two independent histories.
An exact trained-stride match selects a history first; otherwise the nearest
eligible previous line is selected, followed by an invalid or round-robin
replacement entry.  The first observation predicts the next line, while two
matching nonzero deltas establish a signed stride in that history.
`PREFETCH_DISTANCE` is the initial contiguous read-ahead depth; it does not
select one farther line and leave holes.  Demand catching a queued or
outstanding prefetch doubles the depth, bounded by `PREFETCH_MAX_DISTANCE`.
Two unused speculative replacements halve it. `PREFETCH_MAX_STRIDE_LINES`
limits eligible deltas and defaults to 64 lines (4096 bytes).
`PREFETCH_ENABLE=0` removes prefetch issue while retaining the same demand
path.

There is no PC input or LSU predictor state.  The address-only history table
accepts one through four entries.  The default four-entry candidate window
feeds four prefetch MSHRs.  Prefetch transaction IDs occupy the upper half of
the four-bit L1D ID space, so their responses may return out of order while the
parameterized demand MSHRs and multi-inflight store drain share the lower half
through a free-ID bitmap. A completed
speculative line resides in the existing fill buffers until demanded; it does
not install in the L1 tag or data arrays, so unused prefetches cannot evict
resident cache lines. `PREFETCH_DEMAND_RESERVE` entries cannot be consumed by
speculative responses. Demand traffic may use those entries or replace an
unused speculative line. Speculative replacement rotates across eligible
entries so an old slot cannot remain pinned while one lower-index slot absorbs
every replacement.

Demand misses take priority.  A speculative read may pass queued posted stores
only when no buffered store aliases its line.  An aliasing store or
invalidation cancels or discards queued and outstanding speculative copies.
An AMO pauses prefetch generation and issue from its marked read through its
marked write.

L1D assigns accepted reads to an eight-bit speculation epoch. `satp` writes,
`SFENCE.VMA`, and the first presentation of each marked AMO phase advance that
epoch. The barrier cancels queued candidates, stops active generation, clears
completed speculative fill-buffer entries, and marks already-issued prefetch
MSHRs discard-on-response. CCX responses are still consumed; they simply
cannot become cache or fill-buffer state after the cutoff.

Architectural demand MSHRs are not discarded. If an MSHR's CCX read was issued
in an older epoch, L1D consumes the old response without installing it, releases
that transaction-ID credit, and reissues the same line in the new epoch. An
unissued MSHR is relabeled directly. Replay and epoch state are therefore
independent per demand MSHR.

A demand which catches an issued same-line prefetch adopts that speculative
transaction rather than launching a duplicate read. A valid response transfers
the line into the demand MSHR. A discarded or failed speculative response only
releases the dependency; the architectural demand then issues normally, so a
prefetch fault cannot become a demand fault without a demand retry.

L1D also retains two distinct forms of atomic metadata. `atomic_active_q` and
its line address identify the one in-progress local RMW.  In coherent mode a
matching snoop may revoke the private line and clears the RV64A reservation;
if the computed write later reaches the home as an SC, failure restarts the
AMO at its read half.
`ATOMIC_HOT_LINES` defaults to a 16-entry evictable line directory used only
as a prefetch hint. Marked accesses insert there, untrain a matching stream,
and prevent later training, candidate generation, or issue for that line.
The hot directory is not correctness state and may be replaced.

`prefetch_issued_o`, `prefetch_useful_o`, `prefetch_late_o`, and
`prefetch_dropped_o` are one-cycle event outputs for testbench counters.
`useful` means a completed speculative line supplied a later demand; `late`
means demand reached a queued or outstanding speculative request; `dropped`
means the candidate window was full.  `prefetch_useless_o` reports replacement
of an unused speculative fill, and `prefetch_depth_o` exposes the current
adaptive depth.  They are observability signals, not architectural counters.

The command and write-data channels remain independently backpressured and are
correlated by hart, source, and transaction IDs. A later cacheable read may
consume retained same-line dirty bytes through the snapshotted line overlay;
full-cache maintenance is not acknowledged until the store FIFO has drained.
A targeted coherence invalidation does not wait for unrelated store entries
or demand MSHRs.  A matching issued MSHR consumes its old response without
installing it and then reissues the line; its tagged waiters and store overlay
remain attached.
`#LOCK` accesses bypass and
invalidate L1D and remain non-posted, but in the single-hart configuration the
marker is local and is not forwarded as a CCX/L2 home lock.  Uncached/device
writes also remain blocking in the current RTL; the intended later policy is
ordinary posting with software responsible for an explicit pre-barrier.  A
device write does not implicitly perform that pre-drain.  A future CSR may
request automatic pre-barrier behavior.

The fill capacity is distinct from demand concurrency. L1D supports
`DEMAND_MSHRS` unique architectural miss lines, `PREFETCH_OUTSTANDING`
speculative MSHRs, and multiple issued store-buffer entries, all with
transaction-ID-indexed response matching. The defaults are three demand MSHRs
and four prefetch MSHRs. Demand and stores share the eight lower-half
transaction IDs and backpressure locally when either MSHRs or IDs are
exhausted. A demand MSHR is not reclaimed until every same-line tagged waiter
has consumed its response.

`L1I_FILL_BUFFER_LINES`, `L1D_FILL_BUFFER_LINES`, and
`L1D_STORE_BUFFER_LINES`, along with `L1D_DEMAND_MSHRS`, are propagated through
the AXI core-bus, three-pipe core, and production top-level parameters. The
execution pipe defaults to eight LSU tags, matching the default L1D store FIFO
and allowing one hart to hold eight unacknowledged stores. Configurations with
a deeper store FIFO or more simultaneous same-line waiters still require a
larger tag namespace or a separate deferred-fault metadata queue.

The default one-hart AMO path uses `req_lock_i` as a local phase marker. Before
either marked phase proceeds, L1D invalidates its resident copy of the
addressed line. The phase then bypasses L1 lookup, speculative fill buffers,
and allocation while retaining the original cacheable PMA attribute at CCX.
`ccx_req_lock_o` remains tied low.

When `COHERENT_ATOMICS` is enabled, a marked read first issues an LR to the
coherent home to establish the reservation, then performs the ordinary cached
L1D lookup.  Reserve-first ordering prevents a write between a cached lookup
and reservation creation from pairing stale data with a fresh reservation.
If that lookup misses, its refill is an ordinary shared read; it does not
create a second reservation.  A marked write invalidates the requester's local
copy and is encoded as SC.  SC success is returned to RV64A through the marked
write response.  These options are disabled by default so the existing
one-hart L2 continues to receive its established protocol.

The CCX4 coherent path supplies one independent invalidate-probe slot per L1D
in `openrv64_ccx_4h_l1d_probe_cluster`.  Probe acceptance clears the hart's LR
reservation immediately, but ACK is withheld until the real targeted
tag/refill invalidation completes.  Timeout records a protocol error and never
manufactures an ACK.  The home excludes an SC requester from its probe target
mask because the requester invalidates locally before issuing SC; probing it
again would deadlock behind the SC response.  Successful SC still clears every
D-sharer bit for the line.  L1I has no probe endpoint.

The core bus arbitrates independent I-cache and D-cache command sources and
routes responses by `source_id`; only L1D drives write data.  The L1 arrays are
pipelined. L1I still permits one active architectural miss; L1D permits the
configured number of demand MSHRs. Posted L1D writes may additionally occupy
the configured store-buffer capacity. L1I may retain up to the configured
number of untranslated, translated, or aging jobs behind its port. It adds no
probes or coherence behavior. Scalar LSU traffic never uses AXI;
AXI remains only for the `ENABLE_L1I=0` cacheless-fetch path. Page-table walks
use native CCX and identify their memory object with `kind=PTE`.
