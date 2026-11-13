#!/usr/bin/env python3
"""Relabel an LLM-Emu profile pack for the device it will emulate.

WHAT THIS DOES AND, MORE IMPORTANTLY, WHAT IT DOES NOT.

A profile pack is two things in one file: an identity (which device is
being emulated — name, memory, compute units) and a measurement (how
long a step took on the card the pack was captured on). This script
rewrites the first and never touches the second.

That distinction is the whole reason it exists rather than a `cp`. The
pack this repo ships is upstream's A40-Q8-Qwen3-8B.json: Qwen3-8B
captured on an NVIDIA A40, ~29 ms per decode step. Serving it under the
name gfx1250 makes the emulated device present as the AMD part — which
is legitimate, and changes real behaviour, because vLLM sizes its KV
cache from the memory this file declares. It does not make the timings
AMD timings. Nothing can, short of capturing a pack on the hardware.

So the relabelled file carries a `rocm_bake_provenance` block saying
exactly where its numbers came from. The filename is what people read;
this is what survives being read. The validator requires only `version`
and `gpu_model` and ignores unknown keys
(vllm_emulator/profile/validator.py:84), so the block costs nothing.

Memory and compute units default to whatever the source pack declares,
and are NOT invented here. A guessed HBM figure would be indistinguishable
from a measured one to every later reader, and would silently resize the
KV cache. Pass them when the real numbers are known.

Usage:
  emu-profile-pack.py SRC DST --gpu-model gfx1250
                      [--gpu-name NAME] [--memory-bytes N] [--cu-count N]
                      [--source-ref REF]
"""

import argparse
import json
import sys


TABLES = ("prefill_2d_distribution", "decode_2d_distribution",
          "step_cycle_2d_distribution")


def _count_samples(pack):
    return sum(len(r.get("samples") or [])
               for t in TABLES for r in pack.get(t, []))


def _drop_combined(pack):
    """Remove step_cycle_2d_distribution, which duplicates the other two.

    Measured on upstream's A40 pack: its keys are exactly the union of
    the prefill and decode tables, and every bucket's samples are the
    merge of theirs — 46,166 + 232,234 = 278,400, half the file. The
    oracle never reads it while both specific tables exist:
    _sample_2d_distribution picks prefill when has_prefill and decode
    otherwise, falling back to the combined table only "for older
    profile packs" that lack them (gpu_cost_oracle.py:139-146).

    Which is exactly the condition asserted here. A future pack that
    ships only the combined table would be silently gutted by this, so
    it fails loudly instead.
    """
    if "step_cycle_2d_distribution" not in pack:
        return []
    if not pack.get("prefill_2d_distribution"):
        raise SystemExit("refusing to drop step_cycle_2d_distribution: "
                         "prefill_2d_distribution is empty, so the oracle "
                         "would fall back to the table being removed")
    if not pack.get("decode_2d_distribution"):
        raise SystemExit("refusing to drop step_cycle_2d_distribution: "
                         "decode_2d_distribution is empty, so the oracle "
                         "would fall back to the table being removed")
    del pack["step_cycle_2d_distribution"]
    return ["step_cycle_2d_distribution"]


def _quantise(pack, points):
    """Replace each bucket's samples with `points` quantiles of itself.

    The oracle draws with random.choice() over the list
    (gpu_cost_oracle.py:126), so a uniform draw over evenly spaced
    quantiles IS inverse-transform sampling of the same empirical
    distribution, at `points` resolution. The first and last quantiles
    are the true min and max, so the tails survive — the decode bucket
    at tt=8,conc=7 spans 1.8 ms to 149 ms around a 30.5 ms median, and
    all three of those numbers are still in the file afterwards.

    WHY 64 AND NOT 8. Sample COUNT is load-bearing in one place:
    adaptive-K pooling grows K until the cumulative count over pooled
    buckets reaches VLLM_EMULATOR_ORACLE_MIN_SAMPLES, counting
    len(samples) rather than the recorded num_samples
    (gpu_cost_oracle.py:199-206). That floor defaults to 30, so any
    bucket that previously met it alone still does at 64 points, and
    the pooling decisions are unchanged. Buckets smaller than `points`
    are left exactly as they were. Below 30 this would start pooling
    neighbours that it did not before — quietly smoothing latency
    across batch shapes — so keep this at or above that floor.

    num_samples keeps the ORIGINAL count: it is the record of how much
    evidence the bucket rests on, which is still true, and nothing
    reads it as a length.
    """
    if points <= 0:
        return
    for name in TABLES:
        for bucket in pack.get(name, []):
            raw = bucket.get("samples") or []
            n = len(raw)
            bucket["num_samples"] = bucket.get("num_samples", n)
            if n <= points:
                continue
            ordered = sorted(raw)
            bucket["samples"] = [
                ordered[round(i * (n - 1) / (points - 1))]
                for i in range(points)
            ]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--gpu-model", required=True,
                    help="top-level gpu_model, e.g. gfx1250")
    ap.add_argument("--gpu-name", default=None,
                    help="model_config.gpu.gpu_name; defaults to --gpu-model")
    ap.add_argument("--memory-bytes", type=int, default=None,
                    help="emulated device memory; default keeps the source's")
    ap.add_argument("--cu-count", type=int, default=None,
                    help="compute units; default keeps the source's")
    ap.add_argument("--source-ref", default="",
                    help="llm-emu ref the source pack came from")
    ap.add_argument("--quantile-points", type=int, default=64,
                    help="per-bucket quantile points; 0 keeps every raw "
                         "sample (default: 64)")
    ap.add_argument("--keep-combined", action="store_true",
                    help="keep step_cycle_2d_distribution, which is an exact "
                         "duplicate of prefill+decode")
    args = ap.parse_args(argv)

    with open(args.src, encoding="utf-8") as fh:
        pack = json.load(fh)

    before = _count_samples(pack)
    dropped = [] if args.keep_combined else _drop_combined(pack)
    _quantise(pack, args.quantile_points)
    after = _count_samples(pack)

    gpu = pack.setdefault("model_config", {}).setdefault("gpu", {})
    src_model = pack.get("gpu_model", "?")
    src_name = gpu.get("gpu_name", "?")

    pack["gpu_model"] = args.gpu_model
    gpu["gpu_name"] = args.gpu_name or args.gpu_model
    if args.memory_bytes is not None:
        gpu["gpu_memory_bytes"] = args.memory_bytes
    if args.cu_count is not None:
        gpu["gpu_sm_count"] = args.cu_count

    # Left exactly as captured, and worth naming so nobody edits it by
    # accident: gpu_compute_capability is a CUDA concept with no AMD
    # meaning. vLLM still queries it through the platform, so it keeps
    # the source's value rather than acquiring a made-up one.
    pack["rocm_bake_provenance"] = {
        "relabelled_by": "docker/emu-profile-pack.py",
        "source_file": args.src.rsplit("/", 1)[-1],
        "source_gpu_model": src_model,
        "source_gpu_name": src_name,
        "source_llm_emu_ref": args.source_ref,
        "latencies_are_measured_on": src_name,
        "dropped_tables": dropped,
        "quantile_points": args.quantile_points,
        "samples_before": before,
        "samples_after": after,
        "reduction_note": (
            "Bucket samples are quantiles of the originals, not the raw "
            "measurements: the oracle draws with random.choice(), so a "
            "uniform draw over evenly spaced quantiles samples the same "
            "empirical distribution. num_samples still records how many "
            "measurements each bucket rests on. Keep quantile_points at "
            "or above VLLM_EMULATOR_ORACLE_MIN_SAMPLES (default 30) or "
            "adaptive-K pooling will start merging neighbouring buckets "
            "that it previously did not."
        ),
        "warning": (
            "Only the device IDENTITY was relabelled. Every latency in "
            "this pack was measured on "
            f"{src_name} and is a placeholder until a capture on "
            f"{args.gpu_model} replaces it. Do not read these timings as "
            f"{args.gpu_model} performance."
        ),
    }

    with open(args.dst, "w", encoding="utf-8") as fh:
        json.dump(pack, fh)

    print(f"relabelled {args.src} -> {args.dst}")
    print(f"  gpu_model  {src_model} -> {pack['gpu_model']}")
    print(f"  gpu_name   {src_name} -> {gpu['gpu_name']}")
    print(f"  memory     {gpu.get('gpu_memory_bytes')} bytes"
          f"{'' if args.memory_bytes is not None else ' (from source)'}")
    print(f"  cu_count   {gpu.get('gpu_sm_count')}"
          f"{'' if args.cu_count is not None else ' (from source)'}")
    print(f"  dropped    {dropped or 'nothing'}")
    print(f"  samples    {before} -> {after}"
          f" ({args.quantile_points} quantile points per bucket)"
          if args.quantile_points > 0 else
          f"  samples    {before} (raw, not quantised)")
    print(f"  latencies  still measured on {src_name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
