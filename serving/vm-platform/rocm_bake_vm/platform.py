"""Imported by vLLM only once register() has named it."""
from vllm.platforms.rocm import RocmPlatform


class RocmGlooPlatform(RocmPlatform):
    dist_backend: str = "gloo"
