# OpenRV64 Memory Buses

`rtl/core/bus/bus.v` is the core-bus geometry selector. `BUS_CONFIG` chooses
the original 64-bit instruction/data requester in `rtl/core/bus/gen_bus.v` or
the native cache/CCX boundary in `rtl/core/bus/ccx_bus.v`. Both paths expose a
separate native 512-bit CCX PTE client. The generic scalar path remains the
default interface used by `openrv64_platform`.
`rtl/openrv64_top_3p.v` is the fixed three-pipe boundary: it exposes native
512-bit CCX command/write-data/response channels plus residual 256-bit AXI,
and elaborates the AXI-configured bus and three-wide frontend unconditionally.
With L1I enabled, instruction misses are exactly one 64-byte CCX transaction;
they do not use AXI. Page-table walks are also native CCX transactions. AXI
remains only for explicit cacheless-L1I operation.

## Generic blocking interface

The generic instruction/data interface is a single 64-bit blocking memory
bus. PTW traffic is structurally absent from it and uses the parallel CCX
interface.

## Signals

| Signal            | Direction      | Description                                                                                           |
|-------------------|----------------|-------------------------------------------------------------------------------------------------------|
| `mem_valid`       | core to memory | Request is active. Request fields stay stable until `mem_ready`.                                      |
| `mem_ready`       | memory to core | Response/acceptance for the active request.                                                           |
| `mem_write`       | core to memory | `1` for write, `0` for read.                                                                          |
| `mem_addr[63:0]`  | core to memory | Byte address. Fetch requests are 8-byte aligned; data requests preserve their effective byte address. |
| `mem_wdata[63:0]` | core to memory | Write data.                                                                                           |
| `mem_wstrb[7:0]`  | core to memory | One byte lane enable per write byte.                                                                  |
| `mem_rdata[63:0]` | memory to core | Read data valid when `mem_ready` is high for a read.                                                  |
| `mem_error`       | memory to core | Completion failed; valid only with `mem_valid && mem_ready`.                                          |

There is no burst, transaction ID, or separate instruction/data channel on
the generic interface.
Access size and privilege are carried inside the core through translation and
PMP, but are not exported on this initial physical bus.

## Core requester

`rtl/core/bus/gen_bus.v` implements this requester behind the selector. It
accepts separate blocking requests from fetch and the LSU,
latches the selected request, and holds the exported request stable through
completion. LSU requests have priority when both requesters arrive together.
An obsolete fetch can be cancelled, but any already-exported physical request
is still drained before another request is issued.

On a fetch completion, the fetch queue can present an accepted successor miss
on an internal sideband. The core requester captures that successor on the
completion edge and returns directly to translation rather than spending an
intervening cycle in `IDLE`. A resident-line hit does not assert the sideband
or launch an external request. A waiting LSU still takes priority. This is
internal request chaining, not a burst on the top-level physical bus: each
missed 8-byte line remains a separate blocking transaction.

Request ownership includes the virtual address, access payload, effective
privilege, VM mode, ASID, and root page-table PPN. The bus captures that whole
context when it grants ownership; an in-flight request never observes later
CSR or requester-context changes. TLB entries are tagged by VM mode and ASID,
with global entries matching every ASID only within their original VM mode.

Bare requests use identity translation. When the effective privilege is S or
U and `satp.MODE=Sv39`, CCX-path requests first search the separate
fully-associative 16-entry L1 ITLB or DTLB in `rtl/core/bus/tlb.v`. An L1 miss
searches the shared 256-entry, four-way L2 TLB in
`rtl/core/bus/tlb_l2.v`; only an L2 miss is sent to
`rtl/core/bus/ptw.v`. The generic blocking bus retains one shared L1 TLB and
does not instantiate the L2 TLB. TLB entries store mode, ASID/global
ownership, page level, and leaf permission metadata. A tag hit can therefore
complete with a page fault when the cached leaf rejects the current read,
write, execute, privilege, SUM, MXR, A, or D requirements.

The L2 TLB caches 4 KiB translations in 64 indexed sets by default. Superpage
translations bypass it and remain eligible for the fully associative L1 TLBs.
The hierarchy permits duplication but does not enforce inclusion: L1 and L2
replacement are independent and need no back-invalidation tracking. A
successful walk fills the requesting L1 and L2; an L2 hit refills the
requesting L1. Simultaneous misses are serviced LSU, demand fetch, then
speculative instruction prefetch.

The PTW implements a blocking three-level Sv39 walk. It checks canonical
virtual addresses, PTE validity and reserved encodings, leaf permissions,
superpage alignment, inherited global mappings, SUM/MXR, and A/D state.
Physical errors while reading a PTE become an access fault for the original
request. Successful translations refill the TLB; page and access faults are
kept distinct through fetch/LSU, writeback, and the machine/supervisor trap
context.

`SFENCE.VMA` is serializing. At retirement it pulses `tlbi_i`, flushes younger
work, and restarts at the next PC. The current implementation intentionally
treats every `SFENCE.VMA`, including forms with nonzero `rs1` or `rs2`, as a
global shootdown. Invalidation clears TLB validity; it does not manufacture a
faulting entry. The next access misses and either obtains a fresh translation
or receives the PTW's page/access fault. If a shootdown overlaps an active
walk, the PTW terminates that walk and drains any already-accepted CCX response
without consuming it, so pre-fence state cannot refill either the PTE cache or
any TLB. The initiating invalidation also suppresses an L2 hit or PTW response
from filling either L1 on that edge and clears both L1 TLBs plus the shared L2
TLB.

PMP is enforced after translation. Final instruction/data accesses use their
effective privilege and access type. The PTW independently probes PMP as an
S-mode 8-byte read before issuing its CCX line request. A PMP denial becomes
an access fault for the original operation and no PTE request is emitted.

Current VM limitations are deliberate: only Bare and Sv39 are WARL `satp`
modes, shootdown is global rather than address/ASID selective, and A/D bits use
Svade-style fault-on-clear behavior because the memory bus has no atomic PTE
read-modify-write operation. Sv48, Sv57, hardware A/D updates, and IOASIDs are
not implemented.

## AXI interface

The residual AXI configuration has 64-bit addresses, 256-bit data, 32-byte
strobes, and 3-bit transaction IDs. Every transfer is a single-beat INCR
transaction (`AxLEN=0`). AXI is used only by the structural `ENABLE_L1I=0`
cacheless-fetch path. Native L1I, L1D, and PTW traffic does not use it.

With L1I enabled, `fetch_3w.v` requests one 256-bit frontend half-line by
virtual address. `openrv64_l1i_ccx` is VIPT: page-offset virtual bits select
the set/half while the ITLB supplies the physical tag and CCX address. Bare and
ITLB-hit demands launch without a separate translation state. The cache stores
the containing 512-bit line and turns a miss into one aligned native CCX read.
Predicted and
execute-time redirects may preserve resident frontend data for replay, while
reset, context-changing restarts, and `FENCE.I` invalidate the required state.

An accepted conditional branch queues both its direct target and fallthrough
inside L1I. Demand traffic has priority over their translation and fill work;
speculative translation/PMP faults are consumed locally. At architectural
retirement the losing virtual path is translated, if necessary, and its
resident physical line is made a preferred replacement victim rather than
invalidated.

The three-pipe frontend shares one scalar branch predictor across the oldest
control instruction in its current bundle. The accepted prefix ends at that
control lane, its prediction bit travels in that lane's backend packet, and a
predicted-taken direct target redirects the resident window without clearing
it. JALR and the no-speculation policy retain the predictor's unresolved-control
stall behavior.

The three-pipe LSU retains three tagged execution slots, but the core bus
serializes their physical memory operations through one precise DTLB/PTW/PMP
slot and one blocking L1D request port. The original LSU tag is retained and
returned with the data or page/access fault. A cacheable miss emits one aligned
512-bit native CCX read and returns the addressed 64-bit word. Write-through
stores and uncached operations use sub-line address, size, data, and strobes on
the same 512-bit CCX channels. A flush hides a canceled speculative load
response; an accepted store remains irrevocable and is drained.

Stores launch only when they are the ordered retirement head. The current 3P
baseline treats acceptance by the core bus as architectural completion; it
does not wait for the eventual CCX response. The execution LSU retains the
original store tag, PC, instruction, trace ID, and effective address until that
response arrives. While it is pending, another scalar request requiring L1D
remains blocked. A fully covered load may still complete locally from the
retained store word, including normal load shift and signed/unsigned extension.
Partial or non-forwarded loads wait. This is posted architectural completion
with a one-entry address/data bypass, not a multi-entry store buffer.

The overlap check currently compares effective addresses before translation.
That is sufficient for this Bare-mode, identity-mapped benchmark rig. It is not
a complete virtual-memory solution because distinct virtual addresses can
alias the same physical line. The existing translated path remains serialized;
a future cacheable LSU/store buffer must compare translated addresses and apply
PMA/MMIO ordering rules.

The local forwarding path is qualified by a configurable physical-memory
window. `openrv64_top_3p` defaults that window to the platform's 256 MiB RAM
aperture, so ROM and side-effecting MMIO cannot be forwarded. This is sufficient
for the current Bare-mode rig, but it is still only a range check. A production
LSU must use translated physical addresses and real PMA/cacheability attributes
when deciding whether store-to-load forwarding is legal.

A core-to-bus request handshake is only capture by the translation wrapper. A
store remains in the pre-retire queue until its tagged response proves
translation, PMP, and L1D store-buffer admission. A page or access fault is
therefore reported at the original store PC with its effective address in
`tval`; the store does not retire and may be replayed after trap return.

Once admitted by L1D, the physical cache-line write may remain posted across
core retirement and a younger redirect. A simulator or platform must keep
clocking the hierarchy long enough to drain committed stores. A failure during
that later drain cannot be converted back into a precise store exception; it
needs an asynchronous machine-check or fatal platform policy.

The current four-entry pre-retire queue retains virtual-address operations and
blocks younger memory behind an unresolved store. A full LSQ still needs PMA
classification, translated physical addresses, load/store disambiguation,
byte forwarding across multiple stores, and defined FENCE/atomic drain rules.

The remaining AXI limits are no multi-beat bursts, caches, pipelined translated
LSU accesses, exclusive accesses, or AXI connection in `openrv64_platform`.
RV64A remains serialized and uses the backend's ordered request/response
contract rather than AXI exclusives.

## Generic fetch buffering and lane rules

Memory targets return the aligned 64-bit word selected by `mem_addr[63:3]`.
Fetch retains both 32-bit instructions from that word in one of eight tagged
two-slot buffers. The eight lines are arranged as two sets selected by address
bit 3, with four ways comparing tag bits `[63:4]`; the circular unread order
still alternates naturally between sets. The window can hold up to sixteen
unread instructions. Consuming an entry clears its unread state but preserves
its resident line tag and data. A control-flow redirect discards the wrong-path
unread stream and checks the resident set. A predicted direct target hit can
replace the branch in IF/ID on the same edge; other resident hits can bypass an
empty fetch queue. Both cases avoid an external request and receive fresh
dynamic trace IDs. Traps, privilege/context returns, `FENCE.I`, and
`SFENCE.VMA` invalidate the resident window. A target in the upper half of a
word uses only that half, then continues with two instructions per following
aligned request.

`ENABLE_PREDECODE_TARGETS` controls the optional direct-target sidecar. When
enabled, fetch stores each direct control's signed PC-relative displacement in
a 20-bit field with the always-zero low bit omitted. The core sign-extends that
encoding and reuses its normal target adder, so a predicted resident target can
still replay on the redirect edge without storing sixteen absolute 64-bit
addresses. When disabled, the displacement arrays, metadata, and predecode
state are not elaborated. The instruction/tag loop buffer remains intact, and
normal decode still supplies control-flow type and target information.

For narrow data accesses, `mem_addr[2:0]` identifies the addressed byte lane;
store data and `mem_wstrb` use that same lane placement. Preserving the low
address bits is required for side-effecting 32-bit MMIO registers, such as the
PLIC threshold and claim registers that share one 64-bit bus word.

## SoC routing

The physical windows are defined only in `rtl/soc/bus/mem_map.v`.
`openrv64_soc_bus_decode` routes a request to boot ROM, memory, CLINT, PLIC,
UART, GPIO, or the general-purpose timer and muxes the selected target's
`mem_ready` and `mem_rdata` back upstream. Target addresses are translated to
local offsets. An unmapped request reaches no target and completes with
`mem_error` asserted.

Peripheral modules do not contain global base addresses or perform global
range checks. A routed peripheral request is therefore always acknowledged,
including reserved offsets inside that peripheral's assigned window.
