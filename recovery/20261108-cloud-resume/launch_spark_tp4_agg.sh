#!/usr/bin/env bash
# Aggregated 4× DGX Spark TP4 (no PD / Mooncake). Tuned incumbent flags + Engram on disk.
# Run on node 103: bash launch_spark_tp4_agg.sh
set -euo pipefail

container="${1:-dsv41-node}"
moe_backend="${MOE_BACKEND:-flashinfer_cutlass}"
batched_tokens="${BATCHED_TOKENS:-4096}"
spec_k="${SPEC_K:-5}"
linear_backend="${LINEAR_BACKEND:-auto}"
max_num_seqs="${MAX_NUM_SEQS:-16}"
cudagraph_sizes="${CUDAGRAPH_SIZES:-[1,2,4,8,16]}"
kv_cache_bytes="${KV_CACHE_MEMORY_BYTES:-17179869184}"
gpu_mem_util="${GPU_MEMORY_UTILIZATION:-0.80}"
engram_dir="${ENGRAM_DISK_DIR:-/home/aaron/models/engram-tp4}"
port="${PORT:-9000}"

if ! sudo docker inspect --format '{{.State.Running}}' "$container" | grep -qx true; then
  echo "Container $container is not running" >&2
  exit 1
fi

live_serve_pids() {
  sudo docker exec "$container" sh -lc '
    for p in $(pgrep -f "[v]llm serve.*--port '"$port"'" || true); do
      st=$(ps -o stat= -p "$p" 2>/dev/null | tr -d " ")
      case "$st" in *Z*) continue ;; esac
      echo "$p"
    done
  '
}
if [ -n "$(live_serve_pids | head -1)" ]; then
  echo "A live vllm serve is already running on port $port in $container" >&2
  exit 1
fi

sudo docker exec "$container" sh -lc "mkdir -p '$engram_dir'; if [ -s /tmp/vllm-serve.log ]; then cp -a /tmp/vllm-serve.log /tmp/vllm-serve.log.bak-\$(date +%H%M%S); fi; : > /tmp/vllm-serve.log" || true

jit_warmup="${ENABLE_JIT_WARMUP:-true}"
kernel_config=$(printf '{"enable_cutedsl_warmup":false,"enable_jit_warmup":%s,"moe_backend":"%s","linear_backend":"%s"}' \
  "$jit_warmup" "$moe_backend" "$linear_backend")
spec_config=$(printf '{"method":"dspark","num_speculative_tokens":%s}' "$spec_k")
engram_config=$(printf '{"cpu_offload":true,"dp_shared_memory":false,"disk_offload_dir":"%s"}' "$engram_dir")

if [ "${SPEC_DISABLE:-0}" = 1 ]; then
  spec_config=""
fi

cmd=(
  /usr/local/bin/vllm serve /models/DeepSeek-V4.1-Flash-1017-NVFP4
  --host 0.0.0.0
  --port "$port"
  --served-model-name DeepSeek-V4.1-Flash-1017-NVFP4
  --trust-remote-code
  --tensor-parallel-size 4
  --distributed-executor-backend ray
  --tokenizer-mode deepseek_v41
  --reasoning-parser deepseek_v41
  --tool-call-parser deepseek_v41
  --enable-auto-tool-choice
  --language-model-only
  --engram-config "$engram_config"
  --max-model-len 1048576
  --block-size 64
  --max-num-seqs "$max_num_seqs"
  --max-num-batched-tokens "$batched_tokens"
  --gpu-memory-utilization "$gpu_mem_util"
  --kv-cache-dtype fp8
  --no-enable-flashinfer-autotune
  --kv-cache-memory-bytes "$kv_cache_bytes"
  --kernel-config "$kernel_config"
  --enable-chunked-prefill
  --enable-prefix-caching
  --swa-bounded-replay
  --compilation-config
  "$(printf '{"mode":0,"cudagraph_mode":"%s","cudagraph_capture_sizes":%s}' "${CUDAGRAPH_MODE:-FULL_DECODE_ONLY}" "$cudagraph_sizes")"
)

if [ -n "$spec_config" ]; then
  cmd+=(--speculative-config "$spec_config")
fi
if [ "${ENFORCE_EAGER:-0}" = 1 ]; then
  cmd+=(--enforce-eager)
fi

nccl_algo="${NCCL_ALGO_OVERRIDE:-Ring}"
docker_env=(-e "NCCL_ALGO=$nccl_algo")

printf -v command '%q ' "${cmd[@]}"
sudo docker exec "${docker_env[@]}" -d "$container" sh -lc "$command >> /tmp/vllm-serve.log 2>&1"
echo "Spark TP4 agg launch submitted moe=$moe_backend batch=$batched_tokens k=${spec_k:-off} engram=$engram_dir port=$port nccl=$nccl_algo cg=$cudagraph_sizes mode=${CUDAGRAPH_MODE:-FULL_DECODE_ONLY} kv=$kv_cache_bytes gpu_util=$gpu_mem_util jit=$jit_warmup eager=${ENFORCE_EAGER:-0}"
