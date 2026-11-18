<!-- Copyright (c) 2026 GitOps Manager, S.L. SPDX-License-Identifier: Apache-2.0 -->
# terraform/create-cluster

Creates one AKS cluster from `clusters/<cluster>.json`, with Terraform. Run by
`.github/workflows/bootstrap-create-cluster.yml` on GitOps Manager's long-job
runner on Azure (`gom-azure-long`, core-stack's `terraform/runners-azure`).

> **Status: written 9 Nov 2026, never run.** Both stages were validated, and
> `scripts/create_cluster.py` tested locally against the example file, before
> the move to Terraform 1.17.1; nothing has been validated or run with Terraform
> yet. Nothing has run in GitHub Actions or against Azure, so the first test
> is a dry run on the demo estate.

It reproduces what the agent's Azure create does today
(`create_aks_cluster` in `packages/azureapi/azureapi.py`, and the
`CreateCluster` step in `client-daemon/task.py` around it), except where
listed below.

## The stages

Each stage has its own state in setup's storage account (container
`tfstate-identities`, key `clusters/<cluster>/<stage>.tfstate`), so a failed
stage can be re-run without the others.

| Stage | Creates | From the agent |
|---|---|---|
| (workflow) | The resource group, if missing, tagged only when made here | `create_resource_group` |
| `1-cluster` | `traefik_nic` holding Traefik's private IP (the subnet's address with the last octet 100) | `create_traefik_nic_with_private_ip`, `af7task.get_fixed_ip_from_subnet_cidr` |
| | `kubelet-<c>` and `control-plane-<c>` identities | `create_managed_identity` |
| | kubelet: AcrPull on the registry. Control plane: Managed Identity Operator on the kubelet identity, Network Contributor on the subnet and on the node resource group (the node resource group covers kubenet's route table). No Contributor on the cluster's resource group: dropped 12 Nov 2026, in the agent too, as nothing these clusters use needs it | `assign_aks_managed_ids` (the first role: `az aks create` granted it itself) |
| | The cluster: Entra admin groups and Azure RBAC, subnet, zones, upgrade channels, tier, network plugin, policy and overlay mode, the Cilium data plane, pod and service CIDRs, DNS service IP, workload identity and the OIDC issuer, the managed tags on the cluster and its first pool | `az aks create` |
| | The maintenance windows `aksManagedAutoUpgradeSchedule` and `aksManagedNodeOSUpgradeSchedule` (weekly) | `create_maintenance_schedules` |
| | The first node pool, `bootstrap` (mode System, one node per zone, the system pool's size and disk) | `--nodepool-name nodepool1` |
| (workflow) | The ASO identity, `<c>-aso`, by `terraform/cluster-identities` (state `identities/<c>/aso.tfstate`); its client ID in Key Vault as `<c>-aso-client-id` and in `identities/<c>.json` | `bootstrap-cluster-identities.yml` |
| `2-platform` | StorageClass `default-retain` (the agent's, field for field); the cluster file's namespaces and `argocd`; `<c>-argocd-admin-secret` in the shared Key Vault; Argo CD's `repo-secret` and `argocd-secret`; Argo CD from core-stack's `argo-cd` component, and its `infra` project | `create_retain_storage_class`, `check_and_create_namespace` |

**After the stages, the workflow:**
- writes `clusters/<c>.outputs.json` (subscription, resource group, cluster
  ID, OIDC issuer, node resource group, subnet, `load_balancer_ip`,
  `bootstrap_pool`, the identities' IDs, the ASO client ID);
- commits it with `clusters/<c>.json`, and commits `identities/<c>.json`.

## Re-running

Safe. A stage that is up to date plans no changes.

What a re-run never changes:
- the cluster's Kubernetes version, which belongs to the upgrade;
- the first node pool (`default_node_pool` is ignored from the start: the
  handover deletes it);
- `traefik_nic`, which is forgotten once made (removed from the state, not
  destroyed) because core-stack's Traefik deletes it to take its address;
- the resource group, which is never in Terraform's state;
- Argo CD and its two secrets once installed, and the admin password secret.

Removing a namespace from the cluster file makes the plan fail rather than
delete the namespace. Removing the cluster from a run is refused
(`prevent_destroy`).

## 3-handover

**Built, not yet tested.** Not a Terraform stage: a request the GitOps Manager
GUI runs, started by itself after a create (the core stack first, then this
handover queued behind it), and from Node pools ("Hand over from the create")
to retry. After the core stack has installed the Azure Service Operator, it:
1. turns `install_node_pool_operator` on in the stack file, with ASO's client
   ID from the create's identities;
2. renders the cluster file's `node_pools.system` (mode System, taint
   `CriticalAddonsOnly=true:NoSchedule`, as the agent's `taint_system_nodepool`)
   and `node_pools.general` into the CD repo (`<cluster>/nodepools/`) as ASO
   agent pools, syncs them, and waits until ASO reports every one Ready;
3. hands the kubelet and control-plane identities to ASO (`cd-files.yml`
   `adopt-cluster-identities`). Their role assignments stay Terraform's;
4. runs [`bootstrap-handover.yml`](../../.github/workflows/bootstrap-handover.yml):
   it refuses unless every pool but `bootstrap` has succeeded with nodes and
   one is a System pool, then deletes the `bootstrap` pool
   (`az aks nodepool delete`; Terraform already ignores `default_node_pool`),
   and the system pods move across. Safe to run again.

One way: once handed over, the pools and the adopted identities belong to the
CD repo, not Terraform. If a pool can't be made (quota, a bad VM size), the
request stops at step 2 and the cluster keeps working on `bootstrap`: fix
`clusters/<c>.json` and press Retry on the Requests page. A handover that stays
failed or running for over an hour raises the `handover-stuck` ops alert.

What it can rely on from this create, in `clusters/<c>.outputs.json` and
1-cluster's outputs: `cluster_id`, `oidc_issuer_url`, `node_resource_group`,
`subnet_id`, `bootstrap_pool` (`bootstrap`), `kubelet_identity_id`,
`control_plane_identity_id`, `aso_client_id`; the states at
`tfstate-identities/clusters/<c>/{1-cluster,2-platform}.tfstate` and
`tfstate-identities/identities/<c>/aso.tfstate`.

Until the handover, the bootstrap pool runs everything. Traefik waits for
`sku=general` nodes, so it starts only once the general pool exists.

## Differences from the agent's create

| | Agent | Here | Why |
|---|---|---|---|
| First node pool | `nodepool1`, tainted `CriticalAddonsOnly` straight after, then the general pools | `bootstrap`, untainted; the real system and general pools come from ASO at the handover, then `bootstrap` is deleted | Decided 9 Nov 2026: node pools belong to the operator and the CD repo |
| Who may change what after create | The agent, everything it made (`managed_by = AKSManagerAgent`) | The cluster, its identities and their roles are Terraform's (`managed_by = Terraform`), so the GUI and agent treat the cluster as another tool's, as the EKS create does. The Argo CD admin secret is tagged `AKSManagerAgent`, so the GUI may set a new value | As the EKS create (29 Oct 2026) |
| Kubernetes version | The exact patch from the page | The exact patch, or major.minor for the newest patch AKS offers | As the GKE create |
| Managed Identity Operator for the control plane on the kubelet identity | Granted by `az aks create` | An explicit role assignment | azurerm does not grant it |
| Order of the role assignments | All after the cluster | Managed Identity Operator and Network Contributor on the subnet before it (the cluster needs them to come up); the node resource group after | The same assignments, less Contributor |
| SSH key on the nodes | `--generate-ssh-keys` (a key on the agent's disk that nothing uses) | None | A private key would sit in Terraform's state |
| Maintenance window start date | Today, when the page gives none | Azure's default (the day it is set), so a re-run does not move it | The same result on the first run |
| A re-run on a half-made cluster | Refused unless `Succeeded` | Terraform carries on from its state | |

**Not ported, and why:**
- **The external-dns identity** (`<c>-<zone>` with its federated credential)
  and **the ARC push identity** (`<c>-arc-push`, AcrPush): platform
  identities now come through the operator after the handover (or
  `bootstrap-cluster-identities.yml` meanwhile), not the create.
- **The admin kube context file** (`create_admin_context`): nothing reads a
  context on the runner after the run. The stages use the cluster's local
  admin credentials directly, as that context did.
- **Retag of existing resources**: the create makes everything new, tagged.

## Before the first run

- **Setup:** `setup-pipeline.ps1` has run (it writes `pinned.auto.tfvars.json`,
  which the workflow reads), so the state account, the `tfstate-identities`
  container, the Key Vault and the ASO roles exist.
- **`global-cd-repo-secret`** in the shared Key Vault: the CD repo's GitHub
  App, as GitOps Manager writes it (a Kubernetes Secret manifest as JSON).
- **The runner's identity**: the runners' managed identity on
  `gom-azure-long`, made and granted by setup with `RUNNERS=1`. Its roles are
  in [`runner-roles.json`](../../runner-roles.json), with the scope of each
  and why. Running the create elsewhere (`AZURE_CREATE_CLIENT_ID`), give that
  identity the same `runners` grants.
- **Repository variables:** listed at the top of the workflow.

The cluster's API server is public, as the agent's create makes it; the
runner reaches it with the local admin credentials.
