# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# tofu/cluster-identities — one workload identity for one AKS cluster
# -----------------------------------------------------------------------------
# The identities the core stack's components run as on AKS, through workload
# identity: a user-assigned managed identity, a federated credential for the
# component's service account on the cluster's OIDC issuer, and the identity's
# roles. One identity per state (identities/<cluster>/<identity>.tfstate), so
# a run can only ever touch the identity it was asked for.
#
#   external-dns      kube-system/external-dns: DNS Zone Contributor on the
#                     zone, Private DNS Zone Contributor for a private zone
#                     (the agent's assign_aks_managed_ids, azureapi.py)
#   external-secrets  external-secrets/external-secrets: Key Vault Secrets
#                     User on the vault (components/external-secrets)
#   aso               azureserviceoperator-system/azureserviceoperator-default:
#                     AKSManagerNodePoolOperator (setup-pipeline.ps1) on the
#                     cluster and on its node pools' VNets -- the agent pools
#                     of this one cluster, nothing else (components/aso)
#
# The cluster is read by the workflow (az aks show), not here: its ID and OIDC
# issuer come in as variables, and the workflow refuses a cluster whose OIDC
# issuer or workload identity is off -- turning the issuer on cannot be undone,
# so it is never done here. (azurerm's cluster data source also fetches the
# cluster's credentials, which this identity has no business holding.)
#
# Create-if-missing: bootstrap-cluster-identities.yml runs this only for an
# identity the cluster does not have, and refuses when an identity of this
# name exists outside this state. It never imports, changes or replaces one.
# The Azure create, when it exists, runs it for all three.
# -----------------------------------------------------------------------------

locals {
  subjects = {
    "external-dns"     = "system:serviceaccount:kube-system:external-dns"
    "external-secrets" = "system:serviceaccount:external-secrets:external-secrets"
    "aso"              = "system:serviceaccount:azureserviceoperator-system:azureserviceoperator-default"
  }

  # Which roles, where. external-dns's role follows from the zone's ID, as in
  # the agent: a privateDnsZones ID is a private zone.
  assignments = {
    "external-dns" = {
      for i, z in var.dns_zone_ids : "zone-${i}" => {
        scope = z
        role  = strcontains(lower(z), "/providers/microsoft.network/privatednszones/") ? "Private DNS Zone Contributor" : "DNS Zone Contributor"
      }
    }
    "external-secrets" = {
      vault = { scope = var.key_vault_id, role = "Key Vault Secrets User" }
    }
    "aso" = merge(
      { cluster = { scope = var.cluster.id, role = var.aso_role_name } },
      { for i, v in var.subnet_vnet_ids : "vnet-${i}" => { scope = v, role = var.aso_role_name } },
    )
  }[var.identity]
}

resource "azurerm_user_assigned_identity" "this" {
  name                = "${var.cluster.name}-${var.identity}"
  resource_group_name = var.identity_resource_group
  location            = var.location
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = length(local.assignments) > 0
      error_message = "Nothing to grant: external-dns needs dns_zone_ids, external-secrets needs key_vault_id."
    }
  }
}

resource "azurerm_federated_identity_credential" "this" {
  name                = "${var.cluster.name}-${var.identity}"
  resource_group_name = var.identity_resource_group
  parent_id           = azurerm_user_assigned_identity.this.id
  issuer              = var.cluster.oidc_issuer_url
  subject             = local.subjects[var.identity]
  audience            = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "this" {
  for_each = local.assignments

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.this.principal_id
  principal_type       = "ServicePrincipal"
  description          = "GitOps Manager: ${var.identity} on ${var.cluster.name}"
}
