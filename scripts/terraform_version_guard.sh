#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# Never run a Terraform older than the one that last wrote a state.
#
#   terraform_version_guard.sh s3      <bucket> <key> [region]
#   terraform_version_guard.sh azurerm <storage-account> <container> <key>
#   terraform_version_guard.sh gcs     <bucket> <prefix>      (the object <prefix>/default.tfstate)
#
# Prints the version that last wrote the state when it is NEWER than the
# Terraform on PATH (or when none is installed yet); prints nothing when the
# installed one is as new or newer, or there is no state yet. Then, before
# terraform init:
#
#   need=$(bash scripts/terraform_version_guard.sh s3 "$bucket" "$key" "$region")
#   if [ -n "$need" ]; then
#     bash scripts/install_terraform.sh "$need"
#     PATH="${RUNNER_TEMP:-/tmp}/terraform-${need}:$PATH"   # or TERRAFORM_INSTALL_DIR
#   fi
#
# Why: an older Terraform is not promised to read state a newer one wrote, and
# the pins move. One run left on an old pin, or a job released before the pins
# that installed whatever was current, must not take a state backwards.
#
# A state can hold secrets (the certificate states hold private keys). Only its
# terraform_version field is kept: S3 and GCS are read through a pipe; the Azure
# CLI needs a file, private to this run and removed straight away.
set -euo pipefail

version_of() {   # JSON on stdin -> its terraform_version, or nothing
  grep -o '"terraform_version": *"[0-9][0-9.]*' | head -1 | grep -o '[0-9][0-9.]*$' || true
}

older_than() {   # true when $1 is an older release than $2
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

backend="${1:?usage: terraform_version_guard.sh s3|azurerm|gcs <location...>}"
shift
state=""
case "$backend" in
  s3)
    bucket="${1:?bucket}" key="${2:?key}" region="${3:-}"
    region_arg=()
    [ -n "$region" ] && region_arg=(--region "$region")
    # No state yet: nothing to protect.
    aws s3api head-object --bucket "$bucket" --key "$key" "${region_arg[@]}" >/dev/null 2>&1 || exit 0
    state=$(aws s3 cp "s3://${bucket}/${key}" - "${region_arg[@]}" | version_of)
    ;;
  azurerm)
    account="${1:?storage account}" container="${2:?container}" key="${3:?key}"
    exists=$(az storage blob exists --account-name "$account" --container-name "$container" \
               --name "$key" --auth-mode login --query exists -o tsv)
    [ "$exists" = "true" ] || exit 0
    tmp=$(mktemp)
    chmod 600 "$tmp"
    trap 'rm -f "$tmp"' EXIT
    az storage blob download --account-name "$account" --container-name "$container" \
      --name "$key" --auth-mode login --file "$tmp" --no-progress -o none
    state=$(version_of < "$tmp")
    rm -f "$tmp"
    ;;
  gcs)
    bucket="${1:?bucket}" prefix="${2:?prefix}"
    object="gs://${bucket}/${prefix%/}/default.tfstate"
    gcloud storage objects describe "$object" >/dev/null 2>&1 || exit 0
    state=$(gcloud storage cat "$object" | version_of)
    ;;
  *)
    echo "terraform_version_guard.sh: unknown backend '$backend' (s3, azurerm or gcs)" >&2
    exit 2
    ;;
esac

[ -n "$state" ] || exit 0
have=$(terraform version -json 2>/dev/null | version_of || true)
if [ -z "$have" ] || older_than "$have" "$state"; then
  echo "Terraform ${have:-(none)} is older than ${state}, which last wrote this state: use ${state}" >&2
  echo "$state"
fi
