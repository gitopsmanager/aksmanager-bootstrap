# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Written by bootstrap-cluster-identities.yml as identity.auto.tfvars.json.

variable "cluster" {
  type = object({
    name            = string
    resource_group  = string
    subscription_id = string
    id              = string # the managed cluster's resource ID
    oidc_issuer_url = string # its OIDC issuer, which the federated credential trusts
  })
}

variable "identity" {
  description = "external-dns, external-secrets or aso."
  type        = string
  validation {
    condition     = contains(["external-dns", "external-secrets", "aso"], var.identity)
    error_message = "identity must be external-dns, external-secrets or aso."
  }
}

variable "identity_resource_group" {
  description = "Where the identity is created: the shared services resource group (setup-pipeline.ps1)."
  type        = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "dns_zone_ids" {
  description = "external-dns: the zones it writes to."
  type        = list(string)
  default     = []
}

variable "key_vault_id" {
  description = "external-secrets: the vault it reads."
  type        = string
  default     = ""
}

variable "aso_role_name" {
  description = "aso: the role setup-pipeline.ps1 creates."
  type        = string
  default     = "AKSManagerNodePoolOperator"
}

variable "aso_app_identity_role_name" {
  description = "aso: the workload identity role setup-pipeline.ps1 creates (AKSManagerAppIdentityOperator); empty for none."
  type        = string
  default     = ""
}

variable "app_identity_scopes" {
  description = "aso: where it may make workload identities (the cluster's subscription)."
  type        = list(string)
  default     = []
}

variable "app_grant_extra_roles" {
  description = <<-EOT
    aso: roles the client allows workload identities to be given, beyond ours
    (main.tf app_roles_ours), each a role name or GUID: a built-in role, or
    the client's own custom role. From the client's app-grant-roles.json.
    Azure refuses any role on neither list.
  EOT
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for r in var.app_grant_extra_roles : length(trimspace(r)) > 0 && !contains(["owner", "user access administrator", "role based access control administrator", "8e3af657-a8ff-443c-a75c-2fe8c4bcb635", "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9", "f58310d9-a9f6-439a-9e8d-f62e7b41a168"], lower(trimspace(r)))])
    error_message = "app_grant_extra_roles cannot hold Owner, User Access Administrator or Role Based Access Control Administrator: those would let a workload grant itself anything."
  }
}

variable "platform_grant_scopes" {
  description = <<-EOT
    aso, for a cluster created with platform_identities on: the vault and DNS
    zones where Azure Service Operator may grant the platform components their
    roles (core-stack components/platform-identities). It gets Role Based
    Access Control Administrator there, with an ABAC condition: only the roles
    on the fixed list (Key Vault Secrets User, DNS Zone Contributor, Private
    DNS Zone Contributor), only to service principals. Empty for none.
  EOT
  type        = list(string)
  default     = []
}

variable "subnet_vnet_ids" {
  description = "aso: the VNets of the cluster's node pool subnets (joining a subnet is checked against the caller)."
  type        = list(string)
  default     = []
}
