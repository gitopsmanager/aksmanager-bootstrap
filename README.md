# aksmanager-bootstrap

Terraform bootstrap for AKS Manager — provisions Azure infrastructure, managed identities and role assignments, and the Let's Encrypt certificate pipeline.

The Azure counterpart of `eksmanager-bootstrap`. The identity and permissions model it implements is described in `AKSManager-Identity-Model-2026-10-04.md` (GitOps Manager internal).

> **Status: early.** Only the certificate module (`terraform/lets-encrypt`) exists. The setup script, the bootstrap job, the agent's identity and role assignments, and the scheduled certificate job come next.

---

## Certificates: `terraform/lets-encrypt`

Issues one Let's Encrypt wildcard certificate per DNS zone (`*.<zone>`) using DNS-01 against Azure DNS, and stores each in Key Vault as `<prefix>-dns-zone-certs`. The agent reads those secrets and pushes them into clusters.

Certificates are issued centrally rather than per cluster, which keeps well under Let's Encrypt's limit of 50 certificates per registered domain per week. Renewal is apply-driven: a run reissues only certificates with fewer than `min_days_remaining` (default 30) days left, so most runs change nothing.

### Secret format

Each secret is JSON whose keys match a Kubernetes TLS secret, the same shape as on AWS:

| Key | Content |
|---|---|
| `tls.crt` | Leaf certificate **plus** issuer chain |
| `tls.key` | Private key |
| `ca.crt` | Issuer (kept for parity; not needed for public trust) |
| `not_after` | Expiry, RFC 3339 |
| `zone`, `prefix` | Which zone and environment |

Key Vault names allow only letters, digits and dashes, so an underscore in a prefix becomes a dash: `we_prod` → `we-prod-dns-zone-certs`.

### Zone list: `hosted-zones.json`

Copy `example-hosted-zones.json` to `hosted-zones.json` and fill it in. Each zone is addressed by subscription, resource group and name:

```json
{
  "acme-email": "platform-team@acme.com",
  "acme-staging": true,
  "hosted-zones": [
    {
      "dns-zone-prefix": "dev",
      "public-dns-zone": "dev.azure.acme.com",
      "private-dns-zone": "dev.azure.acme.com",
      "subscription": "00000000-0000-0000-0000-000000000000",
      "resource-group": "rg-dns-dev"
    }
  ]
}
```

Unlike AWS there is no per-zone `cert_manager` role to assume. Azure has no assume-role: the identity running the module holds a role assignment on each public zone directly.

### DNS is yours to provide

As with EKS Manager, AKS Manager deploys **into** your DNS; it does not create zones. For each environment you provide a public and a private zone of the same name, and you grant the certificate job's identity a role on the public zone. `example-cert-manager-role.json` defines the tightest such role, TXT records only, with the commands to create and assign it. The built-in **DNS Zone Contributor** also works if you would rather not maintain a custom role.

`scripts/hosted_zones_tfvars.py` validates the file and writes `terraform/lets-encrypt/hosted-zones.auto.tfvars.json`, which Terraform loads automatically. It rejects missing fields, invalid subscription IDs and resource group names, duplicate zones, and two prefixes that would name the same secret.

---

## First run, by hand

Until the scheduled job exists, the module is applied by hand with your own `az login`. This proves issuance, DNS and Key Vault end to end. Use `"acme-staging": true` until it works.

### 1. Resources the module expects

The module writes secrets; it does not create the vault, the zone or the state storage. Create them once (names are examples):

```bash
SUB=<shared services subscription id>
LOC=westeurope

az group create -n rg-aksmanager-certs -l $LOC
az keyvault create -n <vault-name> -g rg-aksmanager-certs -l $LOC --enable-rbac-authorization true
az storage account create -n <stateaccount> -g rg-aksmanager-certs -l $LOC \
  --sku Standard_LRS --allow-shared-key-access false --min-tls-version TLS1_2
az storage container create -n tfstate --account-name <stateaccount> --auth-mode login

az group create -n rg-dns-dev -l $LOC
az network dns zone create -g rg-dns-dev -n dev.azure.<your-domain>
```

Then delegate the zone: add an `NS` record for `dev.azure.<your-domain>` in the parent zone, pointing at the four name servers `az network dns zone show` lists.

### 2. Your own permissions

Owner does **not** grant Key Vault data access when the vault uses RBAC. You need:

- **Key Vault Secrets Officer** on the vault
- **Storage Blob Data Contributor** on the state container
- **DNS Zone Contributor** (or the TXT-only role) on the public zone

### 3. Apply

```bash
python3 scripts/hosted_zones_tfvars.py

cd terraform/lets-encrypt
terraform init \
  -backend-config="storage_account_name=<stateaccount>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=lets-encrypt.tfstate"

terraform apply \
  -var="shared_services_subscription_id=$SUB" \
  -var="key_vault_id=$(az keyvault show -n <vault-name> --query id -o tsv)" \
  -var="azure_auth_method=cli"
```

### 4. Check

```bash
az keyvault secret show --vault-name <vault-name> -n dev-dns-zone-certs \
  --query "{expires:attributes.expires, type:contentType}"
```

The Terraform output `certificate_expiry` shows each certificate's expiry. The state holds the ACME account key and every certificate private key, which is why the backend uses Entra ID authentication and the storage account disallows shared keys.

---

## Licence

See [LICENSE](LICENSE).
