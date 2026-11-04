# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# client_id is what the component's service account names
# (azure.workload.identity/client-id; stacks/<cluster>.json <identity>_client_id).

output "client_id" {
  value = azurerm_user_assigned_identity.this.client_id
}

output "principal_id" {
  value = azurerm_user_assigned_identity.this.principal_id
}

output "identity_id" {
  value = azurerm_user_assigned_identity.this.id
}
