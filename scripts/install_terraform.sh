#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# Install one pinned Terraform release on a GitHub Actions runner.
#
#   scripts/install_terraform.sh <version>        e.g. 1.11.0
#
# GitOps Manager's runner image carries other tools but not Terraform, so the
# workflows that run Terraform (bootstrap-create-cluster.yml,
# bootstrap-cluster-identities.yml, bootstrap-handover.yml) install it here
# first. The version is passed in, pinned in each workflow, and must match the
# buildspecs' TERRAFORM_VERSION: a state written by a newer Terraform cannot be
# read by an older one.
#
# Downloads from releases.hashicorp.com and checks the zip against the
# release's SHA256SUMS before installing. Installs into $RUNNER_TEMP (no root
# needed) and adds it to $GITHUB_PATH for the steps that follow.
set -euo pipefail

version="${1:?usage: install_terraform.sh <version>}"

case "$(uname -m)" in
  x86_64|amd64)  arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "::error::Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

zip="terraform_${version}_linux_${arch}.zip"
base="https://releases.hashicorp.com/terraform/${version}"
work="$(mktemp -d)"
bin="${RUNNER_TEMP:-/tmp}/terraform-${version}"

curl -fsSL -o "${work}/${zip}" "${base}/${zip}"
curl -fsSL -o "${work}/SHA256SUMS" "${base}/terraform_${version}_SHA256SUMS"
( cd "$work" && grep " ${zip}\$" SHA256SUMS | sha256sum -c - )

mkdir -p "$bin"
unzip -oq "${work}/${zip}" terraform -d "$bin"
rm -rf "$work"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$bin" >> "$GITHUB_PATH"
fi
"${bin}/terraform" version
