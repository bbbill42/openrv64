# Moderate out-of-order core proposal

Status: design proposal; shared PRF and LSQ substrates partially implemented

This document proposes a parameterized out-of-order (OOO) OpenRV64 core while
preserving the existing one-pipe (1P) and three-pipe (3P) cores.  It defines
the intended abstraction boundaries and an initial implementation profile; it
distinguishes proposed OOO structures from shared substrate already integrated
into 1P/3P. The current implementation remains documented in
[architecture.md](../architecture.md).

## Goals

- Continue to support 1P, 3P, and OOO core configurations as first-class
  designs.
- Add physical-register renaming, out-of-order issue, independent execution
  units, and precise in-order retirement.
- Make OOO queue depths, register counts, widths, and optional mechanisms
  parameterizable without imposing their machinery on 1P or 3P.
- Share instruction semantics, architectural services, storage primitives,
  and stable protocols where that sharing is real.
- Keep configuration-specific scheduling, pipeline, recovery, and memory
  implementations separate behind those protocols.
- Preserve a path from a simple functional implementation to banked and
  physically credible structures without changing architectural contracts.

## Non-goals

- Replacing the existing 1P or 3P core.
- Turning `dispatch_3p` or the optional tagged issue window into a
  parameter-heavy OOO scheduler.
- Forcing the legacy `exec_pipe_mem` implementation to contain the shared LSQ.
- Treating AXI as the internal core protocol.  AXI remains an external
  transport below the core/cache/complex boundary.
- Claiming that queue depths or RTL IPC establish a physically viable core.

## Core-family layering

The core family should share contracts rather than one scheduler or one giant
set of configuration-dependent ports:

```text
integration/core shell
  |
  +-- frontend profile: scalar or three-wide
  +-- common decoded-uop contract
  |
  +-- backend profile
  |     +-- backend_1p
  |     +-- backend_3p
  |     +-- backend_ooo
  |
  +-- shared architectural services
        CSR / traps / PMP / MMU / memory endpoint / trace
```

Each backend owns the structures that define its scheduling model:

| Backend | Dependency model                       | Scheduling                                       | Register mapping | Memory path                                     |
|---------|----------------------------------------|--------------------------------------------------|------------------|-------------------------------------------------|
| 1P      | Scalar scoreboard                      | In order                                         | Identity         | Existing scalar pipeline                        |
| 3P      | Architectural ownership and forwarding | Strict prefix, with separate experimental window | Identity         | Shared `exec_lsu` containing `lsq`              |
| OOO     | Physical tags and readiness            | Oldest-ready issue queue                         | RAT/RRAT         | Shared LSQ contract with OOO admission/recovery |

Configuration-specific modules are intentional. `dispatch_1p`,
`dispatch_3p`, and the legacy `exec_pipe_mem` remain valid implementations.
The shared memory split is explicit: `exec_lsu` contains address generation,
translation/cache sequencing, atomics, faults, and completion, while `lsq`
contains queue state, memory ordering, physical disambiguation, and forwarding.
The OOO core supplies its own rename/dispatch, scheduler, and recovery rather
than adding OOO cases throughout those files.

Backend selection should occur at a core-composition boundary.  The existing
`dispatch.v` and `exec_top.v` selector interfaces already contain distinct 1P
and 3P port families; they should not acquire a third OOO family.  Fixed public
tops may wrap the selected composition while retaining a generic integration
top where useful.

## Shared contracts

The common boundaries should be narrow enough that every backend can implement
them without carrying another backend's internal state.

### Decoded uop

A decoded uop contains architectural and semantic information only:

- PC, instruction, immediate, and optional trace identity;
- architectural `rs1`, `rs2`, and `rd` plus source-use/destination-write bits;
- ALU, branch, LSU, system, and extension operations;
- predicted direction/target metadata;
- privilege and permission context needed by execution; and
- decoded instruction-access, page, and illegal-instruction faults.

It does not contain a RAT, physical-register readiness, ROB state, or an OOO
issue-queue index.

### Execution request

An execution request contains:

- decoded operation information needed by the selected execution unit;
- captured source values;
- architectural destination for commit and trace;
- an opaque backend destination tag;
- an opaque completion/ROB token; and
- branch-prediction metadata needed for resolution.

The destination fields must remain distinct:

```text
arch_rd     architectural destination used by commit and trace
dst_tag     backend result tag; a physical register in the OOO core
rob_token   dynamic instruction and stale-completion identity
```

`rd` must not mean an architectural register in one backend and a physical
register in another.

### Execution completion

The completion returns the destination tag and ROB token unchanged along with:

- integer result data;
- exception cause and `tval`;
- resolved branch direction and target;
- CSR write intent; and
- xRET, fence, halt, and other commit-time intents.

The backend validates the returned token before changing backend state.  The
execution unit does not write architectural state directly.

### Commit event

A backend-neutral commit event reports the maximal architectural information
needed by the CSR/trap machinery, debug interface, and differential testing:

- PC, instruction, and next PC;
- architectural GPR write address and data;
- exception, cause, and `tval`;
- CSR write intent;
- interrupt/trap/return/fence events; and
- dynamic trace identity.

Backend-specific freeing, RAT/RRAT updates, and issue-queue release are not part
of this architectural event.

### Redirect and kill

A redirect identifies the resolving instruction and its target.  A selective
kill identifies the age boundary and invalidates younger backend state.  Full
architectural restarts remain separate events for traps, interrupts, xRET,
`FENCE.I`, and `SFENCE.VMA`.

### Internal memory request

The internal memory contract must carry transaction identity, operation,
ordering, request kind, attributes, size, physical address, data, and byte
enables.  It may be adapted to the existing bus during bring-up, but the OOO
backend and LSQ must not depend directly on AXI channel or ID geometry.  The
long-term boundary should align with the intent of
[core_complex_protocol.md](../core_complex_protocol.md).

## Initial OOO profile

The proposed starting point is moderate and deliberately parameterized:

| Structure                           | Initial value |                Intended sweep |
|-------------------------------------|--------------:|------------------------------:|
| Fetch/decode/rename width           |             3 |               fixed initially |
| Maximum issue width                 |             3 |                           2-3 |
| Maximum writeback width             |             3 |                           2-3 |
| Maximum retirement width            |             3 |               fixed initially |
| ROB entries                         |            24 |                      16/24/32 |
| Writable integer physical registers |           TBD | selected with RAT/RRAT design |
| Integer/control IQ entries          |            16 |                      12/16/24 |
| Load queue entries                  |             8 |                        4/8/12 |
| Store queue entries                 |             8 |                        4/8/12 |
| Branch checkpoints                  |             8 |                        4/8/16 |
| Initial external data transactions  |             3 |       follows memory endpoint |

The PRF/ROB balance remains deliberately unsettled until RAT, RRAT, free-list,
and recovery state are implemented together. A larger ROB is not presumed
faster: the existing 16-entry experiment was generally limited by control and
ordering rules rather than capacity; see
[issue-window-16.md](../experiments/issue-window-16.md).

The target execution cluster has four independently backpressured sources but
accepts and writes back at most three results per cycle:

| Port | Operations                                                |
|------|-----------------------------------------------------------|
| EX0  | Integer ALU, branch/jump, and initially system operations |
| EX1  | Second integer ALU                                        |
| M    | Independent multiply/divide worker                        |
| LSU  | Address generation, loads, stores, and ordered atomics    |

The first executable milestone may reuse the current EX0/EX1/MEM cluster.
Separating M from EX1 is part of the target structure so a long divide does not
remove the second integer ALU.  Adding a dedicated branch unit remains a
measurement-driven option rather than a baseline requirement.

## Parameterized integer register storage

The register storage should become a shared physical-indexed primitive.  The
architectural-to-physical mapping remains outside it.

Conceptually:

```text
openrv64_int_regfile
  NUM_REGS
  INDEX_WIDTH
  READ_PORTS
  WRITE_PORTS
  RESET_REGS
  READ_WRITE_BYPASS
  DUPLICATE_WRITE_POLICY
  implementation selection and read latency
```

The same storage contract serves each core differently:

| Core |           Registers | Read ports | Write ports | Mapping                         | Write point          |
|------|--------------------:|-----------:|------------:|---------------------------------|----------------------|
| 1P   |                  32 |          2 |           1 | `physical = architectural`      | WB/retirement        |
| 3P   | 31 writable plus p0 |          6 |           3 | `physical = architectural`      | Retirement           |
| OOO  |  Parameterized, TBD |          6 |           3 | `physical = RAT[architectural]` | Validated completion |

The current `rv64-i-gpr_3p.v` is already close to the unbanked 6R/3W storage
case.  Its ordered duplicate-write behavior remains useful for 3P retirement.
Two OOO instructions must never write the same physical destination; duplicate
OOO writeback tags are an assertion failure rather than a priority case.

The storage module owns only physical indices and values.  The following state
belongs to `backend_ooo`:

- speculative rename map (RAT);
- committed rename map (RRAT);
- free-register state;
- physical-register ready bits;
- branch checkpoints and allocation masks; and
- ROB ownership and completion validation.

Physical register zero is reserved, permanently ready, never allocated, and
hardwired to zero.  On reset, RAT and RRAT initially map architectural `xN` to
physical `pN`; registers above the architectural set begin free.

### Architectural debug access

Current tests often inspect the implementation's `u_gpr.regs[]` hierarchy.
That is not a valid architectural interface for an OOO core, whose committed
state is `PRF[RRAT[xN]]`.  The core family needs a backend-neutral committed GPR
debug read:

```text
dbg_gpr_addr
dbg_gpr_data
```

1P and 3P read the identity-mapped file.  OOO reads through RRAT, or uses an
optional retirement-updated architectural mirror for debug.  Tests should use
this interface or the commit trace rather than backend storage hierarchy.

## Rename semantics

Rename accepts a contiguous program-order prefix and processes lanes from
oldest to youngest through a temporary same-cycle RAT/free-state view.

For each non-`x0` destination:

1. Allocate a free physical register.
2. Read the previous RAT mapping as `old_phys`.
3. Record architectural `rd`, `new_phys`, and `old_phys` in the ROB.
4. Update the speculative RAT to `new_phys`.
5. Clear `ready[new_phys]`.
6. Attach physical source tags to the renamed uop.

Sources are mapped before the same instruction updates its destination.  A
younger lane in the same rename group observes mappings established by older
lanes.  This handles same-group RAW and WAW chains without a combinational ALU
chain.  WAR dependencies disappear because each consumer retains the physical
identity selected at rename.

At commit, oldest-to-youngest lanes:

1. update RRAT to `new_phys`;
2. return `old_phys` to the free-register pool; and
3. emit the architectural commit event.

A faulting instruction does not update RRAT or free its previous committed
mapping as though the faulting write occurred.

## Operand capture

Operand capture is the initial OOO policy.  It fits the existing value-carrying
execution requests and keeps PRF access out of the issue-select-to-execute
path.

```text
Decode
  |
  v
Rename: RAT lookup, physical allocation, ROB allocation
  |
  v
Renamed-uop queue
  |
  v
Operand gather/capture
  |-- ready source   -> read PRF and capture value
  |-- unready source -> retain physical tag
  |-- completion     -> validated bypass/capture
  |
  v
Issue queue: {value or tag, ready} per source
  |
  v
Oldest-ready select -> execution
```

The renamed-uop queue decouples architectural rename from PRF timing.  Rename
acceptance depends on ROB space, free physical registers, and renamed-uop queue
space; a later PRF bank conflict does not undo RAT or ROB allocation.  Operand
gather retains or retries unconsumed uops until their required reads are
accepted.

For each source:

- If the physical ready bit is set, gather reads the PRF and stores the value in
  the issue entry.
- If it is clear, gather stores the physical tag with `ready=0`.
- A validated completion broadcasts `{physical_tag, value}`.  A matching issue
  source captures the value and sets its ready bit.
- A completion matching a source being gathered in the same cycle has priority
  over stale PRF/readiness observations.
- Issue reads only the captured operands and ready bits; it does not read the
  PRF.

An IQ16 with two 64-bit captured operands contains roughly 2 KiB of operand
data before tags and control metadata.  That is acceptable as a starting point.
The larger physical risk is the completion-data broadcast and tag-match wiring
across every issue entry.

## PRF implementation and banking

The shared storage seam now exists as `rtl/core/regs/prf.v`.  It parameterizes
register count and tag width, slice count and width, logical port count, bank
count, and physical read/write slots per bank.  The current 1P and 3P GPR
files are compatibility wrappers around a one-bank instance; the vector file
is a compatibility wrapper around the same primitive with two banks and
multiple slices.  This is storage and bank arbitration, not rename state: RAT,
RRAT, free-list, readiness, and recovery logic remain OOO-backend concerns.

Physical-register count is not the only scaling pressure. A larger 6R/3W file
has difficult global wiring; additional entries lengthen it, while the port
count continues to dominate its replication, muxing, and routing.

The initial implementation may be an unbanked flop-based register file:

```text
PRF_REGS = selected after rename-state implementation
PRF_IMPL = FF_UNBANKED
PRF_READ_LATENCY = 0 or 1
```

The architectural interface must nevertheless tolerate variable read latency,
writeback backpressure, and bank conflicts.  A conceptual request/response
contract is:

```text
read request:   valid, physical_tag
read response:  valid, physical_tag, value
write request:  valid, physical_tag, value
```

Scaling beyond 64 physical registers is expected to require banking or another
structured implementation:

```text
PRF_IMPL = BANKED
PRF_BANKS = 2 or 4
PRF_BANK_READ_PORTS = implementation-defined
PRF_BANK_WRITE_PORTS = implementation-defined
```

The bank/row encoding should remain internal where practical; consumers treat
the physical tag as opaque.  Destination allocation may steer new registers
across banks to reduce expected writeback conflicts.  It cannot eliminate
source conflicts because source mappings were established by earlier dynamic
dependencies.

A bank conflict must produce explicit operand-gather retry or completion
backpressure.  It must never drop, overwrite, or silently serialize a request
outside the ready/valid contract.  Held completion ports or a completion
arbiter retain a result until its bank write is accepted.

Operand capture is a policy, not a permanent interface constraint.  If physical
design shows that capture storage and data broadcasts are worse than issue-time
reads, the OOO backend may replace the gather/IQ implementation with tag-only
IQ entries and a post-select PRF-read stage.  RAT, ROB, execution, completion,
and commit contracts remain unchanged.

### Required physical experiments

Standalone synthesis and eventual placed/routed experiments should isolate:

1. RAT/ready lookup through PRF read and operand capture.
2. Validated completion through PRF write acceptance.
3. Completion broadcast through IQ tag match and data capture.
4. Ready/age selection through execution-port issue.
5. The 31-writable-entry identity baseline versus candidate unbanked and
   banked renamed PRFs under the same port and workload assumptions.

Pre-layout combinational reports are useful problem locators, not whole-core
frequency evidence.  The choice between operand capture and issue-time PRF read
remains subject to physical design and workload measurements.

## ROB and completion validation

The OOO ROB is separate from the issue queue.  An issued instruction leaves the
IQ when its execution request is accepted; its compact ROB entry remains until
ordered retirement.

The current tagged issue-window experiment deliberately retains scheduler
entries through retirement and uses full dynamic instruction IDs as producer
tags.  It is a useful executable semantic reference, not the target physical
structure.

Each ROB entry records at least:

- valid, done, and dynamic identity;
- PC, instruction, and trace identity needed by commit/debug;
- architectural `rd`, `new_phys`, and `old_phys`;
- exception, halt, and serialization state;
- result/next-PC information needed at commit;
- CSR and control intents; and
- branch-checkpoint and LQ/SQ identity where applicable.

The ROB must not copy the complete current 402-bit issue and 457-bit completion
packets into every entry.  The current wide retirement representation already
dominates a significant portion of the mapped 3P design; see
[sky130-functional-area.md](../experiments/sky130-functional-area.md).

A completion may write the PRF, mark readiness, wake the IQ, or complete a ROB
entry only when all relevant identity checks match a live instruction.  At a
minimum this includes the live ROB token and expected physical destination.
Matching the physical tag alone is unsafe because a squashed register may have
been returned to the free pool and reallocated before a late load or divide
response arrives.

The existing monotonic 64-bit dynamic ID should initially remain available for
trace, recovery, and stale-response validation.  A bounded slot-plus-generation
identity may replace it in selected hardware paths only after the maximum
lifetime of every execution and memory response is explicitly bounded.

## Branch recovery

Each speculative conditional or predicted indirect branch owns a checkpoint
containing:

- RAT state after the branch's own rename;
- an allocation mask, initially empty, of physical registers allocated by
  younger instructions;
- predictor/RAS recovery identity;
- dynamic instruction identity and ROB position; and
- any additional frontend state that cannot be reconstructed.

Every later physical allocation sets its bit in the allocation masks of all
older active checkpoints.  On misprediction:

1. restore the resolving branch's RAT snapshot;
2. return the checkpoint's younger-allocation mask to the free pool;
3. retain the branch and every older ROB entry;
4. invalidate younger renamed-uop, IQ, ROB, LQ, SQ, and checkpoint entries; and
5. redirect the frontend while preserving monotonically increasing dynamic
   identities.

Full architectural recovery restores RAT from RRAT and rebuilds free state from
the committed mappings.  This path is used for traps, interrupts, and other
full restarts.

The initial scheduler may retain the current conservative rule that conditional
branches resolve in program order while non-control work may pass an
operand-blocked branch.  General out-of-order branch resolution is a later,
measured feature.

## Retirement and precise state

Architectural state changes only through the maximal contiguous completed ROB
prefix.  Up to three ordinary instructions may retire per cycle.  An exception,
halt, or serializing instruction terminates the group as required.

- Integer completion writes the PRF but not architectural mapping state.
- RRAT and free-register state change only at successful retirement.
- CSR writes and trap/return/fence effects occur only through commit.
- Interrupts remain retirement-boundary events.
- CSR, system, xRET, fence, and initially atomic operations issue only when
  authorized at the ROB head.
- A faulting instruction cannot update RRAT or commit its destination.

OOO mode defaults to precise retirement through store translation, protection,
and L1D admission. The current 3P LSU already provides the intended shared
substrate: early tagged translation, physical-address disambiguation, fully
covered same-word forwarding, and ordered store admission. The LSQ quarantines
selectively killed accepted tags until their responses drain; full-flush
cancellation is also tracked at the memory endpoint. Physical writeback below
L1D remains posted and needs a separate machine-check policy for unrecoverable
downstream failures.

## Memory progression

`exec_pipe_mem` remains a supported legacy memory implementation. The active
3P backend instead instantiates `exec_lsu`, which contains the separate
parameterized `lsq`. Neither module understands physical register renaming;
instruction identity and backend metadata remain opaque.

The first OOO milestone may use the same LSQ with conservative admission from
the renamed backend. This permits rename and integer scheduling to be
validated before adding memory-dependence prediction or replay.

The target OOO LSQ allocates load and store entries at rename and follows a
conservative initial policy:

- address generation may occur out of order;
- a load waits behind any older store with an unknown address;
- once older addresses are known, a proven non-overlapping load may issue;
- the youngest fully covering older store may forward to a load;
- partial overlaps wait rather than merge;
- MMIO and other non-idempotent loads remain non-speculative;
- stores become externally visible only when authorized at the ROB head and
  retire only after a successful precise response;
- fences drain the required older memory state; and
- RV64A operations initially drain and serialize the LSQ.

The implemented substrate compares translated physical addresses, including
the Sv39 tagged translation path. Effective-address aperture checks are not
used as alias proofs. The current static cacheable aperture is only a temporary
attribute mechanism; explicit PMA/MMIO classification is still required.

The shared L1 remains blocking by default, but the current CCX L1D selects its
detached-miss interface and implements a parameterized demand MSHR array
(default three). Different lines issue with independent transaction IDs,
same-line requests merge as tagged waiters, and responses may return out of
order. This is enough demand-side cache concurrency for early OOO integration;
it is not an LSQ, memory-dependence predictor, replay machine, or precise
speculative-memory recovery mechanism.

## Parameterization discipline

OOO parameters should describe bounded structures and explicitly selected
features at the `backend_ooo` composition boundary.  They should not alter the
meaning of shared packets or scatter OOO conditionals through 1P/3P modules.

Expected structural parameters include:

- rename, issue, writeback, and retirement widths;
- ROB, renamed-uop queue, IQ, LQ, SQ, and checkpoint depths;
- physical-register count and tag width;
- PRF implementation, bank count, and read latency;
- number and capability of execution ports; and
- supported completion/memory transaction counts.

Optional mechanisms such as selective branch speculation, a real LSQ,
additional execution units, or a banked PRF should instantiate or bypass
well-defined submodules.  Invalid parameter combinations must fail elaboration
with direct assertions rather than degrade silently.

## Verification requirements

The common contracts and every parameterized backend require focused tests.
OOO assertions and directed tests must cover at least:

- x0 always maps to p0, is ready, and remains zero;
- same-group RAW and WAW rename chains;
- unique allocation of physical destinations;
- `old_phys` is freed exactly once and only after retirement;
- RAT/RRAT correctness across ordinary commit, exception, and full recovery;
- completion writes only after live ROB/destination validation;
- stale M/load completion after physical-register reuse;
- oldest-ready issue and execution-port capability selection;
- same-cycle enqueue and completion capture;
- PRF read-bank conflict retry and write-bank backpressure;
- selective recovery retains all and only the correct older state;
- nested branch checkpoints and allocation-mask recovery;
- contiguous in-order retirement and precise exception boundaries;
- loads never pass an unknown-address older store;
- youngest fully covering store-to-load forwarding;
- stores, MMIO, atomics, fences, and CSR effects do not escape speculatively;
  and
- every supported 1P and 3P regression remains unchanged.

Architectural differential checking should use the backend-neutral commit
interface described by [cycle_trace.md](../cycle_trace.md), not internal stage
or register-file hierarchy.  Performance traces should additionally expose RAT
allocation pressure, PRF free count, renamed-uop occupancy, IQ ready/eligible
state, ROB occupancy, recovery, completion arbitration, and LSQ ordering.

Physical checks are required after each major structure is added.  In
particular, logical correctness and RTL IPC do not establish the viability of
the PRF ports, completion broadcasts, issue selection, PMP, divider, or memory
paths.

## Implementation sequence

1. **Common contracts**
   - Define decoded-uop, execution request/completion, commit, redirect/kill,
     and internal memory packets.
   - Keep 1P and 3P behavior unchanged through adapters.

2. **Parameterized register storage and debug state**
   - Add the shared physical-indexed integer register storage.
   - Retain thin 1P and 3P wrappers with their current public behavior.
   - Add backend-neutral committed GPR debug reads and migrate hierarchical
     tests.

3. **Rename and compact ROB with ordered issue**
   - Add RAT, RRAT, free state, physical readiness, renamed-uop queue, and the
     initial ROB.
   - Continue to issue in order through the existing execution/memory cluster.
   - Disable branch speculation and posted stores.

4. **Operand gather and integer OOO issue**
   - Add the selected unbanked PRF, operand-capture stage, IQ16, physical-tag
     wakeup, and oldest-ready execution-port selection.
   - Keep memory program ordered and control operations conservative.

5. **Selective branch recovery**
   - Add eight RAT/allocation checkpoints and selective IQ/ROB recovery.
   - Reuse predictor identities and existing frontend redirect machinery.

6. **LSQ and translated memory**
   - Scale the implemented parameterized LSQ substrate to the selected OOO
     LQ/SQ depths and connect OOO allocation and selective recovery.
   - Retain its tagged translation, physical disambiguation, forwarding, and
     precise store-admission contract.
   - Add explicit PMA/MMIO classification and measure whether another
     translation/L1D launch port is justified.

7. **Execution and physical scaling**
   - Split M from EX1.
   - Compare operand capture with issue-time PRF reads if physical results
     require it.
   - Implement and measure banking where the selected PRF depth requires it.
   - Sweep ROB/IQ/LSQ/PRF sizes and add cache concurrency based on measured
     bottlenecks.

## Settled design decisions

- 1P, 3P, and OOO remain separately supported core configurations.
- OOO is parameterized and may gain optional features without redefining the
  simpler cores.
- Configuration-specific dispatch and pipeline modules remain separate.
- `dispatch_3p` and the legacy `exec_pipe_mem` remain supported
  implementations; the active 3P composition uses the separate `exec_lsu` and
  `lsq`.
- Register storage is physical-indexed and parameterized; RAT/RRAT indirection
  is external to it.
- 1P and 3P use identity physical mapping with no unnecessary RAT hardware.
- OOO uses operand capture initially.
- The PRF/gather contract permits registered or banked reads and explicit
  conflict retry.
- Scaling beyond 64 physical registers is expected to require banking or an
  equivalent structured implementation, subject to physical evidence.
- Architectural register state, CSR effects, traps, and interrupts remain
  precisely ordered at retirement in the OOO baseline.

## Remaining measured choices

- Final ROB/IQ/LSQ and physical-register depths.
- Unbanked versus banked PRF crossover point.
- Number of banks and per-bank port geometry.
- Operand capture versus post-select PRF read after placed/routed comparison.
- Whether branch or M execution needs more independent ports.
- Precise response-gated store retirement versus any explicitly bounded posted
  store/error contract for OOO.
- The point at which a nonblocking L1 becomes necessary for useful OOO memory
  concurrency.
