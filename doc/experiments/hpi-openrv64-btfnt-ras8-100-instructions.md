# OpenRV64 versus HPI: matched 100-instruction pipeline window

This report starts at the 54th dynamic call to `state_transition` in both binaries. The call ordinal aligns the logical workload position; row numbers do not claim ISA-level instruction equivalence.

Observed entry calls: OpenRV64 720, HPI 720.

## Matched-call and 100-instruction summary

| Measurement                                          | OpenRV64 3P BTFNT + RAS8 |         gem5 HPI |
|------------------------------------------------------|-------------------------:|-----------------:|
| Instructions in matched `state_transition` call      |                      132 |              135 |
| Issue-through-retire/commit cycles for matched call  |                      241 |              148 |
| Local matched-call IPC                               |                    0.548 |            0.912 |
| Cycles spanning the selected 100 instructions        |                      183 |              121 |
| Local 100-instruction IPC                            |                    0.546 |            0.826 |
| Issued backend micro-ops for those 100 instructions  |                      100 |              103 |
| Cycles with selected issue / without selected issue  |                 70 / 113 |          77 / 44 |
| Loads / stores / controls / other                    |         19 / 3 / 25 / 53 | 17 / 3 / 33 / 47 |
| One-wide / two-wide / three-wide issue cycles        |              40 / 30 / 0 |    48 / 26 / n/a |
| Cycles where selected oldest instruction was blocked |                      n/a |               45 |

The width row counts architectural instruction starts. The micro-op row exposes decomposed AArch64 instructions, including pre-indexed loads; these are not free single-operation backend work in HPI.

## OpenRV64 stall exposure in this 100-instruction span

Counters overlap: one cycle can carry several causes.

| Condition        | Cycles | Percent of 183-cycle span |
|------------------|-------:|--------------------------:|
| frontend empty   |     15 |                      8.2% |
| frontend held    |     88 |                     48.1% |
| dispatch empty   |     12 |                      6.6% |
| queued, no issue |    100 |                     54.6% |
| RAW              |    137 |                     74.9% |
| WAW              |     95 |                     51.9% |
| read port        |      2 |                      1.1% |
| barrier          |      0 |                      0.0% |
| retire wait      |    109 |                     59.6% |
| BP fetch stall   |      0 |                      0.0% |
| redirect         |      7 |                      3.8% |

## What this window shows

- Instruction count is not the primary deficit. For the same dynamic call HPI executes 3 more architectural instructions yet takes 93 fewer cycles.
- Pre/post-increment is not a hidden one-uop advantage here. HPI decomposes the pre-indexed loads shown below into two issued micro-ops.
- Compare/branch fusion is not required to explain HPI's lead. Its trace issues separate `subs` and conditional-branch instructions; it frequently overlaps the branch with the next independent `subs`.
- The dominant deficit is scheduling and availability: OpenRV64 spends long runs with queued instructions but no issue, and its load-to-use chains expose the full memory-pipe completion latency.
- The predictor never explicitly stalls fetch in this span, but there are 7 correction redirects. Prediction is therefore not free, but it is not large enough to explain the 62-cycle window gap by itself.

## Pipe-state examples and implicated mechanisms

- OpenRV64 rows 1-3 form a true load chain: `ld` issues at 0 and completes at 4, dependent `lbu` issues at 5 and completes at 9, and the branch issues at 10. HPI fills part of the corresponding interval with an independent `orr`, then issues `cbz` and the next independent `movz` together at relative cycle 6.
- OpenRV64 row 11 writes `a2` at issue 22, completes at 23, and retires at 24. Row 12 also writes `a2` and does not issue until 24: RAW forwarding would not remove a destination-ownership WAW stall. HPI rows 9, 11, 13, and 15 repeatedly write `w0` and start on consecutive cycles 10-13, committing later on cycles 13-16.
- HPI starts an older conditional branch and the next younger `subs` together on cycles 10, 11, 12, and 13. OpenRV64 now resolves aligned conditional branches before retirement and can place a branch behind older work in the same issue group, but the branch still terminates that group. It therefore cannot use the second ALU for a younger instruction after the branch as HPI repeatedly does here.
- OpenRV64's issue chooser is a strict prefix: candidate 1 requires candidate 0 to fire and candidate 2 requires candidate 1. It cannot use an idle lane around an oldest blocked load, WAW, branch, or fixed-lane conflict. HPI is also in-order, but its latency-aware scoreboard and input buffering make the oldest-blocked intervals materially shorter.
- `RETWAIT` is visible on 109 of 183 cycles. This does not mean retirement alone owns all of those cycles—the counters overlap—but it shows how often the finite in-order retirement window contains work without completing its oldest contiguous prefix.
- This selected window is inside `state_transition`, not at a return. The RAS improves call-boundary behavior in the full run but does not remove the dependency and scheduling bubbles shown here.

## Where the matched-call cycle gap is largest

There are 160 matched calls with at least 100 architectural instructions on both ISAs. Across those calls, OpenRV64 local IPC has median 0.533; HPI's median is 0.888. The selected call ranks 7 by absolute cycle gap.

| Call occurrence | ORV instructions | ORV cycles | ORV IPC | HPI instructions | HPI cycles | HPI IPC | ORV minus HPI cycles |
|----------------:|-----------------:|-----------:|--------:|-----------------:|-----------:|--------:|---------------------:|
|             230 |              132 |        238 |   0.555 |              135 |        141 |   0.957 |                  +97 |
|             320 |              132 |        238 |   0.555 |              135 |        141 |   0.957 |                  +97 |
|             410 |              132 |        238 |   0.555 |              135 |        141 |   0.957 |                  +97 |
|             500 |              132 |        238 |   0.555 |              135 |        141 |   0.957 |                  +97 |
|             590 |              132 |        238 |   0.555 |              135 |        141 |   0.957 |                  +97 |
|             680 |              132 |        238 |   0.555 |              135 |        141 |   0.957 |                  +97 |
|              54 |              132 |        241 |   0.548 |              135 |        148 |   0.912 |                  +93 |
|              99 |              132 |        241 |   0.548 |              135 |        148 |   0.912 |                  +93 |
|             144 |              132 |        241 |   0.548 |              135 |        148 |   0.912 |                  +93 |
|             189 |              132 |        241 |   0.548 |              135 |        148 |   0.912 |                  +93 |

Stage cycles below are relative to each core's first issue in the window. OpenRV64 shows fetch/decode/issue/complete/retire; HPI's reliable per-instruction events from `MinorExecute` are issue, memory launch (`M`), and ordered commit (`K`).

OpenRV64 `F` and `D` ranges are valid-presentation intervals, not request-to-response latency. For example, `F=0-9` means the same already-fetched instruction was visible through cycle 9 while downstream backpressure prevented acceptance. The trace does not attach an individual AXI line-request start to each instruction.

## 100 dynamic instructions side by side

|   # | OpenRV64 PC and instruction                            | F/D/I/C/R                     | HPI PC and instruction                   | I/M/K            |
|----:|--------------------------------------------------------|-------------------------------|------------------------------------------|------------------|
|   1 | `80000040` ld	a5,0(a0)                                 | `-1/-1/0/4/5`                 | `00400030` ldr   x3, [x0]                | `0/3/4`          |
|   2 | `80000044` lbu	a4,0(a5)                                | `-1/-1/5/9/10`                | `00400034` orr   x6, xzr, x0             | `1/-/4`          |
|   3 | `80000048` beqz	a4,80000384 <state_transition+0x344>   | `-1/-1/10/11/12`              | `00400038` ldrb   w0, [w3]               | `4/5/6`          |
|   4 | `8000004c` lbu	a4,0(a5)                                | `0/0/11/15/16`                | `0040003c` cbz   w0, 0x2f4               | `6/-/9`          |
|   5 | `80000050` li	a3,44                                    | `0/0/11/12/16`                | `00400040` movz   w0, #0, #0             | `6/-/9`          |
|   6 | `80000054` zext.b	a2,a4                                | `0/0/16/17/18`                | `00400044` ldrb   w2, [w3]               | `7/8/10`         |
|   7 | `80000058` beq	a4,a3,800002c4 <state_transition+0x284> | `1/1/16/17/18`                | `00400048` subs   w2, #44                | `9/-/12`         |
|   8 | `8000005c` li	a6,46                                    | `1-5/2-5/17/18/19`            | `0040004c` b.eq   0x23c                  | `10/-/13`        |
|   9 | `80000060` beq	a2,a6,80000290 <state_transition+0x250> | `1-10/2-10/19/20/21`          | `00400050` subs   w0, #5                 | `10/-/13`        |
|  10 | `80000064` bltu	a6,a2,800000a4 <state_transition+0x64> | `2-11/11/20/21/22`            | `00400054` b.eq   0xd0                   | `11/-/14`        |
|  11 | `800000a4` addiw	a2,a2,-48                             | `21/21/22/23/24`              | `00400058` subs   w0, #3                 | `11/-/14`        |
|  12 | `800000a8` zext.b	a2,a2                                | `21/21/24/25/26`              | `0040005c` b.eq   0x100                  | `12/-/15`        |
|  13 | `800000ac` li	a4,9                                     | `21/21/24/25/26`              | `00400060` subs   w0, #4                 | `12/-/15`        |
|  14 | `800000b0` bltu	a4,a2,80000074 <state_transition+0x34> | `22/22/26/27/28`              | `00400064` b.eq   0x60                   | `13/-/16`        |
|  15 | `800000b4` lw	a2,0(a1)                                 | `27/27/28/32/33`              | `00400068` subs   w0, #2                 | `13/-/16`        |
|  16 | `800000b8` addi	a4,a5,1                                | `27/27/28/29/33`              | `0040006c` b.ne   0x184                  | `14/-/17`        |
|  17 | `800000bc` addiw	a2,a2,1                               | `27/27/33/34/35`              | `004001f0` subs   w2, #46                | `14/-/17`        |
|  18 | `800000c0` sw	a2,0(a1)                                 | `28/28/35/37/38`              | `004001f4` b.eq   0x114                  | `15/-/18`        |
|  19 | `800000c4` lbu	a2,1(a5)                                | `28/28/36/42/43`              | `004001f8` b.ls   0xbc                   | `15/-/18`        |
|  20 | `800000c8` beqz	a2,80000390 <state_transition+0x350>   | `28/28/43/44/45`              | `004001fc` sub   w2, w2, #48             | `23/-/26`        |
|  21 | `800000cc` lbu	a5,1(a5)                                | `29/29/44/48/49`              | `00400200` and   w2, w2, #255            | `25/-/28`        |
|  22 | `800000d0` zext.b	a2,a5                                | `29/29/49/50/51`              | `00400204` subs   w2, #9                 | `26/-/29`        |
|  23 | `800000d4` beq	a5,a3,80000348 <state_transition+0x308> | `29-33/29-33/49/50/51`        | `00400208` b.hi   0xbc                   | `27/-/30`        |
|  24 | `800000d8` li	a3,46                                    | `30-35/34-35/50/51/52`        | `0040020c` movz   w0, #4, #0             | `27/-/30`        |
|  25 | `800000dc` addiw	a5,a2,-48                             | `30-36/34-36/50/51/52`        | `00400210` ldr   x2, [x1]                | `28/29/31`       |
|  26 | `800000e0` zext.b	a5,a5                                | `34-43/34-43/52/53/54`        | `00400214` add   w2, w2, #1              | `30/-/33`        |
|  27 | `800000e4` li	a6,9                                     | `36-44/36-44/52/53/54`        | `00400218` str   x2, [x1]                | `31/33/33`       |
|  28 | `800000e8` beq	a2,a3,80000118 <state_transition+0xd8>  | `37-49/37-49/53/54/55`        | `0040021c` b   0x84                      | `32/-/35`        |
|  29 | `80000118` lw	a5,16(a1)                                | `54/54/55/59/60`              | `004002a0` ldrb   w2, [w3, #1]           | `33/34/36`       |
|  30 | `8000011c` addiw	a5,a5,1                               | `54/54/60/61/62`              | `004002a4` add   x4, x3, #1              | `34/-/37`        |
|  31 | `80000120` sw	a5,16(a1)                                | `54/54/62/64/65`              | `004002a8` cbz   w2, 0xffffffffffffff90  | `35/-/38`        |
|  32 | `80000124` lbu	a3,1(a4)                                | `55/55/63/69/70`              | `004002ac` orr   x3, xzr, x4             | `35/-/38`        |
|  33 | `80000128` addi	a5,a4,1                                | `55/55/63/64/70`              | `004002b0` b   0xfffffffffffffd94        | `36/-/39`        |
|  34 | `8000012c` beqz	a3,800003fc <state_transition+0x3bc>   | `55/55/70/71/72`              | `00400044` ldrb   w2, [w3]               | `38/39/40`       |
|  35 | `80000130` lbu	a4,1(a4)                                | `56/56/71/75/76`              | `00400048` subs   w2, #44                | `40/-/43`        |
|  36 | `80000134` li	a3,44                                    | `56-60/56-60/71/72/76`        | `0040004c` b.eq   0x23c                  | `41/-/44`        |
|  37 | `80000138` zext.b	a2,a4                                | `56-62/56-62/76/77/78`        | `00400050` subs   w0, #5                 | `41/-/44`        |
|  38 | `8000013c` beq	a4,a3,80000408 <state_transition+0x3c8> | `57-63/57-63/76/77/78`        | `00400054` b.eq   0xd0                   | `42/-/45`        |
|  39 | `80000140` mv	a4,a5                                    | `61-64/64/77/78/79`           | `00400058` subs   w0, #3                 | `42/-/45`        |
|  40 | `80000144` andi	a5,a2,223                              | `63-70/64-70/77/78/79`        | `0040005c` b.eq   0x100                  | `43/-/46`        |
|  41 | `80000148` li	a3,69                                    | `64-71/64-71/78/79/80`        | `00400060` subs   w0, #4                 | `43/-/46`        |
|  42 | `8000014c` bne	a5,a3,800001a8 <state_transition+0x168> | `65-71/65-71/80/81/82`        | `00400064` b.eq   0x60                   | `44/-/47`        |
|  43 | `800001a8` addiw	a2,a2,-48                             | `81/81/82/83/84`              | `004000c4` subs   w2, #46                | `46/-/49`        |
|  44 | `800001ac` zext.b	a2,a2                                | `81/81/84/85/86`              | `004000c8` b.eq   0x34                   | `47/-/50`        |
|  45 | `800001b0` li	a5,9                                     | `81/81/84/85/86`              | `004000fc` ldr   x0, [x1, #16]           | `56/57/58`       |
|  46 | `800001b4` bgeu	a5,a2,80000124 <state_transition+0xe4> | `82/82/86/87/88`              | `00400100` add   x4, x3, #1              | `58/-/61`        |
|  47 | `80000124` lbu	a3,1(a4)                                | `88/88/89/93/94`              | `00400104` add   w0, w0, #1              | `58/-/61`        |
|  48 | `80000128` addi	a5,a4,1                                | `88/88/89/90/94`              | `00400108` str   x0, [x1, #16]           | `59/62/62`       |
|  49 | `8000012c` beqz	a3,800003fc <state_transition+0x3bc>   | `88/88/94/95/96`              | `0040010c` ldrb   w0, [w3, #1]           | `62/63/65`       |
|  50 | `80000130` lbu	a4,1(a4)                                | `89/89/95/99/100`             | `00400110` cbz   w0, 0x22c               | `64/-/67`        |
|  51 | `80000134` li	a3,44                                    | `89/89/95/96/100`             | `00400114` ldrb   w2, [w3, #1]           | `64/65/67`       |
|  52 | `80000138` zext.b	a2,a4                                | `89/89/100/101/102`           | `00400118` orr   x3, xzr, x4             | `65/-/68`        |
|  53 | `8000013c` beq	a4,a3,80000408 <state_transition+0x3c8> | `90/90/100/101/102`           | `0040011c` subs   w2, #44                | `66/-/69`        |
|  54 | `80000140` mv	a4,a5                                    | `90-91/91/101/102/103`        | `00400120` b.eq   0x160                  | `67/-/70`        |
|  55 | `80000144` andi	a5,a2,223                              | `90-94/91-94/101/102/103`     | `00400124` orr   x0, xzr, x3             | `67/-/70`        |
|  56 | `80000148` li	a3,69                                    | `91-95/91-95/102/103/104`     | `00400128` and   w3, w2, #4294967263     | `68/-/71`        |
|  57 | `8000014c` bne	a5,a3,800001a8 <state_transition+0x168> | `92-95/92-95/104/105/106`     | `0040012c` subs   w3, #69                | `69/-/72`        |
|  58 | `800001a8` addiw	a2,a2,-48                             | `105/105/106/107/108`         | `00400130` b.ne   0x128                  | `70/-/73`        |
|  59 | `800001ac` zext.b	a2,a2                                | `105/105/108/109/110`         | `00400258` sub   w2, w2, #48             | `70/-/73`        |
|  60 | `800001b0` li	a5,9                                     | `105/105/108/109/110`         | `0040025c` and   w2, w2, #255            | `71/-/74`        |
|  61 | `800001b4` bgeu	a5,a2,80000124 <state_transition+0xe4> | `106/106/110/111/112`         | `00400260` subs   w2, #9                 | `72/-/75`        |
|  62 | `80000124` lbu	a3,1(a4)                                | `112/112/113/117/118`         | `00400264` b.hi   0x80                   | `73/-/76`        |
|  63 | `80000128` addi	a5,a4,1                                | `112/112/113/114/118`         | `00400268` ldrb   w2, [w0, #1]! {2 uops} | `73-74/74/76-77` |
|  64 | `8000012c` beqz	a3,800003fc <state_transition+0x3bc>   | `112/112/118/119/120`         | `0040026c` cbz   w2, 0xcc                | `75/-/78`        |
|  65 | `80000130` lbu	a4,1(a4)                                | `113/113/119/123/124`         | `00400270` ldrb   w2, [w0]               | `75/77/78`       |
|  66 | `80000134` li	a3,44                                    | `113/113/119/120/124`         | `00400274` subs   w2, #44                | `77/-/80`        |
|  67 | `80000138` zext.b	a2,a4                                | `113/113/124/125/126`         | `00400278` b.ne   0xfffffffffffffeb0     | `78/-/81`        |
|  68 | `8000013c` beq	a4,a3,80000408 <state_transition+0x3c8> | `114/114/124/125/126`         | `00400128` and   w3, w2, #4294967263     | `78/-/81`        |
|  69 | `80000140` mv	a4,a5                                    | `114-115/115/125/126/127`     | `0040012c` subs   w3, #69                | `79/-/82`        |
|  70 | `80000144` andi	a5,a2,223                              | `114-118/115-118/125/126/127` | `00400130` b.ne   0x128                  | `80/-/83`        |
|  71 | `80000148` li	a3,69                                    | `115-119/115-119/126/127/128` | `00400258` sub   w2, w2, #48             | `80/-/83`        |
|  72 | `8000014c` bne	a5,a3,800001a8 <state_transition+0x168> | `116-119/116-119/128/129/130` | `0040025c` and   w2, w2, #255            | `81/-/84`        |
|  73 | `800001a8` addiw	a2,a2,-48                             | `129/129/130/131/132`         | `00400260` subs   w2, #9                 | `82/-/85`        |
|  74 | `800001ac` zext.b	a2,a2                                | `129/129/132/133/134`         | `00400264` b.hi   0x80                   | `83/-/86`        |
|  75 | `800001b0` li	a5,9                                     | `129/129/132/133/134`         | `00400268` ldrb   w2, [w0, #1]! {2 uops} | `83-84/84/86-87` |
|  76 | `800001b4` bgeu	a5,a2,80000124 <state_transition+0xe4> | `130/130/134/135/136`         | `0040026c` cbz   w2, 0xcc                | `85/-/88`        |
|  77 | `80000124` lbu	a3,1(a4)                                | `136/136/137/141/142`         | `00400270` ldrb   w2, [w0]               | `85/87/88`       |
|  78 | `80000128` addi	a5,a4,1                                | `136/136/137/138/142`         | `00400274` subs   w2, #44                | `87/-/90`        |
|  79 | `8000012c` beqz	a3,800003fc <state_transition+0x3bc>   | `136/136/142/143/144`         | `00400278` b.ne   0xfffffffffffffeb0     | `88/-/91`        |
|  80 | `80000130` lbu	a4,1(a4)                                | `137/137/143/147/148`         | `00400128` and   w3, w2, #4294967263     | `88/-/91`        |
|  81 | `80000134` li	a3,44                                    | `137/137/143/144/148`         | `0040012c` subs   w3, #69                | `89/-/92`        |
|  82 | `80000138` zext.b	a2,a4                                | `137/137/148/149/150`         | `00400130` b.ne   0x128                  | `90/-/93`        |
|  83 | `8000013c` beq	a4,a3,80000408 <state_transition+0x3c8> | `138/138/148/149/150`         | `00400258` sub   w2, w2, #48             | `92/-/95`        |
|  84 | `80000140` mv	a4,a5                                    | `138-139/139/149/150/151`     | `0040025c` and   w2, w2, #255            | `93/-/96`        |
|  85 | `80000144` andi	a5,a2,223                              | `138-142/139-142/149/150/151` | `00400260` subs   w2, #9                 | `94/-/97`        |
|  86 | `80000148` li	a3,69                                    | `139-143/139-143/150/151/152` | `00400264` b.hi   0x80                   | `95/-/98`        |
|  87 | `8000014c` bne	a5,a3,800001a8 <state_transition+0x168> | `140-143/140-143/152/153/154` | `00400268` ldrb   w2, [w0, #1]! {2 uops} | `95-96/96/98-99` |
|  88 | `80000150` lw	a3,20(a1)                                | `143-148/144-148/153/157/158` | `0040026c` cbz   w2, 0xcc                | `97/-/100`       |
|  89 | `80000154` addi	a5,a4,1                                | `144-148/144-148/153/154/158` | `00400270` ldrb   w2, [w0]               | `97/99/100`      |
|  90 | `80000158` addiw	a3,a3,1                               | `144-149/144-149/158/159/160` | `00400274` subs   w2, #44                | `99/-/102`       |
|  91 | `8000015c` sw	a3,20(a1)                                | `149/149/160/162/163`         | `00400278` b.ne   0xfffffffffffffeb0     | `100/-/103`      |
|  92 | `80000160` lbu	a3,1(a4)                                | `149-150/149-150/161/167/168` | `00400128` and   w3, w2, #4294967263     | `100/-/103`      |
|  93 | `80000164` beqz	a3,8000039c <state_transition+0x35c>   | `150-152/150-152/168/169/170` | `0040012c` subs   w3, #69                | `101/-/104`      |
|  94 | `80000168` lbu	a2,1(a4)                                | `150-153/153/169/173/174`     | `00400130` b.ne   0x128                  | `102/-/105`      |
|  95 | `8000016c` li	a6,44                                    | `151-153/153/169/170/174`     | `00400134` ldr   x2, [x1, #20]           | `110/111/112`    |
|  96 | `80000170` zext.b	a3,a2                                | `153-158/153-158/174/175/176` | `00400138` add   x3, x0, #1              | `111/-/114`      |
|  97 | `80000174` beq	a2,a6,800003a8 <state_transition+0x368> | `154-160/154-160/174/175/176` | `0040013c` add   w2, w2, #1              | `112/-/115`      |
|  98 | `80000178` lw	a2,12(a1)                                | `154-161/161/175/179/180`     | `00400140` str   x2, [x1, #20]           | `113/115/115`    |
|  99 | `8000017c` addiw	a5,a3,-43                             | `159-168/161-168/175/176/180` | `00400144` ldrb   w2, [w0, #1]           | `115/116/118`    |
| 100 | `80000180` andi	a5,a5,253                              | `161-169/161-169/180/181/182` | `00400148` cbz   w2, 0x1fc               | `117/-/120`      |

## Cycle-by-cycle backend pipe state

Instruction numbers refer to the table above. Empty cells are real bubbles within that core's selected window.

| Relative cycle | OpenRV64 issue | complete | retire  | ORV stalls                  | HPI issue | memory | commit  | HPI blocked oldest |
|---------------:|----------------|----------|---------|-----------------------------|-----------|--------|---------|--------------------|
|              0 | #1             |          |         | RAW                         | #1        |        |         |                    |
|              1 |                |          |         | RAW+NOISS+RETWAIT           | #2        |        |         | #3                 |
|              2 |                |          |         | RAW+NOISS+RETWAIT           |           |        |         | #3                 |
|              3 |                |          |         | RAW+NOISS+RETWAIT           |           | #1     |         | #3                 |
|              4 |                | #1       |         | RAW+NOISS+RETWAIT           | #3        |        | #1/#2   |                    |
|              5 | #2             |          | #1      | RAW+WAW                     |           | #3     |         | #4                 |
|              6 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #4/#5     |        | #3      |                    |
|              7 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #6        |        |         |                    |
|              8 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           | #6     |         | #7                 |
|              9 |                | #2       |         | RAW+WAW+NOISS+RETWAIT       | #7        |        | #4/#5   | #8                 |
|             10 | #3             |          | #2      |                             | #8/#9     |        | #6      |                    |
|             11 | #4/#5          | #3       |         | RAW+RETWAIT                 | #10/#11   |        |         |                    |
|             12 |                | #5       | #3      | RAW+NOISS                   | #12/#13   |        | #7      |                    |
|             13 |                |          |         | RAW+NOISS+RETWAIT           | #14/#15   |        | #8/#9   |                    |
|             14 |                |          |         | RAW+NOISS+RETWAIT           | #16/#17   |        | #10/#11 |                    |
|             15 |                | #4       |         | RAW+NOISS+RETWAIT           | #18/#19   |        | #12/#13 |                    |
|             16 | #6/#7          |          | #4/#5   |                             |           |        | #14/#15 |                    |
|             17 | #8             | #6/#7    |         | RAW+RETWAIT                 |           |        | #16/#17 |                    |
|             18 |                | #8       | #6/#7   | RAW+NOISS                   |           |        | #18/#19 |                    |
|             19 | #9             |          | #8      | RPORT                       |           |        |         |                    |
|             20 | #10            | #9       |         | RAW+WAW+RPORT+RETWAIT+REDIR |           |        |         |                    |
|             21 |                | #10      | #9      |                             |           |        |         |                    |
|             22 | #11            |          | #10     | RAW+WAW                     |           |        |         |                    |
|             23 |                | #11      |         | WAW+NOISS+RETWAIT           | #20       |        |         |                    |
|             24 | #12/#13        |          | #11     | RAW                         |           |        |         |                    |
|             25 |                | #12/#13  |         | RAW+WAW+NOISS+RETWAIT       | #21       |        |         | #22                |
|             26 | #14            |          | #12/#13 | REDIR                       | #22       |        | #20     | #23                |
|             27 |                | #14      |         | RETWAIT                     | #23/#24   |        |         |                    |
|             28 | #15/#16        |          | #14     | RAW+WAW                     | #25       |        | #21     |                    |
|             29 |                | #16      |         | RAW+WAW+NOISS+RETWAIT       |           | #25    | #22     | #26                |
|             30 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #26       |        | #23/#24 | #27                |
|             31 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #27       |        | #25     |                    |
|             32 |                | #15      |         | RAW+WAW+NOISS+RETWAIT       | #28       |        |         | #29                |
|             33 | #17            |          | #15/#16 | RAW+WAW                     | #29       | #27    | #26/#27 |                    |
|             34 |                | #17      |         | RAW+WAW+NOISS+RETWAIT       | #30       | #29    |         | #31                |
|             35 | #18            |          | #17     | RAW                         | #31/#32   |        | #28     |                    |
|             36 | #19            |          |         | RAW+RETWAIT                 | #33       |        | #29     |                    |
|             37 |                | #18      |         | RAW+WAW+NOISS+RETWAIT       |           |        | #30     |                    |
|             38 |                |          | #18     | RAW+WAW+NOISS               | #34       |        | #31/#32 |                    |
|             39 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           | #34    | #33     | #35                |
|             40 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #35       |        | #34     | #36                |
|             41 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #36/#37   |        |         |                    |
|             42 |                | #19      |         | RAW+WAW+NOISS+RETWAIT       | #38/#39   |        |         |                    |
|             43 | #20            |          | #19     | RAW                         | #40/#41   |        | #35     |                    |
|             44 | #21            | #20      |         | RAW+RETWAIT                 | #42       |        | #36/#37 |                    |
|             45 |                |          | #20     | RAW+NOISS                   |           |        | #38/#39 |                    |
|             46 |                |          |         | RAW+NOISS+RETWAIT           | #43       |        | #40/#41 | #44                |
|             47 |                |          |         | RAW+NOISS+RETWAIT           | #44       |        | #42     |                    |
|             48 |                | #21      |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|             49 | #22/#23        |          | #21     |                             |           |        | #43     |                    |
|             50 | #24/#25        | #22/#23  |         | RAW+WAW+RETWAIT             |           |        | #44     |                    |
|             51 |                | #24/#25  | #22/#23 | WAW+NOISS                   |           |        |         |                    |
|             52 | #26/#27        |          | #24/#25 |                             |           |        |         |                    |
|             53 | #28            | #26/#27  |         | RAW+RETWAIT+REDIR           |           |        |         |                    |
|             54 |                | #28      | #26/#27 |                             |           |        |         |                    |
|             55 | #29            |          | #28     | RAW+WAW                     |           |        |         |                    |
|             56 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #45       |        |         |                    |
|             57 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           | #45    |         |                    |
|             58 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #46/#47   |        | #45     |                    |
|             59 |                | #29      |         | RAW+WAW+NOISS+RETWAIT       | #48       |        |         |                    |
|             60 | #30            |          | #29     | RAW                         |           |        |         | #49                |
|             61 |                | #30      |         | RAW+WAW+NOISS+RETWAIT       |           |        | #46/#47 | #49                |
|             62 | #31            |          | #30     |                             | #49       | #48    | #48     |                    |
|             63 | #32/#33        |          |         | RAW+RETWAIT                 |           | #49    |         | #50                |
|             64 |                | #31/#33  |         | RAW+WAW+NOISS+RETWAIT       | #50/#51   |        |         |                    |
|             65 |                |          | #31     | RAW+WAW+NOISS               | #52       | #51    | #49     | #53                |
|             66 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #53       |        |         | #54                |
|             67 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #54/#55   |        | #50/#51 |                    |
|             68 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #56       |        | #52     | #57                |
|             69 |                | #32      |         | RAW+WAW+NOISS+RETWAIT       | #57       |        | #53     | #58                |
|             70 | #34            |          | #32/#33 |                             | #58/#59   |        | #54/#55 |                    |
|             71 | #35/#36        | #34      |         | RAW+RETWAIT                 | #60       |        | #56     | #61                |
|             72 |                | #36      | #34     | RAW+WAW+NOISS               | #61       |        | #57     | #62                |
|             73 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #62/#63   |        | #58/#59 |                    |
|             74 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #63       | #63    | #60     | #64                |
|             75 |                | #35      |         | RAW+WAW+NOISS+RETWAIT       | #64/#65   |        | #61     |                    |
|             76 | #37/#38        |          | #35/#36 |                             |           |        | #62/#63 | #66                |
|             77 | #39/#40        | #37/#38  |         | RETWAIT                     | #66       | #65    | #63     | #67                |
|             78 | #41            | #39/#40  | #37/#38 | RAW+WAW                     | #67/#68   |        | #64/#65 |                    |
|             79 |                | #41      | #39/#40 | RAW+WAW+NOISS               | #69       |        |         | #70                |
|             80 | #42            |          | #41     | REDIR                       | #70/#71   |        | #66     |                    |
|             81 |                | #42      |         | RETWAIT                     | #72       |        | #67/#68 | #73                |
|             82 | #43            |          | #42     | RAW+WAW                     | #73       |        | #69     | #74                |
|             83 |                | #43      |         | WAW+NOISS+RETWAIT           | #74/#75   |        | #70/#71 |                    |
|             84 | #44/#45        |          | #43     | RAW                         | #75       | #75    | #72     | #76                |
|             85 |                | #44/#45  |         | RAW+NOISS+RETWAIT           | #76/#77   |        | #73     |                    |
|             86 | #46            |          | #44/#45 |                             |           |        | #74/#75 | #78                |
|             87 |                | #46      |         | RETWAIT                     | #78       | #77    | #75     | #79                |
|             88 |                |          | #46     |                             | #79/#80   |        | #76/#77 |                    |
|             89 | #47/#48        |          |         | RAW                         | #81       |        |         | #82                |
|             90 |                | #48      |         | RAW+WAW+NOISS+RETWAIT       | #82       |        | #78     |                    |
|             91 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        | #79/#80 |                    |
|             92 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #83       |        | #81     | #84                |
|             93 |                | #47      |         | RAW+WAW+NOISS+RETWAIT       | #84       |        | #82     | #85                |
|             94 | #49            |          | #47/#48 |                             | #85       |        |         | #86                |
|             95 | #50/#51        | #49      |         | RAW+RETWAIT                 | #86/#87   |        | #83     |                    |
|             96 |                | #51      | #49     | RAW+WAW+NOISS               | #87       | #87    | #84     | #88                |
|             97 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #88/#89   |        | #85     |                    |
|             98 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        | #86/#87 | #90                |
|             99 |                | #50      |         | RAW+WAW+NOISS+RETWAIT       | #90       | #89    | #87     | #91                |
|            100 | #52/#53        |          | #50/#51 |                             | #91/#92   |        | #88/#89 |                    |
|            101 | #54/#55        | #52/#53  |         | RETWAIT                     | #93       |        |         | #94                |
|            102 | #56            | #54/#55  | #52/#53 | RAW+WAW                     | #94       |        | #90     |                    |
|            103 |                | #56      | #54/#55 | RAW+WAW+NOISS               |           |        | #91/#92 |                    |
|            104 | #57            |          | #56     | REDIR                       |           |        | #93     |                    |
|            105 |                | #57      |         | RETWAIT                     |           |        | #94     |                    |
|            106 | #58            |          | #57     | RAW+WAW                     |           |        |         |                    |
|            107 |                | #58      |         | WAW+NOISS+RETWAIT           |           |        |         |                    |
|            108 | #59/#60        |          | #58     | RAW                         |           |        |         |                    |
|            109 |                | #59/#60  |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|            110 | #61            |          | #59/#60 |                             | #95       |        |         |                    |
|            111 |                | #61      |         | RETWAIT                     | #96       | #95    |         | #97                |
|            112 |                |          | #61     |                             | #97       |        | #95     | #98                |
|            113 | #62/#63        |          |         | RAW                         | #98       |        |         |                    |
|            114 |                | #63      |         | RAW+WAW+NOISS+RETWAIT       |           |        | #96     | #99                |
|            115 |                |          |         | RAW+WAW+NOISS+RETWAIT       | #99       | #98    | #97/#98 |                    |
|            116 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           | #99    |         | #100               |
|            117 |                | #62      |         | RAW+WAW+NOISS+RETWAIT       | #100      |        |         |                    |
|            118 | #64            |          | #62/#63 |                             |           |        | #99     |                    |
|            119 | #65/#66        | #64      |         | RAW+RETWAIT                 |           |        |         |                    |
|            120 |                | #66      | #64     | RAW+WAW+NOISS               |           |        | #100    |                    |
|            121 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            122 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            123 |                | #65      |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            124 | #67/#68        |          | #65/#66 |                             |           |        |         |                    |
|            125 | #69/#70        | #67/#68  |         | RETWAIT                     |           |        |         |                    |
|            126 | #71            | #69/#70  | #67/#68 | RAW+WAW                     |           |        |         |                    |
|            127 |                | #71      | #69/#70 | RAW+WAW+NOISS               |           |        |         |                    |
|            128 | #72            |          | #71     | REDIR                       |           |        |         |                    |
|            129 |                | #72      |         | RETWAIT                     |           |        |         |                    |
|            130 | #73            |          | #72     | RAW+WAW                     |           |        |         |                    |
|            131 |                | #73      |         | WAW+NOISS+RETWAIT           |           |        |         |                    |
|            132 | #74/#75        |          | #73     | RAW                         |           |        |         |                    |
|            133 |                | #74/#75  |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|            134 | #76            |          | #74/#75 |                             |           |        |         |                    |
|            135 |                | #76      |         | RETWAIT                     |           |        |         |                    |
|            136 |                |          | #76     |                             |           |        |         |                    |
|            137 | #77/#78        |          |         | RAW                         |           |        |         |                    |
|            138 |                | #78      |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            139 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            140 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            141 |                | #77      |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            142 | #79            |          | #77/#78 |                             |           |        |         |                    |
|            143 | #80/#81        | #79      |         | RAW+RETWAIT                 |           |        |         |                    |
|            144 |                | #81      | #79     | RAW+WAW+NOISS               |           |        |         |                    |
|            145 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            146 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            147 |                | #80      |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            148 | #82/#83        |          | #80/#81 |                             |           |        |         |                    |
|            149 | #84/#85        | #82/#83  |         | RETWAIT                     |           |        |         |                    |
|            150 | #86            | #84/#85  | #82/#83 | RAW+WAW                     |           |        |         |                    |
|            151 |                | #86      | #84/#85 | RAW+WAW+NOISS               |           |        |         |                    |
|            152 | #87            |          | #86     |                             |           |        |         |                    |
|            153 | #88/#89        | #87      |         | RAW+WAW+RETWAIT             |           |        |         |                    |
|            154 |                | #89      | #87     | RAW+WAW+NOISS               |           |        |         |                    |
|            155 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            156 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            157 |                | #88      |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            158 | #90            |          | #88/#89 | RAW+WAW                     |           |        |         |                    |
|            159 |                | #90      |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            160 | #91            |          | #90     | RAW                         |           |        |         |                    |
|            161 | #92            |          |         | RAW+RETWAIT                 |           |        |         |                    |
|            162 |                | #91      |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|            163 |                |          | #91     | RAW+NOISS                   |           |        |         |                    |
|            164 |                |          |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|            165 |                |          |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|            166 |                |          |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|            167 |                | #92      |         | RAW+NOISS+RETWAIT           |           |        |         |                    |
|            168 | #93            |          | #92     |                             |           |        |         |                    |
|            169 | #94/#95        | #93      |         | RAW+RETWAIT                 |           |        |         |                    |
|            170 |                | #95      | #93     | RAW+WAW+NOISS               |           |        |         |                    |
|            171 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            172 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            173 |                | #94      |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            174 | #96/#97        |          | #94/#95 |                             |           |        |         |                    |
|            175 | #98/#99        | #96/#97  |         | RAW+WAW+RETWAIT             |           |        |         |                    |
|            176 |                | #99      | #96/#97 | RAW+WAW+NOISS               |           |        |         |                    |
|            177 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            178 |                |          |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            179 |                | #98      |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            180 | #100           |          | #98/#99 | RAW                         |           |        |         |                    |
|            181 |                | #100     |         | RAW+WAW+NOISS+RETWAIT       |           |        |         |                    |
|            182 |                |          | #100    | REDIR                       |           |        |         |                    |
