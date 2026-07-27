# AI runbook: reproduce and debug the 3P Linux boot

This is an operational runbook for an AI agent reproducing the current
high-visibility Linux test. Run commands from the repository root:

```text
/home/bill/src/openrv64
```

The reference configuration is the three-pipe platform core with BP type 6,
a one-entry issue window, speculation enabled, a 16-entry retirement window,
a four-entry pre-retire store queue, a 256 KiB eight-way L2, L1D prefetching,
a 256-bit AXI generic-bus backend, 256 MiB of RAM, and one Verilator thread.
Do not silently substitute a different configuration and compare its timing
as though it were the same test.

## Preserve evidence

- Inspect `git status --short` before changing or building anything.
- The worktree is often intentionally dirty. Do not reset, clean, overwrite,
  or delete changes, logs, traces, or checkpoints that you did not create.
- Give every run a unique stem and keep its log, configuration, binary path,
  traces, and checkpoint together.
- Record the full simulator exit status. Verilator warning volume is not a
  failure; a nonzero exit or a `$fatal` is.
- Use the `vt1` build as the reference. Do not switch to `--threads 4` while
  debugging an unrelated failure. Threaded execution is a separate experiment
  and has previously failed early.

## Inputs

The reset run loads these files:

```text
build/opensbi/artifacts/trampoline.memh
build/opensbi/artifacts/fw_jump.memh
build/opensbi/artifacts/linux-image.memh
build/opensbi/artifacts/openrv64-dtb.memh
```

`sw/Image` is the source Linux image used to generate
`linux-image.memh`. Prepare or refresh the inputs with:

```bash
make -j8 opensbi build/opensbi/artifacts/linux-image.memh
test -s build/opensbi/artifacts/trampoline.memh
test -s build/opensbi/artifacts/fw_jump.memh
test -s build/opensbi/artifacts/linux-image.memh
test -s build/opensbi/artifacts/openrv64-dtb.memh
```

Do not assume `sw/Image` belongs to the current kernel merely because it
exists. Record its provenance or checksum when comparing runs.

## Run focused regressions first

Before spending hours on a boot, test the affected seams:

```bash
make -B -j8 \
  sim-ccx-bus \
  sim-exec-pipe-mem-timeout \
  sim-exec-top-3p \
  sim-backend-3p
```

`sim-exec-pipe-mem-timeout` is an expected-fatal directed test: it deliberately
sets a four-cycle timeout and passes only if the watchdog fires. A fatal from
that test is not evidence that the normal 10,000-cycle configuration failed.

## Build the reference binary

Use explicit parameter values. This prevents a later Makefile default change
from silently changing the experiment.

```bash
make -B -j8 \
  OPENSBI_3P_PLATFORM_BP_TYPE=6 \
  OPENSBI_3P_PLATFORM_ISSUE_WINDOW=1 \
  OPENSBI_3P_PLATFORM_SPECULATION_WINDOW=1 \
  OPENSBI_3P_PLATFORM_RETIRE_DEPTH=16 \
  OPENSBI_3P_PLATFORM_STORE_QUEUE_DEPTH=4 \
  OPENSBI_3P_PLATFORM_L2_BYTES=262144 \
  OPENSBI_3P_PLATFORM_L2_WAYS=8 \
  OPENSBI_3P_PLATFORM_L1D_PREFETCH_ENABLE=1 \
  OPENSBI_3P_PLATFORM_BUS_TYPE=0 \
  OPENSBI_3P_PLATFORM_BUS_DATA_WIDTH=256 \
  OPENSBI_3P_PLATFORM_MEMORY_BYTES=268435456 \
  OPENSBI_3P_PLATFORM_FDT_BASE=2414870528 \
  OPENSBI_3P_PLATFORM_VERILATOR_THREADS=1 \
  build/verilator/opensbi-3p-platform-bp6-iw1-sw1-rw16-sq4-l2262144x8-pf1-bus0x256-mem268435456-fdt2414870528-vt1/opensbi_3p_platform_tb
```

The reference executable is:

```bash
SIM=build/verilator/opensbi-3p-platform-bp6-iw1-sw1-rw16-sq4-l2262144x8-pf1-bus0x256-mem268435456-fdt2414870528-vt1/opensbi_3p_platform_tb
```

The directory name is part of the configuration record, but it is not proof
that the binary is current. Rebuild after RTL, testbench, Verilator C++, or
elaboration-parameter changes.

## Reset run with live annotations

The simulator emits UART bytes, periodic progress records, sampled pipeline
state, exact `PERF SIGNPOST` records, traps, and early PTW activity on stdout.
Keep that original stream and add function annotations:

```bash
set -o pipefail
RUN=bp6-rw16-sq4-$(date -u +%Y%m%dT%H%M%SZ)
VMLINUX=/path/to/the/matching/vmlinux
mkdir -p build/logs

stdbuf -oL -eL "$SIM" \
  +trampoline_memh=build/opensbi/artifacts/trampoline.memh \
  +firmware_memh=build/opensbi/artifacts/fw_jump.memh \
  +payload_memh=build/opensbi/artifacts/linux-image.memh \
  +payload_words=2097152 \
  +fdt_memh=build/opensbi/artifacts/openrv64-dtb.memh \
  +linux_mode \
  +max_cycles=200000000 \
  2>&1 |
python3 tools/linux_boot_watch.py \
  --configuration bp6-rw16-sq4 \
  --elf "linux=$VMLINUX" \
  --elf opensbi=build/opensbi/artifacts/fw_jump.elf \
  --csv "build/logs/$RUN-functions.csv" |
tee "build/logs/$RUN.log"
```

`set -o pipefail` is required; otherwise `tee` can hide a simulator failure.
If no matching `vmlinux` is available, omit the Linux `--elf` argument rather
than using symbols from a different kernel. The watcher preserves the original
stream and inserts `FUNCTION SAMPLE` and `FUNCTION SIGNPOST` records.

For the least intrusive performance run, redirect stdout directly instead of
running the watcher:

```bash
"$SIM" \
  +trampoline_memh=build/opensbi/artifacts/trampoline.memh \
  +firmware_memh=build/opensbi/artifacts/fw_jump.memh \
  +payload_memh=build/opensbi/artifacts/linux-image.memh \
  +payload_words=2097152 \
  +fdt_memh=build/opensbi/artifacts/openrv64-dtb.memh \
  +linux_mode +max_cycles=200000000 \
  > "build/logs/$RUN.log" 2>&1
```

Direct redirection is block-buffered. A temporarily unchanged log does not
prove the model stopped. Check the process and wait for the next output block.

## Trace controls

The reset and restore binaries accept:

| Plusarg                   | Contents                                                                                                               |
|---------------------------|------------------------------------------------------------------------------------------------------------------------|
| `+instruction_trace=PATH` | One record per retired instruction: cycle, PC, instruction, privilege, exception, next PC, and architectural writeback |
| `+lsu_trace=PATH`         | LSU requests/responses and a bounded L1D lock-state diagnostic                                                         |
| `+ccx_trace=PATH`         | Native CCX command, write-data, and response handshakes, including IDs, kind, address, burst, beat, and error          |
| `+pipeline_trace=PATH`    | Per-cycle deep 3P frontend/window/retirement/LSU/PTW state from the C++ harness                                        |
| `+stop_cycles=N`          | Stop the C++ harness at absolute testbench cycle `N`                                                                   |
| `+max_cycles=N`           | Set the testbench limit on a reset run                                                                                 |
| `+max_cycles_override=N`  | Replace the restored testbench limit after loading a checkpoint                                                        |

Do not enable `+pipeline_trace` for an entire 200-million-cycle boot unless the
storage and slowdown are intentional. Use it for a narrow checkpoint replay.
Its C++ implementation names generated hierarchy below the current full
three-pipe platform. It is not portable to the 1P model or an arbitrary RTL
hierarchy without code changes.

## Checkpoint at 140M, then replay closely

A checkpoint contains the full model state, including RAM. Create its parent
directory and stop immediately after saving. The checkpoint path and target
cycle must be supplied when the process starts; they cannot be added
retroactively to an already-running simulator:

```bash
RUN=bp6-rw16-sq4-140m-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p build/checkpoints build/logs

"$SIM" \
  +trampoline_memh=build/opensbi/artifacts/trampoline.memh \
  +firmware_memh=build/opensbi/artifacts/fw_jump.memh \
  +payload_memh=build/opensbi/artifacts/linux-image.memh \
  +payload_words=2097152 \
  +fdt_memh=build/opensbi/artifacts/openrv64-dtb.memh \
  +linux_mode +max_cycles=200000000 \
  +checkpoint="build/checkpoints/$RUN.vls" \
  +checkpoint_cycles=140000000 \
  +checkpoint_exit \
  > "build/logs/$RUN-save.log" 2>&1
```

Resume that exact binary immediately for the ordinary continuation:

```bash
"$SIM" \
  +restore="build/checkpoints/$RUN.vls" \
  +max_cycles_override=200000000 \
  > "build/logs/$RUN-resume.log" 2>&1
```

Do a broad replay without per-cycle tracing first. The historical failure that
motivated this procedure was near cycle 154,281,360, but that is a search hint,
not an assertion that the current build must fail there. If the problem still
clusters there, derive a closer checkpoint from the 140M image:

```bash
"$SIM" \
  +restore="build/checkpoints/$RUN.vls" \
  +max_cycles_override=200000000 \
  +checkpoint="build/checkpoints/$RUN-154m.vls" \
  +checkpoint_cycles=154000000 \
  +checkpoint_exit \
  > "build/logs/$RUN-154m-save.log" 2>&1
```

Then run a bounded high-visibility replay around the suspected failure:

```bash
"$SIM" \
  +restore="build/checkpoints/$RUN-154m.vls" \
  +max_cycles_override=200000000 \
  +stop_cycles=154500000 \
  +instruction_trace="build/logs/$RUN-inst.trace" \
  +lsu_trace="build/logs/$RUN-lsu.trace" \
  +ccx_trace="build/logs/$RUN-ccx.trace" \
  +pipeline_trace="build/logs/$RUN-pipeline.trace" \
  > "build/logs/$RUN-replay.log" 2>&1
```

Memory-fragment plusargs are not needed after restore because RAM is serialized
in the checkpoint. Trace files are not safely inherited as host file
descriptors: pass every desired trace plusarg again so the restore harness
reopens it.

A `.vls` file is ABI-compatible only with the exact elaborated model that
created it. Treat it as invalid after any relevant RTL, C++, Verilator-version,
or parameter change. A nearby directory name is not sufficient compatibility.

## Inspect progress and failures

Use:

```bash
LOG=build/logs/the-run.log
tail -n 80 "$LOG"
rg -n \
  "FATAL|LSU operation timeout|LSU atomic timeout|cancelled fetch slot|PERF SIGNPOST|openrv64# " \
  "$LOG"
python3 tools/linux_boot_signposts.py "$LOG"
```

The signpost extractor recognizes the OpenSBI banner, Linux banner, kernel
memory accounting, devtmpfs, PLIC, 8250 UART, freeing init memory, PID 1, and
the Bash prompt. Explicit signposts have exact cycles and retired-instruction
counts. UART-only milestones are reported as a bracket between adjacent
periodic samples; do not invent an exact cycle from their line position.

`OPENRV64 BASH INIT` or `Run /init as init process` is not a successful shell.
The success condition is the actual `openrv64# ` prompt. Conversely, absence of
the prompt before the cycle limit is not automatically a deadlock.

For cross-configuration comparison:

```bash
python3 tools/linux_boot_report.py \
  --run "bp6-fixed=build/logs/bp6-fixed.log" \
  --run "baseline=build/logs/baseline.log" \
  --baseline baseline \
  --elf "linux=$VMLINUX" \
  --elf opensbi=build/opensbi/artifacts/fw_jump.elf \
  --xlsx build/logs/linux-boot-comparison.xlsx \
  --csv build/logs/linux-boot-comparison.csv
```

The report includes milestone cycles, instructions retired, and function
symbols. Only compare runs whose image, RAM size, bus model, cache parameters,
tracing overhead, and stopping rules are recorded.

### Known-good reference: 2026-07-24

The reference configuration in this document completed successfully with
Verilator 5.050. Its retained log is:

```text
build/logs/opensbi-3p-linux-bp6-rw16-sq4-cancel-fix-reset-200m.log
```

| Signpost                 |          Cycles |   Instructions retired |
|--------------------------|----------------:|-----------------------:|
| OpenSBI banner           |       2,045,476 |              1,795,757 |
| Linux banner             |       5,784,219 |              4,387,743 |
| PLIC initialized         |      43,303,894 |             16,392,143 |
| 8250 console initialized | 131.5M..131.75M | 44,095,668..44,167,115 |
| Kernel init memory freed | 150.5M..150.75M | 48,997,804..49,058,694 |
| PID 1 started            |   150.75M..151M | 49,058,694..49,130,444 |
| Real `openrv64# ` prompt |     161,654,395 |             52,323,183 |

It crossed the former 154,281,360-cycle failure location, printed
`OPENRV64 BASH INIT`, and later reached the real prompt. The testbench reported
PASS and `$finish`; neither the 10,000-cycle LSU watchdog nor the cancelled
fetch/PTW invariant fired. Wall time was 3,915 seconds on one Verilator thread.
These values are a comparison baseline, not universal acceptance thresholds.

## Decide whether the model is live

A stable sampled PC alone is weak evidence. Linux can execute a long loop at
one address, and stdout may be buffered. Compare at least:

- cycle count and `instret` across multiple progress samples;
- UART byte count;
- instruction trace retirement;
- retirement/window valid and complete masks in the deep pipeline trace;
- outstanding LSU, PTW, and CCX request/response state.

If cycles advance but `instret` does not, inspect a narrow trace interval before
calling it a deadlock. If the 10,000-cycle LSU watchdog fires, preserve the
complete fatal line, configuration, preceding trace, and nearest compatible
checkpoint. Do not merely raise the timeout: the watchdog is intended to expose
a lost request or completion.

The sampled `mcause` field is the current value of the architectural CSR, not
proof that a trap happened in that sample. For example, value 9 means an
environment call from S-mode and can remain visible after that trap was
handled. Use the explicit trap records to identify trap entry.

The PTW/cancellation invariant also matters. A cancelled fetch miss must not
transition to `FETCH_TRANSLATE`, including when cancellation and PTW response
occur on the same edge. If the invariant reports a cancelled fetch slot in
translate state, preserve the exact cycle and replay the preceding interval
with instruction, CCX, and pipeline traces.

## Minimal handoff record

An AI handing this test to another agent should provide:

1. `git status --short` and relevant diff or commit.
2. Exact build command and executable path.
3. Verilator version and simulator exit status.
4. Input image paths plus checksums.
5. Full run command, log path, and trace paths.
6. Last several progress records: cycles, `instret`, PC, UART bytes, and trap
   state.
7. Extracted signposts and whether a real `openrv64# ` prompt occurred.
8. Checkpoint path and the exact binary that can restore it.
9. Any fatal line verbatim, followed by analysis clearly labeled as inference.
