# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Two subscriptions:
#   azurerm         the cluster's
#   azurerm.shared  the shared services one, where the Key Vault is
# Both signed in with az (ARM_USE_CLI), as the runner.
provider "azurerm" {
  features {}
  tenant_id                       = var.runtime.tenant_id
  subscription_id                 = var.cluster.subscription_id
  resource_provider_registrations = "none"
}

provider "azurerm" {
  alias = "shared"
  features {
    key_vault {
      # A secret this stage made is left in the vault if the stage is ever
      # destroyed; the vault's soft delete is not ours to purge.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = false
    }
  }
  tenant_id                       = var.runtime.tenant_id
  subscription_id                 = var.runtime.shared_subscription_id
  resource_provider_registrations = "none"
}

# The cluster's local admin credentials, as the agent's admin context
# (create_admin_context: az aks get-credentials --admin). The agent's create
# leaves local accounts on; a cluster that later turns them off has none, and
# a re-run of this stage then needs kubelogin instead.
data "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster.name
  resource_group_name = var.cluster.resource_group
}

locals {
  kube = data.azurerm_kubernetes_cluster.this.kube_admin_config[0]
}

provider "kubernetes" {
  host                   = local.kube.host
  client_certificate     = base64decode(local.kube.client_certificate)
  client_key             = base64decode(local.kube.client_key)
  cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = local.kube.host
    client_certificate     = base64decode(local.kube.client_certificate)
    client_key             = base64decode(local.kube.client_key)
    cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
  }
}
