"""vLLM's ROCm platform, minus RCCL, for an emulated GPU.

vLLM opens a torch.distributed process group at engine start even for
one GPU, on the platform's `dist_backend`, which for ROCm is NCCL --
RCCL. Creating that group loads RCCL's device code. On a rocjitsu
guest every code object goes through the guest runtime's gfx1250
B0-to-A0 translator first (libhsa_hotswap_rocjitsu), and for RCCL's
that does not finish: the engine grows to 4.8 GB of memory that swap
cannot take and is OOM-killed before any weights load. Measured in a
6 GB guest with 16 GB of swap, in vLLM and in a four-line
`init_process_group(backend="nccl")` alike; the same call with gloo
takes 0.0 s and 555 MiB.

A one-GPU engine sends nothing over that group, so gloo loses
nothing here. Everything else is vLLM's own RocmPlatform, which is
the point: the lane tests the wheels' ROCm path, and this is the one
attribute of it the emulator cannot run.

An out-of-tree platform plugin outranks the built-in ones, so
installing this package is what selects it. It stands down unless
ROCM_BAKE_VM_PLATFORM=1, so that having it installed changes nothing
by accident.
"""
import os


def register():
    if os.environ.get("ROCM_BAKE_VM_PLATFORM") != "1":
        return None
    # The built-in detection, not a copy of it: no card, no platform.
    from vllm.platforms import rocm_platform_plugin
    if rocm_platform_plugin() is None:
        return None
    return "rocm_bake_vm.platform.RocmGlooPlatform"
