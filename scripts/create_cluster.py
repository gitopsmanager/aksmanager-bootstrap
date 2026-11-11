#!/usr/bin/env python3
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
"""
Steps of bootstrap-create-cluster.yml (AKS) that are not Terraform.

    prepare     validate clusters/<name>.json, fill in what setup knows
                (pinned.auto.tfvars.json: the container registry) and
                Traefik's address, and write the variables every stage reads
                (build/create-cluster/create.auto.tfvars.json)
    aso-tfvars  write terraform/cluster-identities' variables for the cluster's
                ASO identity, as bootstrap-cluster-identities.yml writes them
    register    write clusters/<name>.outputs.json: what core-stack's install,
                its workflows and the handover read

The AKS counterpart of eksmanager-bootstrap's and gkemanager-bootstrap's
scripts/create_cluster.py. Standard library only.
"""
import argparse
import ipaddress
import json
import os
import re
import sys

# AKS allows 1-63 letters, digits, '-' and '_'. No '_' here: GitOps Manager's
# names are letters, digits and '-' on every cloud.
NAME_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
GUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
RG_RE = re.compile(r"^[\w\-.()]{0,89}[\w\-()]$")
LOCATION_RE = re.compile(r"^[a-z0-9]+$")
VERSION_RE = re.compile(r"^1\.[0-9]{2}(\.[0-9]+)?$")
VM_RE = re.compile(r"^Standard_[A-Za-z0-9_]+$")
NS_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
SUBNET_RE = re.compile(r"^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/"
                       r"virtualNetworks/[^/]+/subnets/[^/]+$", re.IGNORECASE)
ACR_RE = re.compile(r"^[A-Za-z0-9]{5,50}$")
# A zone prefix names its certificate secret as it is, on every cloud: letters,
# digits and dashes; an underscore is refused, never rewritten.
PREFIX_RE = re.compile(r"^[A-Za-z0-9-]+$")
DAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
OFFSET_RE = re.compile(r"^[+-][0-9]{2}:[0-9]{2}$")
TIME_RE = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")

SPEC_KEYS = {"name", "subscription_id", "resource_group", "location", "zone_prefix", "dns_zone",
             "kubernetes_version", "zones", "tier", "network", "entra", "upgrade", "maintenance",
             "container_registry", "node_pools", "global_namespaces"}
OPTIONAL_KEYS = {"zones", "maintenance", "container_registry", "global_namespaces", "entra", "upgrade", "tier"}
NETWORK_KEYS = {"subnet_id", "plugin", "plugin_mode", "policy", "dataplane", "pod_cidr", "service_cidr",
                "dns_service_ip", "traefik_ip"}
POOL_KEYS = {"vm_size", "count", "disk_size", "disk_type"}
WINDOW_KEYS = {"day_of_week", "interval_weeks", "duration", "utc_offset", "start_time", "start_date"}
AUTO_CHANNELS = ("none", "patch", "stable", "rapid", "node-image")
NODE_OS_CHANNELS = {"none": "None", "unmanaged": "Unmanaged", "securitypatch": "SecurityPatch",
                    "nodeimage": "NodeImage"}


def app_grant_extra_roles(path="app-grant-roles.json"):
    """The client's additions to the roles workload identities may be given:
    app-grant-roles.json, {"roles": ["<name or GUID>", ...]}, theirs."""
    if not os.path.exists(path):
        return []
    roles = load_json(path, path).get("roles") or []
    if not isinstance(roles, list) or not all(isinstance(r, str) and r.strip() for r in roles):
        fail(f"{path}: roles must be a list of role names or GUIDs")
    return [r.strip() for r in roles]


def fail(msg):
    print(f"::error::{msg}")
    sys.exit(1)


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        fail(f"{what} not found: {path}")
    except json.JSONDecodeError as e:
        fail(f"{what} is not valid JSON ({path}): {e}")


def gh_output(**kv):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            for k, v in kv.items():
                f.write(f"{k}={v}\n")


def cidr(value):
    try:
        return ipaddress.ip_network(str(value), strict=True)
    except ValueError:
        return None


def traefik_ip_from(prefix):
    """The agent's af7task.get_fixed_ip_from_subnet_cidr: the subnet's address
    with its last octet set to 100 (10.1.2.0/24 -> 10.1.2.100)."""
    octets = str(prefix).split("/")[0].split(".")
    octets[-1] = "100"
    return ".".join(octets)


def normalise(spec):
    """Defaults, and the agent's spellings in one form, before validation."""
    spec.setdefault("zones", [])
    spec["zones"] = [str(z) for z in spec["zones"]] if isinstance(spec["zones"], list) else spec["zones"]
    spec.setdefault("tier", "free")
    spec.setdefault("global_namespaces", [])
    spec.setdefault("maintenance", {})
    spec.setdefault("entra", {"enabled": False, "azure_rbac": False, "admin_group_object_ids": []})
    spec.setdefault("upgrade", {"auto_upgrade_channel": "none", "node_os_upgrade_channel": "NodeImage"})
    net = spec.get("network")
    if isinstance(net, dict):
        net.setdefault("plugin_mode", "transparent")
        net.setdefault("dataplane", "")
        net.setdefault("pod_cidr", "")
        net.setdefault("traefik_ip", "")
        for k in ("plugin", "plugin_mode", "policy", "dataplane"):
            if isinstance(net.get(k), str):
                net[k] = net[k].strip().lower()
    up = spec["upgrade"]
    if isinstance(up, dict):
        if isinstance(up.get("auto_upgrade_channel"), str):
            up["auto_upgrade_channel"] = up["auto_upgrade_channel"].strip().lower()
        ch = up.get("node_os_upgrade_channel")
        if isinstance(ch, str) and ch.strip().lower() in NODE_OS_CHANNELS:
            up["node_os_upgrade_channel"] = NODE_OS_CHANNELS[ch.strip().lower()]
    if isinstance(spec["maintenance"], dict):
        for k in ("auto_upgrade", "node_os"):
            w = spec["maintenance"].get(k)
            if isinstance(w, dict):
                # The agent's create_maintenance_schedules defaults.
                w.setdefault("day_of_week", "Saturday")
                w.setdefault("interval_weeks", 1)
                w.setdefault("duration", 4)
                w.setdefault("utc_offset", "+00:00")
                w.setdefault("start_time", "00:00")
                w.setdefault("start_date", "")
                if isinstance(w["day_of_week"], str):
                    w["day_of_week"] = w["day_of_week"].strip().capitalize()
                if isinstance(w["start_time"], str):
                    w["start_time"] = w["start_time"][:5]
            spec["maintenance"].setdefault(k, None)
    pools = spec.get("node_pools")
    if isinstance(pools, dict):
        for p in pools.values():
            if isinstance(p, dict):
                p.setdefault("disk_type", "Managed")
    return spec


def validate(spec):
    errors = []
    extra = set(spec) - SPEC_KEYS
    if extra:
        errors.append(f"unknown keys {sorted(extra)}")
    for k in sorted(SPEC_KEYS - OPTIONAL_KEYS - set(spec)):
        errors.append(f"missing {k}")
    if errors:
        return errors
    if not NAME_RE.match(str(spec["name"])):
        errors.append("name: letters, digits and '-' only, 1-63 characters, starting and ending with a letter or digit")
    if not GUID_RE.match(str(spec["subscription_id"])):
        errors.append(f"subscription_id: not a subscription ID: {spec['subscription_id']!r}")
    if not RG_RE.match(str(spec["resource_group"])):
        errors.append(f"resource_group: not a resource group name: {spec['resource_group']!r}")
    if not LOCATION_RE.match(str(spec["location"])):
        errors.append(f"location: an Azure region name, e.g. westeurope, got {spec['location']!r}")
    if not VERSION_RE.match(str(spec["kubernetes_version"])):
        errors.append("kubernetes_version: major.minor (the newest patch) or an exact patch, e.g. 1.33 or 1.33.5")
    if not PREFIX_RE.match(str(spec["zone_prefix"])):
        errors.append(f"zone_prefix: letters, digits and '-' only ('_' is not allowed), got {spec['zone_prefix']!r}")
    if "." not in str(spec["dns_zone"]):
        errors.append("dns_zone: a DNS name, e.g. az-dev.client.example.com")
    zones = spec["zones"]
    if not isinstance(zones, list) or any(z not in ("1", "2", "3") for z in zones) or len(set(zones)) != len(zones):
        errors.append('zones: a list of availability zones, e.g. ["1", "2", "3"], or [] for a regional cluster')
    if str(spec["tier"]).lower() not in ("free", "standard", "premium"):
        errors.append("tier: free, standard or premium")

    net = spec["network"]
    svc = None
    if not isinstance(net, dict):
        errors.append("network must be an object")
    else:
        extra = set(net) - NETWORK_KEYS
        if extra:
            errors.append(f"network: unknown keys {sorted(extra)}")
        for k in sorted({"subnet_id", "plugin", "policy", "service_cidr", "dns_service_ip"} - set(net)):
            errors.append(f"network: missing {k}")
        if not SUBNET_RE.match(str(net.get("subnet_id", ""))):
            errors.append("network.subnet_id: a subnet's resource ID (/subscriptions/.../virtualNetworks/<vnet>/subnets/<subnet>)")
        plugin, mode = net.get("plugin"), net.get("plugin_mode")
        policy, dataplane = net.get("policy"), net.get("dataplane")
        if plugin not in ("azure", "kubenet", "none"):
            errors.append("network.plugin: azure, kubenet or none")
        if mode not in ("transparent", "overlay"):
            errors.append("network.plugin_mode: transparent or overlay")
        elif mode == "overlay" and plugin != "azure":
            errors.append("network.plugin_mode overlay needs network.plugin azure")
        if policy not in ("azure", "calico", "cilium", "none"):
            errors.append("network.policy: azure, calico, cilium or none")
        if dataplane not in ("", "cilium"):
            errors.append('network.dataplane: "" (classic) or cilium')
        # As the GUI page: AKS takes the Cilium policy only with the Cilium
        # data plane, and that only with Azure CNI in overlay mode.
        if dataplane == "cilium" and not (plugin == "azure" and mode == "overlay" and policy == "cilium"):
            errors.append("network.dataplane cilium needs plugin azure, plugin_mode overlay and policy cilium")
        if policy == "cilium" and dataplane != "cilium":
            errors.append("network.policy cilium needs network.dataplane cilium")
        svc = cidr(net.get("service_cidr", ""))
        if svc is None:
            errors.append("network.service_cidr: a CIDR, e.g. 10.0.0.0/16")
        try:
            dns_ip = ipaddress.ip_address(str(net.get("dns_service_ip", "")))
            if svc is not None and (dns_ip not in svc or dns_ip == svc.network_address):
                errors.append("network.dns_service_ip must be inside network.service_cidr, not its first address")
        except ValueError:
            errors.append("network.dns_service_ip: an IP address inside service_cidr, e.g. 10.0.0.10")
        if net.get("pod_cidr"):
            pods = cidr(net["pod_cidr"])
            if mode != "overlay":
                errors.append("network.pod_cidr is for overlay mode only")
            elif pods is None:
                errors.append("network.pod_cidr: a CIDR, e.g. 192.168.0.0/16")
            elif svc is not None and pods.overlaps(svc):
                errors.append("network.pod_cidr must not overlap network.service_cidr")
        if net.get("traefik_ip"):
            try:
                ipaddress.ip_address(str(net["traefik_ip"]))
            except ValueError:
                errors.append("network.traefik_ip: an IP address in the subnet, or leave it out (the subnet's .100)")

    entra = spec["entra"]
    if not isinstance(entra, dict) or not isinstance(entra.get("enabled"), bool) \
            or not isinstance(entra.get("azure_rbac", False), bool):
        errors.append("entra: {enabled: bool, azure_rbac: bool, admin_group_object_ids: [object IDs]}")
    else:
        entra.setdefault("azure_rbac", False)
        entra.setdefault("admin_group_object_ids", [])
        if entra["azure_rbac"] and not entra["enabled"]:
            errors.append("entra.azure_rbac needs entra.enabled")
        ids = entra["admin_group_object_ids"]
        if not isinstance(ids, list) or any(not GUID_RE.match(str(i)) for i in ids):
            errors.append("entra.admin_group_object_ids: a list of Entra group object IDs")

    up = spec["upgrade"]
    if not isinstance(up, dict):
        errors.append("upgrade must be an object")
    else:
        if up.get("auto_upgrade_channel") not in AUTO_CHANNELS:
            errors.append(f"upgrade.auto_upgrade_channel: one of {', '.join(AUTO_CHANNELS)}")
        if up.get("node_os_upgrade_channel") not in NODE_OS_CHANNELS.values():
            errors.append(f"upgrade.node_os_upgrade_channel: one of {', '.join(NODE_OS_CHANNELS.values())}")

    maint = spec["maintenance"]
    if not isinstance(maint, dict) or set(maint) - {"auto_upgrade", "node_os"}:
        errors.append("maintenance: {auto_upgrade: {...} or null, node_os: {...} or null}")
    else:
        for k, w in maint.items():
            if w is None:
                continue
            if not isinstance(w, dict) or set(w) - WINDOW_KEYS:
                errors.append(f"maintenance.{k}: keys {sorted(WINDOW_KEYS)}")
                continue
            if w["day_of_week"] not in DAYS:
                errors.append(f"maintenance.{k}.day_of_week: a day name, e.g. Saturday")
            if not isinstance(w["interval_weeks"], int) or not 1 <= w["interval_weeks"] <= 4:
                errors.append(f"maintenance.{k}.interval_weeks: 1-4")
            if not isinstance(w["duration"], int) or not 4 <= w["duration"] <= 24:
                errors.append(f"maintenance.{k}.duration: hours, 4-24")
            if not OFFSET_RE.match(str(w["utc_offset"])):
                errors.append(f"maintenance.{k}.utc_offset: e.g. +00:00 or -05:00")
            if not TIME_RE.match(str(w["start_time"])):
                errors.append(f"maintenance.{k}.start_time: HH:MM")
            if w["start_date"] and not DATE_RE.match(str(w["start_date"])):
                errors.append(f"maintenance.{k}.start_date: YYYY-MM-DD, or empty for today")

    pools = spec["node_pools"]
    if not isinstance(pools, dict) or set(pools) != {"system", "general"}:
        errors.append("node_pools: exactly system and general (the handover makes them; system's size is also the bootstrap pool's)")
    else:
        for name, pool in pools.items():
            if not isinstance(pool, dict):
                errors.append(f"node_pools.{name} must be an object")
                continue
            extra = set(pool) - POOL_KEYS
            if extra:
                errors.append(f"node_pools.{name}: unknown keys {sorted(extra)}")
            if not VM_RE.match(str(pool.get("vm_size", ""))):
                errors.append(f"node_pools.{name}.vm_size: e.g. Standard_D4s_v5")
            low = 1 if name == "system" else 0
            if not isinstance(pool.get("count"), int) or pool["count"] < low:
                errors.append(f"node_pools.{name}.count: a whole number of nodes, at least {low}")
            if not isinstance(pool.get("disk_size"), int) or pool["disk_size"] < 30:
                errors.append(f"node_pools.{name}.disk_size: GB, at least 30")
            if pool.get("disk_type") not in ("Managed", "Ephemeral"):
                errors.append(f"node_pools.{name}.disk_type: Managed or Ephemeral")

    reg = spec.get("container_registry")
    if reg is not None and (not isinstance(reg, dict) or set(reg) != {"name", "resource_group"}
                            or not ACR_RE.match(str(reg.get("name", "")))
                            or not RG_RE.match(str(reg.get("resource_group", "")))):
        errors.append("container_registry: {name, resource_group}, or leave it out for setup's registry")
    for ns in spec["global_namespaces"]:
        if not NS_RE.match(str(ns)):
            errors.append(f"global_namespaces: {ns!r} is not a namespace name")
    return errors


def cmd_prepare(a):
    spec = load_json(os.path.join(a.clusters_dir, f"{a.cluster}.json"), "Cluster file")
    if spec.get("name") != a.cluster:
        fail(f"clusters/{a.cluster}.json names the cluster {spec.get('name')!r}")
    spec = normalise(spec)
    errors = validate(spec)
    pinned = load_json(a.pinned, "pinned.auto.tfvars.json (setup-pipeline.ps1 writes it)") if a.pinned else {}
    if not errors and spec.get("container_registry") is None:
        if pinned.get("container_registry_name"):
            spec["container_registry"] = {"name": pinned["container_registry_name"],
                                          "resource_group": pinned.get("container_registry_resource_group")
                                          or pinned.get("shared_services_resource_group", "")}
        else:
            errors.append("container_registry: none in the file and none in setup's pinned.auto.tfvars.json "
                          "(the kubelet identity gets AcrPull on it, as the agent's create)")
    net = spec.get("network") or {}
    if not errors and not net.get("traefik_ip"):
        if not a.subnet_prefix:
            errors.append("network.traefik_ip: not given, and the subnet's address prefix is not known (--subnet-prefix)")
        else:
            net["traefik_ip"] = traefik_ip_from(a.subnet_prefix)
    if not errors and a.subnet_prefix:
        try:
            if ipaddress.ip_address(net["traefik_ip"]) not in ipaddress.ip_network(a.subnet_prefix, strict=False):
                errors.append(f"network.traefik_ip {net['traefik_ip']} is not in the subnet ({a.subnet_prefix})")
        except ValueError as e:
            errors.append(f"network: {e}")
    if errors:
        for e in errors:
            print(f"::error::clusters/{a.cluster}.json: {e}")
        sys.exit(1)
    runtime = json.loads(a.runtime)
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "create.auto.tfvars.json"), "w", encoding="utf-8") as f:
        json.dump({"cluster": spec, "runtime": runtime}, f, indent=2)
    gh_output(subscription_id=spec["subscription_id"], resource_group=spec["resource_group"],
              location=spec["location"])
    n = net
    print(f"{a.cluster}: {spec['subscription_id']} {spec['resource_group']} {spec['location']}, "
          f"Kubernetes {spec['kubernetes_version']}, {n['plugin']}"
          f"{' overlay' if n['plugin_mode'] == 'overlay' else ''}"
          f"{' + Cilium' if n['dataplane'] == 'cilium' else ''}, policy {n['policy']}, "
          f"zones {','.join(spec['zones']) or 'none'}, Traefik {n['traefik_ip']}")


def outputs_of(path):
    outputs = load_json(path, "Terraform outputs")

    def out(k):
        v = outputs.get(k, {})
        return v.get("value") if isinstance(v, dict) and "value" in v else v
    return out


def cmd_aso_tfvars(a):
    """terraform/cluster-identities' variables for the aso identity, exactly as
    bootstrap-cluster-identities.yml writes them, so either workflow can carry
    the same state on."""
    spec = load_json(os.path.join(a.clusters_dir, f"{a.cluster}.json"), "Cluster file")
    pinned = load_json(a.pinned, "pinned.auto.tfvars.json")
    runtime = json.loads(a.runtime)
    out = outputs_of(a.terraform_outputs)
    tags = {"AKSManager": "Managed", "deployed_by": "GitOpsManager", "managed_by": "Terraform", "cluster": a.cluster}
    if runtime.get("cost_tag_name"):
        tags[runtime["cost_tag_name"]] = runtime.get("cost_tag_value", "")
    vnet = spec["network"]["subnet_id"].split("/subnets/")[0]
    doc = {
        "cluster": {"name": a.cluster, "resource_group": spec["resource_group"],
                    "subscription_id": spec["subscription_id"], "id": out("cluster_id"),
                    "oidc_issuer_url": out("oidc_issuer_url")},
        "identity": "aso",
        "identity_resource_group": pinned["identities_resource_group"],
        "location": pinned["location"],
        "tags": tags,
        "dns_zone_ids": [],
        "key_vault_id": "",
        "aso_role_name": pinned["node_pool_role"],
        "aso_app_identity_role_name": pinned.get("app_identity_role", ""),
        "app_identity_scopes": [f"/subscriptions/{spec['subscription_id']}"],
        # The client's own additions to the roles workload identities may be
        # given (app-grant-roles.json, theirs).
        "app_grant_extra_roles": app_grant_extra_roles(),
        "subnet_vnet_ids": [vnet],
        # platform_identities: the vault and zones ASO may grant the fixed
        # list on (the workflow finds them).
        "platform_grant_scopes": json.loads(a.platform_grant_scopes or "[]"),
    }
    if not doc["cluster"]["id"] or not doc["cluster"]["oidc_issuer_url"]:
        fail("1-cluster's outputs have no cluster_id / oidc_issuer_url: run 1-cluster first")
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
    print(f"Wrote {a.out}: aso for {a.cluster}, node pool VNet {vnet}")


def cmd_register(a):
    spec = load_json(os.path.join(a.clusters_dir, f"{a.cluster}.json"), "Cluster file")
    out = outputs_of(a.terraform_outputs)
    kubelet = out("kubelet_identity") or {}
    cp = out("control_plane_identity") or {}
    record = {
        "cloud": "azure",
        "subscription_id": spec["subscription_id"],
        "resource_group": spec["resource_group"],
        "location": spec["location"],
        "zone_prefix": spec["zone_prefix"],
        "dns_zone": spec["dns_zone"],
        "kubernetes_version": out("kubernetes_version"),
        "cluster_id": out("cluster_id"),
        "oidc_issuer_url": out("oidc_issuer_url"),
        "node_resource_group": out("node_resource_group"),
        "subnet_id": out("subnet_id"),
        "load_balancer_ip": out("load_balancer_ip"),
        "bootstrap_pool": out("bootstrap_pool"),
        "kubelet_identity_id": kubelet.get("id", ""),
        "control_plane_identity_id": cp.get("id", ""),
        "aso_client_id": a.aso_client_id,
    }
    path = os.path.join(a.clusters_dir, f"{a.cluster}.outputs.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2)
        f.write("\n")
    print(f"Wrote {path}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("prepare")
    s.add_argument("--cluster", required=True)
    s.add_argument("--clusters-dir", default="clusters")
    s.add_argument("--runtime", required=True, help="JSON object of values from the workflow")
    s.add_argument("--pinned", default="", help="setup's pinned.auto.tfvars.json")
    s.add_argument("--subnet-prefix", default="", help="the subnet's address prefix, for Traefik's address")
    s.add_argument("--out", default="build/create-cluster")
    s.set_defaults(fn=cmd_prepare)
    s = sub.add_parser("aso-tfvars")
    s.add_argument("--cluster", required=True)
    s.add_argument("--clusters-dir", default="clusters")
    s.add_argument("--runtime", required=True)
    s.add_argument("--pinned", required=True)
    s.add_argument("--terraform-outputs", required=True, help="1-cluster's outputs")
    s.add_argument("--out", required=True)
    s.add_argument("--platform-grant-scopes", default="[]",
                   help="JSON list: the vault and zones ASO may grant the fixed list on (platform_identities)")
    s.set_defaults(fn=cmd_aso_tfvars)
    s = sub.add_parser("register")
    s.add_argument("--cluster", required=True)
    s.add_argument("--clusters-dir", default="clusters")
    s.add_argument("--terraform-outputs", required=True)
    s.add_argument("--aso-client-id", default="")
    s.set_defaults(fn=cmd_register)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
