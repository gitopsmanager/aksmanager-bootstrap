# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# terraform/cluster-identities — one workload identity for one AKS cluster
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
  # The fixed list: the only roles Azure Service Operator may grant
  # (platform_grant_scopes). Key Vault Secrets User, DNS Zone Contributor,
  # Private DNS Zone Contributor. A role not here is refused by Azure.
  fixed_roles = join(", ", [
    "4633458b-17de-408a-b874-0445c86b69e6",
    "befefa01-2a29-4197-83a8-272ff33ce314",
    "b12aa53e-6015-4669-85d0-8515ebb3ae7f",
  ])
  fixed_list_condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.fixed_roles}} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] StringEqualsIgnoreCase 'ServicePrincipal')) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.fixed_roles}}))"

  # The roles ASO may give a workload identity of the cluster's own (core-stack
  # tools/cd_identities.py, AZURE_ROLES: the same GUIDs), anywhere in the
  # cluster's subscription (app_identity_scopes), only to service principals.
  # Ours: Storage Blob Data Reader / Contributor, Storage Queue Data Reader /
  # Contributor, Key Vault Secrets User, Azure Service Bus Data Sender /
  # Receiver, AcrPull. The client adds more with app_grant_extra_roles.
  app_roles_ours = [
    "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1",
    "ba92f5b4-2d11-453d-a403-e96b0029c9fe",
    "19e7f393-937e-4f77-808e-94535e297925",
    "974c5e8b-45b9-4653-ba55-5f855dd0fb88",
    "4633458b-17de-408a-b874-0445c86b69e6",
    "69a216fc-b8fb-44d8-bc22-1f3c2cd27a39",
    "4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0",
    "7f951dda-4ed3-4680-a7ca-43fe172d538d",
  ]
  guid_pattern     = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
  extra_role_names = toset([for r in var.app_grant_extra_roles : r if !can(regex(local.guid_pattern, r))])
  app_roles = join(", ", distinct(concat(
    local.app_roles_ours,
    [for r in var.app_grant_extra_roles : lower(r) if can(regex(local.guid_pattern, r))],
    # A role's ID is .../roleDefinitions/<guid>: the GUID is its last part.
    [for n in local.extra_role_names : lower(element(split("/", data.azurerm_role_definition.extra[n].role_definition_id), length(split("/", data.azurerm_role_definition.extra[n].role_definition_id)) - 1))],
  )))
  app_list_condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.app_roles}} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] StringEqualsIgnoreCase 'ServicePrincipal')) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.app_roles}}))"

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
      # Workload identities from the CD repo (core-stack tools/cd_identities.py):
      # managed identities and federated credentials,
      var.aso_app_identity_role_name == "" ? {} : {
        for i, s in var.app_identity_scopes : "app-identities-${i}" => { scope = s, role = var.aso_app_identity_role_name }
      },
      # and their role assignments: the allowed list only, to service principals.
      var.aso_app_identity_role_name == "" ? {} : {
        for i, s in var.app_identity_scopes : "app-grants-${i}" => {
        scope = s, role = "Role Based Access Control Administrator", condition = local.app_list_condition }
      },
      # Platform identities' role assignments: the fixed list only.
      { for i, s in var.platform_grant_scopes : "platform-grants-${i}" => {
        scope = s, role = "Role Based Access Control Administrator", condition = local.fixed_list_condition }
      },
    )
  }[var.identity]
}

# A role the client added by name (app_grant_extra_roles): its GUID, for the
# condition. Built-in or the client's own custom role.
data "azurerm_role_definition" "extra" {
  for_each = var.identity == "aso" ? local.extra_role_names : toset([])
  name     = each.value
  scope    = length(var.app_identity_scopes) > 0 ? var.app_identity_scopes[0] : null
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
  condition            = try(each.value.condition, null)
  condition_version    = try(each.value.condition, null) == null ? null : "2.0"
  description          = "GitOps Manager: ${var.identity} on ${var.cluster.name}"
}
