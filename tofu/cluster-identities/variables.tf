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

variable "subnet_vnet_ids" {
  description = "aso: the VNets of the cluster's node pool subnets (joining a subnet is checked against the caller)."
  type        = list(string)
  default     = []
}
