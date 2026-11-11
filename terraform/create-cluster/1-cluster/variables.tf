# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Both come from build/create-cluster/create.auto.tfvars.json, written by
# scripts/create_cluster.py prepare. Every stage takes the same two, so the
# workflow writes one file for all of them.

variable "cluster" {
  description = "The validated clusters/<name>.json, with the container registry filled in from setup's pinned.auto.tfvars.json when the file names none."
  type = object({
    name               = string
    subscription_id    = string
    resource_group     = string
    location           = string
    zone_prefix        = string
    dns_zone           = string
    kubernetes_version = string       # 1.33 (newest patch) or 1.33.5
    zones              = list(string) # [] for a regional cluster
    tier               = string       # free | standard | premium
    network = object({
      subnet_id      = string
      plugin         = string # azure | kubenet | none
      plugin_mode    = string # transparent | overlay
      policy         = string # azure | calico | cilium | none
      dataplane      = string # "" (classic) | cilium
      pod_cidr       = string # overlay only
      service_cidr   = string
      dns_service_ip = string
      traefik_ip     = string # "" = the subnet's address with the last octet 100, as the agent
    })
    entra = object({
      enabled                = bool
      azure_rbac             = bool
      admin_group_object_ids = list(string)
    })
    upgrade = object({
      auto_upgrade_channel    = string # none | patch | stable | rapid | node-image
      node_os_upgrade_channel = string # None | Unmanaged | SecurityPatch | NodeImage
    })
    maintenance = object({
      auto_upgrade = optional(object({
        day_of_week    = string
        interval_weeks = number
        duration       = number
        utc_offset     = string
        start_time     = string
        start_date     = string
      }))
      node_os = optional(object({
        day_of_week    = string
        interval_weeks = number
        duration       = number
        utc_offset     = string
        start_time     = string
        start_date     = string
      }))
    })
    container_registry = object({
      name           = string
      resource_group = string
    })
    node_pools = object({
      system  = object({ vm_size = string, count = number, disk_size = number, disk_type = string })
      general = object({ vm_size = string, count = number, disk_size = number, disk_type = string })
    })
    global_namespaces = list(string)
  })
}

variable "runtime" {
  description = "What the workflow knows: the tenant, the shared services subscription and its Key Vault, the CD repo, the core-stack checkout, the cost tag."
  type = object({
    tenant_id                = string
    shared_subscription_id   = string
    key_vault_name           = string
    key_vault_resource_group = string
    cd_repo_url              = string
    core_stack_dir           = optional(string, "")
    cost_tag_name            = optional(string, "")
    cost_tag_value           = optional(string, "")
  })
}

variable "skip_traefik_nic" {
  description = "Set by the workflow when the Traefik NIC was made and forgotten by an earlier run: not made again."
  type        = bool
  default     = false
}
