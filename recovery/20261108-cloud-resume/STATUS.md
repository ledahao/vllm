# Cloud resume / DeepSeek V4.1 P-D tuning

Started 2026-11-08 16:55 UTC. Preserve existing workspace changes; no PR.

## Inventory

Target: `DeepSeek-V4.1-Flash-1017-NVFP4` (one model, split encoder Prefill and Decode).

- Prefill: s107 / 10.230.0.107, GPUs 0-1, TP2, API 9001, systemd user unit `vllm-prefill-tp2.service`.
- Decode: 103-106, one GB10 per node, Ray TP4 in `dsv41-node`, API 103:9000.
- Proxy: s107:9002, `vllm-pd-proxy.service`, Mooncake bootstrap 9998.
- Incumbent: DSpark K5, max-num-batched-tokens=2048, max-num-seqs=16, KV cache=16GiB/rank, FP8 KV, FULL_DECODE_ONLY graph sizes [1,2,4,8,16,32,64].
- Profiler: torch CPU/CUDA, record shapes, stack disabled, output `/tmp/vllm-profiler`, startup capture enabled. Profiled runs excluded from throughput comparisons.
- Other observed process: s107 B12x `deepseek-v41-flash` on port 8000, TP4, separate deployment. No evidence this is part of the interrupted P/D tuning; preserve it and its resource reservation.

## Recovery

The cloud SSH entry is `gpu107` (configured host key and identity), then SSH from s107 to `aaron@10.230.0.103` through `.106`. Existing sudo Docker commands work through this route. No credentials copied into reports.

103 head was running; 104-106 containers were stopped. Started those containers and verified Ray has 4 active nodes and 4/4 GPU resources allocated. Existing Decode resumed weight loading. Found only rank103 upgraded to Mooncake 0.3.14; other ranks still 0.3.13.post1. Stop only the Decode API before aligning rank packages; do not stop Ray/PID1, which owns container lifetime.

Custom AllReduce cannot safely be forced across this topology: CC12.1 MNNVL multicast capability check disabled it. NCCL remains the supported communication path. Previous Tree environment did not prove Tree kernels; verify actual trace before attributing algorithm effects.

## Validation gate

Health alone is insufficient. Require nonempty generated text through the proxy, correct simple factual/arithmetic answers, successful 3K-token P/D transfers, and completed request counts in raw benchmark JSON. Use the same seeds, input/output sizes, warmup and request counts across comparisons. Preserve K5/2048 on a regression or unverified candidate. Record errors and unresolved blockers explicitly.

## Current state

17:00 UTC: all four Decode ranks aligned to Mooncake 0.3.14. Reused rank103's completed ARM64 uv cache over the existing authenticated LAN route, then used `uv pip install --system --offline mooncake-transfer-engine-cuda13==0.3.14`. Old API ignored TERM while initialization was in progress; terminated its EngineCore and then the API by their verified PIDs. Ray head and worker containers remain running. Restarted `/home/aaron/launch_decode_tp4_profile.sh` with incumbent K5/2048 and startup profiler configuration; no Tree override. Weight loading is in progress.

Planned comparisons after correctness gate: fixed 3K input / 1000 output, seed1, 4 measured requests and 2 warmups at C1, C2, then repeated C1; record latency/throughput and speculative acceptance. If stable, compare a lower DSpark K against K5 on the identical workload. C8 is excluded because prior runs encountered IMA; C2 is the safe upper step until validated.

17:11 UTC: Decode health 200 after weight loading, draft loading and warmup; Ray 4 nodes. Prefill and proxy restarted using their existing systemd units, Prefill health 200. Prefill upgrade dry-run proposed only rc4 -> stable 0.3.14, but download/SSH bandwidth was too slow (4.5MiB of 47.4MiB after several minutes). Canceled the download processes before package replacement; Prefill remains verified 0.3.14rc4. The partial wheel was renamed `.whl.partial`. All four Decode ranks use 0.3.14. Starting four deterministic chat correctness cases through the proxy. No throughput claim yet.

Correctness gate: 4/4 deterministic chat cases passed through proxy, with nonempty `Paris`, `42`, `1, 2, 3`, `READY`; elapsed 0.307-0.431s per request. Raw responses in `smoke-k5.json`.

Benchmark preparation adjustment: `/reset_prefix_cache` is not exposed on this deployed Prefill (404); initial r1 wrapper aborted before measurement. Updated warmup from 2 to 4 to cover the entire four-request deterministic dataset before each measurement. All new comparisons use this updated protocol; they represent replayed, warmed-cache Decode workloads, not cold Prefill. Record actual cache hit ratio and do not directly compare with historical runs using different warmup/cache state. r1b K5/2048 C1 is the first baseline.

## Measured rounds

| Round | Change | Success | Output tok/s | TTFT p50/p99 ms | TPOT p50/p99 ms | Actual hit | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- |
| r1b | K5/2048 C1 baseline | 4/4, 4000 output tokens | 22.4546 | 371.16 / 477.32 | 47.455 / 65.632 | 98.2% | 2.06 |
| r2 | K5/2048 C2, same default sampling | 4/4, 4000 output tokens | 32.5813 | 685.58 / 750.29 | 50.390 / 74.094 | 98.2% | 2.21 |

r1b native benchmark duration 178.137s, median E2E latency 47.779s, p99 65.876s. All four output lengths exactly 1000; no request errors. Older historical ~27 tok/s was not reproduced in this first run; no improvement claim. Started r2 with identical protocol and K5/2048, changing only client concurrency from 1 to 2.

Protocol finding: current server-side `vllm/benchmarks/serve.py` lines 2199 onward explicitly warns that the benchmark no longer sends temperature=0 by default. r1b and r2 inherited server sampling defaults; the dataset seed does not fix model sampling. Treat these as exploratory measurements, not deterministic K comparisons. Updated the harness for subsequent rounds to pass `--temperature=0` explicitly. Rebaseline K5 before comparing K3, and compare saved generated texts where meaningful. This may explain some historical throughput/acceptance differences, but is not yet proven.

r2 increased aggregate throughput 45.1%, while median TTFT rose 84.7% and median TPOT rose 6.2%; four samples and unfixed server sampling limit the conclusion. All requests completed with exactly 1000 tokens; no model/request errors. Updating the shared wrapper while Bash was blocked in the benchmark caused an EOF parsing error after the native result had been written; post-run wrapper snapshots were not all collected. Retained the original JSON/CSV as valid native measurements and recorded the wrapper failure separately. All future runs execute an immutable per-run copy of the wrapper. r3 is the new deterministic K5 C1 baseline with explicit temperature=0.

Memory snapshot: Prefill cgroup current 65.12GB, peak 77.84GB (decimal bytes from systemd), memory high/max/oom/oom_kill counters all 0; target GPUs 0-1 each used 83,911MiB. GB10 NVML framebuffer usage is N/A; startup reports model allocation 77.33GiB/rank, plus configured 16GiB KV cache. See memory snapshots; do not equate host MemAvailable with precise CUDA usage.

## Cursor takeover (2026-11-09 01:38 CST / 17:38 UTC prior day clock)

Codex session interrupted after planning r3. Cursor agent resumed from `recovery/20261108-cloud-resume/STATUS.md` and the Codex rollout. Stack still healthy: Prefill `/health` 200, Decode `/health` 200, proxy serves `/v1/completions` (proxy `/health` 404 is expected). Correctness gate rechecked through proxy: Paris / 42 / 1, 2, 3 / READY (seq needs max_tokens≥64 because reasoning tokens consume budget).

r3 (Codex-started, Cursor-validated): K5/2048 C1 with `--temperature=0`, warmup 4, seed 1, 4 requests. **51.65 tok/s**, TTFT p50 **313.34 ms**, TPOT p50 **16.084 ms**, hit **98.2%**, acceptance **4.69**, 4/4 × 1000 tokens. Spec metrics delta: accepted 6422 / drafts 1588. Greedy decoding more than doubled C1 throughput vs exploratory r1b (22.45 tok/s, accept 2.06) under the same K5/2048 deployment; do not mix r1b/r2 with r3+ when ranking K.

| Round | Change | Success | Output tok/s | TTFT p50/p99 ms | TPOT p50/p99 ms | Actual hit | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- |
| r3 | K5/2048 C1 greedy T=0 | 4/4, 4000 output tokens | 51.6486 | 313.34 / 330.23 | 16.084 / 29.732 | 98.2% | 4.69 |
| r4 | K5/2048 C2 greedy T=0 | 4/4, 4000 output tokens | 79.6357 | 717.66 / 737.58 | 21.878 / 26.768 | 98.2% | 5.33 |

r4 vs r3: aggregate throughput +54.2%, median TTFT +129%, median TPOT +36%; all outputs exactly 1000 tokens. Greedy K5 C1/C2 both stable — attempted K3 compare.

17:50 UTC: stopped Decode API only (Ray 4/4 nodes retained) and launched K3 (`num_speculative_tokens=3`) via `/home/aaron/launch_decode_cloud_k3_candidate.sh` on 103.

18:02 UTC: **K3 startup failed** during kernel warmup with CUDA IMA in `flashinfer_sparse._compact_sm120_prefill_pages` (same site noted in launcher comments for C8+/nsys). EngineCore init aborted; full log archived under `runs/k3-startup-fail/`. No K3 throughput claim.

18:04–18:20 UTC: restored incumbent K5 (`launch_decode_tp4_profile.sh`, `num_speculative_tokens=5`). Decode `/health` 200 again; Ray remained 4/4. Correctness gate rechecked through proxy after restore.

## Recommendation

- **Keep K5/2048 as serving incumbent** under the greedy (`temperature=0`) protocol. Best validated points: C1 **51.65 tok/s** (accept 4.69), C2 **79.64 tok/s** (accept 5.33), hit 98.2%, 4/4×1000.
- Do **not** promote K3 from this attempt; startup IMA blocked measurement. Next K3 try should happen only after a clean Ray/worker reset or an upstream fix for `_compact_sm120_prefill_pages`, and still ladder C1→C2 only.
- Treat r1b/r2 as exploratory (non-greedy sampling); rank only r3+ for K comparisons.
- Optional next tuning levers (not yet run): raise `max-num-batched-tokens` above 2048 to relieve the draft-slot warning, or profile greedy K5 C2 with the active profiler harness — exclude profiled runs from throughput claims.

## C1 3-tier greedy recheck (2026-11-09 07:48 CST)

Script: `ardelva_bench_latest_pd.py` with `--temperature=0`, warmup 4, seed 1, min-requests 4.
Matrix: `3000:1000:50:1;60000:1000:95:1;100000:1000:0:1`. Out: `runs/c1-3tier-greedy-20261109-074824/`.

| Tier | isl | actual hit | out tok/s | TTFT p50 ms | TPOT p50 ms | accept | success |
| --- | --- | --- | --- | --- | --- | --- | --- |
| short | 3000 | 98.2% | 65.07 | 312.11 | 14.678 | 5.77 | 4/4 |
| mid | 60000 | 99.9% | 64.05 | 569.85 | 14.617 | 5.63 | 4/4 |
| long | 100000 | 100.0% | 64.18 | 799.07 | 14.858 | 5.86 | 4/4 |

All three tiers completed under greedy K5/2048; decode throughput stayed ~64–65 tok/s while TTFT rose with context.

## Systematic tune (2026-11-09 morning CST)

Protocol: `ardelva_bench_latest_pd.py`, `--temperature=0`, warmup 4, seed 1, Decode **without** torch profiler. Scripts: `launch_decode_tune.sh`, `run_tune_bench.sh`. Artifacts: `runs/tune-20261109/`, `tune-leaderboard.json`.

### Step 1 — MoE backend (GB10 / SM120)
| Backend | Result |
| --- | --- |
| `flashinfer_cutlass` | **Works** (baseline) |
| `flashinfer_trtllm` | Fail: kernel does not support current device |
| `flashinfer_cutedsl` | Fail: kernel does not support current device |

Only CUTLASS is viable on this topology. EmulationMxfp8 still appears on draft/load path after FlashInferCutlassMxfp8 on target — not fixed this round.

### Step 2 — `max-num-batched-tokens` 2048 vs 4096 (cutlass, Ring)
| Config | C1 short tok/s | C2 fair (4 req) tok/s |
| --- | --- | --- |
| 2048 | 62.78 (repeat 57.33) | 82.26 |
| 4096 | 63.36 | **91.01** (later confirm 77.4) |

C1 essentially tied. C2 showed a +10% peak at 4096 but **high variance** on reconfirm. Still prefer 4096 as the live candidate (warning about draft slots persists even at 4096).

### Step 3 — NCCL Tree
`docker exec -e NCCL_ALGO=Tree` only affects the API process; **Ray workers remain `NCCL_ALGO=Ring`**. True Tree needs Ray/container restart on all ranks. Contaminated API-Tree run C2=77.06 — do not attribute to Tree kernels. Keep Ring.

### Final confirmation (live now)
Cutlass + **4096** + Ring + K5 + no profiler:
| Workload | tok/s | TTFT p50 | TPOT p50 | accept |
| --- | --- | --- | --- | --- |
| C1 3k | 64.71 | 305 | 14.4 | 5.66 |
| C1 60k | 63.00 | 554 | 15.5 | 5.60 |
| C1 100k | 62.41 | 781 | 15.3 | 5.84 |
| C2 fair 3k | 77.4 | 687 | 22.8 | 5.12 |

### Recommendation
- **Serving candidate:** DSpark K5, `moe_backend=flashinfer_cutlass`, `max-num-batched-tokens=4096`, NCCL Ring, profiler off, greedy `T=0` when throughput is the goal.
- **Do not** switch to TRTLLM/CUTEDSL on GB10.
- **Next levers:** (1) fix/avoid EmulationMxfp8 on draft, (2) Ray-wide NCCL Tree A/B, (3) FlashInfer autotune offline, (4) repeat C2 n≥5 before claiming 4096 C2 win, (5) sparse IMA before K/concurrency scan.

## Deep dive (2026-11-09 late morning CST)

### C2 fair repeats (n=5, greedy T=0, no profiler)
| Config | mean tok/s | stdev | min–max | accept mean |
| --- | --- | --- | --- | --- |
| **4096** | **87.21** | 5.34 | 81.98–95.05 | 5.52 |
| 2048 | 79.82 | 10.46 | 62.66–89.83 | 5.10 |

**4096 wins** on mean (+9%) and stability. One 2048 outlier (accept 3.9 → 62.7 tok/s) inflated its variance.

### EmulationMxfp8
Draft/load still falls back to `EmulationMxfp8LinearKernel` after target uses FlashInfer CUTLASS. Root cause on SM120: `FlashInferCutlassMxfp8LinearKernel.can_implement` requires `N % 32 == 0`; some draft layer shapes fail and fall through. Forcing `linear_backend=flashinfer_cutlass` would error those layers, not speed them up. Needs shape/pad fix or a SM120-capable kernel — not a flag flip.

### FlashInfer autotune
Enabled on 4096; loaded cache then hung/long-stalled on `trtllm::fused_moe::gemm*` profiling despite MoE backend being CUTLASS. Startup never reached health within ~25+ min. **Aborted.** Keep `--no-enable-flashinfer-autotune`.

### Ops note
After Decode restart, Prefill Mooncake still targeted a stale port (`192.168.100.103:16037` transfer failures → bench 0 tok/s). **Restart Prefill+proxy** after Decode relaunch. Post-repair confirm: C1 **67.18**, C2 fair **84.67**.

### Live incumbent (repaired)
`flashinfer_cutlass` + **4096** + Ring + K5 + no profiler + no autotune. Prefill/proxy restarted and healthy.


## C8 hang fix (2026-11-09 CST)

**Root cause:** CUDA IMA in `flashinfer_sparse._compact_sm120_prefill_pages` under C8 PD + DSpark + SWA bounded replay (async error surfaced at `src[valid]` / `index_select`). Cannot disable SWA bounded replay: `dsv41_encoder_only_prefill requires SWA bounded replay`.

**Fix:** Clamp/filter OOB sparse indices and block ids before `unique`/`index_select` in `_compact_sm120_prefill_pages`. Deployed into all 4 decode containers + workspace source.

**Also kept:** `cudagraph_capture_sizes=[1,2,4,8,16]` (drop 32/64).

**Probe (isl=3000, greedy T=0, health-gated):**
| Config | C4 tok/s | C8 tok/s | decode after |
| --- | --- | --- | --- |
| before (cg clamp only) | 179.7 | EngineDead | down |
| seqs=8 + cg clamp | 198.5 | EngineDead | down |
| **OOB compact patch + cg clamp** | **207.1** | **277.6** (accept 5.47) | **200** |

Live incumbent: cutlass + batch 4096 + K5 + Ring + SWA bounded on + cg `[1,2,4,8,16]` + OOB compact patch.

Reconfirm C8 alone: **317.0 tok/s**, accept 5.57, decode/prefill 200. Details in `C8_HANG_FIX.md` + `patches/flashinfer_sparse.py.patched-oob`.

Upstream `main` (FETCH `bf19789e`) no longer contains `_compact_sm120_prefill_pages` (path removed/refactored); live image is packaged `v0.32.0` that still has it — patch is deployed there.

## Full 3-tier × C1–C8 gradient (post C8 fix)

| isl | C | out tok/s | TTFT p50 | TPOT p50 | accept | hit% | SLO% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 3000 | 1 | 59.51 | 334.8 | 15.812 | 5.48 | 98.2 | 100.0 |
| 3000 | 2 | 104.80 | 687.7 | 18.332 | 5.75 | 98.2 | 100.0 |
| 3000 | 4 | 205.92 | 896.5 | 17.378 | 5.51 | 98.2 | 100.0 |
| 3000 | 8 | 295.44 | 1593.2 | 21.060 | 5.54 | 47.5 | 90.6 |
| 60000 | 1 | 55.86 | 579.5 | 16.608 | 5.14 | 99.9 | 100.0 |
| 60000 | 2 | 81.60 | 1307.8 | 18.223 | 5.04 | 83.4 | 75.0 |
| 60000 | 4 | 182.40 | 1425.6 | 16.981 | 5.46 | 89.2 | 75.0 |
| 60000 | 8 | 251.10 | 2218.4 | 24.639 | 5.35 | 92.0 | 75.0 |
| 100000 | 1 | 57.95 | 732.8 | 15.229 | 5.38 | 100.0 | 100.0 |
| 100000 | 2 | 69.22 | 6940.1 | 17.908 | 5.25 | 50.0 | 50.0 |
| 100000 | 4 | 107.69 | 7429.4 | 18.379 | 5.40 | 50.0 | 50.0 |
| 100000 | 8 | 125.14 | 8363.9 | 24.497 | 5.25 | 50.0 | 40.6 |

Tag: `3tier-c8-full-20261109-054508`. Matrix `3000/60000/100000 × C1,2,4,8`, greedy T=0, req_per_conc=4, OOB compact patch + cg `[1,2,4,8,16]`. All 12 points success; decode/prefill stayed 200.

## Full suite F→gradient→A/B/C/D/E (C≤8) — 2026-11-09 CST

Tag: `full-suite-c8-20261109-153317` under `/home/aaron/bench/out/`. Runner: `run_full_suite_c8.sh`. Protocol: greedy `T=0`, warmup 4, req_per_conc 4, min-requests 4, seed 1, cutlass+batch4096+K5+cg`[1,2,4,8,16]`+OOB patch. Health stayed 200 through all phases.

First A–D attempt failed with `ImportError: Please install vllm[bench]` / missing `pandas` on custom+multiturn paths. Installed `pandas==2.2.3` via Tsinghua mirror, then retried A–D successfully. Suite B used offline `fixtures/custom/coding_prompts.jsonl` (HF `likaixin/InstructCoder` unreachable from gpu107).

### F — Accuracy (`ardelva-qc-v1`, 40 Q, T=0)
**100.0%** in 35s (`accuracy-par=4`, `max_tokens=4096`).

### Gradient — random 3k/60k/100k × C1,2,4,8

| isl | C | out tok/s | TTFT p50 | TPOT p50 | accept | hit% | SLO% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 3000 | 1 | 63.21 | 307.36 | 14.100 | 5.51 | 98.2 | 100.0 |
| 3000 | 2 | 83.60 | 702.14 | 19.872 | 4.83 | 42.9 | 100.0 |
| 3000 | 4 | 188.28 | 826.18 | 18.040 | 5.50 | 46.0 | 100.0 |
| 3000 | 8 | 319.68 | 1332.92 | 21.003 | 5.55 | 47.5 | 100.0 |
| 60000 | 1 | 60.74 | 592.37 | 16.075 | 5.62 | 99.9 | 100.0 |
| 60000 | 2 | 81.47 | 1304.47 | 18.394 | 5.04 | 83.4 | 75.0 |
| 60000 | 4 | 175.26 | 1572.04 | 17.671 | 5.50 | 89.2 | 75.0 |
| 60000 | 8 | 276.14 | 1539.25 | 24.227 | 5.57 | 92.0 | 75.0 |
| 100000 | 1 | 63.47 | 778.18 | 14.988 | 5.79 | 100.0 | 100.0 |
| 100000 | 2 | 71.40 | 7002.82 | 19.186 | 5.10 | 50.0 | 50.0 |
| 100000 | 4 | 108.35 | 7672.06 | 18.191 | 5.27 | 50.0 | 50.0 |
| 100000 | 8 | 125.86 | 8850.78 | 24.921 | 5.12 | 50.0 | 40.6 |

### A — Realtext 3k/10k/32k × C1–C8 (plus 1 random calib point)

| ds | isl | C | out tok/s | TTFT p50 | TPOT p50 | accept | hit% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 3k | 2531 | 1 | 62.29 | 297.08 | 15.628 | 5.94 | 98.7 |
| 3k | 2531 | 2 | 101.45 | 652.95 | 18.755 | 5.92 | 98.7 |
| 3k | 2531 | 4 | 211.74 | 724.29 | 18.062 | 5.98 | 98.7 |
| 3k | 2531 | 8 | 316.22 | 961.61 | 22.353 | 5.87 | 98.7 |
| 10k | 8390 | 1 | 58.80 | 300.91 | 16.019 | 5.71 | 99.9 |
| 10k | 8390 | 2 | 102.99 | 619.17 | 18.844 | 5.94 | 99.9 |
| 10k | 8390 | 4 | 189.55 | 752.11 | 19.621 | 5.87 | 99.9 |
| 10k | 8390 | 8 | 297.23 | 1022.50 | 23.918 | 5.85 | 99.9 |
| 32k | 26810 | 1 | 58.82 | 371.48 | 16.064 | 5.70 | 99.8 |
| 32k | 26810 | 2 | 100.19 | 829.29 | 18.683 | 5.91 | 99.8 |
| 32k | 26810 | 4 | 179.05 | 905.92 | 19.892 | 5.81 | 99.8 |
| 32k | 26810 | 8 | 312.69 | 1179.28 | 23.137 | 5.89 | 99.8 |

All A points success 100%, SLO 100%.

### B — Coding (offline custom coding_prompts.jsonl)

| C | isl | out tok/s | TTFT p50 | TPOT p50 | accept | hit% |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 737 | 59.14 | 272.81 | 16.007 | 5.69 | 95.7 |
| 2 | 737 | 100.08 | 433.50 | 18.379 | 5.78 | 71.7 |
| 4 | 738 | 204.08 | 760.57 | 18.440 | 5.97 | 89.6 |
| 8 | 738 | 296.25 | 993.35 | 22.785 | 5.75 | 95.5 |

### C — Think (realtext_10k → osl 4000)

| C | out tok/s | TTFT p50 | TPOT p50 | accept | hit% |
| --- | --- | --- | --- | --- | --- |
| 1 | 62.65 | 303.35 | 15.851 | 5.97 | 99.9 |
| 2 | 101.90 | 701.71 | 19.275 | 5.96 | 99.9 |
| 4 | 203.27 | 763.51 | 19.176 | 5.96 | 99.9 |
| 8 | 313.38 | 975.74 | 24.706 | 5.93 | 99.9 |

### D — Multiturn `60000:5000:5`

| C | avg isl | out tok/s | TTFT p50 | TPOT p50 | accept | hit% | SLO% |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 70008 | 21.55 | 1174.8 | 43.337 | 2.31 | 80.9 | 77.5 |
| 2 | 69758 | 33.10 | 1534.0 | 54.211 | 2.17 | 80.5 | 25.6 |
| 4 | 69756 | 54.98 | 1381.79 | 63.834 | 2.11 | 80.5 | 7.7 |
| 8 | 69121 | 83.61 | 1782.76 | 84.636 | 2.25 | 79.7 | 0.0 |

Multiturn acceptance ~2.1–2.3 (vs ~5.5–6 on single-turn greedy) and SLO collapses past C1 under default `ttft:3000,tpot:50`.

### E — Rate scan (isl=3000, rate-cap=8, 60s)

| rate | out tok/s | TTFT p50 | TPOT p50 | accept | hit% | SLO% |
| --- | --- | --- | --- | --- | --- | --- |
| 0.5 | 283.46 | 951.1 | 23.112 | 5.53 | 88.3 | 100.0 |
| 1.0 | 286.82 | 924.54 | 23.570 | 5.51 | 52.4 | 100.0 |
| 1.5 | 297.14 | 975.67 | 23.850 | 5.52 | 65.4 | 100.0 |
| 2.0 | 294.87 | 974.35 | 24.628 | 5.40 | 73.6 | 98.3 |

Artifacts: `runs/full-suite-c8-20261109-153317/` (+ `*-all_points.csv`, `*-accuracy.json`).
