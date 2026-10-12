# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/lets-encrypt — providers and backend
# -----------------------------------------------------------------------------
# Its own root module with its own state, as on AWS. It is applied on a schedule
# with nobody watching, so whatever it can reach it can change unattended.
# Keeping it to certificates and their Key Vault secrets means a scheduled run
# can never touch a cluster, an identity or a role assignment.
#
# Versions are pinned, not floored, for the same reason as the AWS module: the
# behaviours this depends on (DNS-01 record handling, how the chain is split
# across certificate_pem and issuer_pem) are provider implementation details,
# and an upgrade arriving on its own would surface at renewal months later.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # storage_account_name / container_name / key supplied with -backend-config.
  # Entra ID auth to the state blob, never a storage account key: the state
  # holds the ACME account key and every certificate private key, so it is as
  # sensitive as the certificates themselves.
  backend "azurerm" {
    use_azuread_auth = true
  }
}

# Authentication is ambient: the cert job's managed identity when run as the
# job (ARM_USE_MSI / ARM_CLIENT_ID), the operator's `az login` when run by hand.
# azurerm 4.x requires the subscription explicitly.
provider "azurerm" {
  subscription_id = var.shared_services_subscription_id
  features {}
}

# Staging issues from an untrusted root with far higher rate limits. The
# duplicate-certificate limit is 5 per week for an identical name set, which a
# rebuild loop reaches in an afternoon.
provider "acme" {
  server_url = var.acme_use_staging ? "https://acme-staging-v02.api.letsencrypt.org/directory" : "https://acme-v02.api.letsencrypt.org/directory"
}
