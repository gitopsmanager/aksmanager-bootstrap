# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Stage 2 of 2 (3 with the handover): what the cluster needs before Argo CD
# takes over. The AKS counterpart of eksmanager-bootstrap's 4-platform and
# gkemanager-bootstrap's 3-platform.
#
#   StorageClass default-retain  exactly the agent's (kubeapi
#                                create_retain_storage_class, azure): ECK,
#                                Redis and the rest ask for it. AKS's own
#                                "default" class is left alone
#   namespaces                   the cluster file's, and argocd (the agent's
#                                global namespaces, check_and_create_namespace)
#   the Argo CD admin password   per cluster, in the shared services Key Vault
#   Argo CD itself               from core-stack's argo-cd component, and its
#                                infra project
#
# Secret names are bare in Key Vault (no "/"), as core-stack reads them on
# Azure: <cluster>-argocd-admin-secret, global-cd-repo-secret.
# No workload identity grants here: external-dns, External Secrets and ASO's
# identities are terraform/cluster-identities' (ASO's made by the workflow, the
# others through the operator after the handover).
# After this, core-stack's install puts everything else through Argo CD.
# -----------------------------------------------------------------------------

locals {
  admin_secret_name   = "${var.cluster.name}-argocd-admin-secret"
  cd_repo_secret_name = "global-cd-repo-secret"
  namespaces          = setunion(toset(var.cluster.global_namespaces), toset(["argocd"]))
}

data "azurerm_key_vault" "shared" {
  provider            = azurerm.shared
  name                = var.runtime.key_vault_name
  resource_group_name = var.runtime.key_vault_resource_group
}

# ------------------------------------------------------------- StorageClass
# Every field but the labels and annotations is immutable, and this is the
# agent's class field for field, so a cluster made either way has the same.
resource "kubernetes_storage_class_v1" "default_retain" {
  metadata {
    name = "default-retain"
    labels = {
      "addonmanager.kubernetes.io/mode" = "EnsureExists"
      "kubernetes.io/cluster-service"   = "true"
    }
  }
  storage_provisioner    = "disk.csi.azure.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    skuName = "StandardSSD_LRS"
  }
}

# --------------------------------------------------------------- namespaces
resource "kubernetes_namespace_v1" "this" {
  for_each = local.namespaces

  metadata {
    name = each.value
  }

  # Removing a namespace from the cluster file must never delete it.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [metadata[0].labels, metadata[0].annotations]
  }
}

# ------------------------------------------------- Argo CD admin password
resource "random_password" "argocd_admin" {
  length  = 32
  special = false
}

# The agent's format, so the argo-cd component's ExternalSecret and the GUI
# read it unchanged: {"data":{"password":"<base64>"}}. Created, then left to
# the GUI, which may set a new value: tagged as the agent's (managed_by
# AKSManagerAgent), as the EKS create tags its secrets, so the GUI treats it
# as its own.
resource "azurerm_key_vault_secret" "argocd_admin" {
  provider     = azurerm.shared
  name         = local.admin_secret_name
  key_vault_id = data.azurerm_key_vault.shared.id
  value        = jsonencode({ data = { password = base64encode(random_password.argocd_admin.result) } })
  content_type = "application/json"
  tags = merge(
    {
      "AKSManager"  = "Managed"
      "deployed_by" = "GitOpsManager"
      "managed_by"  = "AKSManagerAgent"
      "environment" = var.cluster.zone_prefix
      "cluster"     = var.cluster.name
    },
    var.runtime.cost_tag_name == "" ? {} : { (var.runtime.cost_tag_name) = var.runtime.cost_tag_value },
  )

  lifecycle {
    ignore_changes = all
  }
}

# ----------------------------------------------------- Argo CD's secrets
# Written directly, once: the External Secrets Operator is not installed yet.
# Once it is, the argo-cd component's ExternalSecrets take these over.

# The CD repo's credentials, as the GitHub App install writes them (or a
# username and token put there by hand): a Kubernetes Secret manifest as
# JSON, data.* base64-encoded.
data "azurerm_key_vault_secret" "cd_repo" {
  provider     = azurerm.shared
  name         = local.cd_repo_secret_name
  key_vault_id = data.azurerm_key_vault.shared.id
}

locals {
  cd_repo = jsondecode(data.azurerm_key_vault_secret.cd_repo.value).data
}

resource "kubernetes_secret_v1" "repo" {
  metadata {
    name      = "repo-secret"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }
  # The GitHub App's fields, or a username and token, whichever the stored
  # value holds.
  data = merge(
    { type = "git", url = var.runtime.cd_repo_url },
    can(local.cd_repo.githubAppID) ? {
      githubAppID             = base64decode(local.cd_repo.githubAppID)
      githubAppInstallationID = base64decode(local.cd_repo.githubAppInstallationID)
      githubAppPrivateKey     = base64decode(local.cd_repo.githubAppPrivateKey)
      } : {
      username = base64decode(local.cd_repo.username)
      password = base64decode(local.cd_repo.password)
    },
  )

  lifecycle {
    ignore_changes = all
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# argocd-server will not start without argocd-secret.
resource "kubernetes_secret_v1" "argocd" {
  metadata {
    name      = "argocd-secret"
    namespace = "argocd"
    labels = {
      "app.kubernetes.io/name"    = "argocd-secret"
      "app.kubernetes.io/part-of" = "argocd"
    }
  }
  data = {
    "admin.password"      = bcrypt(random_password.argocd_admin.result)
    "admin.passwordMtime" = timestamp()
  }

  lifecycle {
    ignore_changes = all
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# ------------------------------------------------------------------ Argo CD
# core-stack's argo-cd component at the pinned ref: the chart and values Argo
# CD will manage itself with. Installed once; after that Argo CD manages
# itself from the CD repo. Without the web UI routes and the infra project,
# whose kinds don't exist until this release has installed the CRDs; the
# project is applied just after (terraform_data.infra_project).
locals {
  argo_cd_set = [
    { name = "global.gom.cloud", value = "azure" },
    { name = "global.gom.cluster", value = var.cluster.name },
    { name = "global.gom.dnsZone", value = var.cluster.dns_zone },
    { name = "global.gom.zonePrefix", value = var.cluster.zone_prefix },
    { name = "global.gom.cdRepoUrl", value = var.runtime.cd_repo_url },
    { name = "argo-cd.global.domain", value = "${var.cluster.name}-argocd-argocd-web-ui.${var.cluster.dns_zone}" },
    { name = "repoSecret.enabled", value = "false" },
    { name = "adminPassword.enabled", value = "false" },
    { name = "zoneCert.enabled", value = "false" },
  ]
}

resource "helm_release" "argo_cd" {
  name              = "argo-cd"
  namespace         = "argocd"
  chart             = "${var.runtime.core_stack_dir}/components/argo-cd"
  dependency_update = true
  wait              = true
  timeout           = 900

  set = concat(local.argo_cd_set, [
    { name = "webUi.enabled", value = "false" },
    { name = "project.enabled", value = "false" },
  ])

  lifecycle {
    ignore_changes = all
  }

  depends_on = [
    kubernetes_namespace_v1.this,
    kubernetes_secret_v1.repo,
    kubernetes_secret_v1.argocd,
  ]
}

resource "terraform_data" "infra_project" {
  input = var.cluster.name

  provisioner "local-exec" {
    command = "bash ${path.module}/apply-infra-project.sh"
    environment = {
      SUBSCRIPTION   = var.cluster.subscription_id
      RESOURCE_GROUP = var.cluster.resource_group
      CLUSTER        = var.cluster.name
      CHART          = "${var.runtime.core_stack_dir}/components/argo-cd"
      SET_ARGS       = join(" ", [for s in local.argo_cd_set : "${s.name}=${s.value}"])
    }
  }

  depends_on = [helm_release.argo_cd]
}
