#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# Install one Terraform release, checksum verified.
#
#   scripts/install_terraform.sh <version> [<version>...]      e.g. 1.17.1
#
# With several versions (the pin, and what terraform_version_guard.sh found a
# state was written by) the highest is installed: a run never goes backwards.
#
# GitOps Manager's runner image carries other tools but not Terraform, so the
# workflows that run Terraform (bootstrap-create-cluster.yml,
# bootstrap-cluster-identities.yml, bootstrap-handover.yml) install it here
# first, and the CodeBuild buildspecs use it too. The pin is passed in and must
# match everywhere: raise it in every buildspec, generator and workflow
# together, never lower it.
#
# Downloads from releases.hashicorp.com and checks the zip against the
# release's SHA256SUMS before installing. Installs into TERRAFORM_INSTALL_DIR
# when set (CodeBuild: /usr/local/bin), else ${RUNNER_TEMP:-/tmp}/terraform-<version>
# (no root needed), and adds that to $GITHUB_PATH for the steps that follow.
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: install_terraform.sh <version> [<version>...]" >&2; exit 2; }
for v in "$@"; do
  [ -z "$v" ] || [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    { echo "install_terraform.sh: '$v' is not a release version like 1.17.1" >&2; exit 2; }
done
version=$(printf '%s\n' "$@" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
[ -n "$version" ] || { echo "install_terraform.sh: no version given" >&2; exit 2; }
[ "$version" = "$1" ] || echo "Terraform ${version}, not the pinned $1: a state was written by ${version}, and Terraform never goes back"

case "$(uname -m)" in
  x86_64|amd64)  arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "::error::Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

zip="terraform_${version}_linux_${arch}.zip"
base="https://releases.hashicorp.com/terraform/${version}"
work="$(mktemp -d)"
bin="${TERRAFORM_INSTALL_DIR:-${RUNNER_TEMP:-/tmp}/terraform-${version}}"

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
