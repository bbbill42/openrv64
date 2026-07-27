# OpenRV64 versus HPI: matched 100-instruction pipeline window

This report starts at the 54th dynamic call to `state_transition` in both binaries. The call ordinal aligns the logical workload position; row numbers do not claim ISA-level instruction equivalence.

Observed entry calls: OpenRV64 720, HPI 720.

## Matched-call and 100-instruction summary

| Measurement                                          | OpenRV64 3P oracle + full forwarding |         gem5 HPI |
|------------------------------------------------------|-------------------------------------:|-----------------:|
| Instructions in matched `state_transition` call      |                                  132 |              135 |
| Issue-through-retire/commit cycles for matched call  |                                  230 |              148 |
| Local matched-call IPC                               |                                0.574 |            0.912 |
| Cycles spanning the selected 100 instructions        |                                  176 |              121 |
| Local 100-instruction IPC                            |                                0.568 |            0.826 |
| Issued backend micro-ops for those 100 instructions  |                                  100 |              103 |
| Cycles with selected issue / without selected issue  |                              77 / 99 |          77 / 44 |
| Loads / stores / controls / other                    |                     19 / 3 / 25 / 53 | 17 / 3 / 33 / 47 |
| One-wide / two-wide / three-wide issue cycles        |                          54 / 23 / 0 |    48 / 26 / n/a |
| Cycles where selected oldest instruction was blocked |                                  n/a |               45 |

The width row counts architectural instruction starts. The micro-op row exposes decomposed AArch64 instructions, including pre-indexed loads; these are not free single-operation backend work in HPI.

## OpenRV64 stall exposure in this 100-instruction span

Counters overlap: one cycle can carry several causes.

| Condition        | Cycles | Percent of 176-cycle span |
|------------------|-------:|--------------------------:|
| frontend empty   |     15 |                      8.5% |
| frontend held    |     84 |                     47.7% |
| dispatch empty   |      0 |                      0.0% |
| queued, no issue |     98 |                     55.7% |
| RAW              |    113 |                     64.2% |
| WAW              |    100 |                     56.8% |
| read port        |      4 |                      2.3% |
| barrier          |      0 |                      0.0% |
| retire wait      |     98 |                     55.7% |

## What this window rules out

- Instruction count is not the primary deficit. For the same dynamic call HPI executes 3 more architectural instructions yet takes 82 fewer cycles.
- Pre/post-increment is not a hidden one-uop advantage here. HPI decomposes the pre-indexed loads shown below into two issued micro-ops.
- Compare/branch fusion is not required to explain HPI's lead. Its trace issues separate `subs` and conditional-branch instructions; it frequently overlaps the branch with the next independent `subs`.
- The remaining deficit is scheduling and availability: OpenRV64 spends long runs with queued instructions but no issue, and its load-to-use chains expose the full memory-pipe completion latency.

## Pipe-state examples and implicated mechanisms

- OpenRV64 rows 1-3 form a true load chain: `ld` issues at 0 and completes at 4, dependent `lbu` issues at 4 and completes at 8, and the branch cannot issue until 9. HPI fills part of the corresponding interval with an independent `orr`, then issues `cbz` and the next independent `movz` together at relative cycle 6.
- OpenRV64 row 11 writes `a2` at issue 22, completes at 23, and retires at 24. Row 12 also writes `a2` and does not issue until 24: full data forwarding cannot remove a WAW ownership stall that lasts until retirement. HPI rows 9, 11, 13, and 15 repeatedly write `w0` and start on consecutive cycles 10-13, committing later on 13-16.
- HPI starts an older conditional branch and the next younger `subs` together on cycles 10, 11, 12, and 13. OpenRV64 classifies every control as requiring the retirement head, routes it only to EX0, and terminates its issue group. Thus an already-correctly-predicted branch still serializes the backend; the oracle does not remove that rule.
- OpenRV64's issue chooser is a strict prefix: candidate 1 requires candidate 0 to fire and candidate 2 requires candidate 1. It cannot use an idle lane around an oldest blocked load, WAW, branch, or fixed-lane conflict. HPI is also in-order, but its latency-aware scoreboard and input buffering make the oldest-blocked intervals materially shorter.
- Retirement admission stops unless there is room for a complete three-entry allocation group. That conservative eight-entry-window policy can add avoidable backpressure; independently, `RETWAIT` is visible on 98 of 176 cycles in this window.

## Where the matched-call cycle gap is largest

There are 160 matched calls with at least 100 architectural instructions on both ISAs. Across those calls, OpenRV64 local IPC has median 0.568; HPI's median is 0.888. The selected call ranks 1 by absolute cycle gap.

| Call occurrence | ORV instructions | ORV cycles | ORV IPC | HPI instructions | HPI cycles | HPI IPC | ORV minus HPI cycles |
|----------------:|-----------------:|-----------:|--------:|-----------------:|-----------:|--------:|---------------------:|
|              54 |              132 |        230 |   0.574 |              135 |        148 |   0.912 |                  +82 |
|              99 |              132 |        230 |   0.574 |              135 |        148 |   0.912 |                  +82 |
|             144 |              132 |        230 |   0.574 |              135 |        148 |   0.912 |                  +82 |
|             189 |              132 |        230 |   0.574 |              135 |        148 |   0.912 |                  +82 |
|             234 |              132 |        230 |   0.574 |              135 |        148 |   0.912 |                  +82 |
|             279 |              132 |        230 |   0.574 |              135 |        148 |   0.912 |                  +82 |
|             324 |              132 |        230 |   0.574 |              135 |        148 |   0.912 |                  +82 |
|             369 |              132 |        230 |   0.574 |              135 |        148 |   0.912 |                  +82 |
|             414 |              132 |        230 |   0.574 |              135 |        148 |   0.912 |                  +82 |
|             459 |              132 |        230 |   0.574 |              135 |        148 |   0.912 |                  +82 |

Stage cycles below are relative to each core's first issue in the window. OpenRV64 shows fetch/decode/issue/complete/retire; HPI's reliable per-instruction events from `MinorExecute` are issue, memory launch (`M`), and ordered commit (`K`).

OpenRV64 `F` and `D` ranges are valid-presentation intervals, not request-to-response latency. For example, `F=0-9` means the same already-fetched instruction was visible through cycle 9 while downstream backpressure prevented acceptance. The trace does not attach an individual AXI line-request start to each instruction.

## 100 dynamic instructions side by side

|   # | OpenRV64 PC and instruction                            | F/D/I/C/R                     | HPI PC and instruction                   | I/M/K            |
|----:|--------------------------------------------------------|-------------------------------|------------------------------------------|------------------|
|   1 | `80000040` ld	a5,0(a0)                                 | `-2/-2/0/4/5`                 | `00400030` ldr   x3, [x0]                | `0/3/4`          |
|   2 | `80000044` lbu	a4,0(a5)                                | `-2/-2/4/8/9`                 | `00400034` orr   x6, xzr, x0             | `1/-/4`          |
|   3 | `80000048` beqz	a4,80000384 <state_transition+0x344>   | `-2/-2/9/10/11`               | `00400038` ldrb   w0, [w3]               | `4/5/6`          |
|   4 | `8000004c` lbu	a4,0(a5)                                | `-1/-1/10/14/15`              | `0040003c` cbz   w0, 0x2f4               | `6/-/9`          |
|   5 | `80000050` li	a3,44                                    | `-1/-1/10/11/15`              | `00400040` movz   w0, #0, #0             | `6/-/9`          |
|   6 | `80000054` zext.b	a2,a4                                | `-1/-1/14/15/16`              | `00400044` ldrb   w2, [w3]               | `7/8/10`         |
|   7 | `80000058` beq	a4,a3,800002c4 <state_transition+0x284> | `0/0/16/17/18`                | `00400048` subs   w2, #44                | `9/-/12`         |
|   8 | `8000005c` li	a6,46                                    | `0-4/1-4/17/18/19`            | `0040004c` b.eq   0x23c                  | `10/-/13`        |
|   9 | `80000060` beq	a2,a6,80000290 <state_transition+0x250> | `0-9/1-9/19/20/21`            | `00400050` subs   w0, #5                 | `10/-/13`        |
|  10 | `80000064` bltu	a6,a2,800000a4 <state_transition+0x64> | `1-10/10/21/22/23`            | `00400054` b.eq   0xd0                   | `11/-/14`        |
|  11 | `800000a4` addiw	a2,a2,-48                             | `11/11/22/23/24`              | `00400058` subs   w0, #3                 | `11/-/14`        |
|  12 | `800000a8` zext.b	a2,a2                                | `11-14/11-14/24/25/26`        | `0040005c` b.eq   0x100                  | `12/-/15`        |
|  13 | `800000ac` li	a4,9                                     | `11-16/11-16/24/25/26`        | `00400060` subs   w0, #4                 | `12/-/15`        |
|  14 | `800000b0` bltu	a4,a2,80000074 <state_transition+0x34> | `12-17/12-17/26/27/28`        | `00400064` b.eq   0x60                   | `13/-/16`        |
|  15 | `800000b4` lw	a2,0(a1)                                 | `15-19/18-19/27/31/32`        | `00400068` subs   w0, #2                 | `13/-/16`        |
|  16 | `800000b8` addi	a4,a5,1                                | `17-21/18-21/27/28/32`        | `0040006c` b.ne   0x184                  | `14/-/17`        |
|  17 | `800000bc` addiw	a2,a2,1                               | `18-22/18-22/32/33/34`        | `004001f0` subs   w2, #46                | `14/-/17`        |
|  18 | `800000c0` sw	a2,0(a1)                                 | `20-24/20-24/33/35/36`        | `004001f4` b.eq   0x114                  | `15/-/18`        |
|  19 | `800000c4` lbu	a2,1(a5)                                | `22-24/22-24/34/40/41`        | `004001f8` b.ls   0xbc                   | `15/-/18`        |
|  20 | `800000c8` beqz	a2,80000390 <state_transition+0x350>   | `23-26/23-26/41/42/43`        | `004001fc` sub   w2, w2, #48             | `23/-/26`        |
|  21 | `800000cc` lbu	a5,1(a5)                                | `25-27/27/42/46/47`           | `00400200` and   w2, w2, #255            | `25/-/28`        |
|  22 | `800000d0` zext.b	a2,a5                                | `25-27/27/46/47/48`           | `00400204` subs   w2, #9                 | `26/-/29`        |
|  23 | `800000d4` beq	a5,a3,80000348 <state_transition+0x308> | `27-32/27-32/48/49/50`        | `00400208` b.hi   0xbc                   | `27/-/30`        |
|  24 | `800000d8` li	a3,46                                    | `28-33/33/49/50/51`           | `0040020c` movz   w0, #4, #0             | `27/-/30`        |
|  25 | `800000dc` addiw	a5,a2,-48                             | `28-34/33-34/49/50/51`        | `00400210` ldr   x2, [x1]                | `28/29/31`       |
|  26 | `800000e0` zext.b	a5,a5                                | `33-41/33-41/51/52/53`        | `00400214` add   w2, w2, #1              | `30/-/33`        |
|  27 | `800000e4` li	a6,9                                     | `34-42/34-42/51/52/53`        | `00400218` str   x2, [x1]                | `31/33/33`       |
|  28 | `800000e8` beq	a2,a3,80000118 <state_transition+0xd8>  | `35-46/35-46/53/54/55`        | `0040021c` b   0x84                      | `32/-/35`        |
|  29 | `80000118` lw	a5,16(a1)                                | `47-48/47-48/54/58/59`        | `004002a0` ldrb   w2, [w3, #1]           | `33/34/36`       |
|  30 | `8000011c` addiw	a5,a5,1                               | `47-49/47-49/59/60/61`        | `004002a4` add   x4, x3, #1              | `34/-/37`        |
|  31 | `80000120` sw	a5,16(a1)                                | `47-49/47-49/60/62/63`        | `004002a8` cbz   w2, 0xffffffffffffff90  | `35/-/38`        |
|  32 | `80000124` lbu	a3,1(a4)                                | `49-51/49-51/61/67/68`        | `004002ac` orr   x3, xzr, x4             | `35/-/38`        |
|  33 | `80000128` addi	a5,a4,1                                | `50-51/50-51/61/62/68`        | `004002b0` b   0xfffffffffffffd94        | `36/-/39`        |
|  34 | `8000012c` beqz	a3,800003fc <state_transition+0x3bc>   | `50-53/50-53/68/69/70`        | `00400044` ldrb   w2, [w3]               | `38/39/40`       |
|  35 | `80000130` lbu	a4,1(a4)                                | `52-54/54/69/73/74`           | `00400048` subs   w2, #44                | `40/-/43`        |
|  36 | `80000134` li	a3,44                                    | `52-59/54-59/69/70/74`        | `0040004c` b.eq   0x23c                  | `41/-/44`        |
|  37 | `80000138` zext.b	a2,a4                                | `54-60/54-60/73/74/75`        | `00400050` subs   w0, #5                 | `41/-/44`        |
|  38 | `8000013c` beq	a4,a3,80000408 <state_transition+0x3c8> | `55-61/55-61/75/76/77`        | `00400054` b.eq   0xd0                   | `42/-/45`        |
|  39 | `80000140` mv	a4,a5                                    | `60-62/62/76/77/78`           | `00400058` subs   w0, #3                 | `42/-/45`        |
|  40 | `80000144` andi	a5,a2,223                              | `61-68/62-68/76/77/78`        | `0040005c` b.eq   0x100                  | `43/-/46`        |
|  41 | `80000148` li	a3,69                                    | `62-69/62-69/77/78/79`        | `00400060` subs   w0, #4                 | `43/-/46`        |
|  42 | `8000014c` bne	a5,a3,800001a8 <state_transition+0x168> | `63-69/63-69/79/80/81`        | `00400064` b.eq   0x60                   | `44/-/47`        |
|  43 | `800001a8` addiw	a2,a2,-48                             | `70-73/70-73/80/81/82`        | `004000c4` subs   w2, #46                | `46/-/49`        |
|  44 | `800001ac` zext.b	a2,a2                                | `70-75/70-75/82/83/84`        | `004000c8` b.eq   0x34                   | `47/-/50`        |
|  45 | `800001b0` li	a5,9                                     | `70-76/70-76/82/83/84`        | `004000fc` ldr   x0, [x1, #16]           | `56/57/58`       |
|  46 | `800001b4` bgeu	a5,a2,80000124 <state_transition+0xe4> | `74-76/74-76/84/85/86`        | `00400100` add   x4, x3, #1              | `58/-/61`        |
|  47 | `80000124` lbu	a3,1(a4)                                | `82/82/85/89/90`              | `00400104` add   w0, w0, #1              | `58/-/61`        |
|  48 | `80000128` addi	a5,a4,1                                | `82/82/85/86/90`              | `00400108` str   x0, [x1, #16]           | `59/62/62`       |
|  49 | `8000012c` beqz	a3,800003fc <state_transition+0x3bc>   | `82/82/90/91/92`              | `0040010c` ldrb   w0, [w3, #1]           | `62/63/65`       |
|  50 | `80000130` lbu	a4,1(a4)                                | `83/83/91/95/96`              | `00400110` cbz   w0, 0x22c               | `64/-/67`        |
|  51 | `80000134` li	a3,44                                    | `83/83/91/92/96`              | `00400114` ldrb   w2, [w3, #1]           | `64/65/67`       |
|  52 | `80000138` zext.b	a2,a4                                | `83-84/83-84/95/96/97`        | `00400118` orr   x3, xzr, x4             | `65/-/68`        |
|  53 | `8000013c` beq	a4,a3,80000408 <state_transition+0x3c8> | `84-85/84-85/97/98/99`        | `0040011c` subs   w2, #44                | `66/-/69`        |
|  54 | `80000140` mv	a4,a5                                    | `84-86/86/98/99/100`          | `00400120` b.eq   0x160                  | `67/-/70`        |
|  55 | `80000144` andi	a5,a2,223                              | `85-90/86-90/98/99/100`       | `00400124` orr   x0, xzr, x3             | `67/-/70`        |
|  56 | `80000148` li	a3,69                                    | `86-91/86-91/99/100/101`      | `00400128` and   w3, w2, #4294967263     | `68/-/71`        |
|  57 | `8000014c` bne	a5,a3,800001a8 <state_transition+0x168> | `87-91/87-91/101/102/103`     | `0040012c` subs   w3, #69                | `69/-/72`        |
|  58 | `800001a8` addiw	a2,a2,-48                             | `92-95/92-95/102/103/104`     | `00400130` b.ne   0x128                  | `70/-/73`        |
|  59 | `800001ac` zext.b	a2,a2                                | `92-97/92-97/104/105/106`     | `00400258` sub   w2, w2, #48             | `70/-/73`        |
|  60 | `800001b0` li	a5,9                                     | `92-98/92-98/104/105/106`     | `0040025c` and   w2, w2, #255            | `71/-/74`        |
|  61 | `800001b4` bgeu	a5,a2,80000124 <state_transition+0xe4> | `96-98/96-98/106/107/108`     | `00400260` subs   w2, #9                 | `72/-/75`        |
|  62 | `80000124` lbu	a3,1(a4)                                | `104/104/107/111/112`         | `00400264` b.hi   0x80                   | `73/-/76`        |
|  63 | `80000128` addi	a5,a4,1                                | `104/104/107/108/112`         | `00400268` ldrb   w2, [w0, #1]! {2 uops} | `73-74/74/76-77` |
|  64 | `8000012c` beqz	a3,800003fc <state_transition+0x3bc>   | `104/104/112/113/114`         | `0040026c` cbz   w2, 0xcc                | `75/-/78`        |
|  65 | `80000130` lbu	a4,1(a4)                                | `105/105/113/117/118`         | `00400270` ldrb   w2, [w0]               | `75/77/78`       |
|  66 | `80000134` li	a3,44                                    | `105/105/113/114/118`         | `00400274` subs   w2, #44                | `77/-/80`        |
|  67 | `80000138` zext.b	a2,a4                                | `105-106/105-106/117/118/119` | `00400278` b.ne   0xfffffffffffffeb0     | `78/-/81`        |
|  68 | `8000013c` beq	a4,a3,80000408 <state_transition+0x3c8> | `106-107/106-107/119/120/121` | `00400128` and   w3, w2, #4294967263     | `78/-/81`        |
|  69 | `80000140` mv	a4,a5                                    | `106-108/108/120/121/122`     | `0040012c` subs   w3, #69                | `79/-/82`        |
|  70 | `80000144` andi	a5,a2,223                              | `107-112/108-112/120/121/122` | `00400130` b.ne   0x128                  | `80/-/83`        |
|  71 | `80000148` li	a3,69                                    | `108-113/108-113/121/122/123` | `00400258` sub   w2, w2, #48             | `80/-/83`        |
|  72 | `8000014c` bne	a5,a3,800001a8 <state_transition+0x168> | `109-113/109-113/123/124/125` | `0040025c` and   w2, w2, #255            | `81/-/84`        |
|  73 | `800001a8` addiw	a2,a2,-48                             | `114-117/114-117/124/125/126` | `00400260` subs   w2, #9                 | `82/-/85`        |
|  74 | `800001ac` zext.b	a2,a2                                | `114-119/114-119/126/127/128` | `00400264` b.hi   0x80                   | `83/-/86`        |
|  75 | `800001b0` li	a5,9                                     | `114-120/114-120/126/127/128` | `00400268` ldrb   w2, [w0, #1]! {2 uops} | `83-84/84/86-87` |
|  76 | `800001b4` bgeu	a5,a2,80000124 <state_transition+0xe4> | `118-120/118-120/128/129/130` | `0040026c` cbz   w2, 0xcc                | `85/-/88`        |
|  77 | `80000124` lbu	a3,1(a4)                                | `126/126/129/133/134`         | `00400270` ldrb   w2, [w0]               | `85/87/88`       |
|  78 | `80000128` addi	a5,a4,1                                | `126/126/129/130/134`         | `00400274` subs   w2, #44                | `87/-/90`        |
|  79 | `8000012c` beqz	a3,800003fc <state_transition+0x3bc>   | `126/126/134/135/136`         | `00400278` b.ne   0xfffffffffffffeb0     | `88/-/91`        |
|  80 | `80000130` lbu	a4,1(a4)                                | `127/127/135/139/140`         | `00400128` and   w3, w2, #4294967263     | `88/-/91`        |
|  81 | `80000134` li	a3,44                                    | `127/127/135/136/140`         | `0040012c` subs   w3, #69                | `89/-/92`        |
|  82 | `80000138` zext.b	a2,a4                                | `127-128/127-128/139/140/141` | `00400130` b.ne   0x128                  | `90/-/93`        |
|  83 | `8000013c` beq	a4,a3,80000408 <state_transition+0x3c8> | `128-129/128-129/141/142/143` | `00400258` sub   w2, w2, #48             | `92/-/95`        |
|  84 | `80000140` mv	a4,a5                                    | `128-130/130/142/143/144`     | `0040025c` and   w2, w2, #255            | `93/-/96`        |
|  85 | `80000144` andi	a5,a2,223                              | `129-134/130-134/142/143/144` | `00400260` subs   w2, #9                 | `94/-/97`        |
|  86 | `80000148` li	a3,69                                    | `130-135/130-135/143/144/145` | `00400264` b.hi   0x80                   | `95/-/98`        |
|  87 | `8000014c` bne	a5,a3,800001a8 <state_transition+0x168> | `131-135/131-135/145/146/147` | `00400268` ldrb   w2, [w0, #1]! {2 uops} | `95-96/96/98-99` |
|  88 | `80000150` lw	a3,20(a1)                                | `135-139/136-139/146/150/151` | `0040026c` cbz   w2, 0xcc                | `97/-/100`       |
|  89 | `80000154` addi	a5,a4,1                                | `136-141/136-141/146/147/151` | `00400270` ldrb   w2, [w0]               | `97/99/100`      |
|  90 | `80000158` addiw	a3,a3,1                               | `136-142/136-142/151/152/153` | `00400274` subs   w2, #44                | `99/-/102`       |
|  91 | `8000015c` sw	a3,20(a1)                                | `140-142/140-142/152/154/155` | `00400278` b.ne   0xfffffffffffffeb0     | `100/-/103`      |
|  92 | `80000160` lbu	a3,1(a4)                                | `142-143/142-143/153/159/160` | `00400128` and   w3, w2, #4294967263     | `100/-/103`      |
|  93 | `80000164` beqz	a3,8000039c <state_transition+0x35c>   | `143-145/143-145/160/161/162` | `0040012c` subs   w3, #69                | `101/-/104`      |
|  94 | `80000168` lbu	a2,1(a4)                                | `143-146/146/161/165/166`     | `00400130` b.ne   0x128                  | `102/-/105`      |
|  95 | `8000016c` li	a6,44                                    | `144-146/146/161/162/166`     | `00400134` ldr   x2, [x1, #20]           | `110/111/112`    |
|  96 | `80000170` zext.b	a3,a2                                | `146-151/146-151/165/166/167` | `00400138` add   x3, x0, #1              | `111/-/114`      |
|  97 | `80000174` beq	a2,a6,800003a8 <state_transition+0x368> | `147-152/147-152/167/168/169` | `0040013c` add   w2, w2, #1              | `112/-/115`      |
|  98 | `80000178` lw	a2,12(a1)                                | `147-153/153/168/172/173`     | `00400140` str   x2, [x1, #20]           | `113/115/115`    |
|  99 | `8000017c` addiw	a5,a3,-43                             | `152-160/153-160/168/169/173` | `00400144` ldrb   w2, [w0, #1]           | `115/116/118`    |
| 100 | `80000180` andi	a5,a5,253                              | `153-161/153-161/173/174/175` | `00400148` cbz   w2, 0x1fc               | `117/-/120`      |

## Cycle-by-cycle backend pipe state

Instruction numbers refer to the table above. Empty cells are real bubbles within that core's selected window.

| Relative cycle | OpenRV64 issue | complete | retire  | ORV stalls                  | HPI issue | memory | commit  | HPI blocked oldest |
|---------------:|----------------|----------|---------|-----------------------------|-----------|--------|---------|--------------------|
|              0 | #1             |          |         | RAW                         | #1        |        |         |                    |
|              1 |                |          |         | RAW+NOISS+RETWAIT           | #2        |        |         | #3                 |
|              2 |                |          |         | RAW+NOISS+RETWAIT           |           |        |         | #3                 |
|              3 |                |          |         | RAW+NOISS+RETWAIT           |           | #1     |         | #3                 |
|              4 | #2             | #1       |         | RAW+WAW+RETWAIT             | #3        |        | #1/#2   |                    |
|              5 |                |          | #1      | RAW+WAW+NOISS               |           | #3     |         | #4                 |
|              6 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #4/#5     |        | #3      |                    |
|              7 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #6        |        |         |                    |
|              8 |                | #2       |         | WAW+NOISS+RETWAIT           |           | #6     |         | #7                 |
|              9 | #3             |          | #2      |                             | #7        |        | #4/#5   | #8                 |
|             10 | #4/#5          | #3       |         | RAW+RETWAIT                 | #8/#9     |        | #6      |                    |
|             11 |                | #5       | #3      | RAW+NOISS                   | #10/#11   |        |         |                    |
|             12 |                |          |         | RAW+NOISS+RETWAIT           | #12/#13   |        | #7      |                    |
|             13 |                |          |         | RAW+NOISS+RETWAIT           | #14/#15   |        | #8/#9   |                    |
|             14 | #6             | #4       |         | RETWAIT                     | #16/#17   |        | #10/#11 |                    |
|             15 |                | #6       | #4/#5   | RAW+NOISS                   | #18/#19   |        | #12/#13 |                    |
|             16 | #7             |          | #6      | RAW                         |           |        | #14/#15 |                    |
|             17 | #8             | #7       |         | RAW+RETWAIT                 |           |        | #16/#17 |                    |
|             18 |                | #8       | #7      | RPORT+NOISS                 |           |        | #18/#19 |                    |
|             19 | #9             |          | #8      | RPORT                       |           |        |         |                    |
|             20 |                | #9       |         | RAW+WAW+RPORT+NOISS+RETWAIT |           |        |         |                    |
|             21 | #10            |          | #9      | RAW+WAW+RPORT               |           |        |         |                    |
|             22 | #11            | #10      |         | RAW+WAW+RETWAIT             |           |        |         |                    |
|             23 |                | #11      | #10     | WAW+NOISS                   | #20       |        |         |                    |
|             24 | #12/#13        |          | #11     | RAW                         |           |        |         |                    |
|             25 |                | #12/#13  |         | WAW+NOISS+RETWAIT           | #21       |        |         | #22                |
|             26 | #14            |          | #12/#13 |                             | #22       |        | #20     | #23                |
|             27 | #15/#16        | #14      |         | RAW+WAW+RETWAIT             | #23/#24   |        |         |                    |
|             28 |                | #16      | #14     | RAW+WAW+NOISS               | #25       |        | #21     |                    |
|             29 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           | #25    | #22     | #26                |
|             30 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #26       |        | #23/#24 | #27                |
|             31 |                | #15      |         | WAW+NOISS+RETWAIT           | #27       |        | #25     |                    |
|             32 | #17            |          | #15/#16 | RAW+WAW                     | #28       |        |         | #29                |
|             33 | #18            | #17      |         | WAW+RETWAIT                 | #29       | #27    | #26/#27 |                    |
|             34 | #19            |          | #17     | RAW                         | #30       | #29    |         | #31                |
|             35 |                | #18      |         | RAW+WAW+NOISS+RETWAIT       | #31/#32   |        | #28     |                    |
|             36 |                |          | #18     | RAW+WAW+NOISS               | #33       |        | #29     |                    |
|             37 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        | #30     |                    |
|             38 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #34       |        | #31/#32 |                    |
|             39 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           | #34    | #33     | #35                |
|             40 |                | #19      |         | RAW+WAW+NOISS+RETWAIT       | #35       |        | #34     | #36                |
|             41 | #20            |          | #19     | RAW                         | #36/#37   |        |         |                    |
|             42 | #21            | #20      |         | RAW+RETWAIT                 | #38/#39   |        |         |                    |
|             43 |                |          | #20     | RAW+NOISS                   | #40/#41   |        | #35     |                    |
|             44 |                |          |         | RAW+NOISS+RETWAIT           | #42       |        | #36/#37 |                    |
|             45 |                |          |         | RAW+NOISS+RETWAIT           |           |        | #38/#39 |                    |
|             46 | #22            | #21      |         | RETWAIT                     | #43       |        | #40/#41 | #44                |
|             47 |                | #22      | #21     | NOISS                       | #44       |        | #42     |                    |
|             48 | #23            |          | #22     |                             |           |        |         |                    |
|             49 | #24/#25        | #23      |         | RAW+WAW+RETWAIT             |           |        | #43     |                    |
|             50 |                | #24/#25  | #23     | WAW+NOISS                   |           |        | #44     |                    |
|             51 | #26/#27        |          | #24/#25 |                             |           |        |         |                    |
|             52 |                | #26/#27  |         | WAW+NOISS+RETWAIT           |           |        |         |                    |
|             53 | #28            |          | #26/#27 | RAW+WAW                     |           |        |         |                    |
|             54 | #29            | #28      |         | RAW+WAW+RETWAIT             |           |        |         |                    |
|             55 |                |          | #28     | RAW+WAW+NOISS               |           |        |         |                    |
|             56 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #45       |        |         |                    |
|             57 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           | #45    |         |                    |
|             58 |                | #29      |         | WAW+NOISS+RETWAIT           | #46/#47   |        | #45     |                    |
|             59 | #30            |          | #29     | RAW                         | #48       |        |         |                    |
|             60 | #31            | #30      |         | WAW+RETWAIT                 |           |        |         | #49                |
|             61 | #32/#33        |          | #30     | RAW                         |           |        | #46/#47 | #49                |
|             62 |                | #31/#33  |         | RAW+WAW+NOISS+RETWAIT       | #49       | #48    | #48     |                    |
|             63 |                |          | #31     | RAW+WAW+NOISS               |           | #49    |         | #50                |
|             64 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #50/#51   |        |         |                    |
|             65 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #52       | #51    | #49     | #53                |
|             66 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #53       |        |         | #54                |
|             67 |                | #32      |         | WAW+NOISS+RETWAIT           | #54/#55   |        | #50/#51 |                    |
|             68 | #34            |          | #32/#33 |                             | #56       |        | #52     | #57                |
|             69 | #35/#36        | #34      |         | RAW+RETWAIT                 | #57       |        | #53     | #58                |
|             70 |                | #36      | #34     | RAW+WAW+NOISS               | #58/#59   |        | #54/#55 |                    |
|             71 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #60       |        | #56     | #61                |
|             72 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #61       |        | #57     | #62                |
|             73 | #37            | #35      |         | WAW+RETWAIT                 | #62/#63   |        | #58/#59 |                    |
|             74 |                | #37      | #35/#36 | NOISS                       | #63       | #63    | #60     | #64                |
|             75 | #38            |          | #37     |                             | #64/#65   |        | #61     |                    |
|             76 | #39/#40        | #38      |         | RETWAIT                     |           |        | #62/#63 | #66                |
|             77 | #41            | #39/#40  | #38     | RAW                         | #66       | #65    | #63     | #67                |
|             78 |                | #41      | #39/#40 | RAW+WAW+NOISS               | #67/#68   |        | #64/#65 |                    |
|             79 | #42            |          | #41     | RAW+WAW                     | #69       |        |         | #70                |
|             80 | #43            | #42      |         | RAW+WAW+RETWAIT             | #70/#71   |        | #66     |                    |
|             81 |                | #43      | #42     | WAW+NOISS                   | #72       |        | #67/#68 | #73                |
|             82 | #44/#45        |          | #43     | RAW                         | #73       |        | #69     | #74                |
|             83 |                | #44/#45  |         | WAW+NOISS+RETWAIT           | #74/#75   |        | #70/#71 |                    |
|             84 | #46            |          | #44/#45 |                             | #75       | #75    | #72     | #76                |
|             85 | #47/#48        | #46      |         | RAW+RETWAIT                 | #76/#77   |        | #73     |                    |
|             86 |                | #48      | #46     | RAW+WAW+NOISS               |           |        | #74/#75 | #78                |
|             87 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #78       | #77    | #75     | #79                |
|             88 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #79/#80   |        | #76/#77 |                    |
|             89 |                | #47      |         | WAW+NOISS+RETWAIT           | #81       |        |         | #82                |
|             90 | #49            |          | #47/#48 |                             | #82       |        | #78     |                    |
|             91 | #50/#51        | #49      |         | RAW+RETWAIT                 |           |        | #79/#80 |                    |
|             92 |                | #51      | #49     | RAW+WAW+NOISS               | #83       |        | #81     | #84                |
|             93 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #84       |        | #82     | #85                |
|             94 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #85       |        |         | #86                |
|             95 | #52            | #50      |         | WAW+RETWAIT                 | #86/#87   |        | #83     |                    |
|             96 |                | #52      | #50/#51 | NOISS                       | #87       | #87    | #84     | #88                |
|             97 | #53            |          | #52     |                             | #88/#89   |        | #85     |                    |
|             98 | #54/#55        | #53      |         | RETWAIT                     |           |        | #86/#87 | #90                |
|             99 | #56            | #54/#55  | #53     | RAW                         | #90       | #89    | #87     | #91                |
|            100 |                | #56      | #54/#55 | RAW+WAW+NOISS               | #91/#92   |        | #88/#89 |                    |
|            101 | #57            |          | #56     | RAW+WAW                     | #93       |        |         | #94                |
|            102 | #58            | #57      |         | RAW+WAW+RETWAIT             | #94       |        | #90     |                    |
|            103 |                | #58      | #57     | WAW+NOISS                   |           |        | #91/#92 |                    |
|            104 | #59/#60        |          | #58     | RAW                         |           |        | #93     |                    |
|            105 |                | #59/#60  |         | WAW+NOISS+RETWAIT           |           |        | #94     |                    |
|            106 | #61            |          | #59/#60 |                             |           |        |         |                    |
|            107 | #62/#63        | #61      |         | RAW+RETWAIT                 |           |        |         |                    |
|            108 |                | #63      | #61     | RAW+WAW+NOISS               |           |        |         |                    |
|            109 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            110 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #95       |        |         |                    |
|            111 |                | #62      |         | WAW+NOISS+RETWAIT           | #96       | #95    |         | #97                |
|            112 | #64            |          | #62/#63 |                             | #97       |        | #95     | #98                |
|            113 | #65/#66        | #64      |         | RAW+RETWAIT                 | #98       |        |         |                    |
|            114 |                | #66      | #64     | RAW+WAW+NOISS               |           |        | #96     | #99                |
|            115 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #99       | #98    | #97/#98 |                    |
|            116 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           | #99    |         | #100               |
|            117 | #67            | #65      |         | WAW+RETWAIT                 | #100      |        |         |                    |
|            118 |                | #67      | #65/#66 | NOISS                       |           |        | #99     |                    |
|            119 | #68            |          | #67     |                             |           |        |         |                    |
|            120 | #69/#70        | #68      |         | RETWAIT                     |           |        | #100    |                    |
|            121 | #71            | #69/#70  | #68     | RAW                         |           |        |         |                    |
|            122 |                | #71      | #69/#70 | RAW+WAW+NOISS               |           |        |         |                    |
|            123 | #72            |          | #71     | RAW+WAW                     |           |        |         |                    |
|            124 | #73            | #72      |         | RAW+WAW+RETWAIT             |           |        |         |                    |
|            125 |                | #73      | #72     | WAW+NOISS                   |           |        |         |                    |
|            126 | #74/#75        |          | #73     | RAW                         |           |        |         |                    |
|            127 |                | #74/#75  |         | WAW+NOISS+RETWAIT           |           |        |         |                    |
|            128 | #76            |          | #74/#75 |                             |           |        |         |                    |
|            129 | #77/#78        | #76      |         | RAW+RETWAIT                 |           |        |         |                    |
|            130 |                | #78      | #76     | RAW+WAW+NOISS               |           |        |         |                    |
|            131 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            132 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            133 |                | #77      |         | WAW+NOISS+RETWAIT           |           |        |         |                    |
|            134 | #79            |          | #77/#78 |                             |           |        |         |                    |
|            135 | #80/#81        | #79      |         | RAW+RETWAIT                 |           |        |         |                    |
|            136 |                | #81      | #79     | RAW+WAW+NOISS               |           |        |         |                    |
|            137 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            138 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            139 | #82            | #80      |         | WAW+RETWAIT                 |           |        |         |                    |
|            140 |                | #82      | #80/#81 | NOISS                       |           |        |         |                    |
|            141 | #83            |          | #82     |                             |           |        |         |                    |
|            142 | #84/#85        | #83      |         | RETWAIT                     |           |        |         |                    |
|            143 | #86            | #84/#85  | #83     | RAW+WAW                     |           |        |         |                    |
|            144 |                | #86      | #84/#85 | WAW+NOISS                   |           |        |         |                    |
|            145 | #87            |          | #86     |                             |           |        |         |                    |
|            146 | #88/#89        | #87      |         | RAW+WAW+RETWAIT             |           |        |         |                    |
|            147 |                | #89      | #87     | RAW+WAW+NOISS               |           |        |         |                    |
|            148 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            149 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            150 |                | #88      |         | WAW+NOISS+RETWAIT           |           |        |         |                    |
|            151 | #90            |          | #88/#89 | RAW+WAW                     |           |        |         |                    |
|            152 | #91            | #90      |         | WAW+RETWAIT                 |           |        |         |                    |
|            153 | #92            |          | #90     | RAW                         |           |        |         |                    |
|            154 |                | #91      |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|            155 |                |          | #91     | RAW+NOISS                   |           |        |         |                    |
|            156 |                |          |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|            157 |                |          |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|            158 |                |          |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|            159 |                | #92      |         | NOISS+RETWAIT               |           |        |         |                    |
|            160 | #93            |          | #92     |                             |           |        |         |                    |
|            161 | #94/#95        | #93      |         | RAW+RETWAIT                 |           |        |         |                    |
|            162 |                | #95      | #93     | RAW+WAW+NOISS               |           |        |         |                    |
|            163 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            164 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            165 | #96            | #94      |         | WAW+RETWAIT                 |           |        |         |                    |
|            166 |                | #96      | #94/#95 | NOISS                       |           |        |         |                    |
|            167 | #97            |          | #96     |                             |           |        |         |                    |
|            168 | #98/#99        | #97      |         | RAW+WAW+RETWAIT             |           |        |         |                    |
|            169 |                | #99      | #97     | RAW+WAW+NOISS               |           |        |         |                    |
|            170 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            171 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            172 |                | #98      |         | WAW+NOISS+RETWAIT           |           |        |         |                    |
|            173 | #100           |          | #98/#99 | RAW                         |           |        |         |                    |
|            174 |                | #100     |         | RETWAIT                     |           |        |         |                    |
|            175 |                |          | #100    | NOISS                       |           |        |         |                    |
