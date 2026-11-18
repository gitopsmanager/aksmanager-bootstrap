# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Stage 1 of 2 (3 with the handover): the AKS cluster with its control-plane
# and kubelet identities, their roles, and Traefik's reserved address.
# Reproduces the agent's create_aks_cluster (packages/azureapi/azureapi.py)
# and the CreateCluster step around it (client-daemon/task.py), except where
# the README's "Differences from the agent's create" says otherwise.
#
#   resource group           made by the workflow before this stage when it
#                            is missing (the agent's create_resource_group), so
#                            a client's existing group is never in this state
#   traefik_nic              a NIC holding Traefik's private IP in the subnet
#                            (the agent's create_traefik_nic_with_private_ip):
#                            the address stays free until core-stack's Traefik
#                            deletes the NIC and takes it. Created, then
#                            forgotten by the workflow, so a re-run never makes
#                            it again under the load balancer
#   kubelet-<c>              the kubelet identity (AcrPull on the registry)
#   control-plane-<c>        the cluster's identity (Managed Identity Operator
#                            on the kubelet identity; Contributor on the
#                            cluster's resource group; Network Contributor on
#                            the subnet and on the node resource group) -- the
#                            agent's assign_aks_managed_ids
#   the cluster              every setting the agent's az aks create passes;
#                            workload identity and the OIDC issuer on; the
#                            maintenance windows (create_maintenance_schedules)
#   bootstrap                the one node pool AKS must be created with (mode
#                            System). Untainted, unlike the agent's nodepool1:
#                            until the handover it runs everything, Argo CD
#                            and the core stack included. The handover makes
#                            the real system and general pools through the
#                            Azure Service Operator, then deletes this one;
#                            Terraform ignores default_node_pool from the start
#
# ASO's own identity is not here: the workflow runs terraform/cluster-identities
# for it (identities/<cluster>/aso.tfstate), the same module and state
# bootstrap-cluster-identities.yml uses, so either can carry it on.
# -----------------------------------------------------------------------------

locals {
  name = var.cluster.name

  # az aks create's default DNS prefix (azure-cli _get_default_dns_prefix):
  # the name (10), the resource group (16), the subscription (6).
  dns_name_part = substr(replace(local.name, "/[^A-Za-z0-9-]/", ""), 0, 10)
  dns_prefix = join("-", [
    can(regex("^[A-Za-z]", local.dns_name_part)) ? local.dns_name_part : substr("a${local.dns_name_part}", 0, 10),
    substr(replace(var.cluster.resource_group, "/[^A-Za-z0-9-]/", ""), 0, 16),
    substr(var.cluster.subscription_id, 0, 6),
  ])

  # The agent passes an exact patch; a major.minor takes the newest patch
  # AKS offers in the location (as the GKE create does).
  exact_version      = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.cluster.kubernetes_version))
  kubernetes_version = local.exact_version ? var.cluster.kubernetes_version : data.azurerm_kubernetes_service_versions.this[0].latest_version

  acr_scope = "/subscriptions/${var.runtime.shared_subscription_id}/resourceGroups/${var.cluster.container_registry.resource_group}/providers/Microsoft.ContainerRegistry/registries/${var.cluster.container_registry.name}"

  # The agent's flags, in azurerm's spelling.
  tier = { free = "Free", standard = "Standard", premium = "Premium" }[lower(var.cluster.tier)]
  # "none" is the absence of a channel.
  auto_upgrade_channel = lower(var.cluster.upgrade.auto_upgrade_channel) == "none" ? null : lower(var.cluster.upgrade.auto_upgrade_channel)
  node_os_upgrade_channel = {
    none = "None", unmanaged = "Unmanaged", securitypatch = "SecurityPatch", nodeimage = "NodeImage"
  }[lower(var.cluster.upgrade.node_os_upgrade_channel)]
  network_policy = lower(var.cluster.network.policy) == "none" ? null : lower(var.cluster.network.policy)
  # The agent: --network-plugin-mode only when it isn't "transparent", the
  # Cilium data plane only when asked, the pod CIDR only in overlay mode.
  overlay   = lower(var.cluster.network.plugin_mode) == "overlay"
  dataplane = lower(var.cluster.network.dataplane) == "cilium" ? "cilium" : null
  pod_cidr  = local.overlay && trimspace(var.cluster.network.pod_cidr) != "" ? trimspace(var.cluster.network.pod_cidr) : null

  # The agent's node count for its first pool: one node per zone.
  bootstrap_count = max(1, length(var.cluster.zones))

  windows = {
    for k, w in {
      auto_upgrade = var.cluster.maintenance.auto_upgrade
      node_os      = var.cluster.maintenance.node_os
    } : k => w if w != null
  }
}

data "azurerm_resource_group" "this" {
  name = var.cluster.resource_group
}

data "azurerm_kubernetes_service_versions" "this" {
  count           = local.exact_version ? 0 : 1
  location        = var.cluster.location
  version_prefix  = "${var.cluster.kubernetes_version}."
  include_preview = false
}

# ---------------------------------------------------------------- Traefik IP
# Forgotten after the first apply (bootstrap-create-cluster.yml, "Forget the
# Traefik NIC"); skip_traefik_nic stops a re-run making it again.
resource "azurerm_network_interface" "traefik_nic" {
  count               = var.skip_traefik_nic ? 0 : 1
  name                = "traefik_nic"
  location            = var.cluster.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.cluster.network.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.cluster.network.traefik_ip
  }

  lifecycle {
    ignore_changes = all
  }
}

# ----------------------------------------------------------------- identities
resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "kubelet-${local.name}"
  location            = var.cluster.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "control_plane" {
  name                = "control-plane-${local.name}"
  location            = var.cluster.location
  resource_group_name = data.azurerm_resource_group.this.name
  tags                = local.tags
}

# az aks create --assign-kubelet-identity grants this itself; azurerm doesn't,
# and AKS refuses a kubelet identity its control plane cannot assign.
resource "azurerm_role_assignment" "cp_kubelet_operator" {
  scope                = azurerm_user_assigned_identity.kubelet.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
  description          = "GitOps Manager: ${local.name} control plane assigns its kubelet identity"
}

# assign_aks_managed_ids. The agent made these after the cluster; the two the
# cluster needs to come up in the subnet are made before it here.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = local.acr_scope
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.kubelet.principal_id
  principal_type       = "ServicePrincipal"
  description          = "GitOps Manager: ${local.name} kubelet pulls images"
}

# No Contributor for the control plane on the cluster's resource group (12 Nov
# 2026; the agent's assign_aks_managed_ids dropped it too). AKS needs rights
# outside its node resource group only for things these clusters don't use:
# load balancer IPs or route tables in another group, private-cluster DNS
# zones, disks in another group. The subnet grant below and the node resource
# group grant after the cluster cover the rest, and Contributor stays off the
# roles anything here may assign.

resource "azurerm_role_assignment" "cp_subnet" {
  scope                = var.cluster.network.subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
  description          = "GitOps Manager: ${local.name} control plane on its subnet"
}

# ------------------------------------------------------------------- cluster
resource "azurerm_kubernetes_cluster" "this" {
  name                = local.name
  location            = var.cluster.location
  resource_group_name = data.azurerm_resource_group.this.name
  dns_prefix          = local.dns_prefix
  kubernetes_version  = local.kubernetes_version
  sku_tier            = local.tier

  automatic_upgrade_channel = local.auto_upgrade_channel
  node_os_upgrade_channel   = local.node_os_upgrade_channel

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name            = "bootstrap"
    vm_size         = var.cluster.node_pools.system.vm_size
    node_count      = local.bootstrap_count
    zones           = length(var.cluster.zones) > 0 ? var.cluster.zones : null
    vnet_subnet_id  = var.cluster.network.subnet_id
    os_disk_size_gb = var.cluster.node_pools.system.disk_size
    os_disk_type    = var.cluster.node_pools.system.disk_type
    # The full tag set on the pool too (the agent's --nodepool-tags).
    tags = local.tags
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.control_plane.id]
  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.kubelet.id
  }

  network_profile {
    network_plugin      = lower(var.cluster.network.plugin)
    network_plugin_mode = local.overlay ? "overlay" : null
    network_policy      = local.network_policy
    network_data_plane  = local.dataplane
    pod_cidr            = local.pod_cidr
    service_cidr        = var.cluster.network.service_cidr
    dns_service_ip      = var.cluster.network.dns_service_ip
  }

  # --enable-aad (managed Entra ID) with the admin groups, and
  # --enable-azure-rbac.
  dynamic "azure_active_directory_role_based_access_control" {
    for_each = var.cluster.entra.enabled ? [1] : []
    content {
      tenant_id              = var.runtime.tenant_id
      admin_group_object_ids = var.cluster.entra.admin_group_object_ids
      azure_rbac_enabled     = var.cluster.entra.azure_rbac
    }
  }

  # create_maintenance_schedules: aksManagedAutoUpgradeSchedule and
  # aksManagedNodeOSUpgradeSchedule, weekly. No start date given means
  # Azure's default (today), as the agent's.
  dynamic "maintenance_window_auto_upgrade" {
    for_each = contains(keys(local.windows), "auto_upgrade") ? [local.windows.auto_upgrade] : []
    content {
      frequency   = "Weekly"
      interval    = maintenance_window_auto_upgrade.value.interval_weeks
      duration    = maintenance_window_auto_upgrade.value.duration
      day_of_week = maintenance_window_auto_upgrade.value.day_of_week
      start_time  = maintenance_window_auto_upgrade.value.start_time
      utc_offset  = maintenance_window_auto_upgrade.value.utc_offset
      start_date  = maintenance_window_auto_upgrade.value.start_date == "" ? null : "${maintenance_window_auto_upgrade.value.start_date}T00:00:00Z"
    }
  }

  dynamic "maintenance_window_node_os" {
    for_each = contains(keys(local.windows), "node_os") ? [local.windows.node_os] : []
    content {
      frequency   = "Weekly"
      interval    = maintenance_window_node_os.value.interval_weeks
      duration    = maintenance_window_node_os.value.duration
      day_of_week = maintenance_window_node_os.value.day_of_week
      start_time  = maintenance_window_node_os.value.start_time
      utc_offset  = maintenance_window_node_os.value.utc_offset
      start_date  = maintenance_window_node_os.value.start_date == "" ? null : "${maintenance_window_node_os.value.start_date}T00:00:00Z"
    }
  }

  tags = local.tags

  lifecycle {
    # Removing the cluster from a re-run must never delete it.
    prevent_destroy = true
    # The version moves by the upgrade, not by a re-run of the create. The
    # first pool is the handover's from the moment it exists: the handover
    # deletes it (az aks nodepool delete), and Terraform must never put it back.
    ignore_changes = [kubernetes_version, default_node_pool]
  }

  depends_on = [
    azurerm_role_assignment.cp_kubelet_operator,
    azurerm_role_assignment.cp_subnet,
  ]
}

# assign_aks_managed_ids: the control plane on the node resource group, which
# only exists once the cluster does.
resource "azurerm_role_assignment" "cp_node_rg" {
  scope                = "/subscriptions/${var.cluster.subscription_id}/resourceGroups/${azurerm_kubernetes_cluster.this.node_resource_group}"
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.control_plane.principal_id
  principal_type       = "ServicePrincipal"
  description          = "GitOps Manager: ${local.name} control plane on its node resource group"
}
