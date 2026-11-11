# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Terraform (see the README). State, in setup's
# state storage account (pinned.auto.tfvars.json state_storage_account):
#   tfstate-identities/clusters/<cluster>/1-cluster.tfstate
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # storage_account_name / container_name / key / subscription_id / tenant_id
  # supplied with -backend-config by scripts/run_terraform_stage.sh.
  backend "azurerm" {
    use_azuread_auth = true
  }
}
