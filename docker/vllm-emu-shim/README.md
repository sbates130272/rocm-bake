# vllm-emu-shim

Wires [LLM-Emu](https://github.com/AKafakA/llm-emu) into vLLM without
patching vLLM.

LLM-Emu ships its vLLM wiring as a unified diff against v0.18.1. This
repo pins v0.33.0, where most of that diff no longer applies, and
regenerating it on every `VLLM_REF` bump is exactly the maintenance
this package exists to avoid. Instead the ~25 lines that emulation
actually needs are applied to vLLM's classes at plugin-load time, via
the same meta-path hook mechanism LLM-Emu already uses for
`GPUModelRunner` and `gpu_worker` in `vllm_emulator/cuda_mock.py`.

What it patches, and why each one is needed, is in
[`vllm_emu_shim/_patch.py`](vllm_emu_shim/_patch.py). What it assumes
about vLLM is re-measured by `vllm-emu-selftest`, so a bump that
invalidates an assumption fails loudly instead of serving wrong.

Everything is inert unless `VLLM_EMULATOR_ENABLE_ORACLE` is set.

```bash
vllm-emu-selftest                     # wiring is live, premises hold
vllm-emu-selftest --require-platform  # also needs a readable profile pack
vllm-emu-selftest --capture           # the capture wiring, on a GPU build
```

The other half of the package, [`_capture.py`](vllm_emu_shim/_capture.py),
records step latencies from a *real* vLLM run so a profile pack can be
measured rather than borrowed. Its one claim that cannot be read off
the code — that each step is charged to the batch the engine actually
waited for — has a test that needs no vLLM, no torch and no GPU:

```bash
python3 -I tests/test_capture_attribution.py
```

It runs in CI on every pull request, and it fails if the timing is
reverted to the submit-to-completion form upstream uses, which counts
the previous batch's remaining time twice.

Built and installed by `docker/Dockerfile.vllm-emu`; see
`docs/architecture/emulation.md` for the lane as a whole.

Install it as a wheel, not with `pip install -e`. The profile pack is
resolved at interpreter startup by a `.pth` file that only a built
wheel carries; an editable install still works, but resolves the pack
late, and the shim says so when it loads.
