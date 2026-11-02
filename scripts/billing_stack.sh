#!/usr/bin/env bash

# Resolve clone-specific defaults shared by the build and deploy scripts.
# BILLING_STACK_NAME can be set explicitly; otherwise use the Git origin name,
# falling back to the checkout directory name.
resolve_billing_stack() {
  local root_dir="$1"
  local deployment_env="${2:-development}"
  local repo_name=""
  local raw_name=""
  local digest=""
  local prefix=""

  if [ -n "${BILLING_STACK_NAME:-}" ]; then
    raw_name="${BILLING_STACK_NAME}"
  else
    repo_name="$(git -C "${root_dir}" config --get remote.origin.url 2>/dev/null || true)"
    repo_name="${repo_name##*/}"
    repo_name="${repo_name%.git}"
    raw_name="${repo_name:-$(basename "${root_dir}")}"
  fi

  BILLING_STACK_NAME="$(printf '%s' "${raw_name}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
  if [ -z "${BILLING_STACK_NAME}" ] || ! [[ "${BILLING_STACK_NAME}" =~ ^[a-z][a-z0-9-]*[a-z0-9]$|^[a-z]$ ]]; then
    echo "ERROR: Could not derive a valid billing stack name from '${raw_name}'. Set BILLING_STACK_NAME to a lowercase name starting with a letter and containing only letters, digits, or hyphens." >&2
    return 2
  fi

  BILLING_RESOURCE_PREFIX="${BILLING_STACK_NAME}"
  if [ "${#BILLING_RESOURCE_PREFIX}" -gt 21 ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      digest="$(printf '%s' "${BILLING_STACK_NAME}" | sha256sum)"
    else
      digest="$(printf '%s' "${BILLING_STACK_NAME}" | shasum -a 256)"
    fi
    digest="${digest%% *}"
    prefix="${BILLING_STACK_NAME:0:14}"
    prefix="${prefix%-}"
    BILLING_RESOURCE_PREFIX="${prefix}-${digest:0:6}"
    echo "NOTE: Stack name '${BILLING_STACK_NAME}' is longer than 21 characters; resource names use '${BILLING_RESOURCE_PREFIX}' (with a stable hash) to satisfy the 30-character service-account ID limit." >&2
  fi

  DEFAULT_BILLING_SERVICE_NAME="${BILLING_RESOURCE_PREFIX}-api"
  DEFAULT_BILLING_SERVICE_ACCOUNT_NAME="${BILLING_RESOURCE_PREFIX}-sa"
  DEFAULT_BILLING_RECONCILER_SERVICE_ACCOUNT_NAME="${BILLING_RESOURCE_PREFIX}-recon-sa"
  DEFAULT_BILLING_IMAGE_NAME="${BILLING_RESOURCE_PREFIX}-billing-api"
  DEFAULT_TF_STATE_PREFIX="superapp-billing/stacks/${BILLING_STACK_NAME}/${deployment_env}/terraform/state"
}
