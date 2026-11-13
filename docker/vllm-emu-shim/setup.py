"""Only here to put one .pth file at the top of site-packages.

Everything else about this package is declared in pyproject.toml. A
.pth has to sit beside the packages, not inside one, and setuptools
has no declarative way to say that: package-data lands inside the
package, and data-files lands under sys.prefix. Copying it into
build_lib is the mechanism setuptools itself uses for
distutils-precedence.pth.

Why the .pth exists at all is in _vllm_emu_pack_env.py.
"""

import os

from setuptools import setup
from setuptools.command.build_py import build_py

PTH = "vllm_emu_shim_pack.pth"


class build_py_with_pth(build_py):
    def run(self):
        super().run()
        self.copy_file(PTH, os.path.join(self.build_lib, PTH),
                       preserve_mode=False)


setup(cmdclass={"build_py": build_py_with_pth})
