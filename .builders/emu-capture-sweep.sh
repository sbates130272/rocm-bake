#!/usr/bin/env bash
# Drive load at a traced vLLM so its step trace covers a useful range
# of (tokens, concurrency) cells. Run it while `make emu-capture-serve`
# is up; see docs/architecture/emulation.md.
#
# Rates are scaled to THIS device, not borrowed from upstream. A
# measured probe put saturation at ~0.75 req/s for 256-in/128-out on
# gfx1151 with Qwen3-8B (20 CUs), so upstream's 1..32 req/s ladder
# would saturate at every rung and fill a single concurrency bucket.
# Re-probe before trusting these rungs on another card:
#
#     vllm bench serve --dataset-name random --random-input-len 256 \
#         --random-output-len 128 --num-prompts 8 --request-rate inf These
# rungs straddle saturation instead, and each cell is sized to run
# roughly 100 s.
#
# Two prompt shapes: a decode-heavy one and a prefill-heavy one. The
# pack's prefill and decode tables are keyed on scheduled tokens, and
# one shape only ever visits a narrow band of them.
#
# Warmup is excluded by LINE COUNT, not by a marker. The builder does
# honour a {"__marker__":"profiling_start"} line, but the tracer
# buffers up to 200 records and appends in bulk, so a marker written
# from outside can land before records measured before it. Counting
# lines after a flush is unambiguous.
set -uo pipefail

TRACE="${TRACE:-/tmp/emu-trace/steps.jsonl}"
MODEL="${MODEL:-Qwen/Qwen3-8B}"
CTR="${CTR:-rocm-serving-vllm-1}"

lines() { wc -l < "$TRACE" 2>/dev/null || echo 0; }
steps() { grep -c total_tokens "$TRACE" 2>/dev/null || echo 0; }

bench() {  # in_len out_len rate num_prompts seed
    docker exec "$CTR" vllm bench serve \
        --backend vllm --model "$MODEL" \
        --dataset-name random \
        --random-input-len "$1" --random-output-len "$2" \
        --num-prompts "$4" --request-rate "$3" --seed "$5" \
        --ignore-eos \
        2>&1 | grep -E 'Successful requests|Request throughput|Output token throughput|Mean TPOT' \
             | sed 's/^/        /'
}

cell() {  # in_len out_len rate num_prompts
    local t0 before
    before=$(steps)
    t0=$(date +%s)
    printf '  %5s in / %3s out  rate=%-4s n=%-3s' "$1" "$2" "$3" "$4"
    echo
    bench "$1" "$2" "$3" "$4" 1
    echo "        -> $(( $(steps) - before )) steps in $(( $(date +%s) - t0 ))s"
}

echo "== warmup (compile and cudagraph capture; excluded from the pack)"
bench 256 128 4 16 0 >/dev/null 2>&1
bench 1024 64 4 8 0 >/dev/null 2>&1
sleep 5
START=$(lines)
echo "   trace has $START lines after warmup; the pack starts here"
echo

echo "== decode-heavy: 256 in / 128 out"
cell 256 128 0.1  10
cell 256 128 0.25 25
cell 256 128 0.5  40
cell 256 128 1.0  60
cell 256 128 inf  48
echo
echo "== prefill-heavy: 1024 in / 64 out"
cell 1024 64 0.25 25
cell 1024 64 0.5  40
cell 1024 64 inf  32

sleep 5
echo
echo "== done: $(lines) lines, $(steps) steps; warmup ended at line $START"
echo "START_LINE=$START"
echo
echo "Next: stop the server so the trace is flushed, then drop the"
echo "warmup and build the pack --"
echo "  make emu-capture-down GPU_HOST=<node>"
echo "  { head -1 $TRACE; tail -n +$((START + 1)) $TRACE; } > trimmed.jsonl"
