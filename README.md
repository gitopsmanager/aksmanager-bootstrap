# aksmanager-bootstrap

OpenTofu bootstrap for AKS Manager — provisions Azure infrastructure, managed identities and role assignments, and the Let's Encrypt certificate pipeline.

The Azure counterpart of `eksmanager-bootstrap`. The identity and permissions model it implements is described in `AKSManager-Identity-Model-2026-10-04.md` (GitOps Manager internal).

> **Status: early.** Only the certificate module (`tofu/lets-encrypt`) exists. The setup script, the bootstrap job, the agent's identity and role assignments, and the scheduled certificate job come next.

---

## OpenTofu, not Terraform

Every module here is applied with [OpenTofu](https://opentofu.org), pinned
(1.13.1) and checksum-verified, as in `eksmanager-bootstrap`. The certificate
module moved from `terraform/lets-encrypt` to `tofu/lets-encrypt`; its state is
the same blob in the same storage account, so the move changes nothing that is
deployed. Two names date from Terraform and stay: the state container `tfstate`,
and the `managed_by = "Terraform"` tag on the certificate secrets, which every
guard reads as "the pipeline wrote this".

The certificate job carries its script in its own environment, so after syncing
this change into your private repo, **re-run `setup-pipeline.ps1`** before the
job's next run. To check the move first without issuing anything, run setup
once with `$env:PLAN_ONLY = "true"`, run the workflow, and read the plan in its
output (no changes is the expected result); then run setup again without it.

## Cluster identities: `tofu/cluster-identities`

The workload identities the core stack's components run as on AKS, one per
state (`identities/<cluster>/<identity>.tfstate`, in its own container
`tfstate-identities`):

| Identity | Service account | Role |
|---|---|---|
| `external-dns` | `kube-system/external-dns` | DNS Zone Contributor on the zone (Private DNS Zone Contributor for a private zone) |
| `external-secrets` | `external-secrets/external-secrets` | Key Vault Secrets User on the vault |
| `aso` | `azureserviceoperator-system/azureserviceoperator-default` | `AKSManagerNodePoolOperator` on the cluster and its node pools' VNets: that cluster's agent pools, nothing else |

`bootstrap-cluster-identities.yml` adds one missing identity to a cluster that
already exists; the GUI starts it when a cluster's node pools move to the CD
repo. It is **create-if-missing**: it refuses an identity of the same name it
did not make, never imports, changes or replaces one, and refuses a cluster
whose OIDC issuer or workload identity is off (turning the issuer on cannot be
undone). It records each client ID in `identities/<cluster>.json`. It signs in
as `id-aksmanager-identities` (setup step 12b), which may create identities in
the shared services resource group and assign those four roles and no others.

Workflows that record something here (`identities/<cluster>.json`) commit it through a pull
request that is squash-merged at once (gitopsmanager/Auto-Commit-Squash-Merge),
so two runs at the same time are merged, never overwritten. They use the run's
own token, which GitHub lets open pull requests only when **Settings ->
Actions -> General -> Workflow permissions -> Allow GitHub Actions to create
and approve pull requests** is on (or the same setting for the whole
organisation). It is off by default; without it the record step fails. With a
required review on `main`, allow GitHub Actions to bypass it, or the merge
waits for a review that never comes.

## Certificates: `tofu/lets-encrypt`

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
      "resource-group": "rg-dns-dev",
      "private-resource-group": "rg-dns-dev"
    }
  ]
}
```

`resource-group` is the **public** zone's resource group: the certificate job writes its DNS-01 challenge records there. `private-resource-group` is the **private** zone's, used only by AKS Manager for external-dns; it is optional, and when omitted the private zone is taken to be in `resource-group`. Both zones must be in the subscription given.

Unlike AWS there is no per-zone `cert_manager` role to assume. Azure has no assume-role: the identity running the module holds a role assignment on each public zone directly.

### DNS is yours to provide

As with EKS Manager, AKS Manager deploys **into** your DNS; it does not create zones. For each environment you provide a public and a private zone of the same name, and you grant the certificate job's identity a role on the public zone. `example-cert-manager-role.json` defines the tightest such role, TXT records only, with the commands to create and assign it. The built-in **DNS Zone Contributor** also works if you would rather not maintain a custom role.

`scripts/hosted_zones_tfvars.py` validates the file and writes `tofu/lets-encrypt/hosted-zones.auto.tfvars.json`, which OpenTofu loads automatically. It rejects missing fields, invalid subscription IDs and resource group names, duplicate zones, and two prefixes that would name the same secret.

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

cd tofu/lets-encrypt
tofu init \
  -backend-config="storage_account_name=<stateaccount>" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=lets-encrypt.tfstate"

tofu apply \
  -var="shared_services_subscription_id=$SUB" \
  -var="key_vault_id=$(az keyvault show -n <vault-name> --query id -o tsv)" \
  -var="azure_auth_method=cli"
```

### 4. Check

```bash
az keyvault secret show --vault-name <vault-name> -n dev-dns-zone-certs \
  --query "{expires:attributes.expires, type:contentType}"
```

The output `certificate_expiry` shows each certificate's expiry. The state holds the ACME account key and every certificate private key, which is why the backend uses Entra ID authentication and the storage account disallows shared keys.

---

## The M2M client secret: `m2m-client-secret`

`setup-pipeline.ps1` (step 9a) stores the M2M client secret from the Settings
-> Terraform (Azure) block (`EKSMANAGER_CLIENT_SECRET`) in the Key Vault as
`m2m-client-secret`. The cluster monitor's managed identity reads it to sign in
to the GUI. The Azure agent never needed it there: it gets the secret from its
install bundle.

Always set to the Settings block's value: the M2M client lives in the GUI's
Cognito, so that is the source of truth, and a stored value that differs is
stale (for example after the client was rotated). It is rewritten only when it
differs, tagged `managed_by=AKSManagerBootstrap`. Deleted but not purged: setup
stops and says how to recover or purge it.

The cluster monitor's identity needs **Key Vault Secrets User** on the vault;
that is granted where the monitor's Container App is created, not here.

## Licence

[Apache License 2.0](LICENSE). See also [NOTICE](NOTICE).
