#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# One stage of terraform/create-cluster: init against the cluster's own state,
# plan, and apply that exact plan (or stop at the plan).
#
#   run_terraform_stage.sh <stage> <cluster> <plan|apply> <tfvars>
#
# The AKS create's copy of eksmanager-bootstrap's script: the same graceful
# stop. State in setup's storage account (azurerm backend, Entra sign-in):
#   $STATE_ACCOUNT / $STATE_CONTAINER / clusters/<cluster>/<stage>.tfstate
# with STATE_SUBSCRIPTION (the account's subscription) and ARM_TENANT_ID.
# STAGE_DIR and STATE_KEY, when set, run another module and state instead
# (the ASO identity: terraform/cluster-identities, identities/<cluster>/aso.tfstate,
# the state bootstrap-cluster-identities.yml uses).
#   run_terraform_stage.sh --stop     after a cancel: let Terraform stop gracefully
#
# Terraform: this calls `terraform` (terraform/README.md).
#
# Graceful stop. GitHub kills a cancelled step about 10 seconds after the
# cancel, too soon for Terraform to finish the changes in flight, write its
# state and release its lock. So plan and apply, the commands that lock the
# state, run apart from the step (terraform_session.py, in a session of its own)
# and the step only watches them. On a cancel:
#   - this step sends Terraform ONE interrupt, its graceful stop: it finishes
#     what it is changing, writes the state, releases the lock and exits.
#     Never two: a second interrupt makes it exit at once.
#   - the workflow's `if: cancelled()` step runs --stop, which sends that
#     interrupt if this step didn't get to, and waits for Terraform to end.
#     A lock left behind is removed only when it is this runner's and no
#     Terraform is running (the workflow's concurrency group means no other
#     run can hold it).
# init and output run in the step as before: init takes no lock, and output
# only reads.
set -euo pipefail

runs="${RUNNER_TEMP:-/tmp}/terraform-runs"
here=$(cd "$(dirname "$0")" && pwd)

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

# interrupt <run dir>: Terraform's one interrupt, at most once whoever asks
# (mkdir is the once).
interrupt() {
  local run=$1
  mkdir "$run/interrupted" 2>/dev/null || return 0
  if alive "$run/terraform.pid"; then
    kill -INT "$(cat "$run/terraform.pid")" 2>/dev/null || true
    echo "Asked Terraform ($(cat "$run/what")) to stop gracefully."
  fi
}

# follow <run dir>: show Terraform's output until it ends. Sets rc.
follow() {
  local run=$1 tail_pid
  tail -n +1 -F "$run/log" 2>/dev/null &
  tail_pid=$!
  # Until it writes its exit code, or its session is gone without one.
  while [ ! -f "$run/rc" ]; do
    if [ -f "$run/session.pid" ] && ! alive "$run/session.pid" && [ ! -f "$run/rc" ]; then
      break
    fi
    sleep 2
  done
  sleep 2   # tail -F's last read
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
  rc=$(cat "$run/rc" 2>/dev/null || echo 1)
}

# ---------------------------------------------------------------- --stop
if [ "${1:-}" = --stop ]; then
  shopt -s nullglob
  found=0
  for run in "$runs"/*/; do
    run=${run%/}
    [ -f "$run/rc" ] && continue
    found=1
    interrupt "$run"
    echo "Waiting for Terraform ($(cat "$run/what")) to finish and release its lock..."
    follow "$run"
    echo "Terraform ($(cat "$run/what")) ended with exit code $rc."
    echo "Stopped gracefully: $(cat "$run/what"), exit code $rc. Re-run the create to continue from here." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  done
  [ "$found" = 1 ] || echo "No Terraform command was running."

  # A lock left behind (Terraform killed after all): remove it if it is this
  # runner's and nothing is running. Each state once (plan and apply share
  # one).
  declare -A checked=()
  for run in "$runs"/*/; do
    run=${run%/}
    [ -f "$run/lock" ] || continue
    read -r account container key dir < "$run/lock"
    alive "$run/terraform.pid" && continue
    [ -z "${checked[$key]:-}" ] || continue
    checked[$key]=1
    # The azurerm backend's lock: a lease on the state blob, its details in the
    # blob's metadata (terraformlockid, base64 JSON).
    meta=$(az storage blob show --account-name "$account" --container-name "$container" --name "$key" \
             --auth-mode login --query metadata.terraformlockid -o tsv 2>/dev/null || true)
    [ -n "$meta" ] && [ "$meta" != None ] || continue
    lock=$(printf '%s' "$meta" | base64 -d 2>/dev/null || true)
    [ -n "$lock" ] || continue
    who=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("Who",""))' "$lock")
    id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("ID",""))' "$lock")
    if [ "${who#*@}" = "$(uname -n)" ] && [ -n "$id" ]; then
      echo "Removing the lock this runner left on $key ($id)."
      terraform -chdir="$dir" force-unlock -force "$id"
      echo "Removed a leftover state lock on \`$key\`." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    else
      echo "::warning::$key is locked by $who, not this runner; left as it is."
    fi
  done
  exit 0
fi

# ---------------------------------------------------------------- a stage
stage="$1" cluster="$2" mode="$3" tfvars="$4"
dir="${STAGE_DIR:-terraform/create-cluster/$stage}"
for v in STATE_ACCOUNT STATE_CONTAINER STATE_SUBSCRIPTION ARM_TENANT_ID; do
  [ -n "${!v:-}" ] || { echo "::error::$v is not set"; exit 1; }
done
[ -d "$dir" ] || { echo "::error::No stage $stage ($dir)"; exit 1; }
case "$mode" in plan|apply) ;; *) echo "::error::mode must be plan or apply"; exit 1 ;; esac

cp "$tfvars" "$dir/create.auto.tfvars.json"
key="${STATE_KEY:-clusters/$cluster/$stage.tfstate}"

# tf_run <what> <terraform args...>: one locking command, apart from the step.
# Sets rc.
run=""
tf_run() {
  local what=$1; shift
  mkdir -p "$runs"
  run=$(mktemp -d "$runs/$stage.XXXXXX")
  echo "$what" > "$run/what"
  echo "$STATE_ACCOUNT $STATE_CONTAINER $key $dir" > "$run/lock"
  : > "$run/log"
  setsid --fork python3 "$here/terraform_session.py" "$run" "$@" < /dev/null
  follow "$run"
  run=""
}

# GitHub's cancel: one interrupt to Terraform, then leave the waiting to the
# workflow's `if: cancelled()` step (--stop).
on_cancel() {
  trap - INT TERM
  if [ -n "$run" ]; then
    interrupt "$run"
    echo "::warning::Cancelled during $(cat "$run/what"): Terraform is stopping gracefully; the next step waits for it."
  fi
  exit 130
}
trap on_cancel INT TERM

# Never older than the Terraform that last wrote this state.
need=$(bash "$here/terraform_version_guard.sh" azurerm "$STATE_ACCOUNT" "$STATE_CONTAINER" "$key")
if [ -n "$need" ]; then
  bash "$here/install_terraform.sh" "$need" >/dev/null
  PATH="${TERRAFORM_INSTALL_DIR:-${RUNNER_TEMP:-/tmp}/terraform-${need}}:$PATH"
fi

echo "::group::terraform init ($key)"
terraform -chdir="$dir" init -input=false -reconfigure \
  -backend-config="storage_account_name=$STATE_ACCOUNT" \
  -backend-config="container_name=$STATE_CONTAINER" \
  -backend-config="key=$key" \
  -backend-config="subscription_id=$STATE_SUBSCRIPTION" \
  -backend-config="tenant_id=$ARM_TENANT_ID"
echo "::endgroup::"

# -detailed-exitcode: 0 no changes, 2 changes, 1 error.
tf_run "$stage plan" -chdir="$dir" plan -input=false -no-color -detailed-exitcode -out=tfplan
case "$rc" in
  0) echo "$stage: no changes" ;;
  2) echo "$stage: changes planned" ;;
  *) echo "::error::$stage: plan failed"; exit 1 ;;
esac

# NO_DESTROY=1: refused, before anything is applied, when the plan deletes or
# replaces anything (scripts/plan_guard.py).
if [ "${NO_DESTROY:-}" = 1 ] && [ "$rc" = 2 ]; then
  terraform -chdir="$dir" show -json tfplan > "${RUNNER_TEMP:-/tmp}/$stage.plan.json"
  python3 "$here/plan_guard.py" "${RUNNER_TEMP:-/tmp}/$stage.plan.json" || { echo "::error::$stage: refused, nothing applied"; exit 1; }
fi

if [ "$mode" = apply ] && [ "$rc" = 2 ]; then
  tf_run "$stage apply" -chdir="$dir" apply -input=false -no-color tfplan
  [ "$rc" = 0 ] || { echo "::error::$stage: apply failed (exit code $rc)"; exit 1; }
fi

# Outputs, for the next steps and the cluster's record.
mkdir -p build/create-cluster
terraform -chdir="$dir" output -json > "build/create-cluster/$stage.outputs.json"
