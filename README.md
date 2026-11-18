# aksmanager-bootstrap

Terraform bootstrap for AKS Manager — provisions Azure infrastructure, managed identities and role assignments, and the Let's Encrypt certificate pipeline.

The Azure counterpart of `eksmanager-bootstrap`. The identity and permissions model it implements is described in `AKSManager-Identity-Model-2026-10-04.md` (GitOps Manager internal).

> **Status.**
> - **In use:** `setup-pipeline.ps1`, and the Let's Encrypt certificate pipeline it sets up: the `job-aksmanager-letsencrypt` Container Apps job (weekly, Mondays 03:17 UTC, and on demand from `.github/workflows/lets-encrypt.yml`), which issues and renews one wildcard per zone into Key Vault.
> - **Opt-in, not yet tested:** zone grants, agentless cluster create with its identities and handover, GitOps Manager's runners, and the cluster monitor's secret. See [Opt-in features](#opt-in-features-not-yet-tested).
> - **Not here yet:** the current agent's own identity and role assignments. They are granted by hand today.

---

## Certificates: `terraform/lets-encrypt`

Issues one Let's Encrypt wildcard certificate per DNS zone (`*.<zone>`) using DNS-01 against Azure DNS, and stores each in Key Vault as `<prefix>-dns-zone-certs`. Deploy in AKS Manager copies it into the namespaces that use it; a renewal reaches the clusters on the next Deploy (External Secrets, picking renewals up by itself, is on the roadmap).

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

A prefix may contain only lower-case letters, digits and dashes, and names the secret as written: `we-prod` → `we-prod-dns-zone-certs`. Anything else is refused before the run starts.

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

As with EKS Manager, AKS Manager deploys **into** your DNS; it does not create zones. For each environment you provide a public and a private zone of the same name, and delegate the public one from your parent domain. The certificate job's identity needs a role on each public zone: `setup-pipeline.ps1` creates the tightest one, `AKSManagerCertManager` (TXT records only, the definition in `example-cert-manager-role.json`), and assigns it. Set `CERT_DNS_ROLE` to use another role instead, such as the built-in **DNS Zone Contributor**.

`scripts/hosted_zones_tfvars.py` validates the file and writes `terraform/lets-encrypt/hosted-zones.auto.tfvars.json`, which Terraform loads automatically. It rejects missing fields, invalid subscription IDs and resource group names, duplicate zones, and two prefixes that would name the same secret.

---

## Running the module by hand

Normally the certificate job runs this module, set up by `setup-pipeline.ps1`. Applying it by hand with your own `az login` is for proving issuance, DNS and Key Vault end to end in a test subscription, or for troubleshooting. Use `"acme-staging": true` until it works, and never alongside the job on the same state.

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

## Opt-in features (not yet tested)

Everything above is the tested bootstrap. The features below are in this repo
but **off unless you switch them on** when running `setup-pipeline.ps1`. Off,
setup creates and grants exactly what it did before they existed. Switch them on
in a demo subscription first.

| Switch (environment variable) | What it turns on | What it creates or grants in Azure |
|---|---|---|
| `ZONE_GRANTS=1` | The Let's Encrypt workflow grants the certificate job its DNS-01 role on a zone added to `hosted-zones.json` later, without another setup run | Role Based Access Control Administrator for `id-aksmanager-github` in each zone subscription, held by an ABAC condition to that one role for that one identity |
| `CREATE_CLUSTER=1` (with `AKS_SUBSCRIPTIONS`) | Cluster identities and agentless create (`bootstrap-cluster-identities.yml`, `bootstrap-create-cluster.yml`, `terraform/cluster-identities`, `terraform/create-cluster/`) and the handover (`bootstrap-handover.yml`) | Identity `id-aksmanager-identities` with a federated credential, state container `tfstate-identities`, Managed Identity Contributor on the shared resource group, Reader on each AKS subscription, Role Based Access Control Administrator limited by ABAC to five roles, and three custom roles |
| `RUNNERS=1` (with `AKS_SUBSCRIPTIONS`, `RUNNERS_ENVIRONMENT_ID`) | GitOps Manager's runners, installed by the `job-aksmanager-runners` Container Apps job (`runners.yml`, `scripts/runners-job.sh`) | Resource group `rg-aksmanager-runners`, two identities, state container `tfstate-runners`. **Review before enabling:** every role both identities get, with its scope and why, is in [`runner-roles.json`](runner-roles.json), which setup reads: nothing else is granted. The runners' identity gets **Contributor and Azure Kubernetes Service RBAC Cluster Admin on every AKS subscription**, Key Vault Secrets Officer, and Role Based Access Control Administrator limited to assigning the eight roles listed there (never Owner or Contributor) |
| `CLUSTER_MONITOR=1` | The cluster monitor reads the M2M client secret from the vault | Secret `m2m-client-secret` in the vault |

`PLAN_ONLY=true`, set as an environment override when starting the certificate
job (`az containerapp job start ... --env-vars PLAN_ONLY=true`), plans and
applies nothing.

Everything on Azure runs Terraform 1.17.1, pinned: the version that wrote the
certificate state. The certificate job and the
runners job install it themselves, and the new workflows install it on the runner
(`scripts/install_terraform.sh`).

None of them ever runs a Terraform older than the one that last wrote a state:
before each `terraform init` they read the state's recorded version
(`scripts/terraform_version_guard.sh`; the certificate job does the same itself)
and install that one instead when it is newer. The pin only moves up.

---

## Licence

Apache License 2.0 -- see [LICENSE](LICENSE) and [NOTICE](NOTICE).
