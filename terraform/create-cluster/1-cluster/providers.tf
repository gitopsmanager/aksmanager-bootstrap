# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# The cluster's subscription, signed in with az (ARM_USE_CLI): on GitOps
# Manager's long-job runner on Azure (gom-azure-long) as the runners' managed
# identity, elsewhere through the workflow's azure/login. The runner's
# identity needs the roles in the README's "Before the first run".
provider "azurerm" {
  features {}
  tenant_id       = var.runtime.tenant_id
  subscription_id = var.cluster.subscription_id
  # Registers nothing: setup did that for every AKS subscription.
  resource_provider_registrations = "none"
}

locals {
  # The agent's azure_managed_tags (packages/azureapi), with managed_by naming
  # Terraform, the creator, as the EKS create does ("Managed By = Terraform"):
  # the GUI and the agent treat the cluster as another tool's (its version is
  # not upgraded by them, its pools are scaled only). environment is the zone
  # prefix, as the agent's environment_from_zone.
  cost_tag = var.runtime.cost_tag_name == "" ? {} : { (var.runtime.cost_tag_name) = var.runtime.cost_tag_value }
  tags = merge(
    {
      "AKSManager"  = "Managed"
      "deployed_by" = "GitOpsManager"
      "managed_by"  = "Terraform"
      "environment" = var.cluster.zone_prefix
    },
    local.cost_tag,
  )
}
