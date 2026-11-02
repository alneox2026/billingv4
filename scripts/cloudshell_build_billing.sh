#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# SuperApp Central Billing API — Cloud Shell Build Script
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_CONFIG="${ROOT_DIR}/cloudbuild.yaml"
DOCKERFILE="${ROOT_DIR}/services/billing_api_v3/Dockerfile"
. "${SCRIPT_DIR}/billing_stack.sh"
resolve_billing_stack "${ROOT_DIR}" "${DEPLOYMENT_ENV:-development}"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-ceo-agent-repo}"
IMAGE_NAME="${IMAGE_NAME:-${DEFAULT_BILLING_IMAGE_NAME}}"
TAG="${TAG:-latest}"

if [ -z "${PROJECT_ID}" ]; then
  echo "ERROR: PROJECT_ID is not set and could not be detected from gcloud config." >&2
  exit 1
fi

if [ ! -f "${BUILD_CONFIG}" ]; then
  echo "ERROR: Cloud Build config not found: ${BUILD_CONFIG}" >&2
  exit 1
fi

if [ ! -f "${DOCKERFILE}" ]; then
  echo "ERROR: Billing API Dockerfile not found: ${DOCKERFILE}" >&2
  exit 1
fi

echo "================================================================="
echo " Building SuperApp Central Billing API"
echo " Project:    ${PROJECT_ID}"
echo " Region:     ${REGION}"
echo " Repository: ${REPOSITORY}"
echo " Image:      ${IMAGE_NAME}:${TAG}"
echo "================================================================="

# Ensure Artifact Registry repo exists
gcloud artifacts repositories describe "${REPOSITORY}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" >/dev/null 2>&1 || {
    echo "Creating Artifact Registry repository: ${REPOSITORY}..."
    gcloud artifacts repositories create "${REPOSITORY}" \
      --project="${PROJECT_ID}" \
      --repository-format=docker \
      --location="${REGION}" \
      --description="SuperApp Docker repository"
}

IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:${TAG}"

echo "--> Submitting Cloud Build for Billing API..."
gcloud builds submit "${ROOT_DIR}" \
  --project="${PROJECT_ID}" \
  --config="${BUILD_CONFIG}" \
  --substitutions="_IMAGE_TAG=${IMAGE_TAG}"

echo "================================================================="
echo " Build Completed Successfully!"
echo " Image: ${IMAGE_TAG}"
echo "================================================================="
