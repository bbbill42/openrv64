# Core control and management unit

`openrv64_cmu` is the core-local CSR sub-block for architectural performance
monitoring. It implements the RISC-V Zicntr/Zihpm machine state rather than an
OpenRV64-only counter CSR bank:

- `mcycle`, `minstret`
- `mhpmcounter3` through `mhpmcounter31`
- `mhpmevent3` through `mhpmevent31`
- `mcountinhibit`, `mcounteren`, and `scounteren`
- read-only `cycle`, `time`, `instret`, and `hpmcounter3` through
  `hpmcounter31` aliases

The default core implements eight HPM counter/event pairs (`3` through `10`).
`HPM_COUNTERS` is parameterized from 0 through the architectural maximum of
29. Standard CSR addresses for unimplemented pairs remain valid M-mode CSRs
that read zero and ignore writes, as permitted by the privileged
specification.

The general CSR block retains trap, privilege, and PMP state. It delegates the
performance CSR ranges to the CMU. This keeps the CMU small and prevents it
from becoming a second, inconsistent privilege-control block.

## Event encoding

RISC-V standardizes `mhpmeventN` as WARL event selectors but leaves the raw
hardware event encoding platform-defined. OpenRV64 uses bits 37:0 as a mask.
Each selected pulse adds one, so a counter can count multiple occurrences in
one cycle. For example, selecting event bits 4, 5, and 6 counts retired
instructions on a three-wide core rather than merely cycles with retirement.
Unsupported upper selector bits read as zero.

|   Bit | Event                                        |
|------:|:---------------------------------------------|
|     0 | Cycle                                        |
|   1-3 | Issue lanes 0-2                              |
|   4-6 | Retirement lanes 0-2                         |
|     7 | Zero-issue cycle                             |
|     8 | Zero-retirement cycle                        |
|     9 | Frontend empty                               |
|    10 | Dispatch empty                               |
|    11 | RAW stall                                    |
|    12 | Barrier stall                                |
|    13 | Pipe-busy stall                              |
|    14 | Redirect                                     |
|    15 | Redirect recovery                            |
|    16 | Direction misprediction                      |
|    17 | Target misprediction                         |
|    18 | Fetch request                                |
|    19 | Fetch response                               |
|    20 | Fetch cancellation                           |
|    21 | LSU request                                  |
|    22 | LSU response                                 |
|    23 | LSU request wait                             |
|    24 | LSU outstanding cycle                        |
|    25 | L1I demand hit                               |
|    26 | L1I demand miss                              |
|    27 | L1I prefetch launch                          |
|    28 | Useful L1I prefetch                          |
|    29 | L1I demand blocked by prefetch               |
|    30 | L1D load hit                                 |
|    31 | L1D load miss                                |
|    32 | Store request accepted                       |
|    33 | Retirement head incomplete                   |
|    34 | Instruction completed behind retirement head |
| 35-37 | Lost issue slots 0-2                         |

The encoding is shared with `openrv64_core_perf`; the macro definitions live
in `rtl/core/cmu/defs.v`.

The 1P and 3P cores currently connect cycle, issue/retirement, empty-cycle,
redirect, fetch, LSU, barrier, and accepted-store events where exact pulses
already exist. Events that require new cache or retirement telemetry are tied
low. In particular, bits 25-31 are not inferred from external request latency:
that would conflate cache misses with translation and downstream
backpressure.

## Scope

The implemented hardware is sufficient for M-mode firmware to configure raw
HPM counters and expose selected counters to S/U mode. The SBI PMU extension
is a separate firmware interface and is not implemented by this RTL change.
Counter overflow interrupts and privilege-mode filtering from Sscofpmf are
also not implemented yet.

Primary specifications:

- [RISC-V privileged machine-level CSRs](https://docs.riscv.org/reference/isa/priv/machine.html)
- [Zicntr and Zihpm](https://docs.riscv.org/reference/isa/unpriv/counters.html)
- [SBI PMU extension](https://docs.riscv.org/reference/sbi/ext-pmu.html)
