# Captured profile packs

A pack is what the emulator replays: measured per-step latencies from a
real vLLM run, keyed on the shape of the batch. Capturing one is
described in `docs/architecture/emulation.md`.

These are committed because they are small and expensive to make. A
pack costs a GPU node an hour or so of exclusive time, and the reduced
form is ~20 KB -- the raw trace it came from is ~700 KB and is not kept.

| pack | device | model | measured |
| --- | --- | --- | --- |
| `gfx1151-Q8-Qwen3-8B.json` | AMD Radeon 8060S Graphics (gfx1151, 20 CU) | Qwen/Qwen3-8B bf16 | yes |

Each file's own `rocm_bake_provenance` block records what it is: whether
the timings were measured or borrowed, what they were captured with,
and how the samples were reduced. Read that before reading the numbers.
