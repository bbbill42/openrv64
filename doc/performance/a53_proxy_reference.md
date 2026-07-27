# This document is extermely old (like, a whole week!), and is kept primarily to use for HPI number reference

# Cortex-A53-class performance reference

This document freezes the 2026-07-18 comparison for
`sw/coremark_loop.c`. It is the reference for judging future OpenRV64 1P and
3P performance work.

The timing reference is gem5's High-Performance In-order (HPI) ARMv8-A
model. gem5 describes HPI as representative of a modern in-order ARMv8-A
implementation. It is useful as a Cortex-A53-class target, but it is not a
cycle-exact Cortex-A53 model and the results must not be presented as measured
Cortex-A53 silicon performance.

## Headline result

| Core/model                  | ISA     | Retired instructions |  Cycles |      IPC |
|-----------------------------|---------|---------------------:|--------:|---------:|
| ARM gem5 HPI reference      | AArch64 |               58,695 |  72,146 | 0.813559 |
| OpenRV64 1P, repeat-last BP | RV64I   |               52,547 | 141,804 |   0.3706 |
| OpenRV64 3P, repeat-last BP | RV64I   |               52,547 | 185,775 |   0.2829 |

At the same clock rate, the saved HPI run completes the workload 1.966 times
faster than the 1P snapshot and 2.575 times faster than the 3P snapshot. The
3P snapshot is also 31.0% slower than 1P despite its three-wide frontend,
issue, completion, and retirement interfaces.

Do not compare the IPC values across ISAs in isolation. The AArch64 binary
commits 11.7% more instructions than the RV64I binary. Same-work cycle count
is the useful cross-ISA comparison here; IPC remains useful within one ISA
and for diagnosing whether each core uses its available width.

## Same-pipe RAW forwarding follow-up

The first 3P dependency optimization was measured later on 2026-07-18.  It is
intentionally narrow: dispatch may route an instruction to the ALU pipe whose
completion register holds the immediately preceding value, and that pipe
feeds the value into its own operand mux.  Only `{valid, rd}` metadata returns
to dispatch; the 64-bit value is not broadcast between pipes.

The resulting comparison is:

| Workload                 | Core/model                        | Retired instructions |  Cycles |      IPC |
|--------------------------|-----------------------------------|---------------------:|--------:|---------:|
| `test.elf` resident loop | OpenRV64 1P                       |                  308 |     329 |   0.9362 |
| `test.elf` resident loop | OpenRV64 3P, local RAW forwarding |                  308 |     323 |   0.9536 |
| CoreMark-derived loop    | ARM gem5 HPI reference            |               58,695 |  72,146 | 0.813559 |
| CoreMark-derived loop    | OpenRV64 1P                       |               52,547 | 141,804 |   0.3706 |
| CoreMark-derived loop    | OpenRV64 3P baseline              |               52,547 | 185,775 |   0.2829 |
| CoreMark-derived loop    | OpenRV64 3P, local RAW forwarding |               52,547 | 184,959 |   0.2841 |

The remembered approximately 0.9 IPC result therefore applies to the tiny
resident `test.elf` loop, and both cores still achieve it.  It does not apply
to the branch-heavy CoreMark-derived workload.  On that workload the first
forwarding step saves 816 cycles, a 0.44% speedup, and raises IPC by only
0.0012.  The current 3P result remains 30.4% slower than 1P and takes 2.563
times the HPI reference's cycles.

The full traced counter delta explains why the speedup is small:

| 3P CoreMark-derived counter          | Baseline | Local forwarding |        Delta |
|--------------------------------------|---------:|-----------------:|-------------:|
| Total cycles                         |  185,775 |          184,959 |         -816 |
| Issue active cycles                  |   41,840 |           41,904 |          +64 |
| Three-lane issue utilization         |    9.43% |            9.47% | +0.04 points |
| Dispatch nonempty, no issue          |  111,250 |          110,370 |         -880 |
| Any queued RAW indication            |  114,030 |          109,818 |       -4,212 |
| Retire queue nonempty, no retirement |  119,554 |          118,674 |         -880 |
| Three-wide issue cycles              |      241 |              241 |            0 |

This mechanism forwards only the completion visible in the immediately next
cycle.  A cross-pipe dependency, a load result, an older result whose local
completion window has passed, or two live inputs produced by different pipes
still stalls.  Same-bundle producer/consumer pairs also stall deliberately;
there is no combinational ALU-to-ALU chain within one issue cycle.  WAW and
hard-order rules are unchanged.  The next material dependency step needs a
persistent producer-ready/owner record or a broader bypass network; repeating
this one-cycle special case will not recover the CoreMark-derived IPC gap.

## Workload contract

This is a finite, branch-heavy workload derived from CoreMark's
`core_state.c` state machine. It is not the full CoreMark benchmark, does not
run CoreMark's list or matrix kernels, and does not produce a CoreMark score.
Calling the result “CoreMark/MHz” would be wrong.

The common C source has these properties:

- a fixed 338-byte input corpus, excluding its terminating NUL;
- eight complete passes over that corpus;
- volatile input loads to retain the data-dependent control flow;
- integer parsing states, calls, switch/if control flow, and a small integer
  mixing tail;
- no operating system, libc, allocator, files, or timer calls;
- no deliberate cache-capacity working set;
- a final memory-visible `coremark_loop_sink` value of `0x0a27789d`.

The source SHA-256 for this reference is:

```text
adec2749ecdc32c02bd1c013156d5e1b5c7a5d45be05e63be7205c83c5541ef0  sw/coremark_loop.c
```

The ARM wrappers explicitly compare `coremark_loop_sink` with the expected
checksum and exit with failure on a mismatch. The saved RTL runs terminate at
the expected EBREAK and follow the same C source, but the current RTL
testbenches do not independently assert the sink value. A future benchmark
harness should add a memory-result assertion; the value left in `a0` is not a
valid substitute because `coremark_loop()` returns `void`.

## Architecture of the two machines

### What the HPI proxy actually models

gem5's HPI CPU is implemented by the MinorCPU timing model. MinorCPU names
four pipeline stages, but those are simulation containers, not a literal
four-stage Cortex-A53 pipeline diagram:

```text
             prediction back to Fetch1
                       ^
                       |
32 KiB L1I -> Fetch1 -> Fetch2 -> Decode -> Execute
                64 B     macro     <=2       input buffers
                lines     ops      uops/cyc  + scoreboard
                                            + FU pipelines
                                            + LSQ
                                            + in-flight queue
                                            + <=2 in-order commit
```

`Fetch1` reads cache lines. `Fetch2` turns line bytes into architectural
macro-instructions and performs prediction. `Decode` expands macro-ops into
micro-ops at up to two per cycle. `Execute` is much more than an ALU stage: it
contains seven cycles' worth of input buffering, a latency-aware scoreboard,
the functional-unit pipelines, load/store queues, the program-order in-flight
queue, execution, and commit.

The configured functional units are:

| HPI unit         | Count |          Operation latency | Issue interval | Important role                  |
|------------------|------:|---------------------------:|---------------:|---------------------------------|
| Integer ALU      |     2 |                   3 cycles |        1 cycle | General integer and branch work |
| Integer multiply |     1 |                   3 cycles |        1 cycle | Multiply and multiply-add       |
| Integer divide   |     1 |     3 cycles in this model |       3 cycles | Integer division                |
| Float/SIMD       |     1 |                   6 cycles |        1 cycle | AArch64 SIMD/FP operations      |
| Memory           |     1 | 1 cycle plus memory system |        1 cycle | Loads and stores through LSQ    |
| Miscellaneous    |     1 |                    1 cycle |        1 cycle | System and prefetch operations  |

HPI is still an in-order machine. It does not skip a blocked oldest
instruction to issue a younger independent instruction. Its important
advantage is that "in order" does not mean "wait for retirement." The
scoreboard records the predicted result-return cycle and the producing
functional unit. Instruction-specific source-relative latencies describe
when a consumer may use a forwarded result. For a normal AArch64 integer
operation the default source-relative latencies are `[2, 2, 2, 0]`, subject to
functional-unit forwarding restrictions. A dependent instruction can
therefore issue as soon as the result will be available to it, usually well
before the producer reaches architectural commit.

Memory operations can issue early into the LSQ when dependencies and ordering
allow. The resolved configuration has a five-entry store buffer, a one-entry
LSQ request queue, a two-entry transfer queue, at most two memory accesses in
flight, and capacity to move two stores into the store buffer per cycle. HPI
still limits architectural memory issue and memory commit to one each per
cycle.

The predictor is materially more capable than OpenRV64's saved predictor:

- 64-entry local history/table and 1,024-entry global predictor;
- 1,024-entry chooser, with two-bit counters in all three tables;
- 128-entry direct-mapped BTB;
- eight-entry return-address stack;
- a separate two-way, 256-set indirect-target predictor in the resolved gem5
  configuration.

This machinery is why the result should be called an HPI or A53-class proxy,
not a claim about the exact physical Cortex-A53 pipeline. gem5 models the
performance-relevant mechanisms, but its four named stages and exact queue/FU
latencies are not a reverse-engineered A53 implementation.

### How OpenRV64 3P works

The saved 3P path is:

```text
256-bit AXI read, one 32 B beat
              |
              v
4 x 32 B direct-mapped resident fetch slots
              |
              v up to 3 contiguous RV64I instructions
        three-wide decode
              |
              v
      6-entry dispatch queue
              |
              v strict program-order prefix
   +----------+----------+
   |          |          |
  EX0        EX1        MEM
 branch      RV64M      load/store
 system      + ALU      only
 + ALU
   |          |          |
   +----------+----------+
              |
              v
8-entry completion/retirement queue
              |
              v maximal contiguous prefix, <=3 commits/cycle
```

The three issue outputs are physical pipes, not three interchangeable lanes.
Loads and stores are fixed to `MEM`; branches, jumps, system operations,
fences, and other hard controls are fixed to `EX0`; RV64M operations are fixed
to `EX1`; ordinary integer operations are balanced between `EX0` and `EX1`.
Two instructions cannot use the same physical pipe in one cycle.

Dispatch is deliberately strict. Candidate 1 fires only if older candidate 0
fires in the same cycle, and candidate 2 fires only if candidate 1 fires. A
dependency, full pipe, or memory stall at the head therefore prevents issue
around it even if a younger instruction is independent and has a free pipe.
This is the same broad in-order issue policy as HPI, but OpenRV64 combines it
with a much more conservative register map.

The register map marks a destination busy when its instruction issues and
normally clears it only when that instruction retires. A later source read is
a RAW hazard and a later write to the same register is a WAW hazard for that
whole interval. The only important shortcut is same-edge retirement bypass:
an instruction issuing beside an older retirement can read the newly committed
value. The follow-up implementation described above adds immediate local
EX0/EX1 completion forwarding, but there is still no general execute-result
availability tracking or cross-pipe producer-to-consumer forwarding.

Completion may occur out of order, but that does not make this an
out-of-order-execution core. The retirement queue merely remembers completed
results and exposes the maximal completed program-order prefix, up to three
entries. Issue remains a strict prefix and retirement remains in order. There
is also a conservative capacity gate: issue resumes only when the eight-entry
retirement queue has room for a complete three-entry allocation group, even
when the current group contains only one useful instruction.

The frontend is also narrower in storage than the phrase "loop buffer" can
suggest. It has four direct-mapped 32-byte resident entries: a 128-byte window,
not an associative instruction cache and not a decoded-loop buffer. A bundle
can cross a line boundary when both lines are resident, and an ordinary
redirect cancels pending sequential requests without invalidating all warm
lines. Those are useful properties, but unrelated code at the same direct-map
indices replaces the resident lines.

For scale, the RV64 `coremark_loop` outer function is 88 bytes and can fit in
that window, but it calls the 236-byte `scan_input` and the 1,004-byte
`state_transition`. The executable `.text` is 1,392 bytes. The actual hot
working set therefore does not fit in 128 bytes, while all of it fits trivially
in HPI's 32 KiB L1I. The resident window helps the small outer loop and short
local loops, but it cannot cover the complete branch-heavy traversal.

### Where HPI has an architectural advantage

| Mechanism              | gem5 HPI proxy                                       | OpenRV64 3P snapshot                                           | Expected consequence here                                                      |
|------------------------|------------------------------------------------------|----------------------------------------------------------------|--------------------------------------------------------------------------------|
| Instruction storage    | 32 KiB, two-way L1I, 64 B lines                      | Four direct-mapped 32 B lines, 128 B total                     | HPI retains the full hot text; 3P repeatedly replaces lines                    |
| Conditional prediction | Local/global tournament plus chooser                 | One global bit: repeat the last conditional outcome            | HPI separates unrelated branch histories                                       |
| Calls and returns      | BTB, indirect predictor, eight-entry RAS             | Direct targets from predecode; targetless indirect jumps stall | HPI predicts returns; every RV64 `jalr` call/return can stop 3P fetch          |
| Dependency handling    | Latency-aware scoreboard and forwarding              | Destination busy from issue through retirement                 | HPI overlaps dependent integer work instead of waiting for commit              |
| Integer issue          | Two pipelined integer ALUs                           | Two ALU-capable pipes, but fixed routing and strict prefix     | Similar nominal ALU count; HPI exposes it much more often                      |
| Memory scheduling      | Early LSQ issue and store buffering                  | One fixed MEM pipe and conservative ordered-head checks        | HPI can decouple memory work from commit more effectively                      |
| Admission/retirement   | Buffered execute input, two-wide in-order commit     | Six dispatch, eight retire, full-three-slot admission gate     | 3P's wider retirement does not help when the head or capacity gate blocks      |
| ISA/code generation    | AArch64 has rotate, pair load/store, and SIMD idioms | RV64I uses separate shifts/adds and scalar initialization      | Some local AArch64 sequences are denser, but this is not the main measured win |

The ISA row needs restraint. AArch64 uses useful instructions in this binary,
including `ror`, `stp`/`ldp`, and SIMD updates to adjacent counters. Some of
those architectural instructions expand into multiple HPI micro-ops, so they
are not free. More importantly, the AArch64 run commits 11.7% *more*
architectural instructions overall. The measured 2.575x cycle advantage is
therefore principally a pipeline/prediction result, not an instruction-count
advantage.

OpenRV64 does have two large advantages in this experiment: its external RAM
has no cache-miss or DRAM timing, and its RV64 binary executes fewer
architectural instructions. It also has a theoretical three-wide retirement
ceiling. The present 3P result loses despite those advantages because only
9.43% of available issue and retire lane-slots are used.

## What each run measures

### QEMU functional run

QEMU runs the bare-metal AArch64 ELF on `-M virt` with `-cpu cortex-a53`.
`one-insn-per-tb=on` and `nochain` make every translated block correspond to
one dynamic instruction, allowing the trace parser to count the executed
instruction path.

| Counter                                        | Result |
|------------------------------------------------|-------:|
| Translation blocks                             | 58,706 |
| Instructions before the final semihosting exit | 58,705 |
| Distinct dynamic PCs                           |    261 |

The QEMU count is ten instructions above gem5's committed count because the
bare-metal and syscall-emulation entry/exit wrappers differ. QEMU TCG does
not model Cortex-A53 cycles, so no QEMU timing, CPI, or IPC number is used.
`-cpu cortex-a53` selects the architectural feature set only.

### gem5 HPI timing run

The timing run uses gem5 syscall-emulation mode and the same C body compiled
for AArch64. Its compact counters are:

| Counter                |         Result | Interpretation                           |
|------------------------|---------------:|------------------------------------------|
| CPU cycles             |         72,146 | HPI model cycles at the configured 1 GHz |
| Committed instructions |         58,695 | Architectural AArch64 instructions       |
| IPC                    |       0.813559 | Committed instructions divided by cycles |
| Fetched instructions   |         72,934 | Includes work later discarded            |
| Fetch rate             | 1.010922/cycle | Below the two-wide maximum               |
| Fetched over committed |         24.26% | Frontend/wrong-path surplus              |
| Committed branches     |         18,642 | 31.76% of committed instructions         |
| Branch mispredictions  |          1,508 | 8.09% of committed branches              |
| Discarded micro-ops    |          4,432 | Squashed before commit                   |
| L1I demand misses      |             20 | Cold/compulsory footprint is small       |
| L1D demand misses      |             14 | Data footprint is also small             |

A separate `MinorExecute` diagnostic run recorded the following event-cycle
counts. These conditions overlap and therefore must not be added into a
single stall total.

| HPI execute diagnostic           | Cycles | Percent of run |
|----------------------------------|-------:|---------------:|
| Any failed issue attempt         | 27,653 |         38.33% |
| Dependency-blocked issue attempt | 23,093 |         32.01% |
| Functional-unit blocked attempt  |  4,946 |          6.86% |
| Two-issue limit reached          | 17,524 |         24.29% |
| Two-commit limit reached         | 17,579 |         24.37% |
| One-memory-commit limit reached  | 13,207 |         18.31% |

The HPI model configuration is:

- one 1 GHz, two-wide in-order ARMv8-A CPU;
- decode width 2, issue limit 2, and commit limit 2;
- at most one memory issue and one memory commit per cycle;
- 32 KiB, two-way L1I with 1-cycle tag/data/response components;
- 32 KiB, four-way L1D with 1-cycle tag/data/response components;
- 1 MiB, 16-way L2 with 13-cycle tag/data and 5-cycle response components;
- 64-byte cache lines;
- tournament conditional predictor, 128-entry direct-mapped BTB, and
  eight-entry return-address stack;
- one 128 MiB DDR3-1600 channel with two ranks;
- full `MinorTrace` enabled.

The memory hierarchy is real in the HPI timing model, but this workload barely
exercises its miss behavior: only 34 total L1 demand misses occurred. Removing
DRAM latency therefore does not, by itself, explain the approximately 2.6x
gap between HPI and the saved OpenRV64 3P run.

### OpenRV64 1P snapshot

The 1P run uses the repeat-last predictor (`BP_TYPE=3`), normal ALU
forwarding, and load forwarding disabled. Its testbench memory is a 64 KiB,
64-bit array with `mem_ready` asserted whenever `mem_valid` is asserted. It
has no modeled DRAM or cache miss latency.

| 1P stage/cause                    |  Cycles | Percent of run |
|-----------------------------------|--------:|---------------:|
| IF occupied                       | 131,781 |         92.93% |
| ID occupied                       |  90,462 |         63.79% |
| EX occupied                       |  73,469 |         51.81% |
| MEM occupied                      |  84,557 |         59.63% |
| WB occupied                       |  52,548 |         37.06% |
| RAW/scoreboard stall              |  28,124 |         19.83% |
| Instruction-memory pipeline stall |  18,614 |         13.13% |
| Data-memory pipeline stall        |  32,009 |         22.57% |
| Execute stall                     |  20,921 |         14.75% |
| Frontend held                     |  38,132 |         26.89% |

Those stall labels are internal pipeline conditions. In particular,
`if-memory` and `data-memory` do not mean the testbench inserted a DRAM wait
state; the external memory handshake is combinationally ready.

### OpenRV64 3P snapshot

The 3P run uses `openrv64_top_3p.v`, the repeat-last predictor, the native
256-bit AXI interface, and the testbench's 16 MiB AXI RAM. A RAM read transfers
one aligned 32-byte line in one beat. The fabric accepts reads into an
eight-entry queue and returns RAM data through a registered AXI response. It
does not model a cache hierarchy or DRAM timing, but AXI handshakes, the
registered response, and core-internal fetch/LSU latency still consume cycles.

The stage utilization was:

| 3P stage | Active cycles | Occupied lane-slots | Three-lane utilization |
|----------|--------------:|--------------------:|-----------------------:|
| Fetch    |       130,584 |             383,996 |                 68.90% |
| Decode   |       102,769 |             235,871 |                 42.32% |
| Issue    |        41,840 |              52,549 |                  9.43% |
| Complete |        48,058 |              52,548 |                  9.43% |
| Retire   |        41,607 |              52,548 |                  9.43% |

The architectural issue and retirement width distribution makes the loss of
width explicit:

| Width in a cycle | Issue cycles | Percent of all cycles | Retire cycles | Percent of all cycles |
|-----------------:|-------------:|----------------------:|--------------:|----------------------:|
|                0 |      143,935 |                77.48% |       144,169 |                77.60% |
|                1 |       31,372 |                16.89% |        31,258 |                16.83% |
|                2 |       10,227 |                 5.51% |         9,755 |                 5.25% |
|                3 |          241 |                 0.13% |           593 |                 0.32% |

Of the cycles that issue anything, 74.98% issue only one instruction and just
0.58% issue three. The 3P core is therefore not losing primarily because the
frontend cannot place three instructions in a fetch bundle. It is usually
unable to turn queued instructions into multiple issues.

The trace's cycle predicates were:

| 3P condition                             |  Cycles | Percent of run |
|------------------------------------------|--------:|---------------:|
| Frontend empty                           |  55,191 |         29.71% |
| Frontend held                            |  83,420 |         44.90% |
| Dispatch queue nonempty but no issue     | 111,250 |         59.88% |
| Queued RAW hazard present                | 114,030 |         61.38% |
| Queued WAW hazard present                |  55,541 |         29.90% |
| Queued read-port hazard present          |   2,288 |          1.23% |
| Queued serialization barrier present     |     586 |          0.32% |
| Retire queue nonempty but no retirement  | 119,554 |         64.35% |
| Branch-predictor stall                   |  42,195 |         22.71% |
| Redirect/correction                      |   7,218 |          3.89% |
| Fetch request waiting for AXI acceptance |       0 |          0.00% |

These are overlapping predicates, not an additive CPI stack. `axi_wait=0`
means the fetch request was never held off at the AXI address-acceptance
boundary; it does not mean an AXI read response appears in zero cycles. The
same trace contains 53,399 accepted AXI read addresses.

## Concrete pipeline-state examples

The examples below are excerpts from the saved full traces, not constructed
timing diagrams. They show why the aggregate IPC values differ.

### OpenRV64 1P: ordinary pipeline backpressure

The readable 1P trace uses `>` for an instruction that advances during the
cycle, `~` for one held in place, and `FLUSH` for invalidated work. This excerpt
is the entry to RV64 `coremark_loop`:

```text
cycle | IF       | ID       | EX       | MEM      | WB       | cause
   25 | >051c    | >0518    | .        | .        | .        | -
   26 | >0520    | >051c    | >0518    | .        | .        | -
   27 | >0524    | >0520    | >051c    | >0518    | .        | -
   28 | ~0528    | ~0524    | ~0520    | ~051c    | >0518    | RAW + data-memory + execute
   29 | ~0528    | ~0524    | ~0520    | ~051c    | .        | same
   30 | ~0528    | ~0524    | ~0520    | ~051c    | .        | same
   31 | >0528    | >0524    | >0520    | >051c    | .        | -
```

The pipe initially fills at one instruction per cycle. The load at `0524`
depends on the address made at `0520`, while the older store occupies the
memory path. One dependency/backpressure event freezes four stages for three
cycles. This repeated stop-and-go pattern explains why a nominally simple
single-issue core reaches only 0.3706 IPC even though external memory asserts
ready immediately.

### OpenRV64 3P: a full frontend behind a blocked backend

The 3P renderer writes entries as `uid@low-PC`. `F`, `D`, `I`, `C`, and `R`
mean fetch, decode, issue, complete, and retire; `dq/rq` are dispatch- and
retire-queue occupancy. Issue entries are printed in physical pipe order
`EX0/EX1/MEM`, not program order.

The relevant RV64 instructions are:

| UID  | PC         | Instruction                           |
|------|------------|---------------------------------------|
| `8`  | `80000518` | `addi sp,sp,-32`                      |
| `9`  | `8000051c` | `sd s0,16(sp)`                        |
| `a`  | `80000520` | `auipc s0,0`                          |
| `b`  | `80000524` | `lw s0,424(s0)`                       |
| `c`  | `80000528` | `sd s1,8(sp)`                         |
| `d`  | `8000052c` | `sd ra,24(sp)`                        |
| `e`  | `80000530` | `li s1,8`                             |
| `f`  | `80000534` | `auipc ra,0`                          |
| `10` | `80000538` | `jalr` to `scan_input`                |
| `11` | `8000053c` | `xor a0,a0,s0` on the sequential path |

A compact rendering of cycles 25-71 is:

| Cycle(s) | Important state                                                                           | What it means                                                                                                   |
|----------|-------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| 25-28    | Fetch/decode quickly fill; at 28, `I=a/9`, `R=8`, `dq/rq=6/1`                             | The frontend can supply bundles and two physical pipes can issue together                                       |
| 29-37    | Fetch holds `11@053c` and younger instructions; no issue; `dq/rq=6/2`; RAW, WAW, BP stall | A full dispatch queue cannot make progress while issued writers remain busy and the indirect jump is unresolved |
| 38       | `I=b`, `R=9/a`, `dq/rq=6/2`                                                               | Retirement clears the busy producer and the dependent load can finally issue                                    |
| 39-44    | No issue; fetch remains held                                                              | The backend again drains serially                                                                               |
| 45-46    | `I=c`, then `R=b`                                                                         | One more store becomes admissible after the load progresses                                                     |
| 47-53    | No issue; `dq/rq=4/1`                                                                     | Four decoded instructions wait despite free frontend bandwidth                                                  |
| 54       | `I=e/f/d`, `C=c`                                                                          | A genuine three-issue cycle: ALU `e` uses EX0, ALU `f` EX1, and older store `d` MEM                             |
| 55-63    | `C=e/f`, `R=c`, then no issue until `C=d`; RAW, WAW, BP stall                             | Completion alone does not release destination busy state; the head group must reach retirement                  |
| 64       | `I=10`, `R=d/e/f`, redirect                                                               | The indirect `jalr` issues only when the older prefix retires; its resolved target restarts fetch               |
| 65-66    | Complete and retire `10`; barrier active                                                  | The ordered control instruction drains through the backend                                                      |
| 67-69    | All architectural stages empty                                                            | Redirect/refill bubble                                                                                          |
| 70-71    | Target fetch resumes at `8000042c`; two target instructions issue at 71                   | Useful work restarts roughly six cycles after the redirecting issue                                             |

This window directly answers the fetch question. Fetch is not continuously
starved: it has already placed `xor` and following sequential instructions on
the frontend interface. They sit there from cycle 29 through 64 because the
dispatch queue is full, a targetless indirect jump has stopped speculation,
and the backend cannot release dependencies quickly. The frontend is not
healthy in an absolute sense—its 128-byte resident window and indirect-control
policy are real limitations—but adding more fetch requests alone would not
repair this 36-cycle hold.

The three-issue cycle at 54 also shows an important nuance. Printed pipe order
is `e/f/d`, but program order is `d/e/f`; the older store is routed to `MEM`
while the two younger independent integer operations use `EX0` and `EX1`.
The hardware already has the essential ability to fill all three pipes. It
almost never reaches a dependency-free, differently routed three-instruction
prefix: only 241 cycles, 0.13% of the run, issue at width three.

### HPI: latency-aware dual issue through the same branchy code

The HPI `MinorExecute` trace below is inside AArch64 `state_transition`. The
code contains alternating compares and conditional branches. HPI's two
integer units can pair the branch consuming the previous flags with the next
independent compare that creates a new set of flags:

| HPI cycle | Commit/completion                   | New issue                     | Blocked oldest operation                 |
|----------:|-------------------------------------|-------------------------------|------------------------------------------|
|       710 | Early memory issue of `ldrb@400044` | none                          | `subs@400048` waits for the byte         |
|       711 | `cbz@40003c` and `movz@400040`      | `subs@400048`                 | `b.eq@40004c` waits for flags            |
|       712 | `ldrb@400044`                       | `b.eq@40004c` + `subs@400050` | none after two-issue limit               |
|       713 | none                                | `b.eq@400054` + `subs@400058` | none after two-issue limit               |
|       714 | `subs@400048`                       | `b.eq@40005c` + `subs@400060` | none after two-issue limit               |
|       715 | `b.eq@40004c` + `subs@400050`       | `b.eq@400064` + `subs@400068` | none after two-issue limit               |
|       716 | `b.eq@400054` + `subs@400058`       | `b.ne@40006c` + `sub@400070`  | none after two-issue limit               |
|       717 | `b.eq@40005c` + `subs@400060`       | `and@400074`                  | `subs@400078` waits on a true dependency |
|       718 | `b.eq@400064` + `subs@400068`       | `subs@400078`                 | `b@40007c` waits for flags               |
|       719 | `b.ne@40006c`, taken                | redirect to `4001f0`          | younger stream is discarded              |

This is not out-of-order issue: whenever the oldest instruction is blocked,
HPI stops. The difference is that the scoreboard makes the block last only
until the required forwarded value will be ready. Once ready, the core often
uses both integer units and later commits two instructions per cycle. That is
the behavior OpenRV64 needs to approximate if 0.9 IPC is the near-term goal.

AArch64 pair operations should not be overinterpreted. At the entry to
`coremark_loop`, `stp x29,x30,[sp,#-16]!` is expanded by gem5 into address and
store micro-operations across several cycles. HPI gains from buffered,
pipelined handling of those micro-ops; the architectural `stp` mnemonic does
not represent one free pair-store cycle.

## Diagnosis and design implication

The measured facts support this diagnosis:

1. The workload fits easily in the HPI caches, so modeled DRAM latency is not
   a major part of the ARM reference result.
2. The OpenRV64 3P AXI address channel did not backpressure fetch at all.
3. The 3P frontend produced substantial bundles, but issue and retirement
   used only 9.43% of their available lane-slots.
4. RAW, WAW, branch holds, and retirement waits dominate the recorded 3P
   conditions.
5. The 128-byte direct-mapped resident window is useful but cannot retain the
   complete 1,392-byte hot text; it is not a full loop buffer or L1I.
6. More instruction residency can reduce refill traffic, but it cannot remove
   conservative dependency blocking or retirement serialization.

The practical order of attack is therefore:

1. remove false or over-conservative RAW/WAW blocking with correct forwarding
   and result-availability tracking;
2. allow multiple non-conflicting queued instructions to issue in the same
   cycle;
3. eliminate unnecessary retirement bubbles while preserving contiguous
   in-order retirement;
4. add return/indirect-target prediction and improve conditional prediction;
5. expand or make instruction residency more associative after measuring the
   residual frontend cost;
6. retain the ideal AXI RAM experiment so backend gains are not hidden by a
   new memory hierarchy.

That order is an inference from the current trace, not a proof that fetch is
finished. Every future performance run should retain the pipeline trace so a
new bottleneck can be identified after each backend improvement.

## OpenRV64 cycle targets

The targets below keep the RV64 dynamic instruction count fixed at 52,547 and
compare same-work cycles at the same hypothetical clock frequency. They do
not account for a difference in achievable Fmax.

| Target           | Maximum RV cycles | Required RV IPC | Speed over HPI | Cycle reduction from current 3P |
|------------------|------------------:|----------------:|---------------:|--------------------------------:|
| Match HPI cycles |            72,146 |           0.728 |          1.00x |                          61.16% |
| Recover 0.9 IPC  |            58,386 |           0.900 |          1.24x |                          68.57% |
| Clear win        |            48,097 |           1.093 |          1.50x |                          74.11% |
| Beat it by far   |            36,073 |           1.457 |          2.00x |                          80.58% |

Recovering 0.9 IPC would already beat this HPI result by 23.6% in same-clock
cycle count because the RV64 binary executes fewer instructions. The 2x-HPI
goal requires 1.457 IPC, or 48.6% of the theoretical three-instruction retire
width. That target is aggressive but not arithmetically absurd. The hard part
is exposing that width through this workload's dependency and branch pattern.

## Reproducing the ARM reference

Run the checked-in occasional-use helper:

```sh
tools/run-a53-proxy.sh
```

It builds the AArch64 images, runs QEMU for functional validation, then runs
the gem5 HPI timing model with `MinorTrace`. It pins gem5 commit
`51edbbb9cfd37e92e9901aea2caa4a8f20eda005` and reuses an existing build.
The first gem5 build is roughly 5-7 GiB and may take several minutes. Set
`GEM5_ROOT` if the checkout must survive `/tmp` cleanup.

Useful controls are:

```sh
GEM5_ROOT=/path/to/gem5 GEM5_JOBS=16 tools/run-a53-proxy.sh
A53_RUN_QEMU=0 tools/run-a53-proxy.sh
A53_RUN_GEM5=0 tools/run-a53-proxy.sh
```

For an occasional issue/commit diagnostic like the HPI pipeline excerpt in
this document, add `MinorExecute` and use a separate output directory because
the trace is much larger:

```sh
A53_RUN_QEMU=0 \
A53_GEM5_DEBUG_FLAGS=MinorTrace,MinorExecute \
A53_GEM5_OUTDIR=/tmp/openrv64-a53-minor-execute \
tools/run-a53-proxy.sh
```

The default remains `MinorTrace` alone. The reference diagnostic trace with
both flags was approximately 315 MiB versus 182 MiB for `MinorTrace` alone.

## Reproducing the OpenRV64 snapshots

Build the shared RV64 image, then run 1P with its full trace:

```sh
make sw-coremark-loop
make sim-sw-trace \
    SW_BIN=sw/coremark-loop.bin \
    SW_MEMH=sim/coremark-loop-1p-bp3.memh \
    SW_BP_TYPE=3 \
    SW_RUN_ARGS='+halt_only +no_expect_a0 +max_cycles=200000' \
    SW_TRACE_CSV=sim/coremark-loop-1p-bp3-trace.csv \
    SW_TRACE_REPORT=sim/coremark-loop-1p-bp3-pipeline.txt
```

Run 3P through the native 256-bit AXI/16 MiB RAM testbench:

```sh
make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-loop-256.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    AXI_3P_PERF_ARGS= \
    AXI_3P_PERF_BP_TYPE=3 \
    AXI_3P_TRACE_CSV=sim/coremark-loop-3p-bp3-trace.csv \
    AXI_3P_TRACE_REPORT=sim/coremark-loop-3p-bp3-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS='--around-pc 80000518'
```

For the local-forwarding follow-up, the same commands were rerun with these
output names so the baseline traces remained intact:

```sh
make sim-sw-trace \
    SW_BIN=sw/coremark-loop.bin \
    SW_MEMH=sim/coremark-loop-1p-bp3-local-forward-reference.memh \
    SW_BP_TYPE=3 \
    SW_RUN_ARGS='+halt_only +no_expect_a0 +max_cycles=200000' \
    SW_TRACE_CSV=sim/coremark-loop-1p-bp3-local-forward-reference-trace.csv \
    SW_TRACE_REPORT=sim/coremark-loop-1p-bp3-local-forward-reference-pipeline.txt

make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/coremark-loop.elf \
    AXI_3P_PERF_BIN=sim/coremark-loop-256.bin \
    AXI_3P_PERF_MEMH=sim/coremark-loop-256.memh \
    AXI_3P_PERF_MAX_CYCLES=250000 \
    AXI_3P_PERF_ARGS= \
    AXI_3P_PERF_BP_TYPE=3 \
    AXI_3P_TRACE_CSV=sim/coremark-loop-3p-bp3-local-forward-trace.csv \
    AXI_3P_TRACE_REPORT=sim/coremark-loop-3p-bp3-local-forward-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS='--around-pc 80000518'
```

The `test.elf` comparison must regenerate its binary from the ELF.  The
checked-out `sw/test.bin` was 112 bytes while the measured ELF produced a
44-byte binary, so using that stale file yielded a different 1P program.

```sh
riscv64-elf-objcopy -O binary sw/test.elf sim/test-current.bin

make sim-sw-trace \
    SW_BIN=sim/test-current.bin \
    SW_MEMH=sim/test-1p-bp3-current.memh \
    SW_BP_TYPE=3 \
    SW_RUN_ARGS='+done_pc=80000010 +expect_a0=64 +max_cycles=20000' \
    SW_TRACE_CSV=sim/test-1p-bp3-current-trace.csv \
    SW_TRACE_REPORT=sim/test-1p-bp3-current-pipeline.txt

make sim-top-axi-3p-perf \
    AXI_3P_PERF_ELF=sw/test.elf \
    AXI_3P_PERF_BIN=sim/test-256-local-forward.bin \
    AXI_3P_PERF_MEMH=sim/test-256-local-forward.memh \
    AXI_3P_PERF_MAX_CYCLES=20000 \
    AXI_3P_PERF_ARGS='+done_pc=80000010 +expect_a0=64' \
    AXI_3P_PERF_BP_TYPE=3 \
    AXI_3P_TRACE_CSV=sim/test-3p-bp3-local-forward-trace.csv \
    AXI_3P_TRACE_REPORT=sim/test-3p-bp3-local-forward-pipeline.txt \
    AXI_3P_TRACE_RENDER_ARGS='--around-pc 80000010'
```

The generated evidence is:

- `sim/a53/coremark-loop-a53-qemu-report.txt`: functional instruction report;
- `sim/a53/gem5-hpi/report.txt`: compact HPI counter report;
- `sim/a53/gem5-hpi/stats.txt`: complete gem5 statistics;
- `sim/a53/gem5-hpi/config.ini`: resolved gem5 configuration;
- `sim/a53/gem5-hpi/minor-trace.log`: full HPI pipeline trace;
- `sim/coremark-loop-1p-bp3-trace.csv`: stable 1P cycle trace;
- `sim/coremark-loop-1p-bp3-pipeline.txt`: readable 1P report;
- `sim/coremark-loop-3p-bp3-trace.csv`: stable 3P cycle trace;
- `sim/coremark-loop-3p-bp3-pipeline.txt`: readable 3P report.

These files are ignored by Git and can be recreated. The raw trace sizes in
the reference run were 43,175,047 bytes for 1P, 137,177,299 bytes for 3P, and
182,443,345 bytes for HPI. Full tracing is intentionally part of performance
runs despite the storage cost.

Reference SHA-256 values for the compact artifacts and RTL raw traces are:

```text
4649c20195356e579b1d370dc0c45f126c0be9163fe38e2352585437592ac316  sim/a53/coremark-loop-a53-qemu-report.txt
499184227282b4f49134c9257a65993c9d60b81dda6b7b6e1315317c831dd645  sim/a53/gem5-hpi/report.txt
0d7e94063d3e55d99b5719e8455c9a70903212e06aae6594bb595ec1eea22314  sim/coremark-loop-1p-bp3-trace.csv
e0bccec5196873f900c88df2ab9b651304e5b80234bfe988272379a347e3b1e1  sim/coremark-loop-3p-bp3-trace.csv
0d7e94063d3e55d99b5719e8455c9a70903212e06aae6594bb595ec1eea22314  sim/coremark-loop-1p-bp3-local-forward-reference-trace.csv
e7e123df47bd45c66886f727e9765713c65c58f0054d424e59f7148319354a46  sim/coremark-loop-3p-bp3-local-forward-trace.csv
410a5378eee8eef72eebe60103982cb378e26de30aefe5f7e7fab827820608ed  sim/test-1p-bp3-current-trace.csv
41c41755f88befab2bfe74f0960fff8c79df0310dff16bc65f10caf46234f871  sim/test-3p-bp3-local-forward-trace.csv
```

## Exact reference environment

- OpenRV64 repository base commit
  `a79de051fa73a6bc217e391a5c40a0570cefa2b9`;
- `riscv64-elf-gcc` 15.2.0, RV64 build using `-march=rv64i -O2`;
- `aarch64-linux-gnu-gcc` 16.1.0, ARM build using
  `-mcpu=cortex-a53 -O2`;
- Icarus Verilog 13.0 stable;
- QEMU 11.0.2;
- gem5 25.1.0.1 at the pinned commit above;
- HPI activity idling disabled with
  `system.cpu_cluster.cpus[0].enableIdling=False` to avoid gem5 25.1's
  initial activity-recorder underflow.

gem5's `Ticked` accounting retains elapsed wait cycles when activity idling is
enabled, so keeping HPI clocked for this workaround does not remove memory
wait time. The gem5 build warns that host GCC 16 is newer than its officially
supported compiler range. The result reproduced exactly across repeated
runs, but both facts remain part of the reference conditions.

The base commit does not, by itself, identify uncommitted RTL changes that may
have existed when the raw traces were produced. Once this reference and the
associated RTL are committed together, that commit should replace the base
commit above as the canonical snapshot identifier. Until then, the dated raw
trace hashes are the authoritative identity for these exact results.

## Rules for future comparisons

For a new result to replace or compare against this reference:

1. keep the common source unchanged, or record a new source hash and do not
   claim direct comparability;
2. use repeat-last branch prediction unless the comparison is explicitly a
   predictor experiment;
3. validate the final memory checksum, not the undefined return register;
4. enable and retain the full pipeline trace;
5. report cycles, retired instructions, IPC, issue/retire width, and the
   dominant overlapping stall predicates;
6. compare cross-ISA performance using same-work cycles, not IPC alone;
7. report RTL Fmax separately if converting cycle counts into time.
