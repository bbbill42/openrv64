# RV64F/RV64D ISA and standalone execution pipeline

This document defines the floating-point ISA contract added to OpenRV64, the
architectural floating-point register file, and the deliberately unintegrated
first execution pipeline.  The encoding headers cover the ratified F and D
instruction spaces.  The register file and execution block are synthesizable,
but the core does **not** advertise F or D yet.

## Architectural contract

The intended architectural configuration is RV64 with `FLEN=64`:

- F provides IEEE-754 binary32 arithmetic and 32 floating-point registers.
- D widens those registers to 64 bits and adds IEEE-754 binary64 arithmetic.
- A binary32 value held in a 64-bit floating-point register is NaN-boxed: bits
  63:32 are all ones.  A computational F instruction treats a non-boxed input
  as canonical NaN.
- `fcsr` contains the five accrued exception flags in `fflags` and the dynamic
  rounding mode in `frm`.  Their CSR addresses are `0x003`, `0x001`, and
  `0x002`, respectively.
- The rounding modes are RNE, RTZ, RDN, RUP, and RMM.  An instruction `rm` of
  DYN selects `frm`; reserved `rm` or `frm` values must be rejected.
- The exception flags are invalid operation (`NV`), divide by zero (`DZ`),
  overflow (`OF`), underflow (`UF`), and inexact (`NX`).

The Verilog encoding contract is in `rtl/core/isa/rv64-f.v` and
`rtl/core/isa/rv64-d.v`.

The architectural FPR is `openrv64_rv64fd_fpr` in
`rtl/core/regs/rv64-fd-fpr.v`.  It is a 32-entry identity-mapped instance of
the shared parameterized register file, configured for three combinational
reads and one ordered write.  There is no hardwired-zero FPR: `f0` is ordinary
writable state.  The file stores values bit-for-bit; binary32 producers remain
responsible for NaN boxing before writeback.

### Major encodings

| Class               | Opcode                 | Additional selector                     |
|---------------------|------------------------|-----------------------------------------|
| `FLW`, `FLD`        | `0000111` (`LOAD-FP`)  | `funct3=010`, `011`                     |
| `FSW`, `FSD`        | `0100111` (`STORE-FP`) | `funct3=010`, `011`                     |
| `FMADD.S/D`         | `1000011`              | `fmt=00`, `01`                          |
| `FMSUB.S/D`         | `1000111`              | `fmt=00`, `01`                          |
| `FNMSUB.S/D`        | `1001011`              | `fmt=00`, `01`                          |
| `FNMADD.S/D`        | `1001111`              | `fmt=00`, `01`                          |
| Other FP operations | `1010011` (`OP-FP`)    | `funct5`, `fmt`, `rs2`, and `funct3/rm` |

For the R4 fused operations, bits 31:27 are `rs3`, bits 26:25 are `fmt`,
and bits 14:12 are `rm`.  For OP-FP, bits 31:27 are `funct5` and bits
26:25 are `fmt`.

| OP-FP family                | `funct5` | Secondary selection       |
|-----------------------------|----------|---------------------------|
| `FADD`                      | `00000`  | `fmt`                     |
| `FSUB`                      | `00001`  | `fmt`                     |
| `FMUL`                      | `00010`  | `fmt`                     |
| `FDIV`                      | `00011`  | `fmt`                     |
| `FSGNJ`, `FSGNJN`, `FSGNJX` | `00100`  | `funct3=000/001/010`      |
| `FMIN`, `FMAX`              | `00101`  | `funct3=000/001`          |
| FP format conversion        | `01000`  | source format in `rs2`    |
| `FSQRT`                     | `01011`  | `rs2=0`                   |
| `FLE`, `FLT`, `FEQ`         | `10100`  | `funct3=000/001/010`      |
| FP-to-integer conversion    | `11000`  | W/WU/L/LU in `rs2`        |
| Integer-to-FP conversion    | `11010`  | W/WU/L/LU in `rs2`        |
| `FMV.X.W/D`, `FCLASS.S/D`   | `11100`  | `funct3=000/001`, `rs2=0` |
| `FMV.W/D.X`                 | `11110`  | `funct3=000`, `rs2=0`     |

This covers the F/D arithmetic, fused arithmetic, comparisons, classification,
sign injection, minimum/maximum, integer conversions, S/D conversions, raw
moves, and floating load/store encodings needed by RV64.  Integer conversion
selectors include RV64's signed and unsigned 64-bit `L`/`LU` forms.

## Standalone execution pipeline

`openrv64_exec_fpu_rv64fd` in `rtl/core/exec/fpu/rv64-fd.v` is an elastic
variable-latency pipeline:

1. The input stage classifies operands, handles architectural special cases,
   and initializes the arithmetic state.
2. A one-entry fast lane accepts non-iterative operations and arithmetic
   special cases that were completely resolved during classification.
3. Fourteen iteration stages advance four significand bits per stage for
   multiply, fused multiply-add, divide, and square root.  Multiply consumes a
   radix-16 digit; divide and square root unroll four radix-2 steps in each
   stage.
4. Binary32 multiply exits after six iteration stages and binary32 square root
   after seven.  Fused operations, divide, and binary64 multiply/square root
   continue to the final stage.
5. A rotating arbiter selects among the fast lane, the two binary32 taps, and
   the final iterative stage.

Without contention, the observable timing is:

| Result class          |  `result_valid_o` appears | Earliest output handshake |
|-----------------------|--------------------------:|--------------------------:|
| Fast lane             |          after acceptance |                   1 cycle |
| `FMUL.S`              |  after 6 iteration cycles |                  7 cycles |
| `FSQRT.S`             |  after 7 iteration cycles |                  8 cycles |
| Final iterative stage | after 14 iteration cycles |                 15 cycles |

The distinction exists because ready/valid transfers occur on rising edges:
the consumer observes a newly asserted `result_valid_o` during the cycle and
accepts it at the following edge.

Tagged results may complete out of issue order.  This avoids placing a second
reorder structure in the FPU; architectural retirement must use the tag and
remain ordered.  The output arbiter is fair and locks its selected source while
`result_ready_i` is low, so the visible tag, result, and flags cannot change
under backpressure.

Here, an output stall means exactly
`result_valid_o && !result_ready_i`.  It does not intrinsically mean retirement
is stalled.  A blocked result holds its source and backpressure propagates
through that lane as its available slots fill.  The input `ready_o` is selected
from the lane required by the presented request, so a blocked fast lane does
not prevent an iterative request from entering if the iterative pipeline has
space, and vice versa.  `flush_i` discards every in-flight request in both
lanes.

This is intentionally a deep, low-combinational-complexity-per-stage
implementation, not a short combinational divide/square-root path.  The
throughput is not free: arithmetic state and iteration logic are replicated
across all fourteen stages rather than shared by one blocking engine.

The interface reports floating and integer results separately, the five
per-instruction exception flags, and an explicit `unsupported_o` bit.  The tag
is opaque and is intended to become a retirement or producer tag during later
integration.  `type_i` carries the instruction `rs2` selector for conversions:
W/WU/L/LU for integer conversions and S/D for format conversions.

### Implemented now

- `FADD.S/D`, `FSUB.S/D`, `FMUL.S/D`, `FDIV.S/D`, and `FSQRT.S/D`.
- `FMADD.S/D`, `FMSUB.S/D`, `FNMSUB.S/D`, and `FNMADD.S/D`, with one final
  rounding rather than a rounded multiply followed by an add.
- All five rounding modes, including dynamic selection through `frm`.
- Normal, subnormal, zero, infinity, quiet-NaN, and signaling-NaN handling.
- Canonical NaN production and binary32 NaN boxing.
- `FSGNJ*`, `FMIN/FMAX`, `FEQ/FLT/FLE`, and `FCLASS` for S and D.
- `FMV.X.W`, `FMV.W.X`, `FMV.X.D`, and `FMV.D.X` datapath behavior.
- `FCVT.W/WU/L/LU.S/D`, `FCVT.S/D.W/WU/L/LU`, `FCVT.S.D`, and `FCVT.D.S`,
  including saturation, accrued per-instruction flags, and RV64 sign
  extension for 32-bit integer conversion results.
- Tagged out-of-order completion, full valid/ready backpressure, stable
  arbitration under output stalls, and flush.

### Rejected requests

`unsupported_o` is reserved for an invalid operation enum, a format other than
S or D, a reserved static or dynamic rounding mode, or an invalid conversion
type selector.  Architecturally defined F/D computational operations do not
return an unsupported placeholder.

## Deliberately not integrated

The following core work is still required before F/D can be advertised:

- decode and illegal-instruction qualification;
- connection of the implemented architectural FPR to decode, dispatch, LSU,
  execution, and retirement;
- `mstatus.FS`, `fcsr`, accrued flag updates, and state-dirty tracking;
- floating load/store routing, alignment, and fault behavior through the LSU;
- dispatch hazards, producer ownership, forwarding, and writeback selection;
- precise retirement and exception behavior;
- context/debug exposure and architectural compliance tests;
- an instruction decoder that maps encoded operation and conversion selectors
  onto the standalone unit interface.

The standalone block is intentionally absent from `CORE_SRCS` and `EXEC_SRCS`.
Its focused checks are `make sim-isa-fp`, `make sim-rv64-fd-fpr`, and
`make sim-exec-fpu-rv64-fd`; the aggregate regression runs all three without
wiring the FPU or FPR into either core.
