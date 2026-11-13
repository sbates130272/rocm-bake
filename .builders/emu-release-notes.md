An arch-free vLLM that serves without a GPU: vLLM built with no device
backend, plus [LLM-Emu](https://github.com/AKafakA/llm-emu), which replaces
the GPU forward pass with a latency draw from a captured profile pack. The
scheduler, batching, admission and HTTP stack are vLLM's own code.

PEP 503 index: https://sbates130272.github.io/rocm-bake/data/wheels/emu/

Install is two steps. The index pins no torch on purpose, because PyPI's
torch for Linux is the CUDA build:

    pip install --index-url https://download.pytorch.org/whl/cpu torch

    pip install --index-url https://sbates130272.github.io/rocm-bake/data/wheels/emu/ \
        --extra-index-url https://pypi.org/simple \
        "rocm-torch[device-emu]"

Then serve:

    VLLM_EMULATOR_ENABLE_ORACLE=1 VLLM_EMULATOR_MOCK_CUDA=1 \
        vllm serve Qwen/Qwen3-8B --max-model-len 2048

What these wheels are not:

- **Not ROCm builds.** The release tag carries a ROCm version only because
  it shares publishing machinery with the per-card releases. Every wheel
  here is `py3-none-any` and contains no device code.
- **Not a performance measurement.** The emulated device presents as an AMD
  Instinct MI455X, but every latency in the profile pack was measured on an
  NVIDIA A40. The timings are placeholders until a capture on AMD hardware
  replaces them.
- **Not inference.** No weights are loaded and the output tokens are filler.

Details: https://sbates130272.github.io/rocm-bake/architecture/emulation/
