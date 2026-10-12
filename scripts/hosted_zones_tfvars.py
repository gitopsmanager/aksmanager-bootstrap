#!/usr/bin/env python3
# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
"""Validate hosted-zones.json and write it as Terraform variables.

    python3 scripts/hosted_zones_tfvars.py [hosted-zones.json] [out.auto.tfvars.json]

Writes terraform/lets-encrypt/hosted-zones.auto.tfvars.json by default, which
Terraform loads automatically and .gitignore keeps out of the repo.

Validation happens here, before Terraform, for the reason the AWS workflow gives:
a malformed zone list otherwise surfaces minutes into a run, and a zone silently
missing from the list makes Terraform plan to destroy that certificate (which
prevent_destroy then refuses, but only after the run has failed).
"""

import json
import re
import sys
from pathlib import Path

GUID = re.compile(r"^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")
# Key Vault secret names allow alphanumerics and dashes; underscores in a prefix
# are turned into dashes when the secret is named, so they are allowed here.
PREFIX = re.compile(r"^[A-Za-z0-9_-]+$")
# Azure resource group names: alphanumerics, underscore, dash, period,
# parentheses; up to 90 characters; not ending in a period.
RESOURCE_GROUP = re.compile(r"^[\w\-.()]{1,90}(?<!\.)$")


def main() -> int:
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "hosted-zones.json")
    out = Path(sys.argv[2] if len(sys.argv) > 2 else "terraform/lets-encrypt/hosted-zones.auto.tfvars.json")

    try:
        doc = json.loads(src.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"{src} not found. Copy example-hosted-zones.json and fill it in.")
        return 1
    except json.JSONDecodeError as e:
        print(f"{src} is not valid JSON: {e}")
        return 1

    problems = []

    email = doc.get("acme-email", "")
    if not email:
        problems.append("missing top-level 'acme-email' -- Let's Encrypt requires a registration contact, and it is where expiry warnings go")
    elif "@" not in email:
        problems.append(f"acme-email '{email}' does not look like an address")

    staging = doc.get("acme-staging", False)
    if not isinstance(staging, bool):
        problems.append(f"acme-staging must be true or false, not {staging!r}")

    zones = doc.get("hosted-zones") or []
    if not zones:
        problems.append("no 'hosted-zones' entries")

    resolved, seen_zone, seen_secret = {}, set(), {}
    for i, z in enumerate(zones):
        where = z.get("public-dns-zone") or f"entry {i}"
        for field in ("dns-zone-prefix", "public-dns-zone", "subscription", "resource-group"):
            if not z.get(field):
                problems.append(f"{where}: missing '{field}'")

        prefix = z.get("dns-zone-prefix", "")
        if prefix:
            if not PREFIX.fullmatch(prefix):
                problems.append(f"{where}: dns-zone-prefix '{prefix}' may contain only letters, digits, '-' and '_'")
            # Two prefixes that differ only by '_' vs '-' would name one secret.
            secret = prefix.replace("_", "-") + "-dns-zone-certs"
            if secret in seen_secret:
                problems.append(f"{where}: dns-zone-prefix '{prefix}' and '{seen_secret[secret]}' both name the secret '{secret}'")
            seen_secret[secret] = prefix

        sub = str(z.get("subscription", ""))
        if sub and not GUID.fullmatch(sub):
            problems.append(f"{where}: subscription '{sub}' is not a subscription ID (GUID)")

        rg = z.get("resource-group", "")
        if rg and not RESOURCE_GROUP.fullmatch(rg):
            problems.append(f"{where}: resource-group '{rg}' is not a valid resource group name")

        name = z.get("public-dns-zone", "")
        if name:
            if name in seen_zone:
                problems.append(f"{name}: listed more than once")
            seen_zone.add(name)
            # Keyed by zone name, so the Terraform address of a certificate is
            # stable when entries are reordered.
            resolved[name] = {
                "dns_zone_prefix": prefix,
                "public_dns_zone": name,
                "subscription_id": sub,
                "resource_group": rg,
            }

    if problems:
        print(f"{src} has problems:")
        for p in problems:
            print(f"  - {p}")
        return 1

    out.write_text(json.dumps({
        "acme_email": email,
        "acme_use_staging": staging,
        "hosted_zones": resolved,
    }, indent=2) + "\n", encoding="utf-8")

    print(f"OK: {len(resolved)} zone(s) valid, acme-email={email} -> {out}")
    if staging:
        print("NOTE: acme-staging is true -- certificates chain to an untrusted root.")
    for z in resolved.values():
        print(f"  {z['dns_zone_prefix']:10} {z['public_dns_zone']}  subscription={z['subscription_id']}  rg={z['resource_group']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
