#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# The Let's Encrypt certificate job.
#
# Runs as the Container Apps job job-aksmanager-letsencrypt, which
# setup-pipeline.ps1 creates: weekly on its own cron, and on demand from the
# "Run lets encrypt certificate job" workflow. It is the Azure counterpart of
# the AWS eksmanager-lets-encrypt CodeBuild project.
#
# Everything runs as the job's managed identity, id-aksmanager-letsencrypt.
# The identity's reach is limited to certificates: TXT records in the public
# zones, the Key Vault secrets, and the certificate OpenTofu state.
#
# Steps:
#   1. Tools: the image is mcr.microsoft.com/azure-cli (az, python3); git,
#      unzip and openssl are added with tdnf, and OpenTofu is downloaded at a
#      pinned release, checksum verified against the release's SHA256SUMS.
#   2. Sign in: az login --identity. OpenTofu and lego both use that az login
#      (ARM_USE_CLI, azure_auth_method=cli). The azurerm backend could not use
#      a Container Apps managed identity directly -- it did not support the
#      platform's IDENTITY_ENDPOINT (hashicorp/terraform#37268) -- and the az
#      login is the documented workaround, which OpenTofu's backend supports
#      the same way (use_cli).
#   3. The private repo, cloned with the bootstrap GitHub App (credentials in
#      Key Vault as global-bootstrap-github-app), for hosted-zones.json and
#      tofu/lets-encrypt (terraform/lets-encrypt in a repo not yet synced
#      since the move).
#   4. hosted-zones.json validated by scripts/hosted_zones_tfvars.py.
#   5. The vault guard: a zone whose <prefix>-dns-zone-certs was not written
#      by the pipeline (a manually saved certificate, live or soft-deleted) is
#      left out, as in setup. Manual certificates are never overwritten.
#   6. tofu init + the empty-state guard + tofu apply.
#
# Configuration comes from the job's environment, set by setup-pipeline.ps1.
# TOFU_VERSION overrides the pinned OpenTofu release when set.
# ALLOW_EMPTY_STATE=true overrides the empty-state guard (see below).
# PLAN_ONLY=true plans instead of applying: nothing is issued, renewed or
# written, and the run reports whether the plan has changes. For checking a
# change -- the move to OpenTofu -- against the live state first.
# -----------------------------------------------------------------------------
set -euo pipefail

log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

for v in AZURE_CLIENT_ID TENANT_ID SUBSCRIPTION_ID KEY_VAULT_NAME KEY_VAULT_ID APP_SECRET_NAME \
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

# Pinned, as on AWS (eksmanager-bootstrap's buildspecs): a release arriving on
# its own would surface at renewal, unattended.
TOFU_VERSION="${TOFU_VERSION:-1.13.1}"
log "OpenTofu $TOFU_VERSION"
(
    cd "$WORK"
    base="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}"
    curl -fsSLO "${base}/tofu_${TOFU_VERSION}_linux_amd64.zip"
    curl -fsSLO "${base}/tofu_${TOFU_VERSION}_SHA256SUMS"
    grep " tofu_${TOFU_VERSION}_linux_amd64.zip\$" "tofu_${TOFU_VERSION}_SHA256SUMS" | sha256sum -c --quiet - ||
        die "OpenTofu ${TOFU_VERSION} failed its checksum"
    unzip -q -o "tofu_${TOFU_VERSION}_linux_amd64.zip" tofu -d /usr/local/bin
)
tofu version

# ── 2. Sign in as the job's managed identity ──────────────────────────────────
log "Signing in as managed identity $AZURE_CLIENT_ID"
# --client-id on current az; --username on releases before it.
az login --identity --client-id "$AZURE_CLIENT_ID" --allow-no-subscriptions -o none 2>/dev/null ||
    az login --identity --username "$AZURE_CLIENT_ID" --allow-no-subscriptions -o none ||
    die "az login --identity failed -- is $AZURE_CLIENT_ID assigned to this job?"
# Best effort. The identity's roles are on resources, not the subscription, so
# az may not list the subscription at all; nothing below depends on it --
# OpenTofu takes ARM_SUBSCRIPTION_ID and Key Vault calls name the vault.
az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null || true

# ── 3. The private repo, through the bootstrap GitHub App ─────────────────────
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

# Scoped to the one repo, as the server and setup do.
GH_TOKEN=$(curl -fsS -X POST \
    -H "Authorization: Bearer ${header}.${payload}.${signature}" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"repositories\":[\"${GITHUB_REPO_NAME}\"]}" \
    "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])') ||
    die "GitHub would not issue a token for ${GITHUB_ORG}/${GITHUB_REPO_NAME} -- is the App installed on it?"

log "Cloning ${GITHUB_ORG}/${GITHUB_REPO_NAME}"
# The token goes in a header for this one command, never in the remote URL,
# so it is not written into the clone's config.
auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)
git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth}" \
    clone -q --depth 1 "https://github.com/${GITHUB_ORG}/${GITHUB_REPO_NAME}.git" "$WORK/repo" ||
    die "could not clone ${GITHUB_ORG}/${GITHUB_REPO_NAME}"
unset GH_TOKEN auth
cd "$WORK/repo"
log "At commit $(git rev-parse --short HEAD): $(git log -1 --format=%s)"

# The module's folder: tofu/lets-encrypt since the move to OpenTofu,
# terraform/lets-encrypt in a private repo not yet synced since. Either works
# here; the state is the same blob whichever folder applies it.
MODULE=tofu/lets-encrypt
[ -d "$MODULE" ] || MODULE=terraform/lets-encrypt
[ -d "$MODULE" ] || die "neither tofu/lets-encrypt nor terraform/lets-encrypt is in ${GITHUB_ORG}/${GITHUB_REPO_NAME}"

# ── 4. hosted-zones.json ──────────────────────────────────────────────────────
TFVARS="$MODULE/hosted-zones.auto.tfvars.json"
python3 scripts/hosted_zones_tfvars.py hosted-zones.json "$TFVARS" || die "hosted-zones.json did not validate (see above)"

# ── 5. Vault guard ────────────────────────────────────────────────────────────
log "Vault guard"
managed_by() {   # tags JSON on stdin -> the managed_by value, any spelling
    python3 -c '
import json, re, sys
tags = json.load(sys.stdin) or {}
print(next((v for k, v in tags.items() if re.sub(r"[^a-z0-9]", "", k.lower()) == "managedby"), ""))'
}
# "Terraform" is the pipeline's managed_by value, kept after the move to
# OpenTofu (tofu/lets-encrypt/main.tf says why).
blocked=()
keep=()
while IFS=$'\t' read -r key prefix zone; do
    secret="${prefix//_/-}-dns-zone-certs"
    if tags=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$secret" --query tags -o json 2>"$WORK/err"); then
        owner=$(printf '%s' "$tags" | managed_by)
        if [ "$owner" != "Terraform" ]; then
            blocked+=("$zone: $secret is a manually saved certificate (managed_by='$owner')")
            continue
        fi
    elif grep -q -i -E 'not ?found' "$WORK/err"; then
        if tags=$(az keyvault secret show-deleted --vault-name "$KEY_VAULT_NAME" --name "$secret" --query tags -o json 2>/dev/null); then
            if [ "$(printf '%s' "$tags" | managed_by)" != "Terraform" ]; then
                blocked+=("$zone: $secret was deleted but not purged, and is not the pipeline's")
                continue
            fi
        fi
    else
        die "could not read $secret in $KEY_VAULT_NAME: $(cat "$WORK/err")"
    fi
    keep+=("$key")
    log "  ok $prefix -> $secret"
done < <(python3 -c '
import json, sys
for k, z in json.load(open(sys.argv[1]))["hosted_zones"].items():
    print("\t".join([k, z["dns_zone_prefix"], z["public_dns_zone"]]))' "$TFVARS")

for b in "${blocked[@]}"; do echo "WARNING: SKIPPED $b"; done
[ ${#keep[@]} -gt 0 ] || die "every zone was skipped by the vault guard -- nothing to issue"
if [ ${#blocked[@]} -gt 0 ]; then
    python3 -c '
import json, sys
path, keep = sys.argv[1], set(sys.argv[2:])
doc = json.load(open(path))
doc["hosted_zones"] = {k: v for k, v in doc["hosted_zones"].items() if k in keep}
json.dump(doc, open(path, "w"), indent=2)' "$TFVARS" "${keep[@]}"
fi

# ── 6. OpenTofu ───────────────────────────────────────────────────────────────
export ARM_USE_CLI=true
export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export ARM_TENANT_ID="$TENANT_ID"
export TF_IN_AUTOMATION=1
cd "$MODULE"

log "tofu init"
tofu init -input=false \
    "-backend-config=storage_account_name=${STATE_ACCOUNT}" \
    "-backend-config=container_name=${STATE_CONTAINER}" \
    "-backend-config=key=${STATE_KEY}" \
    "-backend-config=resource_group_name=${STATE_RESOURCE_GROUP}" \
    "-backend-config=subscription_id=${SUBSCRIPTION_ID}" \
    "-backend-config=tenant_id=${TENANT_ID}"

# Empty-state guard, as in setup and on AWS. An empty state while the vault
# already holds certificates the pipeline wrote means the state was lost, not
# never created: applying would try to recreate every secret.
managed=$(tofu state list 2>/dev/null | grep -c -v '^data\.' || true)
if [ "${managed:-0}" -eq 0 ] && [ "${ALLOW_EMPTY_STATE:-}" != "true" ]; then
    ours=$(az keyvault secret list --vault-name "$KEY_VAULT_NAME" \
        --query "[?tags.managed_by=='Terraform'].name" -o tsv | tr '\n' ' ')
    if [ -n "${ours// /}" ]; then
        die "the OpenTofu state ${STATE_ACCOUNT}/${STATE_CONTAINER}/${STATE_KEY} is empty, but
$KEY_VAULT_NAME already holds certificates the pipeline wrote ($ours). The state has
been lost; applying would try to recreate them. Check the blob's versions:
  az storage blob list --account-name $STATE_ACCOUNT --container-name $STATE_CONTAINER --auth-mode login --include v -o table
If this really is a fresh start, set ALLOW_EMPTY_STATE=true on the job for one run."
    fi
fi

# Staging -> production. OpenTofu renews only inside min_days_remaining, so
# after acme-staging is turned off a zone would keep its staging certificate --
# untrusted root -- for about two months. -replace cannot force it either:
# prevent_destroy refuses the destroy half. So when staging is off and any
# zone's stored certificate came from a staging CA ("(STAGING) ..." issuer),
# this run renews regardless of days remaining. Renewal is an in-place update,
# which prevent_destroy allows. Every zone is renewed in that run, which costs
# one certificate each against the 5-per-week limit for an identical name.
renew_args=()
staging=$(python3 -c 'import json; print(str(json.load(open("hosted-zones.auto.tfvars.json")).get("acme_use_staging", False)).lower())')
if [ "$staging" = "false" ]; then
    for key in "${keep[@]}"; do
        prefix=$(python3 -c 'import json,sys; print(json.load(open("hosted-zones.auto.tfvars.json"))["hosted_zones"][sys.argv[1]]["dns_zone_prefix"])' "$key")
        secret="${prefix//_/-}-dns-zone-certs"
        issuer=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$secret" --query value -o tsv 2>/dev/null |
                 python3 -c 'import json,sys; print(json.load(sys.stdin).get("tls.crt", ""))' 2>/dev/null |
                 openssl x509 -noout -issuer 2>/dev/null || true)
        if printf '%s' "$issuer" | grep -q -i 'staging'; then
            log "$secret holds a staging certificate ($issuer) but acme-staging is off -- renewing now"
            renew_args=("-var=min_days_remaining=365")
        fi
    done
fi

# The ACME account first, on its own. Staging and production accounts are
# separate, so after acme-staging changes the account must be registered on the
# new server -- but acme_certificate already asks that server about the account
# while PLANNING, and fails with accountDoesNotExist before the registration in
# the same apply could run. A targeted apply creates it first. On every other
# run this changes nothing.
tf_vars=(
    "-var=shared_services_subscription_id=${SUBSCRIPTION_ID}"
    "-var=key_vault_id=${KEY_VAULT_ID}"
    "-var=azure_auth_method=cli"
)

if [ "${PLAN_ONLY:-}" = "true" ]; then
    # No apply at all, not even the ACME account's. -detailed-exitcode: 0 no
    # changes, 2 changes, 1 error. After the move to OpenTofu a plan with no
    # changes is the result to expect: same state, same providers.
    log "tofu plan (PLAN_ONLY: nothing is applied)"
    set +e
    tofu plan -input=false -detailed-exitcode "${tf_vars[@]}" "${renew_args[@]}"
    rc=$?
    set -e
    case "$rc" in
        0) log "PLAN_ONLY: no changes" ;;
        2) log "PLAN_ONLY: the plan has changes (above); nothing was applied" ;;
        *) die "tofu plan failed" ;;
    esac
    log "Done"
    exit 0
fi

log "tofu apply (ACME account)"
tofu apply -input=false -auto-approve -target=acme_registration.this "${tf_vars[@]}"

log "tofu apply"
tofu apply -input=false -auto-approve "${tf_vars[@]}" "${renew_args[@]}"

log "Certificates:"
tofu output -json certificate_expiry 2>/dev/null || true
log "Done"
