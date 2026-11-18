#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# The runners job: GitOps Manager's runners in Azure (the hot ad-hoc pool,
# gom-azure-adhoc; the long jobs from zero, gom-azure-long; ops alerts and
# State of World captures), applied from runners/ with Terraform.
#
# Runs as the Container Apps job job-aksmanager-runners, which
# setup-pipeline.ps1 creates, on demand from the "Install GitOps Manager
# runners" workflow (.github/workflows/runners.yml). The Azure counterpart of
# eksmanager-bootstrap's scripts/apply_runners.sh, which CodeBuild runs: the
# runners cannot be installed by a workflow on themselves.
#
# SaaS only: the subscription's sync delivers the module as runners/; without
# it (the free bootstrap) this does nothing.
#
# As the job's own identity, id-aksmanager-runners-job, which may (setup step
# 12c, nothing more):
#   - create and change Container Apps and jobs in the runners' resource group
#     ($RUNNERS_RESOURCE_GROUP) and place them in the cluster monitor's
#     Container Apps environment
#   - attach the runners' identity, id-aksmanager-runners (Managed Identity
#     Operator on that one identity). It holds the runners' roles, granted by
#     setup, as the AWS runners run as the agent role: this job assigns no
#     roles at all.
#   - read the organisation's GitHub App secret, and write (never read) the
#     copy of its key that the jobs' scaler (KEDA) reads
#   - its own Terraform state, container tfstate-runners
#
# Steps:
#   1. Tools: Terraform at a pinned release, checksum verified (as the
#      certificate job).
#   2. Sign in: az login --identity (Terraform uses that login, ARM_USE_CLI).
#   3. The private repo, cloned with the bootstrap GitHub App, and its
#      repository variables read with the same token: RUNNER_IMAGE,
#      RUNNER_CAPTURE_IMAGE, RUNNERS_HOT, RUNNERS_MAX, RUNNERS_LONG_MAX,
#      RUNNERS_PLAN_ONLY -- the names eksmanager-bootstrap's bootstrap.yml
#      reads on AWS.
#   4. pinned.auto.tfvars.json (setup writes it): the subscription, the
#      resource groups, the vault, the registry, the runners' identity and the
#      Container Apps environment.
#   5. terraform init, plan, apply.
#
# Skips, with a NOTICE and success, while something it needs is not there
# yet: runners/, RUNNER_IMAGE, the Container Apps environment, or the
# organisation's GitHub App secret (global-arc-global-arc-runner-<org>, which
# the GUI writes when the App is installed; re-run setup afterwards so the job
# may read it).
#
# Configuration comes from the job's environment, set by setup-pipeline.ps1.
# PLAN_ONLY=true (on the job, or the RUNNERS_PLAN_ONLY repository variable)
# plans and applies nothing. TERRAFORM_VERSION overrides the pinned release.
# -----------------------------------------------------------------------------
set -euo pipefail

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
notice() { echo "NOTICE: $*"; log "Done (nothing applied)"; exit 0; }

for v in AZURE_CLIENT_ID TENANT_ID SUBSCRIPTION_ID KEY_VAULT_NAME APP_SECRET_NAME \
         GITHUB_REPO_NAME STATE_RESOURCE_GROUP STATE_ACCOUNT STATE_CONTAINER STATE_KEY; do
    [ -n "${!v:-}" ] || die "$v is not set on the job -- re-run setup-pipeline.ps1"
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── 1. Tools ──────────────────────────────────────────────────────────────────
need=()
for t in git unzip openssl curl python3; do
    command -v "$t" >/dev/null 2>&1 || need+=("$t")
done
if [ ${#need[@]} -gt 0 ]; then
    log "Installing ${need[*]}"
    tdnf install -y -q "${need[@]}" >/dev/null || die "could not install ${need[*]}"
fi

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.17.1}"
log "Terraform $TERRAFORM_VERSION"
(
    cd "$WORK"
    base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
    curl -fsSLO "${base}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
    curl -fsSLO "${base}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
    grep " terraform_${TERRAFORM_VERSION}_linux_amd64.zip\$" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c --quiet - ||
        die "Terraform ${TERRAFORM_VERSION} failed its checksum"
    unzip -q -o "terraform_${TERRAFORM_VERSION}_linux_amd64.zip" terraform -d /usr/local/bin
)
terraform version

# ── 2. Sign in as the job's managed identity ──────────────────────────────────
log "Signing in as managed identity $AZURE_CLIENT_ID"
az login --identity --client-id "$AZURE_CLIENT_ID" --allow-no-subscriptions -o none 2>/dev/null ||
    az login --identity --username "$AZURE_CLIENT_ID" --allow-no-subscriptions -o none ||
    die "az login --identity failed -- is $AZURE_CLIENT_ID assigned to this job?"
az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null || true

# ── 3. The private repo and its variables, through the bootstrap GitHub App ───
log "Reading the GitHub App from $KEY_VAULT_NAME"
az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$APP_SECRET_NAME" --query value -o tsv \
    > "$WORK/app.json" || die "could not read $APP_SECRET_NAME from $KEY_VAULT_NAME"
chmod 600 "$WORK/app.json"

app_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$WORK/app.json" "$1"; }
APP_ID=$(app_field appId)
INSTALL_ID=$(app_field installId)
GITHUB_ORG=$(app_field githubOrg)
[ -n "$APP_ID" ] && [ -n "$INSTALL_ID" ] && [ -n "$GITHUB_ORG" ] ||
    die "$APP_SECRET_NAME is incomplete (needs appId, installId, privateKey, githubOrg)"
app_field privateKey | base64 -d > "$WORK/app.pem"
chmod 600 "$WORK/app.pem"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | b64url)
signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$WORK/app.pem" -binary | b64url)
rm -f "$WORK/app.pem" "$WORK/app.json"

# Scoped to the one repo, and to reading it and its variables.
GH_TOKEN=$(curl -fsS -X POST \
    -H "Authorization: Bearer ${header}.${payload}.${signature}" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"repositories\":[\"${GITHUB_REPO_NAME}\"],\"permissions\":{\"contents\":\"read\",\"actions_variables\":\"read\"}}" \
    "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])') ||
    die "GitHub would not issue a token for ${GITHUB_ORG}/${GITHUB_REPO_NAME} -- is the App installed on it?"

# A repository variable, or empty when it is not set.
repo_var() {
    local body code
    body=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO_NAME}/actions/variables/$1")
    code=${body##*$'\n'}
    body=${body%$'\n'*}
    case "$code" in
        200) printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("value", "").strip())' ;;
        404) echo "" ;;
        *) die "could not read the repository variable $1 ($code)" ;;
    esac
}
RUNNER_IMAGE=$(repo_var RUNNER_IMAGE)
RUNNER_CAPTURE_IMAGE=$(repo_var RUNNER_CAPTURE_IMAGE)
RUNNERS_HOT=$(repo_var RUNNERS_HOT)
RUNNERS_MAX=$(repo_var RUNNERS_MAX)
RUNNERS_LONG_MAX=$(repo_var RUNNERS_LONG_MAX)
[ "$(repo_var RUNNERS_PLAN_ONLY)" = "true" ] && PLAN_ONLY=true

log "Cloning ${GITHUB_ORG}/${GITHUB_REPO_NAME}"
auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)
git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth}" \
    clone -q --depth 1 "https://github.com/${GITHUB_ORG}/${GITHUB_REPO_NAME}.git" "$WORK/repo" ||
    die "could not clone ${GITHUB_ORG}/${GITHUB_REPO_NAME}"
unset GH_TOKEN auth
cd "$WORK/repo"
log "At commit $(git rev-parse --short HEAD): $(git log -1 --format=%s)"

[ -d runners ] || notice "no runners/ in ${GITHUB_ORG}/${GITHUB_REPO_NAME} (the free bootstrap, or not synced yet): nothing to do."

# ── 4. Setup's outputs ────────────────────────────────────────────────────────
[ -f pinned.auto.tfvars.json ] || die "pinned.auto.tfvars.json not found -- run setup-pipeline.ps1 first"
pin() { python3 -c 'import json,sys; print(json.load(open("pinned.auto.tfvars.json")).get(sys.argv[1], "") or "")' "$1"; }
LOCATION=$(pin location)
KV_RG=$(pin key_vault_resource_group)
ACR=$(pin container_registry_name)
ACR_RG=$(pin container_registry_resource_group)
RUNNERS_RG=$(pin runners_resource_group)
RUNNERS_IDENTITY=$(pin runners_identity_name)
ENVIRONMENT_ID=$(pin runners_environment_id)

missing=()
[ -n "$RUNNERS_RG" ] && [ -n "$RUNNERS_IDENTITY" ] || missing+=("runners_resource_group / runners_identity_name in pinned.auto.tfvars.json (re-run setup-pipeline.ps1)")
[ -n "$ACR" ] || missing+=("container_registry_name in pinned.auto.tfvars.json (CONTAINER_REGISTRY_NAME for setup)")
[ -n "$ENVIRONMENT_ID" ] || missing+=("runners_environment_id in pinned.auto.tfvars.json (RUNNERS_ENVIRONMENT_ID for setup: the cluster monitor's Container Apps environment)")
[ -n "$RUNNER_IMAGE" ] || missing+=("the repository variable RUNNER_IMAGE")
[ ${#missing[@]} -eq 0 ] || notice "runners not applied, missing: ${missing[*]}"

ARC_SECRET="global-arc-global-arc-runner-$(echo "$GITHUB_ORG" | tr '[:upper:]' '[:lower:]')"
if ! az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$ARC_SECRET" --query id -o tsv >/dev/null 2>"$WORK/err"; then
    notice "runners not applied: $ARC_SECRET cannot be read in $KEY_VAULT_NAME ($(head -c 200 "$WORK/err")).
The GUI writes it when the GitHub App is installed; then re-run setup-pipeline.ps1 so this job may read it."
fi

# ── 5. Terraform ───────────────────────────────────────────────────────────────
export ARM_USE_CLI=true
export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export ARM_TENANT_ID="$TENANT_ID"
export TF_IN_AUTOMATION=1

args=(
    -var="tenant_id=${TENANT_ID}"
    -var="subscription_id=${SUBSCRIPTION_ID}"
    -var="resource_group=${RUNNERS_RG}"
    -var="location=${LOCATION}"
    -var="container_app_environment_id=${ENVIRONMENT_ID}"
    -var="key_vault_name=${KEY_VAULT_NAME}"
    -var="key_vault_resource_group=${KV_RG}"
    -var="container_registry_name=${ACR}"
    -var="container_registry_resource_group=${ACR_RG}"
    -var="identity_name=${RUNNERS_IDENTITY}"
    -var="identity_resource_group=${RUNNERS_RG}"
    -var="github_org=${GITHUB_ORG}"
    -var="runner_image=${RUNNER_IMAGE}"
)
# The counts the repository sets; the module's defaults otherwise.
[ -n "$RUNNERS_HOT" ] && args+=(-var="hot=${RUNNERS_HOT}")
[ -n "$RUNNERS_MAX" ] && args+=(-var="max=${RUNNERS_MAX}")
[ -n "$RUNNERS_LONG_MAX" ] && args+=(-var="long_max=${RUNNERS_LONG_MAX}")
# The images runners' image (State of World captures); runner_image otherwise.
[ -n "$RUNNER_CAPTURE_IMAGE" ] && args+=(-var="images_image=${RUNNER_CAPTURE_IMAGE}")
# SaaS: the runners sign in to the GUI (M2M), with the client secret setup
# stored in the vault (m2m-client-secret).
if [ -n "${M2M_CLIENT_ID:-}" ] && [ -n "${M2M_COGNITO_URL:-}" ] && [ -n "${SERVER_URL:-}" ]; then
    args+=(-var="m2m=true" -var="m2m_client_id=${M2M_CLIENT_ID}"
           -var="m2m_token_url=${M2M_COGNITO_URL%/}/oauth2/token" -var="server_url=${SERVER_URL%/}")
fi

# Never older than the Terraform that last wrote this state: the repo's own
# guard (scripts/terraform_version_guard.sh), once the private copy has it.
if [ -f scripts/terraform_version_guard.sh ]; then
    need=$(bash scripts/terraform_version_guard.sh azurerm "$STATE_ACCOUNT" "$STATE_CONTAINER" "$STATE_KEY") ||
        die "could not read the runners state to check which Terraform wrote it"
    if [ -n "$need" ]; then
        log "The state was written by Terraform $need, newer than the pinned $TERRAFORM_VERSION: using $need"
        TERRAFORM_INSTALL_DIR=/usr/local/bin bash scripts/install_terraform.sh "$need" >/dev/null ||
            die "could not install Terraform $need"
    fi
else
    log "No scripts/terraform_version_guard.sh in this copy yet: Terraform $TERRAFORM_VERSION as pinned"
fi

cd runners
log "terraform init"
terraform init -input=false -reconfigure \
    "-backend-config=storage_account_name=${STATE_ACCOUNT}" \
    "-backend-config=container_name=${STATE_CONTAINER}" \
    "-backend-config=key=${STATE_KEY}" \
    "-backend-config=resource_group_name=${STATE_RESOURCE_GROUP}" \
    "-backend-config=subscription_id=${SUBSCRIPTION_ID}" \
    "-backend-config=tenant_id=${TENANT_ID}"

rc=0
terraform plan -input=false -out=tfplan -detailed-exitcode "${args[@]}" || rc=$?
case "$rc" in
    0) log "PLAN (runners/): no changes" ;;
    2) log "PLAN (runners/): changes, listed above" ;;
    *) die "terraform plan failed" ;;
esac
if [ "${PLAN_ONLY:-}" = "true" ]; then
    log "Done (PLAN_ONLY: nothing applied)"
    exit 0
fi
terraform apply -input=false tfplan
terraform output
log "Done: runners applied"
