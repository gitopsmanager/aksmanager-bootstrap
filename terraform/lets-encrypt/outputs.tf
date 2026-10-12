# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.

# Names only. Never output certificate_pem or private_key_pem: outputs are
# printed in the job log.
output "secret_names" {
  description = "Key Vault secret holding each zone's wildcard, keyed by zone."
  value       = local.secret_names
}

output "certificate_expiry" {
  description = <<-EOT
    Expiry per zone. Worth reading in the job log after each run: the cheapest
    confirmation that renewal is actually happening.
  EOT
  value       = { for k, v in acme_certificate.wildcard : k => v.certificate_not_after }
}
