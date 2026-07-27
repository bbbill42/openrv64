# OpenRV64 core complex and shared L2

`openrv64_core_complex_nh` is the generated 1-16-hart complex. It accepts one
native 512-bit CCX port per hart, validates and straps each port to
`HART_ID_BASE + hart_index`, round-robin arbitrates requests, and terminates
them in a shared L2.
`genbus_interface` then converts the L2 producer width to the independently
selected AXI4 or WISHBONE Revision B.4 width and protocol.

```text
hart 0 -- native CCX --+
hart 1 -- native CCX --+-- line crossbar -- shared L2 -- genbus_interface
...                    |                                      |
hart N -- native CCX --+                         +------------+-----------+
                                                   |                      |
                                              AXI4 master        WISHBONE B.4 master
```

The older `openrv64_ccx_protocol_wrapper_{1h,2h,4h}` modules remain cacheless
protocol tests and compatibility seams.  They are not aliases for the full
core complex.

## L2 geometry and policy

The defaults are:

- 256 KiB, configurable to 512 KiB or 1 MiB with `L2_BYTES`;
- eight ways, configurable with `L2_WAYS`;
- 64-byte lines, matching the current L1 line size and the native 512-bit CCX
  beat;
- write-back and write-allocate; and
- invalid-first, round-robin replacement.

Eight ways is a defensible starting point, not a measured optimum.  At
256 KiB and 64-byte lines it gives 512 sets.  Four ways would reduce tag
comparators and likely lower hit latency and energy, but changing that before
workload measurements would be guesswork.  The parameter remains exposed so
four-way and eight-way implementations can be compared with miss-rate and
timing data.

The native controller has parameterized command and response queues plus
multiple per-line MSHRs. Requests may hit under unrelated misses, and requests
to an outstanding miss line merge into its waiter queue. The default is eight
MSHRs with eight waiters each.

Cacheable hits do not reach the external bus.  Stores update byte-selected L2
data and mark the line dirty.  Dirty replacement writes a whole line before
refill.  While that writeback is pending, the reserved victim snapshot remains
an authoritative lookup source: matching reads are returned from it rather
than allocating a second miss against stale backing memory.  Matching writes
wait until the already-issued writeback completes.  A writeback failure
preserves the dirty victim and fails every merged request; a refill failure
leaves the destination invalid and likewise fails the merged requests. Device
or non-cacheable requests bypass allocation but remain ordered through the
same controller.

`FENCE` completes only after older MSHRs, bus transactions, hits, and responses
have drained. `FENCE + kind=PTE` also advances an eight-bit PTE generation.
PTE reads reject matching lines from older generations, selecting a stale
matching dirty line for writeback before refill. Generation wrap after 256
shootdowns is a known first-implementation risk.

The data and tag store is split into one synchronous, full-line SRAM-inference
boundary per way. Fill, merged-store replay, and resident-store writes share
each way's write port with fixed priority. The PTE generation is packed into
the inferred tag SRAM; valid, dirty, reservation, and replacement state remain
separate metadata.

The northbound CCX and southbound L2 producer interfaces are fixed at 512 bits,
one 64-byte cache line per accepted data beat. Native cache endpoints may
request bursts of consecutive cache lines; each line remains a separate beat
and home operation. Width conversion occurs only below L2.

## Shared generic bus boundary

The L2 does not contain AXI or WISHBONE state. Its southbound neutral request
carries:

| Field         | Meaning                                                                                                                         |
|---------------|---------------------------------------------------------------------------------------------------------------------------------|
| `valid/ready` | One accepted external beat.                                                                                                     |
| `write`       | Read or write selection.                                                                                                        |
| `addr`        | Physical byte address.                                                                                                          |
| `size`        | Base-two logarithm of transfer bytes.                                                                                           |
| `burst`       | Read-only AXI-LEN-style count: zero is this request only; `N` declares this request plus the next `N` contiguous peer requests. |
| `wdata/wstrb` | Producer-width data and per-byte enables, already lane-positioned.                                                              |
| `cacheable`   | Transport hint; line traffic is cacheable and bypass traffic is not.                                                            |

The response carries producer-width read data and an error bit.
`rtl/bus/genbus_interface.v` is the shared boundary used here and by the
vector streaming cache. `UPSTREAM_DATA_WIDTH` and `DOWNSTREAM_DATA_WIDTH` are
independent. It splits a wide producer transfer over a narrow downstream bus,
places a narrow transfer in the addressed lane of a wider bus, and performs
the inverse read-data assembly. `READ_BUFFER_DEPTH` and
`WRITE_BUFFER_DEPTH` independently size its admission and outstanding state.
Untagged upstream responses are restored to request-acceptance order. AXI
reads and writes may execute concurrently, but a younger request is not issued
past an older opposite-direction request whose byte range overlaps.

The current CCX/L2 instance explicitly drives southbound genbus `burst=0`.
`BUS_DATA_WIDTH` independently selects the external width. One 512-bit L2
request therefore becomes 16, 8, 4, 2, or 1 downstream beats on 32-, 64-, 128-,
256-, or 512-bit AXI. The southbound adapter splits at AXI limits and 4 KiB
boundaries.

`BUS_TYPE` selects `OPENRV64_COMPLEX_BUS_AXI` or
`OPENRV64_COMPLEX_BUS_WISHBONE` at elaboration. `BUS_DATA_WIDTH` accepts 32,
64, 128, 256, or 512 bits for either backend. The official WISHBONE B.4
specification caps a data port at 64 bits. OpenRV64 deliberately extends the
same DAT/SEL/ADR and Classic-cycle handshake to 128-, 256-, and 512-bit ports
for experiments; those widths are nonstandard and are not expected to be
portable to arbitrary WISHBONE interconnects or peripherals.

### AXI4

One neutral request wider than the external port becomes one AXI4 INCR burst,
up to the AXI limit of 256 beats. AW and W may handshake independently. Up to
`READ_BUFFER_DEPTH` reads and `WRITE_BUFFER_DEPTH` writes can be admitted, and
multiple address transactions using the fixed master `AXI_ID` can be
outstanding. AXI's same-ID ordering is therefore part of this interface
contract. R and B IDs must match `AXI_ID`, and non-OKAY responses become CCX
errors.

The optional neutral `burst` count performs explicit read coalescing. A leader
with count `N` reserves room for itself and the next `N` requests; followers
must be contiguous, have the same size/cacheability, and carry count zero.
Genbus emits one larger INCR burst but still returns one upstream response per
neutral request. Each response may cut through as soon as its own beats are
complete rather than waiting for the final AXI `RLAST`. Declared write
coalescing and speculative detection of unrelated adjacent requests are not
implemented. Genbus automatically splits a declared group at the 256-beat AXI
limit and at every 4 KiB boundary.

### WISHBONE B.4 and wide-data extension

The WISHBONE path uses the same admission buffers, then drains the globally
oldest request. It emits one Classic transfer per genbus beat (`CTI=000`,
`BTE=00`).  It holds `CYC` for the transfer, holds `STB` until the request is
accepted under the B.4 `STALL` rule, and then waits for exactly one of `ACK`,
`ERR`, or `RTY`.  `RTY` inserts an idle cycle and reissues the request;
`WB_MAX_RETRIES` limits retries, with zero meaning no limit.

Widths above 64 bits are an OpenRV64 extension, not WISHBONE B.4 compliance.
They change only the widths of `DAT` and byte-select `SEL`; transfer ordering,
termination, retry behavior, and address-shift semantics remain identical.

The WISHBONE specification defines the lower `ADR` boundary from port size and
granularity rather than requiring one universal flat-vector convention.
`WB_ADDR_SHIFT` makes that integration choice explicit.  It defaults to
`clog2(BUS_DATA_WIDTH/8)`, which exports a bus-word address for an 8-bit
granularity port.  Set it to zero for an interconnect whose flat `ADR` vector
expects the complete byte address.  `SEL` always contains byte enables.

The implementation follows the OpenCores WISHBONE Revision B.4 signal and
termination rules: <https://cdn.opencores.org/downloads/wbspec_b4.pdf>.

## L1 and coherence boundary

The shared L2 is correct for direct hart requests when there are no private
cached copies.  It is **not yet coherent with multiple private L1 caches**.
The current L1 has a back-invalidation input, but this L2 does not yet track
sharers or emit invalidations.  Placing it below multiple enabled L1s today can
leave a private clean copy stale after another hart writes the line.

L1 integration therefore still requires a probe/invalidation network with at
least these rules:

1. a store must invalidate other private copies before it becomes visible;
2. an inclusive L2 must invalidate every private copy before replacing a line;
3. an L1 must accept a probe while its own miss is outstanding, or the design
   needs a nonblocking probe queue to avoid eviction/refill deadlock; and
4. LR/SC reservations and AMOs must occupy the same per-line order as ordinary
   requests.

The standalone scalar compatibility wrappers still apply one constant
`DEFAULT_ATTR` to a whole legacy port. They are not used by this complex and
must not be substituted for a native endpoint carrying per-request PMA/CCX
attributes.

## Verification

Focused targets are:

- `make sim-ccx-l2` for the native 512-bit L2, including fills, hits, dirty
  stale-PTE writeback/refill, and PTE-generation shootdown;
- `make sim-genbus-axi sim-genbus-wb` for independent read/write buffering,
  wide-request bursts, declared read coalescing, response order, read
  cut-through, and the serialized WISHBONE fallback; and
- `make sim-core-complex-2h-axi sim-core-complex-4h-wb` for generated hart IDs,
  response routing, one-line merging, L2 hits, shared genbus width conversion,
  the explicit zero burst count, and both complete backend paths.
