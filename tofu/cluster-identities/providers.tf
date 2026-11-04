# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# tofu/cluster-identities — providers and backend
# -----------------------------------------------------------------------------
# Applied by bootstrap-cluster-identities.yml as id-aksmanager-identities
# (setup-pipeline.ps1 step 12b), signed in with az (ARM_USE_CLI).
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # storage_account_name / container_name / key supplied with -backend-config:
  # the identities container, never the certificate state's (that holds every
  # certificate private key, and this workflow has no business reading it).
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.cluster.subscription_id
  # The identity registers no resource providers: setup did that.
  resource_provider_registrations = "none"
}
