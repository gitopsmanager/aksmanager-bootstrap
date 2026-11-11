# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
"""Refuse an Terraform plan that deletes or replaces anything.

    plan_guard.py <plan.json>      (terraform show -json tfplan)

Exit 0 when every change is a create, an update or a read; exit 1, listing
them, when any resource would be deleted or replaced. run_terraform_stage.sh runs
it before the apply when NO_DESTROY=1 (the operator identity workflows: they
add and change grants, and must never take an identity away by replacing it).
"""
import json
import sys


def destructive(plan):
    out = []
    for rc in plan.get("resource_changes") or []:
        actions = (rc.get("change") or {}).get("actions") or []
        if "delete" in actions:
            what = "replaced" if "create" in actions else "deleted"
            out.append(f"{rc.get('address')}: {what}")
    return out


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    with open(argv[1], encoding="utf-8") as f:
        plan = json.load(f)
    bad = destructive(plan)
    if bad:
        print("::error::The plan would delete or replace:")
        for b in bad:
            print(f"  {b}")
        return 1
    print("Plan checked: nothing deleted or replaced.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
