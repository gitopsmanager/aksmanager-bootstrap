# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.

variable "shared_services_subscription_id" {
  type        = string
  description = "Subscription holding the certificate Key Vault. Required by azurerm 4.x."
}

variable "key_vault_id" {
  type        = string
  description = <<-EOT
    Resource ID of the Key Vault the certificates are written to. Created by the
    pipeline setup, not here: this module may write secrets in the vault but
    must never be able to delete or reconfigure it. The vault must use the
    Azure RBAC permission model.
  EOT
}

variable "acme_email" {
  type        = string
  description = <<-EOT
    Registration contact for the ACME account. Let's Encrypt uses it for expiry
    warnings, which are the backstop if a scheduled renewal silently stops
    running.
  EOT
}

variable "acme_use_staging" {
  type        = bool
  default     = false
  description = <<-EOT
    Point at Let's Encrypt staging. Certificates chain to an untrusted root, so
    browsers warn and gRPC clients (including the ArgoCD CLI) fail outright.
    Staging proves the issuance pipeline, not the trust experience.
  EOT
}

variable "min_days_remaining" {
  type        = number
  default     = 30
  description = <<-EOT
    Renew when fewer than this many days remain. Against a 90-day certificate
    and a weekly schedule this first fires around day 60, leaving roughly four
    further attempts before expiry, so each failure is visible for a month
    before it becomes an outage.
  EOT
}

variable "azure_auth_method" {
  type        = string
  default     = "msi"
  description = <<-EOT
    How lego authenticates to Azure DNS: "msi" for the cert job's managed
    identity, "cli" when run by hand after `az login`. Separate from the azurerm
    provider's authentication, which lego does not share.
  EOT

  validation {
    condition     = contains(["msi", "cli"], var.azure_auth_method)
    error_message = "azure_auth_method must be \"msi\" or \"cli\"."
  }
}

variable "azure_client_id" {
  type        = string
  default     = ""
  description = <<-EOT
    Client ID of the cert job's user-assigned managed identity, when
    azure_auth_method is "msi". Without it a host with several identities picks
    one arbitrarily, and the error names DNS rather than the identity.
  EOT
}

variable "hosted_zones" {
  description = <<-EOT
    Resolved zone list, written by scripts/hosted_zones_tfvars.py from
    hosted-zones.json.

    Each zone is addressed by subscription + resource group + name. Azure
    public and private DNS zones are different resource types, so unlike
    Route 53 there is no ambiguity between two zones sharing a name, as long as
    lego is told the zone is public (AZURE_PRIVATE_ZONE below).
  EOT

  type = map(object({
    dns_zone_prefix = string
    public_dns_zone = string
    subscription_id = string
    resource_group  = string
  }))
}

variable "public_resolvers" {
  type        = list(string)
  default     = ["8.8.8.8:53", "1.1.1.1:53"]
  description = <<-EOT
    Resolvers for the DNS-01 pre-flight check. Must be public: a job inside a
    VNet linked to the private zone of the same name would otherwise resolve
    the zone internally, where the challenge record does not exist, and wait
    for propagation it can never observe.
  EOT
}
