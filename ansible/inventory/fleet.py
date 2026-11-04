#!/usr/bin/env python3
"""Ansible dynamic inventory over the fleet manifest.

Thin on purpose: every decision about what a node is lives in
.builders/fleet.py, and this only speaks the inventory script protocol
at it. Groups are capabilities — builds, gpus, registrys, caches,
metrics — so a play says what a node is for rather than naming
machines.

    ansible-inventory -i inventory/fleet.py --graph
    ansible-playbook -i inventory/fleet.py site.yml

FLEET / FLEET_MANIFEST select the manifest, same as everywhere else:

    FLEET=<profile> ansible-playbook -i inventory/fleet.py site.yml
"""
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent


def fleet_module():
    spec = importlib.util.spec_from_file_location(
        "fleet", ROOT / ".builders" / "fleet.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv):
    mod = fleet_module()
    try:
        data = mod.load()
    except mod.FleetError as exc:
        print(f"fleet inventory: {exc}", file=sys.stderr)
        return 1

    if "--list" in argv:
        print(mod.inventory(data))
        return 0
    # _meta carries every hostvar, so --host must return an empty
    # object rather than re-deriving them; ansible warns about the
    # mismatch if it does not.
    if "--host" in argv:
        print("{}")
        return 0
    print(json.dumps({"_meta": {"hostvars": {}}}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
