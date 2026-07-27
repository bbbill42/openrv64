# Private vector unit contract

This block is an OpenRV64-specific coprocessor experiment. It borrows the RVV
`vtype` layout and integer LMUL grouping, but it is not an RVV implementation.
There is no `vl`, `vstart`, mask execution, vector CSR state, standard vector
instruction decode, or element-precise trap restart.

## Blocks

- `rtl/core/regs/rv64-i-vec.v` is a private 32 by `VLEN` register file split
  into even- and odd-register banks. Every physical port is 64 bits: there are
  four logical reads, limited to two reads per parity bank, and two logical
  writes, limited to one write per parity bank. Bank conflicts return ready
  low. There is no scalar GPR path.
- `rtl/core/exec/vec/rv64-vec.v` implements group-wide AND, OR, XOR and NOT,
  floating lane ADD and MUL, and two private accumulators with load, MAC, and
  export operations. It consumes and produces one 64-bit slice per cycle.
  LMUL changes the number of slices, never the port width.
- `rtl/core/exec/vec/rv64-vec-lsu.v` implements aligned register-group loads
  and stores over an exclusive tagged port. Register-file transfers remain
  `DATAPATH_WIDTH` wide, while `MEM_DATA_WIDTH` independently controls the
  cache-side beat. The current integration packs four 64-bit RF slices into
  one 256-bit request and unpacks a 256-bit response the same way. A
  `READ_ONLY` parameter makes a secondary instance reject stores.
- `rtl/core/exec/vec/rv64-vec-cache.v` is a shared, parameterized vector SRAM
  cache. The default is 256 KiB, four-way, 64-byte lines, eight miss entries,
  and two 256-bit VLSU clients. Supported capacities are power-of-two sizes
  from 256 KiB through 2 MiB. Its data array has no reset and is shaped for
  SRAM inference; valid/tag/replacement metadata controls access.
- `rtl/core/exec/vec/rv64-vec-cache-bus.v` connects that cache to
  `rtl/bus/genbus_interface.v`, the same generic width/protocol boundary used
  below the core-complex L2. `CACHE_BUS_DATA_WIDTH` selects the cache producer
  width independently of external `BUS_DATA_WIDTH` and defaults to one complete
  cache line (512 bits at the default geometry). Both backends accept
  power-of-two widths from 32 through 512 bits. WISHBONE widths above 64 bits
  use the explicitly nonstandard OpenRV64 wide-data extension.
  `GENBUS_READ_BUFFER_DEPTH` and `GENBUS_WRITE_BUFFER_DEPTH` independently size
  the shared boundary queues; the read depth defaults to the cache MSHR count.

The LSU dispatch carries a scalar base-register index rather than a resolved
address. After accepting the command, the LSU obtains that pointer through a
read-only ready/valid GPR sideband and retries the read internally on a port
conflict. There is deliberately no GPR write sideband yet; compare reduction
or lane extraction can add one when their semantics are defined.

The operation selectors in `rtl/core/exec/vec/defs.v` are private interface
values, not instruction encodings.

## Instruction-stream test top

`rtl/openrv64_vec_test_top.sv` is a test-only replacement for the production
top. It fetches one instruction from a 64-bit instruction-beat port, reuses the
production RV64I decoder plus one integer ALU and branch unit, and instantiates
the private vector register file, arithmetic pipe, and two LSUs. Scalar
instructions and the primary LSU remain blocking. Arithmetic dispatch is
nonblocking into an eight-context queue by default, and the frontend may
continue issuing scalar, LSU, and independent arithmetic instructions. A load
is sent preferentially to an idle read-only LSU and may remain in flight while
the front end issues following instructions. A second load falls back to the
primary LSU. Both LSUs feed the shared vector cache through independent
256-bit tagged client ports; the cache retains each originating tag while it
performs a line fill. The test top leaves the final AXI/WISHBONE pin wrapper
out so its simple memory model can inject explicit retry responses. Scalar
loads/stores, CSRs, traps, interrupts, prediction, and normal production-core
integration are intentionally absent.

The custom instruction definitions live in
`rtl/core/exec/vec/instr-defs.v`. They use RISC-V custom opcode space solely so
short test programs can exercise the blocks; they are not RVV encodings:

| Opcode             | `funct3` | Operation                     | Operands                                                               |
|--------------------|---------:|-------------------------------|------------------------------------------------------------------------|
| custom-0 `0001011` |      000 | set private `vtype`           | `rs1` names the scalar GPR containing the complete command; `rd=rs2=0` |
| custom-0 `0001011` |  001-110 | AND, OR, XOR, NOT, FADD, FMUL | `rd=vd`, `rs1=vs1`, `rs2=vs2`                                          |
| custom-0 `0001011` |      111 | `VSYNC`                       | `rs1` and `rs2` name two vector registers to wait for; `rd=0`          |
| custom-1 `0101011` |      000 | vector load                   | `rd=vd`, `rs1` names the pointer GPR, `rs2=0`                          |
| custom-1 `0101011` |      001 | vector store                  | `rs2=vs3`, `rs1` names the pointer GPR, `rd=0`                         |
| custom-2 `1011011` |      000 | `VLDA`                        | copy `vs1` into accumulator `a`; `rd=rs2=0`                            |
| custom-2 `1011011` |      001 | `VSTA`                        | copy accumulator `a` to `vd`; `rs1=rs2=0`                              |
| custom-2 `1011011` |      010 | `VMAC`                        | `acc[a] = acc[a] + vs1 * vs2`; `rd=0`                                  |
| custom-3 `1111011` |      000 | `VPRFM` aged                  | prefetch `imm4=bits[23:20]` lines from scalar `rs1`; `rd=0`            |
| custom-3 `1111011` |      001 | `VPRFM` streaming             | same descriptor, with discard-next-after-consumption insertion         |

For custom-2, instruction bit 25 selects accumulator `a` (`0` or `1`); bits
31:26 remain zero.

For custom-3, bits 31:24 and `rd` must be zero. The four-bit line count is
literal, so zero is a no-op and the largest one-instruction descriptor is 15
lines. The base address is aligned down to a cache-line boundary. The command
retires when its descriptor is accepted; fills continue independently.

The LSU requests its pointer through a ready/valid GPR read sideband after
dispatch and owns any replay caused by that read stalling. Neither vector unit
has a GPR write path. The scalar ALU can still update the harness's ordinary
GPR file so a program can construct pointers and loop counters.

There is no implicit vector RAW, WAR, or WAW issue scoreboard. Software must
avoid hazards. Every accepted writer contributes its complete LMUL destination
group to an outstanding-write set. `VSYNC vA,vB` blocks until both named
registers are absent from that set, meaning every arithmetic, primary-load,
and background-load writer covering either register has completed its last
register-file write. A one-register wait encodes that register in both fields.
Multiple writes covering the same register remain visible until all owners
retire. Ordinary vector instructions do not inspect this set; omitting a
required `VSYNC` can intentionally read stale data.

`make sim-vec-test-top` runs a ROM-style instruction stream that performs a
vector load/XOR/store sequence, FP32 load/arithmetic/store sequences, a
`VLDA`/`VMAC`/`VSTA` accumulator sequence, an internally retried memory beat,
and a scalar countdown branch loop before halting on `EBREAK`. `make sim-vec`
includes this test along with the three block-level vector tests.

`sw/vector/matmul.S` is an assembled FP32 matrix-multiply workload for this
top. It uses the existing scalar RV64I ALU/branch path for PC-relative pointer
setup, 32-byte pointer increments, nested loop counts, call, and return; no new
scalar opcode was required. At VLEN=256 it processes eight output columns per
vector and accepts any positive number of eight-column blocks. Since the ISA
has no scalar broadcast, A is explicitly prepacked with eight copies of each
logical scalar and B is stored in `[N/8][K][8]` block-major order. This is a
software layout constraint, not a hidden vector-to-GPR or GPR-to-lane path.
The column-block loop is unrolled by two. One loaded A vector feeds the two
private accumulator contexts for adjacent output vectors; odd vector-column
counts use an acc0-only tail. Both VMAC recurrences overlap without
reassociating either reduction. `make sim-vec-matmul` links the program and
verifies a 2x3 by 3x16 result in the RTL harness, including an injected LSU
retry.

`sw/matmul_bf16.S` applies the same blocked algorithm to sixteen BF16 lanes per
256-bit vector. Its ABI uses `a5=N/16`, packed `A[M][K][16]`, block-major
`B[N/16][K][16]`, and row-major `C[M][N]`. It uses the two private VMAC
contexts, retaining FP32 product/add precision until each BF16 accumulator
update is rounded. `make sim-vec-matmul-bf16` verifies a
larger 4x8 by 8x32 assembled workload and all 128 result elements.

## `vtype` command

Arithmetic and LSU dispatch carry a 64-bit `vtype`-shaped command:

| Bits  | Field    | Current behavior                                   |
|-------|----------|----------------------------------------------------|
| 2:0   | `vlmul`  | RVV integer encodings for m1, m2, m4, and m8       |
| 5:3   | `vsew`   | RVV SEW encoding; checked against floating format  |
| 6     | `vta`    | Carried in the command but inert without `vl`      |
| 7     | `vma`    | Carried in the command but inert without masks     |
| 10:8  | `xfmt`   | Private FP32, BF16, FP8 E4M3, or FP4 E2M1 selector |
| 62:11 | reserved | Must be zero                                       |
| 63    | `vill`   | Rejects the command when set                       |

Standard RVV `vtype` cannot distinguish BF16 from FP16 and cannot encode FP8
or FP4. Bits 10:8 are therefore an explicit private extension, not a claim of
standard compatibility. Packed FP4 uses `vsew=8` because there is no standard
SEW=4 encoding.

Fractional LMUL is rejected. Group bases must be naturally aligned: m2 starts
on an even register, m4 on a multiple of four, and m8 on a multiple of eight.
The current operations are same-width, so source and destination groups have
the same LMUL. A future widening operation will need an independently derived
destination EMUL.

Arithmetic dispatch has `vs1`, `vs2`, and `vd` group indices. MAC avoids a
third architectural source by using two private accumulator groups selected by
instruction bit 25. `VLDA a,vs1` initializes one, every `VMAC a,vs1,vs2`
implicitly reads and replaces it, and `VSTA a,vd` exports it to the vector
register file. Each accumulator retains its own native format and LMUL metadata;
`VMAC` and `VSTA` are rejected if the current command does not match the
selected accumulator. A later `VLDA` replaces that context's data and metadata.

Only one command per selected accumulator may be live because successive
VMACs on that context form a true recurrence. Commands selecting the other
accumulator, plus independent ADD, MUL, and bit operations, may occupy younger
tagged contexts. Accumulator updates occur one slice per cycle only at matching retirement, exactly like architectural vector
writeback. A tagged kill therefore cannot expose a speculative or partial
update. `VLDA` and `VMAC` do not enter the architectural vector write-owner
set; `VSTA` does, so software includes `vd` in a `VSYNC` before consuming its
export.

The arithmetic engine stores speculative results in parameterized tagged
contexts, each an array of 64-bit slices. The shared feed engine sends all
slices of the oldest unfed command and then advances immediately to the next
command; an m1 256-bit command therefore has a four-cycle initiation interval
when the RF is ready, independent of the default eleven-stage lane latency.
Lane tags contain both context and slice indices, so returning commands cannot
alias their result buffers. Completion and matching retirement remain in
dispatch order. A commit drains one slice per cycle into the register file and
asserts retirement ready with the final accepted write. The unit never
constructs a `MAX_LMUL*VLEN` register-file transfer.

## Floating formats

The initial arithmetic formats are:

| `xfmt` | Format               | Required `vsew` | Lanes per 64-bit slice |
|-------:|----------------------|-----------------|-----------------------:|
|      0 | FP32 / IEEE binary32 | 32              |                      2 |
|      1 | BF16                 | 16              |                      4 |
|      2 | FP8 E4M3FN           | 8               |                      8 |
|      3 | FP4 E2M1             | 8, packed       |                     16 |

Arithmetic uses round-to-nearest, ties-to-even. FP4 and FP8 finite overflow
saturates to the largest finite magnitude. BF16/FP32 use infinities and a
canonical quiet NaN. There is no `fflags` output. FP64 is deliberately absent.

FP4, FP8, and BF16 operands expand exactly into the internal FP32 lanes. For
VMAC, their product and addition remain FP32 and round once when stored back
to the narrow accumulator, giving fused behavior at the selected narrow
format. FP32 VMAC uses the existing FP32 multiplier result as the add input,
so it rounds after multiply and again after add. It is intentionally a MAC,
not an IEEE-754 single-rounding binary32 FMA.

The ordinary FP lane pipeline accepts one 64-bit vector slice every cycle and
has a configurable latency, defaulting to eleven stages. The separate MAC
lane bank also accepts one slice per cycle and defaults to 22 stages, with a
registered boundary between its multiply and add halves.
Context-plus-slice tags travel with every token, allowing slices from younger
commands to follow an older command before its first result returns. If both
complete input slices are positive zero, an ordinary ADD/MUL result is
deposited directly in the tagged context without entering the lane pipelines.
Other
exact-zero add/multiply cases and multiply-by-one use shorter combinational
paths inside a lane but retain its fixed token latency. More general per-lane
early completion would require merging early and pipelined lanes back into one
tagged result slice.

## Dispatch, replay, and retirement

Dispatch transfers a command once. The arithmetic unit owns it in one of
`INFLIGHT_DEPTH` contexts after the ready/valid handshake; the two LSU
instances retain their private command slots. If an integration holds
`operands_ready_i` low, the oldest unfed arithmetic command remains queued and
`replay_o` is asserted. This input is not driven by a vector-register
scoreboard in the test top. The scalar core observes replay but does not resend
the operation.

Completed load and arithmetic data remain in the vector unit. A matching
retirement commit causes a sequence of private 64-bit vector-register writes;
a tagged retirement kill discards a pending, executing, or completed
speculative command. Thus the main retirement queue carries only the tag and
status, never vector result data.

Stores additionally require `ordered_valid_i` with the matching tag before any
memory request is emitted. This prevents a speculative store from escaping the
unit.

## Vector cache and external memory

The cache consumes translated physical addresses. Address translation remains
above the VLSU/cache boundary and is not implemented in this test top. The
cache bypasses scalar L1/L2 lookup completely; it is not another level in the
ordinary cache hierarchy.

Demand reads allocate and fetch a complete tagged line. The requesting VLSU
holds its beat until the fill completes, while other clients and prefetch
entries may remain outstanding. A request to a line already being filled waits
and then hits rather than allocating a duplicate fill. Stores do not allocate:
each 256-bit VLSU beat bypasses to the external bus and invalidates a matching
vector-cache line. This is only local vector-cache invalidation. L1/L2 snoop or
invalidation signals are still undefined and must be added before coherent
shared scalar/vector buffers are claimed.

Replacement first chooses an invalid way, then a consumed streaming way, then
the oldest ordinary way. An aged `VPRFM` line participates in normal aging.
A streaming line also ages normally until a demand reads its final 256-bit
word. That read marks it discard-next; it remains valid and readable until the
next replacement in the same set.

The VLSU/cache link remains a tagged request/response stream. The cache retains
the client and tag in its miss entry and owns cache-level replay. The
bus-facing wrapper has an ordered tag FIFO matching genbus admission capacity,
so multiple miss requests can remain in flight without losing the cache MSHR
identity. Genbus is shared with CCX/L2, independently parameterizes producer
and downstream widths, and selects AXI or WISHBONE. Separate read and write
buffers permit multiple fixed-ID AXI transactions to be outstanding while
restoring the untagged response stream to acceptance order. AXI IDs identify
the vector master, not individual cache miss entries. WISHBONE uses the same
admission buffering but drains Classic transfers in global order. WISHBONE
`RTY` is retried inside its backend. AXI `SLVERR`/`DECERR` are errors, never
retries.

The neutral bus request also carries an eight-bit, AXI-LEN-style read burst
count. Zero denotes only the current request; `N` declares the current request
plus the next `N` same-size, same-attribute, contiguous requests. Each follower
carries zero. Genbus combines the group into one AXI INCR transaction while
returning one response and tag per original cache request. It may return an
early member after that member's beats arrive, without waiting for the final
group `RLAST`. Cross-request write coalescing is not implemented.

VPRFM allocation is held long enough to expose a contiguous ready MSHR batch.
Demand/store MSHRs remain higher priority; a prefetch batch starts at its
lowest ready address so an unrelated round-robin pointer cannot split it at
the MSHR ring boundary. A line-wide cache producer can therefore turn a
four-line VPRFM into one four-beat transaction on 512-bit AXI. A longer
descriptor is emitted in batches bounded by the MSHR count, genbus read-buffer
depth, and AXI's 256-beat limit. Genbus also splits at 4 KiB boundaries. CCX
does not use this hint and drives its genbus burst count to zero.

The bus wrapper supports 32, 64, 128, 256, and 512-bit buses. With the default
512-bit cache-side beat, one 64-byte fill becomes one 16-, 8-, 4-, 2-, or
1-beat AXI burst respectively. WISHBONE uses the same width range, although
128 bits and above are an OpenRV64 experiment rather than B.4-compliant. For a
downstream bus wider than the producer transfer, the request is emitted as a
narrow, correctly lane-positioned transfer; for a narrower bus one neutral
request becomes consecutive full-width beats in one AXI burst.

The maximum m8 register group must be an integer multiple of
`MEM_DATA_WIDTH`. The active cache-side beat count is
`VLEN * LMUL / MEM_DATA_WIDTH`. With the current 64-bit RF slice and 256-bit
VLSU/cache port, m1 is one cache request but still four RF cycles; m8 is eight
cache requests and 32 RF cycles. `CACHE_BUS_DATA_WIDTH` and the external bus
width remain independent parameters below that link.

There is intentionally no GPR load/store forwarding or compare-to-GPR
sideband. Those crossings can later be expressed through the proposed magic
memory aperture without changing the private register file.
