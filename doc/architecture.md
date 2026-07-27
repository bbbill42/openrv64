# OpenRV64 architecture

This document describes the RTL that exists in this repository. It separates
the default architecture from selectable experiments; it is not a roadmap or
a statement of intended peak performance. The primary performance target is
the three-pipe core behind `openrv64_top_3p`. The scalar core remains supported
and is summarized separately.

## Architectural invariants

The current design is built around a few deliberate rules:

1. Architectural state changes in program order. Integer register and CSR
   writes occur at retirement, and the three-pipe backend retires only a
   contiguous ready prefix.
2. The default three-pipe dispatcher is not an out-of-order scheduler. It may
   send as many as three oldest queued instructions to independent units, but
   it cannot step around a blocked older candidate.
3. The 3P backend has a parameterized physical register file (31 writable
   entries plus hardwired `p0`, with five-bit tags by default), but the active
   map is strictly `xN -> pN`. There is no dynamic physical allocation, RAT,
   free list, or rename recovery. Outstanding architectural-register writers
   are therefore still tracked explicitly, and optional forwarding is an
   exception to the resulting RAW interlock.
4. Ordinary aligned conditional branches may execute before reaching the
   retirement head. In the default strict backend, a correctly predicted BEQ
   or BNE may share its issue group with younger predicted-path work; every
   other branch terminates the group. A mispredicted branch therefore cannot
   have a younger instruction already issued beside it.
5. Stores are ordered at the retirement head. A core-to-bus request handshake
   is only translation-wrapper capture; architectural completion waits for the
   tagged translation, PMP, and L1D-admission response.
6. The 3P path has private L1I/L1D clients on native 512-bit CCX. L1D has
   parameterized demand MSHRs and a cache-line store buffer, but there is still
   no complete coherent multi-hart hierarchy.

These rules are more important than the informal names of the pipeline stages:
they define which optimizations can be added locally and which require a real
speculative recovery mechanism.

## Configurations and top-levels

| Boundary | Backend | Memory boundary | Purpose |
| --- | --- | --- | --- |
| `openrv64_l1i_top` | Standalone 256-bit fetch client | Native 512-bit CCX plus external translation service | VIPT L1I integration, synthesis, and trace-replay validation |
| `openrv64_top` | Selectable 1P or 3P | 64-bit blocking bus; 256-bit AXI is legal only with 3P | General integration wrapper |
| `openrv64_top_3p` | Fixed 3P | Native 512-bit CCX plus residual 256-bit AXI4 | Primary 3P performance and cache/CCX boundary |
| `openrv64_platform` | Currently the general wrapper and blocking SoC bus | Integrated ROM, 256 MiB simulation RAM, CLINT, PLIC, UART, GPIO, and timer | Firmware and OpenSBI platform validation |

`OPENRV64_BACKEND_1P` and `OPENRV64_BACKEND_3P` are implemented. The encoded
2P selection is reserved but not implemented. The specialized 3P top exposes
the retirement, forwarding, hazard, branch, and issue-window experiment
parameters that the general wrapper leaves at their 3P defaults.

The 3P core can still be elaborated behind the generic bus for compatibility,
but that geometry uses the legacy fetch path and presents at most two decode
lanes. `openrv64_top_3p` fixes both parts of the throughput configuration: the
three-wide fetcher and the native-CCX cache path.

The 3P integration testbench is a separate artifact. It terminates 512-bit
native CCX cache-line traffic against a 256-bit, 256 MiB RAM model, and routes
non-RAM CCX accesses to the existing 64-bit SoC peripheral bus. PTW requests
use CCX with `kind=PTE`; residual AXI services only explicit cacheless
instruction fetch. The
fabric currently lives in
`tb/tb_top_axi_3p.sv`; it is not yet the synthesizable `openrv64_platform`
interconnect.

## Implemented ISA and privilege architecture

The integrated cores execute fixed-width 32-bit RV64 instructions. The
advertised `misa` base is RV64I with S and U privilege support, plus A and M
when their parameters are enabled.

- RV64I integer, control-flow, load/store, and word operations are integrated.
- Zicsr and Zifencei behavior is integrated.
- RV64A is implemented and enabled by default. Atomics are serialized through
  the MEM lane; the AXI requester does not use AXI exclusive transactions.
- RV64M is implemented by the EX0 lane but disabled by default at the public
  tops.
- Machine, supervisor, and user privilege modes, delegated traps and
  interrupts, MRET/SRET, and the main machine/supervisor CSR state are
  implemented.
- Sixteen PMP entries use 4 KiB grain and support OFF/NAPOT matching plus
  lock bits. TOR and NA4 writes are WARL-coerced to OFF. NAPOT bounds are
  normalized when `pmpaddr` is written rather than decoded on every access.
- Bare translation and Sv39 are implemented.

The core does not implement the compressed C extension, so all instruction PCs
and direct branch targets must be four-byte aligned. F and D encodings and a
standalone elastic execution pipeline exist, but floating-point decode,
register state, CSR state, LSU routing, and retirement are not integrated; see
[rv64-fd.md](rv64-fd.md). RVV is not implemented.

## Three-pipe organization

The default 3P dataflow is:

```text
       direction predictor + BTB + RAS
                 |       ^ training/correction
                 v       |
AXI -> 4 x 32-byte fetch window -> 3 decoders -> 6-entry decoded FIFO
                                                   |
                         oldest contiguous prefix, up to three
                                                   |
                         retirement allocation + pipe routing
                            /              |              \
                           v               v               v
                    EX0: ALU/M    EX1: ALU/control  MEM: LSU/A, 3 tags
                           \               |               /
                            independent tagged completions
                                         |
                              8-entry retirement queue
                                         |
                        contiguous in-order retire, up to three
                              |                       |
                          integer GPRs            CSRs/traps
```

The readable 3P trace calls these logical regions `F`, `D`, `Q`, `I`, `C`, and
`R`. They are not all single-cycle pipeline registers. For example, `Q` may
hold an instruction for many cycles, RV64M and memory have variable latency,
and completion may wait behind an older unfinished retirement entry.

### Fetch and instruction supply

`fetch_3w.v` retains the current and immediately following 256-bit bridge
lines.  It issues only one line request at a time; cache residency, speculative
translation, and branch-path prefetching are owned by the VIPT L1I below it.

The frontend:

- emits a contiguous prefix of zero to three 32-bit instructions per cycle;
- can assemble that prefix across a 32-byte line boundary;
- advances only by the prefix accepted by decode;
- preserves resident lines across ordinary predicted and execute-time
  redirects, which makes small loops replay locally;
- cancels an obsolete frontend request on redirects while lower cache/CCX work
  is drained by L1I; and
- invalidates the resident window on reset, traps, privilege returns,
  `FENCE.I`, `SFENCE.VMA`, and other context-changing restarts.

This two-line window is a fetch bridge, not the instruction cache.  The L1I
beneath it is virtually indexed and physically tagged, uses 64-byte native CCX
fills, and queues both paths of accepted conditional branches.  The path not
taken is aged for replacement only after the branch retires.

Optional predecode stores the signed PC-relative displacement for JAL and
conditional branches. Direct targets therefore come from the instruction plus
the normal target adder and never consume BTB entries. The selectable advanced
predictor has a BTB only for indirect JALR targets. Disabling predecode removes
the direct-target sidecar but not the resident instruction lines.

Three decoders operate in parallel, but the accepted frontend prefix ends at
the oldest control instruction in the bundle. Only that control instruction
consults the scalar predictor. A predicted-taken redirect therefore never
admits sequential instructions after the same branch on that edge.

### Branch prediction and control flow

The direction predictor is selected with `BP_TYPE`:

| Value | Policy | Behavior |
| ---: | --- | --- |
| 0 | stall | Do not speculate; hold fetch/decode until the control resolves |
| 1 | always taken | Predict conditional branches taken |
| 2 | always not taken | Predict conditional branches not taken; direct jumps remain taken |
| 3 | repeat last | Reuse the most recently resolved conditional direction |
| 4 | BTFNT | Backward taken, forward not taken |
| 5 | bimodal | PC-indexed saturating-counter table with BTFNT cold behavior |
| 6 | gshare + BTB | 256-entry global-history direction table, 256-entry tagged JALR target table, speculative history recovery, and RAS |
| 7 | gshare-512 + BTB | Fixed 512-entry three-bit direction table with nine history bits; otherwise the mode-6 target and recovery machinery |
| 8 | tournament + BTB | 2048-entry global PHT, 512-entry local-history table, 1024-entry local PHT, 512-entry chooser, mode-6 BTB/recovery, and RAS |

The public default is the conservative stall policy. The implemented bimodal
defaults are 32 entries, three counter bits, and a four-entry update FIFO. The
table is direct-indexed and untagged, so unrelated PCs can alias. Up to three
retiring/resolving branches can enqueue training updates, while the table
retains a single write port.

The optional return-address stack defaults to eight entries and recognizes the
RISC-V x1/x5 call and return hints. It updates on resolution rather than
speculative lookup. A return is predicted only when a valid stack top exists;
other indirect JALRs stall until their target resolves. Direct JAL and
conditional targets do not need a BTB because their displacement is available
from predecode/decode.

Mode 6 adds an eight-bit speculative global history XORed with PC bits to
index a 256-entry, three-bit direction table. It checkpoints the prediction
index, pre-branch history, and any predicted indirect target in a 16-entry
ordered control queue. Resolution trains the original entry; a redirect rolls
history back to the checkpoint plus the actual outcome. With the speculation
window enabled, the checkpoint also carries the decode-time instruction ID:
resolution finds it associatively, correctly resolved younger branches may
wait in the queue, and committed history advances only when resolved records
reach the queue head. Selective recovery retains the resolving record and all
older records while dropping younger checkpoints. Its separate
256-entry direct-mapped BTB has a 16-bit tag and 64-bit target and is used only
for non-return JALRs. The RAS has priority for architectural return hints.
Invalid direction entries retain BTFNT behavior, and a cold indirect still
uses the existing resolve-time interlock. See
[performance/bp-results.md](performance/bp-results.md) for measured results
and implementation limits.

Mode 7 is the fixed low-cost step above mode 6: 512 three-bit counters and
nine global-history bits. The existing `BP_GSHARE_ENTRIES` and counter-width
parameters continue to configure mode 6; they deliberately do not alter mode
7.

Mode 8 is a conventional tournament predictor. Its global component uses
2048 three-bit counters and 11 speculative history bits. Its local component
uses 512 PC-indexed ten-bit histories and a shared 1024-entry three-bit PHT.
A 512-entry two-bit PC-indexed chooser starts weakly global and changes only
when the global and local components disagree. Global history uses the same
tagged checkpoint and recovery rules as mode 6. Local history updates at
conditional-branch resolution. The direction payload is 15,360 bits
(1.875 KiB); resettable valid state adds 4,096 bits, for 2.375 KiB total
direction state before checkpoint records, BTB, and RAS.

Tournament confidence ignores the chooser when the global and local
components agree. When they disagree, a prediction is strong only when both
the selected component and the chooser are strong. This confidence affects
alternate-path fetching only when the frontend confidence gate is enabled.

The predictor data arrays are reset-free and guarded by resettable valid
vectors, so synthesis retains the large tables as memories. This is not yet a
physical timing result. Mode 8's local-history read, local-PHT read, and final
chooser mux form a serial lookup path in the current combinational frontend.
A macro implementation also needs an explicit solution for simultaneous
lookup and training ports.

The simulation harnesses count accepted BTB and RAS lookups, hits, misses, and
wrong-target resolutions separately. These are simulation-visible events in
the predictor wrapper, not architectural performance counters.

In the normal strict 3P path, an aligned conditional branch issues as soon as
its operands and EX1 are ready; it does not wait for retirement. It resolves in
EX1 and redirects immediately on a direction error. The branch still occupies
EX1, allocates a retirement entry, and cannot retire ahead of older work.

A conditional branch normally terminates its backend issue group. Older
candidates may issue beside a following branch. With
`ENABLE_EQ_BRANCH_PAIRING=1`, dispatch also compares the ready operands of BEQ
and BNE. If that equality result proves the predicted direction correct, the
branch keeps its EX1 claim and hard retirement classification but waives the
same-cycle issue barrier. Younger predicted-path candidates may then claim the
other pipes subject to normal RAW, WAW, capacity, and structural checks:

```text
queue candidates       prediction/result       available issue
--------------------   ----------------------  ------------------------------
ADD, BEQ, LW           BEQ proved correct      ADD -> EX0, BEQ -> EX1, LW -> MEM
BEQ, ADD, LW           BEQ proved correct      BEQ -> EX0, ADD -> EX1, LW -> MEM
BEQ, ADD, LW           direction mismatch      BEQ -> EX0; ADD and LW wait
BLT, ADD, LW           any                     BLT -> EX0; ADD and LW wait
```

The comparator does not speculate past an unresolved result. A RAW-blocked
BEQ/BNE cannot issue, and strict-prefix issue prevents its younger candidates
from issuing even if stale operand bits happen to match the prediction. A
direction mismatch retains the normal barrier. Correction therefore still
needs to squash only the fetch stream and decoded FIFO, not age-selectively
roll back execution or retirement state.

The default branch-only completion bypass can make that operand ready from a
registered EX0, EX1, or MEM completion in the same cycle. Each architectural
destination remembers the retirement slot of its youngest live writer. A
completion is eligible only when its slot matches that owner, so an older WAW
completion with the same `rd` cannot satisfy or corrupt the branch. The
selected 64-bit value feeds the BEQ/BNE pairing comparator and the EX0 issue
payload; it does not enable forwarding for an ordinary ALU or memory consumer.

This is intentionally limited to equality branches. Adding signed/unsigned
magnitude comparators would lengthen the dispatch operand-to-issue path for
less coverage. Even the equality-only path is a real timing tradeoff and needs
placed-and-routed timing validation; RTL IPC alone does not prove closure.

`FREE_BRANCHES` is an implemented diagnostic mode, not the baseline. It
recomputes a conditional branch in dispatch, marks it complete at retirement
allocation, removes its EX0 claim, and permits correctly predicted younger
candidates to remain in the issue group. This is a useful performance upper
bound, but it puts branch comparison on dispatch timing and must not be quoted
as normal-core performance.

### Decode queue, issue, and structural routing

The strict dispatch path has a six-entry FIFO of decoded instruction payloads.
The payload carries PC, instruction, immediate, source and destination
registers, decoded unit operations, predicted direction, privilege context,
fault state, and an optional trace ID. Source values are captured from the GPR
and forwarding paths when the instruction issues; execution units do not read
the architectural GPR directly.

Up to the oldest three FIFO entries become issue candidates. Allocation into
the retirement queue and issue to an execution pipe occur together and must
form a strict program-order prefix:

- candidate 1 cannot issue unless candidate 0 issues;
- candidate 2 cannot issue unless candidates 0 and 1 issue;
- one instruction may claim each physical pipe per cycle; and
- the retirement queue conservatively resumes allocation only when it has room
  for a complete three-entry group.

Capability routing is fixed where required and flexible for base integer ALU
operations:

| Instruction class | Pipe |
| --- | --- |
| Branch, jump, system/CSR, fence, decoded fault | EX1 |
| RV64M | EX0 |
| Load, store, RV64A | MEM |
| Base integer ALU | EX0 or EX1 |

The router tries to preserve a fixed-capability lane for a following candidate
and, for the local ALU bypass, prefers the pipe that owns the producer.

Hard-order operations constrain issue more strongly. Aligned conditional
branches are not persistent after they issue; proved-correct BEQ/BNE may also
waive the same-group barrier.
Jumps, system/CSR operations, fences, decoded exceptions, and other hard
operations remain ordered at the architectural head as required by their
side effects.

Strict prefix issue is the main head-of-line rule. If the oldest candidate is
waiting for a true dependency or a busy unit, independent younger candidates
do not pass it even when another pipe is idle.

### Register ownership and forwarding

The 3P integer register file has `PHYS_REG_COUNT` writable storage entries (31
by default), six combinational read selectors, and three ordered retirement
write ports. Hardwired `p0` consumes no entry; physical tag `pN` maps to storage
entry `N-1`. The tag width is therefore
`clog2(PHYS_REG_COUNT + 1)`. The current identity renamer maps architectural
`x0` through `x31` to `p0` through `p31`, so all 31 default writable entries
are reachable. Counts below 31 are illegal. Source indices are translated
before PRF reads.

Each retirement entry captures `new_phys` and `old_phys` when it is allocated.
Retirement writes the captured `new_phys` rather than deriving a physical tag
again from the completion's architectural `rd`. In identity mode both tags
equal `rd`; retaining both now establishes the ROB/free-list boundary required
by later dynamic renaming. Same-cycle retirement bypass gives a reader the
youngest matching physical tag, and multiple same-destination retirement
writes leave the youngest program-order value in the identity-mapped register.

This seam is not dynamic renaming. Source physical tags are not retained in
issue entries, physical readiness is not tracked, and results still write the
PRF at retirement rather than validated completion. A real RAT/free-list
implementation must add those pieces plus committed-map and squash recovery;
replacing the identity function alone would be incorrect.

`RELAX_WAW=1`, the default, allows several live instructions to write the same
architectural register. A per-register writer count is incremented on
allocation and decremented on ordered retirement. This removes false WAW
serialization without allocating distinct physical destinations. A consumer
behind multiple live writers still waits unless a producer-tagged experimental
mode can identify the youngest value unambiguously.

The forwarding tiers are distinct:

1. **Local ALU completion forwarding**, enabled in the strict path, publishes
   the current EX0 and EX1 destination tags. Dispatch routes a matching
   consumer back to that ALU pipe, whose local operand mux supplies the value.
2. **Branch-only live completion forwarding**, selected by
   `BRANCH_COMPLETION_FORWARD_MASK`, exposes current registered EX0, EX1,
   and/or MEM completion values only to conditional-branch operands. The
   default mask is `111`. Eligibility is qualified by the youngest writer's
   retirement slot, not merely by matching `rd`; at the default eight-entry
   retirement depth that owner tag is three bits per architectural register.
3. **General live completion forwarding**, selected by
   `COMPLETION_FORWARD_MASK`, can expose the current registered EX0, EX1,
   and/or MEM completion values to every candidate operand. The default mask
   is `000`; useful masks are `011` for ALU completions, `100` for MEM, and
   `111` for all three.
4. **Full forwarding**, selected by `ENABLE_FULL_FORWARDING`, constructs an
   architectural-register value map from the indexed youngest-owner state and
   current completion overlay. Completed-but-unretired values remain in that
   canonical owner map; the backend no longer scans or exports every
   retirement result entry. It is an upper-bound experiment and is disabled
   by default.
5. **Aggressive producer ownership**, selected by `RELAX_HAZARDS`, retains the
   youngest live producer ID, ready bit, and result for every architectural
   register. It makes relaxed WAW plus broad forwarding unambiguous, but it is
   materially closer to a result/rename table than a small bypass network and
   is disabled by default.

No mode cascades an ALU result combinationally into a younger instruction in
the same issue group. Same-bundle RAW dependencies wait at least until a later
cycle. A result that has not completed, especially a load response, cannot be
forwarded by any of these networks.

### Execution lanes

Each physical lane has independent input readiness and a held tagged
completion port. A long M operation or memory request does not inherently stop
the other execution lanes from accepting unrelated work.

- **EX0** implements a base integer ALU and the single RV64M worker. M
  operations are iterative/variable-latency and fixed to this pipe.
- **EX1** implements a second base integer ALU plus branch/jump, system/CSR,
  fence, exception, and trap-producing operations. Valid aligned conditional
  branches produce their direction and redirect as they execute.
- **MEM** implements RV64I loads/stores and serialized RV64A operations. Its
  simple-operation queue has eight tags and can accept independent loads on
  consecutive cycles.

Completions carry the dynamic instruction ID and retirement slot. This allows
the execution lanes and tagged memory responses to complete out of order
without making architectural state out of order.

### Retirement and precise state

The default retirement queue has eight entries. Strict dispatch assigns a
monotonically increasing modular 10-bit dynamic ID and circular slot when an
instruction issues. Each execution lane may complete its own slot
independently. The separate 64-bit trace ID is debug state, not the execution
identity.

The ordering queue stores only valid, complete, dynamic ID, and ring pointers.
It drives three slot selectors into a canonical record bank. Each selected
entry supplies a 130-bit allocation record and a 281-bit completion-only
record; allocation fields are not copied back through the 457-bit execution
completion packet. Trace-enabled builds store one 64-bit trace value per
allocation in a separate bank. The physical area profile disables that bank.

The queue presents only the maximal completed prefix beginning at its head.
Up to three ordinary instructions may retire in one cycle. An exception, halt,
or hard-order entry ends that retirement group. Faulting entries are consumed
to release ownership but do not write a GPR or increment the architectural
retired-instruction count.

Architectural GPR writes and CSR write intents are applied at retirement.
Interrupts are recognized at a retirement boundary and are deferred across a
same-cycle CSR write or another control event. MRET, SRET, `FENCE.I`, and
`SFENCE.VMA` restart the frontend and flush younger state.

This provides precise integer, CSR, branch, load, synchronous store, and trap
behavior. A store does not complete merely because the core-to-bus request was
captured. It remains in the pre-retire store queue until a tagged response
proves translation, PMP, and L1D store-buffer admission. Translation and
protection failures therefore trap at the original store PC without
architecturally retiring the store. The physical cache-line drain may remain
posted below L1D; a failure after that committed boundary requires a separate
machine-check policy and is not a replayable page/PMP fault.

## Load/store and memory ordering

The 3P backend uses `exec_lsu.v` as its containing LSU and `lsq.v` as a
separate, parameterized unified load/store queue. The defaults are four load
entries and four store entries. The single age-ordered entry array uses fixed
load/store slot partitions so its two allocation-ready paths are independent.
The LSU owns address generation, translation and cache request sequencing,
RV64A, exception construction, and backend completion. The LSQ owns entry
state, age/order checks, physical-address disambiguation, forwarding, and
request eligibility. The legacy
`exec_pipe_mem.v` remains available to configurations which use the older
memory pipe; it does not contain the unified LSQ.

Loads and stores have independent allocation ports, but the containing LSU
currently has one translation/L1D launch port. The second legacy 3P external
memory port is tied off. An ordinary store may allocate and request translation
speculatively. Translation and PMP return a tagged physical address without
touching L1D. Only an exact match at the ordered retirement head permits the
store's physical request to reach L1D. A successful physical response means
L1D admitted the store into its ordered store buffer.

An ordinary load also translates before physical access. It waits behind every
older store whose physical address is unknown. Once all relevant addresses are
known, a cacheable load may pass stores on different physical cache lines. A
same-word load whose requested bytes are fully covered by older stores is
forwarded bytewise from the youngest matching stores. Partial coverage and
other same-line cases wait. Uncacheable loads issue only at the ordered head.
These rules use translated physical addresses; virtual-address equality is not
used as a memory-dependence proof.

Cacheable load misses allocate a parameterized demand MSHR (three by default)
and issue one aligned 512-bit native CCX line read per unique line. Different
lines use independent transaction IDs and may return out of order; same-line
loads merge as tagged waiters. L1D returns each addressed 64-bit word and
retains the full line in the cache.
Write-through stores and uncached scalar accesses use sub-line address, size,
data, and strobes on the same 512-bit CCX channels. No scalar LSU request uses
an AXI ID or drives AXI directly. A redirect hides a canceled speculative load
response, while an accepted store remains irrevocable and is drained.

Core-bus request acceptance is not architectural completion. The store remains
at the memory-ordering head until its tagged response. On success that response
means the translated and PMP-approved store was admitted by L1D; retirement may
then proceed while L1D drains the physical cache-line write independently.

The static `L1D_CACHEABLE_BASE`/`L1D_CACHEABLE_SIZE` physical aperture
classifies a translated load as cacheable RAM. It is not a complete PMA
implementation. An ordinary load may begin translation past unresolved
control regardless of its virtual address, but the LSQ does not release the
physical access until translation has completed. A translated address outside
the RAM aperture remains ordered at the retirement head, preventing
speculative device reads. SATP, `SFENCE.VMA`, fences, stores, and atomics
cannot pass pending ordered memory state; younger non-memory execution may
continue filling the retirement window.

RV64A drains simple MEM work and runs as a serialized ordered operation. It
uses the core request/response contract rather than AXI exclusives. Atomics do
not yet use the ordinary early-translation path.

A redirect immediately removes younger LSQ entries that have not launched a
request. A younger entry with an accepted translation or physical request
retains its LSQ tag in a killed quarantine slot until the response is consumed;
the response cannot complete architecturally and the finite-width tag cannot
be reused early. A store whose physical request was accepted at the ordered
head is already irrevocable and is retained through redirect. A full flush may
also mark accepted reads canceled at the tagged memory endpoint while their
underlying operations drain.

## Translation, protection, and physical bus

The core bus owns instruction/data translation and the shared physical
requester. Bare mode is identity translated. In the AXI configuration, S/U
accesses under Sv39 consult separate 16-entry, fully associative instruction
and data L1 TLBs, then a shared 256-entry, four-way L2 TLB on an L1 miss. The
generic blocking requester instead uses one shared 16-entry TLB and has no L2
TLB. Entries retain ASID, global, page-size, permission, A, and D state.

The shared L2 TLB has 64 indexed sets and four independently read payload
banks. It caches 4 KiB translations only; 2 MiB and 1 GiB leaves remain in the
fully associative L1 TLBs because indexing a superpage with 4 KiB VPN bits
would be incorrect. The hierarchy is neither inclusive nor exclusive. A PTW
response fills the requesting L1 and the L2, and an L2 hit fills the
requesting L1, but replacement at either level does not invalidate or update
the other. Demand LSU lookup has priority over demand fetch and speculative
instruction prefetch. `L2_TLB_ENTRIES` and `L2_TLB_WAYS` parameterize the
structure; the entry count, way count, and resulting set count must be
powers of two.

One blocking three-level page-table walker handles 4 KiB, 2 MiB, and 1 GiB
leaves. It checks canonical addresses, invalid/reserved PTE encodings,
superpage alignment, privilege, SUM, MXR, and access type. A/D bits use
Svade-style fault-on-clear behavior because the physical interface has no
atomic PTE update mechanism. `SFENCE.VMA` and a successful writable `satp` CSR
access currently perform the same conservative global translation barrier:
older memory completes first, all local TLB/PTW and frontend context is
invalidated, a CCX `ACQ_REL` PTE fence completes, and only then may fetch or
LSU traffic restart. The initiating pulse clears both L1 TLBs and the shared
L2 TLB and suppresses any same-cycle PTW or L2-to-L1 fill. Address- and
ASID-selective invalidation are not implemented.

PMP is checked after translation at the physical requester boundary. Page
faults and physical access faults remain distinct through completion and
retirement.

The fast three-tag LSU path is currently a Bare-mode path. A translated tagged
request falls back to the precise blocking DTLB/PTW path and retains its
original LSU tag until that operation completes. Consequently, translation is
functionally supported but the D-side translated path is not pipelined across
multiple requests.

### AXI geometry

The 3P AXI interface has:

- 64-bit addresses;
- 256-bit read/write data and 32 byte strobes;
- 3-bit transaction IDs; and
- independent AXI read-address, read-data, write-address, write-data, and
  write-response channels.

Every current transfer is a single-beat INCR transaction with `AxLEN=0`.
Cacheless instruction reads use a 32-byte transfer. IDs 0-3 identify its four
instruction-line slots. IDs 4-7 are currently unused; L1D and PTW requests use
native CCX rather than AXI.

| AXI ID | Owner |
| ---: | --- |
| 0-3 | Instruction-line reads |
There are no AXI data operations, multi-beat bursts, cache refills, exclusive
accesses, or coherence transactions.

### SoC address map and test integration

The common physical map is:

| Target | Base | Size |
| --- | ---: | ---: |
| Boot ROM | `0x0000_1000` | 64 KiB |
| CLINT | `0x0200_0000` | 64 KiB |
| PLIC | `0x0c00_0000` | 64 MiB |
| UART | `0x1000_0000` | 256 B |
| GPIO | `0x1001_0000` | 4 KiB |
| Timer | `0x1002_0000` | 4 KiB |
| RAM | `0x8000_0000` | 256 MiB |

The integrated generic-bus platform resets at ROM, whose three-instruction
stub jumps to RAM at `0x8000_0000`. The AXI performance testbench normally
overrides reset to RAM and loads the benchmark image directly. Its native AXI
RAM consumes the RAM aperture; non-RAM accesses are lane-adapted into the
existing blocking SoC decoder and peripherals.

See [memory_bus.md](memory_bus.md), [integration/bus.txt](integration/bus.txt),
and [integration/platform.txt](integration/platform.txt) for the signal-level
bus, reset, interrupt, and platform contracts.

## Optional tagged issue window

`ENABLE_ISSUE_WINDOW` selects a separate dispatch implementation while leaving
the strict FIFO path instantiated and recoverable. The window depth must equal
the retirement depth; the 16-entry experiment therefore uses a 16-entry
retirement queue as well.

Unlike strict dispatch, the window allocates an ID and retirement slot at
decode time. Each source records either committed GPR data or the ID of its
youngest producer. Completion broadcasts wake waiting operands, and the
scheduler selects the oldest eligible instruction for each compatible physical
pipe. Independent younger ALU work can therefore issue around an unresolved
older dependency while architectural retirement remains ordered.

With `ENABLE_SPECULATION_WINDOW=0`, this is real out-of-order issue but it is
deliberately limited:

- hard-order operations constrain younger issue;
- memory operations remain program ordered;
- memory cannot pass an older live branch;
- a branch may execute before retirement, but prediction correction is held
  until that branch reaches the retirement head;
- no rename checkpoints or general age-selective rollback exist; and
- `FREE_BRANCHES` and the issue window cannot be enabled together.

`ENABLE_SPECULATION_WINDOW=1` merges selective speculation into the same
window; it requires `ENABLE_ISSUE_WINDOW=1`. Decode-time instruction IDs become
both producer tags and speculation-age tags. A ready branch resolves in EX1
and redirects immediately rather than waiting at the retirement head. The
issue window, retirement queue, and tagged gshare checkpoint queue retain the
resolving branch and every older instruction while discarding only younger
state. IDs remain monotonic across recovery, so a late completion from a
squashed instruction cannot alias newly allocated work even if its physical
retirement slot is reused. The register-owner map is rebuilt from surviving
entries, including an older WAW producer whose value completed before the
recovery.

A legal aligned direct JAL is deterministic once decoded. It may therefore
issue before the retirement head and does not prevent younger replayable ALU
work from issuing; its link-register result remains buffered until ordered
retirement. JALR remains ordered unless and until the window explicitly
consumes a valid BTB/RAS target as speculation metadata.

With the speculation window enabled, a legal aligned conditional branch also
does not establish an issue frontier merely because its compare operands are
not ready. Younger replayable instructions may execute while the branch waits
in the window. Conditional controls themselves resolve in program order: a
younger conditional cannot issue until every older conditional has issued and
resolved. This prevents nested wrong-path redirects and predictor updates while
still allowing non-control work through the unresolved branch. When the older
branch's operands arrive, EX1 resolves it immediately. A correct prediction
retains the speculative work; a correction removes retirement and dispatch
entries with a younger monotonic instruction ID and rebuilds the surviving
register-owner map. This is speculative execution, not a free branch: the
wrong-path work still consumes issue capacity and the redirect still refills
the frontend.

Ordinary loads may begin translation past an unresolved older branch or early
direct JAL without classifying their virtual address. Once translation
returns, only a physical address inside the configured cacheable-RAM aperture
may issue before ordered retirement. Stores, atomics, translated MMIO/non-RAM
reads, and memory-to-memory reordering remain conservative. Wrong-path RAM
responses may return after recovery but are discarded by the non-reused
instruction tag. This is not a substitute for cache request cancellation or
memory-dependence speculation.

The implementation is selectable and checksum-tested, but it is not the
current baseline. It has no dynamic physical-register renaming, retains
in-order retirement, and the current associative wakeup/owner-rebuild logic
has not been timing-closed. The RAS is conservatively cleared on selective
recovery rather than checkpointed. See
[experiments/issue-window-16.md](experiments/issue-window-16.md).

## Scalar 1P core

The 1P core is the original conventional scalar pipeline. Its logical stages
are IF, ID, EX, MEM, and WB, with individually parameterized stage registers.
It has one instruction in issue, a scalar scoreboard, EX/MEM forwarding, an
optional direct load-use bypass, and the same decode, CSR, privilege, PMP,
Sv39, branch-predictor, and exception blocks where applicable.

The scalar core normally uses the 64-bit blocking physical bus. Its generic
fetcher retains eight tagged 64-bit words arranged as two sets by four ways,
for as many as sixteen unread 32-bit instructions. It is preserved for simple
integration, regression, and performance comparison; the fixed 3P AXI top is
the current throughput-development target.

The 1P forwarding controls are independent of the 3P controls:
`ENABLE_FORWARDING` enables normal arithmetic-result bypass and
`ENABLE_LOAD_FORWARDING` enables the timing-expensive memory-response-to-EX
load bypass. See [forwarding.md](forwarding.md).

## Default 3P parameter profile

The defaults on `openrv64_top_3p` are intentionally conservative except for
ordered WAW relaxation:

| Parameter | Default | Meaning |
| --- | ---: | --- |
| `RETIRE_DEPTH` | 8 | Retirement/completion entries |
| `ENABLE_RV64M` | 0 | Iterative M execution disabled |
| `ENABLE_RV64A` | 1 | Serialized atomics enabled |
| `RELAX_WAW` | 1 | Multiple ordered writers to one architectural rd allowed |
| `RELAX_HAZARDS` | 0 | Youngest-producer result table disabled |
| `BRANCH_COMPLETION_FORWARD_MASK` | `111` | Producer-slot-qualified EX0/EX1/MEM bypass to conditional branches |
| `COMPLETION_FORWARD_MASK` | `000` | Cross-pipe live completion bypass disabled |
| `ENABLE_FULL_FORWARDING` | 0 | Completed retirement-entry map disabled |
| `ENABLE_ISSUE_WINDOW` | 0 | Six-entry strict-prefix dispatch selected |
| `STORE_QUEUE_DEPTH` | 4 | Pre-retire speculative store entries |
| `ENABLE_POSTED_STORES` | 1 | Compatibility parameter; 3P completion still waits for L1D admission |
| `ENABLE_EQ_BRANCH_PAIRING` | 1 | Proved-correct BEQ/BNE may retain younger predicted-path issue |
| `FREE_BRANCHES` | 0 | Diagnostic branch completion at dispatch disabled |
| `BP_TYPE` | 8 | Tournament direction predictor, tagged indirect BTB, and RAS |
| `BP_RAS_ENABLE` | 1 | RAS hardware elaborated |
| `BP_RAS_DEPTH` | 8 | Return stack entries |
| `BP_BIMODAL_ENTRIES` | 32 | Bimodal direction entries when selected |
| `BP_BIMODAL_COUNTER_BITS` | 3 | Saturating counter width |
| `BP_BIMODAL_UPDATE_DEPTH` | 4 | Serialized predictor update FIFO |
| `BP_GSHARE_ENTRIES` | 256 | Gshare PHT entries when mode 6 is selected; mode 7 is fixed at 512 |
| `BP_GSHARE_COUNTER_BITS` | 3 | Gshare saturating counter width |
| `BP_BTB_ENTRIES` | 256 | Tagged indirect-target entries |
| `BP_BTB_TAG_BITS` | 16 | Indirect-target tag width |
| `BP_INFLIGHT_DEPTH` | 16 | Ordered prediction/checkpoint records |
| `ENABLE_PREDECODE_TARGETS` | 1 | Direct PC-relative target sidecar enabled |

Performance experiments commonly select alternate predictor modes, live or
full forwarding, and aggressive hazards. Those are valid RTL configurations,
but results from them must name the parameters rather than being presented as
the default core.

## Trace and validation

The scalar trace exports the stable `openrv64-cycle-v1` IF/ID/EX/MEM/WB ABI.
The 3P performance harness emits `openrv64-3p-cycle-v2`, including fetch,
decode, decoded queue, physical issue pipes, completion, retirement, first
blocking cause, completed-entry state, frontend line state, and tagged LSU
request/response details. See [cycle_trace.md](cycle_trace.md).

Useful checks include:

```sh
make -B sim
make -B sim-top-axi-3p-bp
make -B sim-top-axi-3p-perf \
    AXI_3P_PERF_BIN=sw/test.bin \
    AXI_3P_PERF_MEMH=sim/test-256.memh
```

`sim-top-axi-3p-perf` enables the detailed 3P trace. Functional Sky130
partition reports are available through `make yosys-resources-core-sky130`,
but they are pre-layout logical-area results, not placed-and-routed timing or
die-size claims.

## Current architectural limitations

- Private L1I/L1D and branch-path L1I prefetching exist, but there is no
  complete coherent multi-hart hierarchy or final cacheable-memory attribute
  policy.
- The unified LSQ has one translation/L1D launch port. It blocks partial
  same-line forwarding cases, uses a static cacheable aperture rather than a
  complete PMA model, and serializes atomics at the ordered head.
- Predictor modes 6 through 8 have a direct-mapped BTB for non-return JALRs;
  the default stall policy and modes 1 through 5 still limit indirect
  prediction to the RAS.
- The frontend ends decode admission at the first control instruction. The
  strict backend pairs younger work only past proved-correct BEQ/BNE; other
  branches still terminate the issue group.
- Default strict-prefix issue cannot walk around a blocked head instruction.
- Same-bundle dependent execution is not cascaded.
- Translated tagged LSU traffic is serialized through one DTLB/PTW path.
- `SFENCE.VMA` is global; Sv48/Sv57 and hardware A/D updates are absent.
- Errors after successful L1D admission still need a defined asynchronous
  machine-check policy.
- RV64F/D, RVV, and compressed instructions are not integrated.
- Single hart only. The integrated platform has one machine CLINT context and
  one supervisor PLIC context.
- The synthesizable integrated platform still uses the blocking bus; the
  native 256-bit RAM plus MMIO AXI fabric is currently testbench-only.
- Performance test RAM is not a model of a physically closed cache/memory
  hierarchy. Fixed-clock IPC results do not establish achievable frequency.

The near-term architectural work is tracked in [TODO.md](TODO.md). Detailed
performance counterfactuals remain under [experiments/](experiments/) and
should not silently redefine the baseline described here.
