# OpenRV64 core-complex protocol

The core-complex protocol is the internal memory transaction contract between
a hart endpoint and the shared ordering, cache, and coherence machinery. AXI4
is not this internal protocol. AXI4 is the external transport used below the
complex to reach memory or an SoC fabric.

The first implementation is `openrv64_ccx_protocol_wrapper_1h` in
`rtl/complex/protocol/wrapper_1h.v`. It connects the existing blocking
physical port of one hart to a single-outstanding AXI4 master through explicit
CCX request and response channels:

```text
OpenRV64 physical port
        |
        v
hart_legacy_adapter  -- CCX request/response --  axi_master
                                                   |
                                                   v
                                             external AXI4
```

This wrapper is deliberately conservative. It permits only one transaction at
a time, so the one-hart memory stream remains strictly ordered. It does not
yet contain a cache, directory, crossbar, mesh, or multi-hart home agent.

The next generated implementation is `openrv64_ccx_protocol_wrapper_nh`.
`openrv64_ccx_protocol_wrapper_2h` and
`openrv64_ccx_protocol_wrapper_4h` fix that implementation at two and four
harts. Slice zero of each packed core port belongs to hart zero. Each generated
hart endpoint is strapped to `HART_ID_BASE + hart_index`.

The multi-hart wrappers use a round-robin N-to-one request crossbar. The
arbitration pointer advances on request acceptance, so a hart that continuously
requests cannot hold fixed priority over another requesting hart. Responses
route by their explicit hart ID rather than by a retained grant. Downstream
logic therefore sets the real outstanding limit: the cacheless AXI protocol
wrapper still permits one transaction globally, while the shared L2 can accept
same-line merge requests from other harts during a fill.

## Implemented compatibility request

The currently implemented scalar compatibility CCX request carries:

| Field     | Width | Meaning                                                   |
|-----------|------:|-----------------------------------------------------------|
| `hart_id` |     4 | Source hart, supporting IDs 0 through 15.                 |
| `txn_id`  |     4 | Requester-local transaction identity.                     |
| `op`      |     4 | Read, write, LR, SC, AMO operation, or fence.             |
| `order`   |     2 | None, acquire, release, or acquire-release.               |
| `kind`    |     2 | Legacy, fetch, data, or PTW request.                      |
| `attr`    |     4 | Cacheable, device, idempotent, and executable attributes. |
| `size`    |     3 | Base-two logarithm of the transfer size in bytes.         |
| `addr`    |    64 | Physical byte address.                                    |
| `wdata`   |    64 | Scalar write data.                                        |
| `wstrb`   |     8 | Scalar byte write enables.                                |

The response returns `hart_id`, `txn_id`, 64-bit read data, error, and SC
success. A hart endpoint accepts only a response matching both identities.

The compatibility endpoint can recover only READ versus WRITE from the
current core pins. It therefore emits `kind=LEGACY`, `order=NONE`, an
integration-selected default attribute, and an eight-byte physical transfer.
This channel is a bring-up seam and is not the native cache-facing CCX
datapath.

## Native 512-bit cache-line request

The required native interface above CCX is 512 bits wide. One accepted data
beat carries exactly one 64-byte cache line. Cacheable refills, evictions,
interventions, and prefetches therefore cross CCX one complete line at a time
rather than as eight scalar requests.

In addition to the identity, operation, ordering, requester-kind, attributes,
and physical address above, a native request carries:

| Field       |                  Width | Meaning                                                                          |
|-------------|-----------------------:|----------------------------------------------------------------------------------|
| `source_id` | implementation-defined | I-cache, D-cache, PTW, or another endpoint within the hart.                      |
| `burst_len` |                      8 | Additional consecutive cache lines; zero means one line and 255 means 256 lines. |
| `wdata`     |                    512 | One cache-line write-data beat.                                                  |
| `wstrb`     |                     64 | One byte enable per cache-line byte.                                             |

A request for `burst_len=N` covers `N+1` lines beginning at the aligned start
address. Each line remains a separate 512-bit data beat and a separate
coherence/home operation. The burst is a transport and scheduling declaration,
not a multi-line atomic region. Responses return one line per beat in increasing
address order and include transaction identity plus a final-beat indication.
Different tagged bursts may interleave.

All lines in one burst must be physically contiguous and have identical PMA
attributes and ordering. The requester splits at translation or attribute
boundaries. CCX itself does not inherit AXI's 4 KiB burst restriction; the
southbound transport splits there when required.

Sub-line atomics and uncached operations still travel on this 512-bit datapath.
Their address and size select the meaningful byte lanes, and they must use
`burst_len=0`. The fabric receives LR, SC, and AMO intent explicitly and never
infers an atomic sequence from adjacent operations.

## Memory ordering

The one-hart wrapper has one outstanding transaction, which gives a total
order over that hart's physical memory requests. The AXI address and data
channels may handshake independently, but the CCX write completes only after
the AXI write response. Reads complete only after their AXI read response.

With multiple harts, memory RAW, WAR, and WAW cases are resolved at the home
for the addressed coherence granule:

- operations to the same granule enter one serialization order;
- different granules remain independent;
- fences constrain the issuing hart rather than stopping every hart; and
- atomic operations occupy one indivisible position in the home order.

This is per-address memory ordering, not cross-hart register scoreboarding.

## AXI mapping

The initial compatibility bridge accepts only eight-byte protocol transfers and emits them
as single-beat AXI transactions on the existing 256-bit external data bus.
Address bits `[4:3]` select the 64-bit data and strobe lane. AW and W are
tracked independently, and R/B responses must match the configured AXI ID.
AXI error responses become CCX errors and then ordinary core bus errors.

Only CCX READ and WRITE are translated today. Reserved operations complete
with an error rather than silently degrading into non-atomic AXI traffic.
This mapping describes the implemented legacy wrapper, not the native 512-bit
cache-line and multi-line burst contract.

## Shared-cache implementation

`openrv64_core_complex_nh` does not retain these scalar endpoints. It accepts
the native 512-bit CCX channels directly, inserts a shared L2, and presents an
AXI/WISHBONE-independent external beat interface.
See `doc/core_complex.md` for geometry, merge ordering, bus selection, and the
remaining L1-coherence and atomic limitations.
