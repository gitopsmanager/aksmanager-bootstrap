# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
output "argocd_admin_secret" {
  description = "Key Vault name of the Argo CD admin password (in the shared services vault)."
  value       = local.admin_secret_name
}
