#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Apply core-stack argo-cd's "infra" AppProject, once Argo CD (and so its
# CRDs) is installed. It cannot be part of helm_release.argo_cd: Helm maps
# every object before installing any, and the AppProject kind does not exist
# until that same release has installed Argo CD's CRDs.
#
# Rendered from the same chart and values, so Argo CD's later sync of its own
# Application finds the project already as it renders.
#
# Called by terraform_data.infra_project with: SUBSCRIPTION RESOURCE_GROUP
# CLUSTER CHART and SET_ARGS (the helm --set arguments, space separated, no
# spaces inside). The local admin credentials, as the stage's providers and
# the agent's admin context use.
set -euo pipefail

export KUBECONFIG
KUBECONFIG=$(mktemp)
trap 'rm -f "$KUBECONFIG"' EXIT
az aks get-credentials --admin --subscription "$SUBSCRIPTION" --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER" --file "$KUBECONFIG" --overwrite-existing --only-show-errors

set_flags=()
for s in $SET_ARGS; do set_flags+=(--set "$s"); done

# The chart's dependency was fetched by helm_release.argo_cd (dependency_update).
helm template argo-cd "$CHART" -n argocd --show-only templates/appproject.yaml "${set_flags[@]}" \
  | kubectl apply --server-side --field-manager=core-stack -f -
