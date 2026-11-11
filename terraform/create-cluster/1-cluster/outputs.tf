# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# What the workflow records (clusters/<cluster>.outputs.json), what the ASO
# identity run takes (the cluster's ID and OIDC issuer), and what the
# handover relies on.

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "cluster_id" {
  value = azurerm_kubernetes_cluster.this.id
}

output "kubernetes_version" {
  value = azurerm_kubernetes_cluster.this.kubernetes_version
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "node_resource_group" {
  value = azurerm_kubernetes_cluster.this.node_resource_group
}

output "bootstrap_pool" {
  description = "The first node pool's name: the handover deletes it once the system and general pools are Ready."
  value       = "bootstrap"
}

output "subnet_id" {
  value = var.cluster.network.subnet_id
}

output "load_balancer_ip" {
  description = "Traefik's private IP, held by traefik_nic until Traefik is installed (core-stack's load_balancer_ip)."
  value       = var.cluster.network.traefik_ip
}

output "kubelet_identity" {
  value = {
    id           = azurerm_user_assigned_identity.kubelet.id
    client_id    = azurerm_user_assigned_identity.kubelet.client_id
    principal_id = azurerm_user_assigned_identity.kubelet.principal_id
  }
}

output "control_plane_identity" {
  value = {
    id           = azurerm_user_assigned_identity.control_plane.id
    client_id    = azurerm_user_assigned_identity.control_plane.client_id
    principal_id = azurerm_user_assigned_identity.control_plane.principal_id
  }
}
