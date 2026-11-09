#!/usr/bin/env bash
# Full ardelva suite capped at C8: F → gradient → A → B → C → D → E
# Usage on s107: bash run_full_suite_c8.sh [tag]
set -euo pipefail

tag=${1:-full-suite-c8-$(date +%Y%m%d-%H%M%S)}
root=/home/aaron/bench/out/$tag
mkdir -p "$root"/{F-accuracy,gradient,A-realtext,B-coding,C-think,D-multiturn,E-rate}
echo "$tag" > /home/aaron/bench/out/LATEST_FULL_SUITE_TAG.txt
echo "$root" > /home/aaron/bench/ardelva_latest.outdir

PY=/home/aaron/src/vllm/.venv/bin/python
BENCH=/home/aaron/bench/ardelva_bench_latest_pd.py
VLLM=/home/aaron/src/vllm/.venv/bin/vllm
TOK=/data/models/LibertAIDAI--DeepSeek-V4.1-Flash-1017-NVFP4/master
MODEL=DeepSeek-V4.1-Flash-1017-NVFP4
BASE=http://127.0.0.1:9002
FIX=/home/aaron/bench/fixtures
MT_DIR=/home/aaron/src/vllm/benchmarks/multi_turn

export ARDELVA_PREFIX_METRICS_URL=http://127.0.0.1:9001
export ARDELVA_SPEC_METRICS_URL=http://10.230.0.103:9000
export OPENAI_API_KEY="$(head -n 1 /home/aaron/.config/vllm/openai_api_keys)"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

COMMON=(
  "$PY" -u "$BENCH"
  --base-url "$BASE"
  --model "$MODEL"
  --tokenizer "$TOK"
  --vllm "$VLLM"
  --endpoint /v1/completions --backend vllm
  --extra "--tokenizer-mode deepseek_v41 --temperature=0"
  --min-requests 4 --req-per-conc 4 --warmup 4 --seed 1
  --conc 1,2,4,8
)

health() {
  local d p
  d=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 http://10.230.0.103:9000/health || echo 000)
  p=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 http://127.0.0.1:9001/health || echo 000)
  echo "$d $p"
}

require_health() {
  read -r d p <<<"$(health)"
  if [[ "$d" != "200" || "$p" != "200" ]]; then
    echo "HEALTH_FAIL decode=$d prefill=$p" | tee -a "$root/watch.log"
    return 1
  fi
  return 0
}

run_phase() {
  local name=$1; shift
  local out=$root/$name
  mkdir -p "$out/results"
  date -u --iso-8601=seconds >"$out/start.txt"
  printf "%q " "$@" >"$out/command.txt"; printf "\n" >>"$out/command.txt"
  echo "==== PHASE $name start $(date -u --iso-8601=seconds) ====" | tee -a "$root/master.log"
  set +e
  "$@" >"$out/bench_stdout.log" 2>&1
  local rc=$?
  set -e
  date -u --iso-8601=seconds >"$out/end.txt"
  printf "%s\n" "$rc" >"$out/exit-code.txt"
  cp -a "$out/results/ardelva_points.csv" "$out/ardelva_points.csv" 2>/dev/null || true
  cp -a "$out/results/ardelva_accuracy.json" "$out/ardelva_accuracy.json" 2>/dev/null || true
  echo "==== PHASE $name end rc=$rc $(date -u --iso-8601=seconds) ====" | tee -a "$root/master.log"
  return "$rc"
}

watch_loop() {
  local pid=$1
  while kill -0 "$pid" 2>/dev/null; do
    read -r d p <<<"$(health)"
    echo "$(date -u --iso-8601=seconds) decode=$d prefill=$p" >>"$root/watch.log"
    if [[ "$d" != "200" || "$p" != "200" ]]; then
      echo "$(date -u --iso-8601=seconds) HEALTH_DOWN decode=$d prefill=$p — killing suite" | tee -a "$root/watch.log"
      kill "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
      pkill -f "ardelva_bench_latest_pd.py" 2>/dev/null || true
      echo ABORTED_HEALTH >"$root/ABORTED"
      return 3
    fi
    sleep 20
  done
  return 0
}

date -u --iso-8601=seconds >"$root/start.txt"
require_health || { echo 2 >"$root/exit-code.txt"; exit 2; }

overall=0

# F accuracy
if ! run_phase F-accuracy "${COMMON[@]}" --out "$root/F-accuracy/results" --accuracy-only --accuracy-par 4 --accuracy-max-tokens 4096; then
  overall=1
fi
require_health || { echo 3 >"$root/exit-code.txt"; exit 3; }

# Gradient: 3k/60k/100k × C1,2,4,8
if ! run_phase gradient "${COMMON[@]}" --out "$root/gradient/results" \
  --matrix "3000:1000:50:1,2,4,8;60000:1000:95:1,2,4,8;100000:1000:0:1,2,4,8"; then
  overall=1
fi
require_health || { echo 3 >"$root/exit-code.txt"; exit 3; }

# A realtext 3k/10k/32k @ C1,2,4,8  (tiny random skipped via empty? use one cheap matrix point then realtext — instead run as custom datasets)
# Prefer script native --realtext path: include a single C1 short matrix point as calibration then realtext.
if ! run_phase A-realtext "${COMMON[@]}" --out "$root/A-realtext/results" \
  --matrix "3000:1000:50:1" \
  --realtext "$FIX/realtext" \
  --output-len 1000 \
  --skip-chat-template; then
  overall=1
fi
require_health || { echo 3 >"$root/exit-code.txt"; exit 3; }

# B coding (offline custom fallback; HF InstructCoder unreachable)
if ! run_phase B-coding "${COMMON[@]}" --out "$root/B-coding/results" \
  --dataset "custom:$FIX/custom/coding_prompts.jsonl" \
  --output-len 1000 \
  --skip-chat-template; then
  overall=1
fi
require_health || { echo 3 >"$root/exit-code.txt"; exit 3; }

# C think: realtext_10k → 4000 @ C1,2,4,8
if ! run_phase C-think "${COMMON[@]}" --out "$root/C-think/results" \
  --dataset "custom:$FIX/realtext/realtext_10k.jsonl" \
  --output-len 4000 \
  --skip-chat-template; then
  overall=1
fi
require_health || { echo 3 >"$root/exit-code.txt"; exit 3; }

# D multiturn @ C1,2,4,8
if ! run_phase D-multiturn "${COMMON[@]}" --out "$root/D-multiturn/results" \
  --dataset "multiturn:60000:5000:5" \
  --mt-dir "$MT_DIR"; then
  overall=1
fi
require_health || { echo 3 >"$root/exit-code.txt"; exit 3; }

# E rate scan on 3k, cap concurrency 8
if ! run_phase E-rate "${COMMON[@]}" --out "$root/E-rate/results" \
  --matrix "3000:1000:0:1" \
  --only-rate --rate "0.5,1,1.5,2" --rate-cap 8 --rate-seconds 60 \
  --slo "ttft:3000,tpot:50"; then
  overall=1
fi

# Merge CSVs
{
  echo "phase,isl,osl,hit,c,nreq,out_tps,ttft_p50,tpot_p50,ttft_p99,tpot_p99,total_tps,success,accept,ttft_t1,ttft_tn,ds,rate,slo_ttft,slo_tpot,slo_pct,good_tps,goodput"
  for ph in gradient A-realtext B-coding C-think D-multiturn E-rate; do
    f=$root/$ph/ardelva_points.csv
    if [[ -f "$f" ]]; then
      awk -v p="$ph" -F, "NR>1 {print p\",\"\$0}" "$f"
    fi
  done
} >"$root/all_points.csv"

date -u --iso-8601=seconds >"$root/end.txt"
printf "%s\n" "$overall" >"$root/exit-code.txt"
echo "FULL_SUITE_DONE rc=$overall out=$root" | tee -a "$root/master.log"
exit "$overall"
