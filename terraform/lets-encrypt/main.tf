# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/lets-encrypt — one wildcard certificate per DNS zone
# -----------------------------------------------------------------------------
# Issues *.<zone> from Let's Encrypt via DNS-01 against Azure DNS and stores the
# result in Key Vault, one secret per zone. The agent reads those secrets and
# pushes them into clusters; nothing here talks to Kubernetes.
#
# The Azure sibling of eksmanager-bootstrap/terraform/lets-encrypt. Same
# certificate, same secret shape, same renewal rule. What differs:
#   - No assume-role hop. The identity running this holds a role assignment on
#     each public zone directly (the custom TXT-only role), so a zone needs only
#     its address, not a per-zone role.
#   - Key Vault instead of Secrets Manager: secret names allow only
#     alphanumerics and dashes, so an underscore in a prefix becomes a dash.
#
# Renewal is apply-driven: the provider reissues only when a certificate is
# inside min_days_remaining, so most scheduled runs change nothing.
#
# Rate limits worth knowing before changing anything here:
#   - 5 per week per IDENTICAL name set. Only rebuilds of the same zone hit it.
#     Point those at staging.
#   - 50 per week per registered domain: the ceiling on NEW zones per week when
#     they all sit under one domain.
# -----------------------------------------------------------------------------

locals {
  # Key Vault secret names: 1-127 characters, alphanumerics and dashes only.
  # dev -> dev-dns-zone-certs, we_prod -> we-prod-dns-zone-certs. The agent must
  # build the name with the same rule.
  secret_names = {
    for k, z in var.hosted_zones :
    k => "${replace(z.dns_zone_prefix, "_", "-")}-dns-zone-certs"
  }
}

# One ACME account for all zones. Its key lives in state, as do the certificate
# private keys, which is why the backend uses Entra ID auth and never a key.
resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "acme_registration" "this" {
  account_key_pem = tls_private_key.acme_account.private_key_pem
  email_address   = var.acme_email
}

resource "acme_certificate" "wildcard" {
  for_each = var.hosted_zones

  account_key_pem = acme_registration.this.account_key_pem

  # Wildcard only, as on AWS: the apex validates against the same
  # _acme-challenge name and would need two TXT values present at once, for a
  # name nothing terminates TLS on.
  common_name = "*.${each.value.public_dns_zone}"

  min_days_remaining    = var.min_days_remaining
  recursive_nameservers = var.public_resolvers

  dns_challenge {
    provider = "azuredns"

    config = merge(
      {
        # Explicit, never discovered: the zone is named by its full address.
        AZURE_SUBSCRIPTION_ID = each.value.subscription_id
        AZURE_RESOURCE_GROUP  = each.value.resource_group
        AZURE_ZONE_NAME       = each.value.public_dns_zone

        # The challenge must land in the public zone, where Let's Encrypt
        # resolves it. A private zone of the same name is a different resource
        # type, and this keeps lego away from it.
        AZURE_PRIVATE_ZONE = "false"

        AZURE_AUTH_METHOD = var.azure_auth_method

        AZURE_TTL                 = "60"
        AZURE_PROPAGATION_TIMEOUT = "300"
        AZURE_POLLING_INTERVAL    = "10"
      },
      var.azure_client_id != "" ? { AZURE_CLIENT_ID = var.azure_client_id } : {}
    )
  }
}

resource "azurerm_key_vault_secret" "wildcard" {
  for_each = var.hosted_zones

  name         = local.secret_names[each.key]
  key_vault_id = var.key_vault_id
  content_type = "application/json"

  # Expiry on the secret itself, so Key Vault's own near-expiry events and the
  # portal show it without reading the value.
  expiration_date = acme_certificate.wildcard[each.key].certificate_not_after

  # Keys match a Kubernetes TLS secret exactly, and match the AWS secret, so
  # the agent's push is the same mapping on both clouds.
  value = jsonencode({
    # certificate_pem is the LEAF ONLY. The issuer must be appended: browsers
    # tolerate a missing intermediate, Go, Java and C++ clients do not, so a
    # leaf-only chain shows up as "the web UI works but argocd login fails".
    "tls.crt" = "${acme_certificate.wildcard[each.key].certificate_pem}${acme_certificate.wildcard[each.key].issuer_pem}"
    "tls.key" = acme_certificate.wildcard[each.key].private_key_pem

    # Kept for parity with the AWS secret shape. Not needed for public trust.
    "ca.crt" = acme_certificate.wildcard[each.key].issuer_pem

    "not_after" = acme_certificate.wildcard[each.key].certificate_not_after
    "zone"      = each.value.public_dns_zone
    "prefix"    = each.value.dns_zone_prefix
  })

  # The Azure tag convention the agent uses (lowercase, underscores):
  # AKSManager = ownership, managed_by = what created it. Terraform creates
  # these, so the agent treats them as read-only -- a manual save of the zone
  # certificate is refused rather than reverted by the next apply.
  tags = {
    "AKSManager"  = "Managed"
    "deployed_by" = "GitOpsManager"
    "managed_by"  = "Terraform"
    "Environment" = each.value.dns_zone_prefix
    "Zone"        = each.value.public_dns_zone
    "Prefix"      = each.value.dns_zone_prefix
  }

  # The zone list is loose data rather than reviewed code, so a careless edit
  # can drop a zone. Without this, that silently destroys a live certificate.
  # Key Vault soft delete is the second net if this is ever overridden.
  lifecycle {
    prevent_destroy = true
  }
}
