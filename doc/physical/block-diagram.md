# OpenRV64 3P detailed block diagram

## What was inspected, and when (UTC)

| Item             | Value                                                                |
|------------------|----------------------------------------------------------------------|
| Inspection       | Live RTL hierarchy and interface-width audit                         |
| Inspected        | 2026-07-23 10:02:15 UTC                                              |
| Source           | Git `091bc5ab03b0`, with a dirty working tree                        |
| Boundary         | `openrv64_top_3p`                                                    |
| Core topology    | Three-wide fetch/decode/issue/retire, EX0/EX1/MEM                    |
| ISA parameters   | Live default `M=0`, `A=1`; last physical profile enabled RV64M+A     |
| Main memory path | Native ready/valid CCX, 512-bit line data                            |
| Diagram          | [`openrv64-core-block-diagram.svg`](openrv64-core-block-diagram.svg) |

The SVG is intentionally large and zoomable. It documents the implemented RTL,
not a floorplan, and block dimensions are not proportional to physical area.

The retirement block, its connections, and the physical-snapshot comparison
were re-audited on 2026-07-26 05:56 UTC at Git `e23485a0720` with a dirty
working tree. Other blocks retain the inspection date above.

![Detailed OpenRV64 3P block diagram](openrv64-core-block-diagram.svg)

## Important snapshot differences

The live wrapper defaults and the last corrected physical-size run are not the
same configuration:

| Item                       | Live RTL default | Last corrected size run |
|----------------------------|-----------------:|------------------------:|
| L1I                        |    16 KiB, 4-way |           16 KiB, 4-way |
| L1I data RAM               |     4 x 64 x 512 |            4 x 64 x 512 |
| L1D                        |    16 KiB, 8-way |           16 KiB, 4-way |
| L1D data RAM               |     8 x 256 x 64 |            32 x 64 x 64 |
| Aggregate L1 data capacity |           32 KiB |                  32 KiB |

The 2026-07-25 `tagged-l1d-260725` run mapped **7.123870 mm2 of standard-cell
logic plus 32 KiB of inferred L1 data SRAM**. Its cache capacities match the
live defaults, but its L1D organization does not. It also predates the compact
retirement rewrite, so it remains a projection baseline rather than a current
whole-core result.

Internal dynamic instruction IDs are now 10 bits from predictor lookup through
dispatch, execution, completion, redirect, and retirement. The separate
architectural trace UID embedded in issue/completion payloads remains 64 bits.
Retirement stores that trace UID only once, in an allocation-only debug bank
that disappears when trace support is disabled. Age tests use modular
subtraction, so the 1023-to-0 wrap remains ordered while fewer than half of the
1,024-ID namespace can be live. The configured queues are far below that
512-ID limit.

## Wide interfaces and coupling

| Producer -> consumer                              | Type                                 |                                                                Implemented payload |
|---------------------------------------------------|--------------------------------------|-----------------------------------------------------------------------------------:|
| Fetch -> decode                                   | 3-lane decoupled packet              |                                                                       3 x 120 bits |
| Decode/packet build -> dispatch                   | 3-lane decoupled packet              |                                             3 x (402 payload + 2 source-use flags) |
| Dispatch -> each execution lane                   | held ready/valid issue               |                               402 payload + 10 ID + 3 slot + valid = 416 bits/lane |
| Each execution lane -> backend completion ingress | held ready/valid completion          |                                457 result + 10 ID + 3 slot + valid = 471 bits/lane |
| Completion ingress -> canonical record bank       | qualified slot write                 |                        281 completion-only result + 3 slot + valid = 285 bits/lane |
| Retirement queue -> record bank                   | ordered selectors                    |                                                                     3 x 3-bit slot |
| Record bank -> retire                             | ordered head prefix                  | 130 allocation + 281 completion + valid = 412 bits/lane; optional trace64 sideband |
| GPR -> dispatch                                   | combinational read                   |                                       6 x 64 data, selected by 6 x 5-bit addresses |
| Retire -> GPR                                     | architectural commit                 |                                          3 x (valid + 5-bit address + 64-bit data) |
| Youngest-owner map -> backend forwarding          | indexed architectural-register state |                                           32 x (valid, ready, ID10, slot3, data64) |
| Live completions -> backend forwarding            | three-lane overlay                   |                                                  3 x (valid + ID10 + rd5 + data64) |
| MEM -> memory subsystem                           | tagged decoupled LSU request         |                                tag3, address64, data64, strobe8, size3, lock/write |
| Fetch -> memory subsystem                         | decoupled line request               |                              address64, stash/demand; response address64 + data256 |

Retirement is split into an ordering queue and a canonical record bank. At the
area configuration (`ENABLE_TRACE=0`), they store per entry:

```text
ordering: valid1 + complete1 + dynamic ID10
records:  allocation130 + completion281
= 423 bits/entry
= 3,384 bits across eight entries
```

The prior implementation stored 415 bits of allocation metadata and copied a
457-bit completion packet into every slot: 884 bits per entry including ID and
control, or 7,072 bits at depth eight. The compact representation removes
3,688 resident bits (52.15%) before mux/enable logic. Trace-enabled builds add
one 64-bit allocation-only entry, not another pair of full-packet copies.

## External memory protocols

The enabled-cache configuration sends L1I, L1D, and PTW traffic through three
independent ready/valid CCX channels:

| Channel    |                                                                                                               Payload |
|------------|----------------------------------------------------------------------------------------------------------------------:|
| Command    | 98 bits: hart4, transaction4, source2, operation4, lock1, order2, kind2, attributes4, size3, address64, burst length8 |
| Write data |                                          595 bits: hart4, transaction4, source2, beat8, last1, data512, byte strobe64 |
| Response   |                                    533 bits: hart4, transaction4, source2, beat8, last1, data512, error1, SC-success1 |

The 256-bit AXI4 master remains in the top-level pinout but is active only for
explicit cacheless-L1I operation. Scalar LSU and PTW traffic do not use AXI.
The legacy 64-bit blocking bus is tied off by `openrv64_top_3p`.

## Source RTL

- [`rtl/openrv64_top_3p.v`](../../rtl/openrv64_top_3p.v)
- [`rtl/core/rv64_top_3p.v`](../../rtl/core/rv64_top_3p.v)
- [`rtl/core/backend/backend_3p.v`](../../rtl/core/backend/backend_3p.v)
- [`rtl/core/backend/backend-defs.v`](../../rtl/core/backend/backend-defs.v)
- [`rtl/core/dispatch/dispatch_3p.v`](../../rtl/core/dispatch/dispatch_3p.v)
- [`rtl/core/exec/exec_top_3p.v`](../../rtl/core/exec/exec_top_3p.v)
- [`rtl/core/retire/retire_queue_3p.v`](../../rtl/core/retire/retire_queue_3p.v)
- [`rtl/core/retire/retire_records_3p.v`](../../rtl/core/retire/retire_records_3p.v)
- [`rtl/core/bus/ccx_bus.v`](../../rtl/core/bus/ccx_bus.v)
- [`rtl/core/cache/l1/l1i/l1i.v`](../../rtl/core/cache/l1/l1i/l1i.v)
- [`rtl/core/cache/l1/l1d/l1d.v`](../../rtl/core/cache/l1/l1d/l1d.v)
- [`rtl/complex/protocol/defs.v`](../../rtl/complex/protocol/defs.v)
