#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# SuperApp Central Billing API — Cloud Shell Deploy Script
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/infra/terraform"
. "${SCRIPT_DIR}/billing_stack.sh"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-ceo-agent-repo}"
DEPLOYMENT_ENV="${DEPLOYMENT_ENV:-development}"
case "${DEPLOYMENT_ENV}" in
  prod) DEPLOYMENT_ENV="production" ;;
  dev) DEPLOYMENT_ENV="development" ;;
  stage) DEPLOYMENT_ENV="staging" ;;
  development|staging|production) ;;
  *)
    echo "ERROR: DEPLOYMENT_ENV must be development, staging, or production (or shorthand dev/stage/prod)." >&2
    exit 2
    ;;
esac

resolve_billing_stack "${ROOT_DIR}" "${DEPLOYMENT_ENV}"
IMAGE_NAME="${IMAGE_NAME:-${DEFAULT_BILLING_IMAGE_NAME}}"
BILLING_SERVICE_NAME="${BILLING_SERVICE_NAME:-${DEFAULT_BILLING_SERVICE_NAME}}"
BILLING_SERVICE_ACCOUNT_NAME="${BILLING_SERVICE_ACCOUNT_NAME:-${DEFAULT_BILLING_SERVICE_ACCOUNT_NAME}}"
BILLING_RECONCILER_SERVICE_ACCOUNT_NAME="${BILLING_RECONCILER_SERVICE_ACCOUNT_NAME:-${DEFAULT_BILLING_RECONCILER_SERVICE_ACCOUNT_NAME}}"

TF_STATE_BUCKET="${TF_STATE_BUCKET:-${PROJECT_ID}-tfstate}"
TF_STATE_PREFIX="${TF_STATE_PREFIX:-${DEFAULT_TF_STATE_PREFIX}}"
LEGACY_TF_STATE_PREFIX="superapp-billing/${DEPLOYMENT_ENV}/terraform/state"
if [ "${TF_STATE_PREFIX}" = "${LEGACY_TF_STATE_PREFIX}" ] && [ "${ALLOW_SHARED_BILLING_TERRAFORM_STATE:-false}" != "true" ]; then
  echo "ERROR: TF_STATE_PREFIX points to the legacy shared state path '${LEGACY_TF_STATE_PREFIX}'." >&2
  echo "Use the clone-specific default '${DEFAULT_TF_STATE_PREFIX}', or set ALLOW_SHARED_BILLING_TERRAFORM_STATE=true only when intentionally managing that existing deployment." >&2
  exit 2
fi

ALLOWED_ORIGINS_JSON="${ALLOWED_ORIGINS_JSON:-}"
if [ -z "${ALLOWED_ORIGINS_JSON}" ]; then
  ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-https://ceoappdev.flutterflow.app}"
  ALLOWED_ORIGINS_JSON="$(python3 -c 'import json,sys; print(json.dumps([item.strip() for item in sys.argv[1].split(",") if item.strip()]))' "${ALLOWED_ORIGINS}")"
fi

if [ "${DEPLOYMENT_ENV}" = "production" ] && [ "${ALLOWED_ORIGINS:-}" = "https://ceoappdev.flutterflow.app" ] && [ "${ALLOW_DEV_ORIGIN_IN_PROD:-false}" != "true" ]; then
  echo "WARNING: Deploying to production with default development origin: https://ceoappdev.flutterflow.app" >&2
  echo "         Set ALLOWED_ORIGINS to your production domain(s), e.g. ALLOWED_ORIGINS='https://app.yourdomain.com'" >&2
fi

if [ -z "${BILLING_CATALOG_PATH:-}" ]; then
  if [ "${DEPLOYMENT_ENV}" = "production" ]; then
    BILLING_CATALOG_PATH="/app/config/billing.prod.yaml"
  else
    BILLING_CATALOG_PATH="/app/config/billing.test.yaml"
  fi
fi

if [ -z "${PROJECT_ID}" ]; then
  echo "ERROR: PROJECT_ID is not set and could not be detected from gcloud config." >&2
  exit 1
fi

if [ "${DEPLOYMENT_ENV}" = "production" ]; then
  if [ "${PROJECT_ID}" = "ceo-dev123" ] && [ "${ALLOW_DEV_PROJECT_IN_PROD:-false}" != "true" ]; then
    echo "ERROR: PROJECT_ID is set to placeholder development project 'ceo-dev123' in a production deployment." >&2
    echo "Set PROJECT_ID to your active production project, or export ALLOW_DEV_PROJECT_IN_PROD=true if intentional." >&2
    exit 2
  fi
fi

echo "================================================================="
echo " Deploying SuperApp Central Billing API"
echo " Project:      ${PROJECT_ID}"
echo " Region:       ${REGION}"
echo " Environment:  ${DEPLOYMENT_ENV}"
echo " Stack:        ${BILLING_STACK_NAME}"
echo " Cloud Run:    ${BILLING_SERVICE_NAME}"
echo " Image:        ${IMAGE_NAME}"
echo " State Bucket: ${TF_STATE_BUCKET}"
echo " State Prefix: ${TF_STATE_PREFIX}"
echo " Catalog:      ${BILLING_CATALOG_PATH}"
echo " Origins:      ${ALLOWED_ORIGINS_JSON}"
echo "================================================================="

# Resolve latest image digest
echo "--> Resolving container image digest from Artifact Registry..."
IMAGE_BASE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}"
IMAGE_DIGEST="$(gcloud artifacts docker images describe "${IMAGE_BASE}:latest" --format='value(image_summary.digest)' 2>/dev/null || true)"

if [ -z "${IMAGE_DIGEST}" ]; then
  echo "ERROR: Image ${IMAGE_BASE}:latest not found. Run ./scripts/cloudshell_build_billing.sh first." >&2
  exit 1
fi

BILLING_API_IMAGE="${IMAGE_BASE}@${IMAGE_DIGEST}"
echo "Using immutable image: ${BILLING_API_IMAGE}"

cd "${TF_DIR}"

if [ -n "${TF_STATE_BUCKET}" ]; then
  echo "--> Initializing Terraform with GCS backend (${TF_STATE_BUCKET}/${TF_STATE_PREFIX})..."
  terraform init -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="prefix=${TF_STATE_PREFIX}"
else
  echo "ERROR: TF_STATE_BUCKET is required for GCS remote state backend." >&2
  exit 1
fi

PLAN_FILE="$(mktemp -t billing_plan_XXXXXX.tfplan)"
trap 'rm -f "${PLAN_FILE}"' EXIT

TF_VARS=(
  -var="project_id=${PROJECT_ID}"
  -var="region=${REGION}"
  -var="deployment_environment=${DEPLOYMENT_ENV}"
  -var="billing_api_image=${BILLING_API_IMAGE}"
  -var="billing_api_catalog_path=${BILLING_CATALOG_PATH}"
  -var="billing_api_allowed_origins=${ALLOWED_ORIGINS_JSON}"
  -var="billing_api_service_name=${BILLING_SERVICE_NAME}"
  -var="billing_api_service_account_name=${BILLING_SERVICE_ACCOUNT_NAME}"
  -var="billing_reconciler_service_account_name=${BILLING_RECONCILER_SERVICE_ACCOUNT_NAME}"
)

# Collection names remain Terraform-configured (terraform.tfvars first, then
# variables.tf defaults). Only an explicit environment override is forwarded.
if [ -n "${FIRESTORE_CUSTOMER_WALLETS_COLLECTION:-}" ]; then
  TF_VARS+=(-var="firestore_customer_wallets_collection=${FIRESTORE_CUSTOMER_WALLETS_COLLECTION}")
fi
if [ -n "${FIRESTORE_WALLET_TRANSACTIONS_COLLECTION:-}" ]; then
  TF_VARS+=(-var="firestore_wallet_transactions_collection=${FIRESTORE_WALLET_TRANSACTIONS_COLLECTION}")
fi
if [ -n "${FIRESTORE_CUSTOMER_BILLING_ACCOUNTS_COLLECTION:-}" ]; then
  TF_VARS+=(-var="firestore_customer_billing_accounts_collection=${FIRESTORE_CUSTOMER_BILLING_ACCOUNTS_COLLECTION}")
fi
if [ -n "${FIRESTORE_CUSTOMER_BILLING_PERIODS_COLLECTION:-}" ]; then
  TF_VARS+=(-var="firestore_customer_billing_periods_collection=${FIRESTORE_CUSTOMER_BILLING_PERIODS_COLLECTION}")
fi
if [ -n "${FIRESTORE_STRIPE_WEBHOOK_EVENTS_COLLECTION:-}" ]; then
  TF_VARS+=(-var="firestore_stripe_webhook_events_collection=${FIRESTORE_STRIPE_WEBHOOK_EVENTS_COLLECTION}")
fi
if [ -n "${FIRESTORE_SUBSCRIPTION_CANCELLATION_REQUESTS_COLLECTION:-}" ]; then
  TF_VARS+=(-var="firestore_subscription_cancellation_requests_collection=${FIRESTORE_SUBSCRIPTION_CANCELLATION_REQUESTS_COLLECTION}")
fi

if [ -n "${STRIPE_SECRET_KEY_SECRET_ID:-}" ]; then
  TF_VARS+=(-var="billing_api_stripe_secret_key_secret_id=${STRIPE_SECRET_KEY_SECRET_ID}")
fi
if [ -n "${STRIPE_SECRET_KEY_SECRET_VERSION:-}" ]; then
  TF_VARS+=(-var="billing_api_stripe_secret_key_secret_version=${STRIPE_SECRET_KEY_SECRET_VERSION}")
fi

# Optional Checkout Return URLs
if [ -n "${CHECKOUT_SUCCESS_URL:-}" ]; then
  TF_VARS+=(-var="billing_api_checkout_success_url=${CHECKOUT_SUCCESS_URL}")
fi
if [ -n "${CHECKOUT_CANCEL_URL:-}" ]; then
  TF_VARS+=(-var="billing_api_checkout_cancel_url=${CHECKOUT_CANCEL_URL}")
fi

# Optional Stripe Webhook Secret ID & Version
if [ -n "${STRIPE_WEBHOOK_SIGNING_SECRET_ID:-}" ]; then
  TF_VARS+=(-var="billing_api_stripe_webhook_signing_secret_id=${STRIPE_WEBHOOK_SIGNING_SECRET_ID}")
fi
if [ -n "${STRIPE_WEBHOOK_SIGNING_SECRET_VERSION:-}" ]; then
  TF_VARS+=(-var="billing_api_stripe_webhook_signing_secret_version=${STRIPE_WEBHOOK_SIGNING_SECRET_VERSION}")
fi

echo "--> Generating Terraform plan..."
set +e
terraform plan "${TF_VARS[@]}" -detailed-exitcode -out="${PLAN_FILE}"
PLAN_EXIT=$?
set -e

if [ "${PLAN_EXIT}" -eq 0 ]; then
  echo "No infrastructure changes detected. Billing API is up to date."
  terraform output
  exit 0
elif [ "${PLAN_EXIT}" -ne 2 ]; then
  echo "ERROR: Terraform plan failed with exit code ${PLAN_EXIT}." >&2
  exit "${PLAN_EXIT}"
fi

# Check for destructive changes
DESTRUCTIVE_ADDRESSES="$(terraform show -json "${PLAN_FILE}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for rc in data.get("resource_changes", []):
    if "delete" in rc.get("change", {}).get("actions", []):
        print(rc["address"])
' 2>/dev/null || true)"

if [ -n "${DESTRUCTIVE_ADDRESSES}" ] && [ "${ALLOW_TERRAFORM_DELETES:-false}" != "true" ]; then
  echo "ERROR: Terraform plans to delete the following resources:" >&2
  echo "${DESTRUCTIVE_ADDRESSES}" >&2
  echo "Set ALLOW_TERRAFORM_DELETES=true only if intentional." >&2
  exit 1
fi

if [ "${TERRAFORM_AUTO_APPROVE:-false}" = "true" ]; then
  terraform apply -auto-approve "${PLAN_FILE}"
elif [ -t 0 ]; then
  read -r -p "Apply the reviewed Terraform plan above? Type 'yes' to continue: " APPLY_CONFIRMATION
  if [ "${APPLY_CONFIRMATION}" != "yes" ]; then
    echo "Deployment cancelled."
    exit 1
  fi
  terraform apply "${PLAN_FILE}"
else
  echo "ERROR: Non-interactive run requires TERRAFORM_AUTO_APPROVE=true." >&2
  exit 1
fi

echo "================================================================="
echo " SuperApp Central Billing API Deployed Successfully!"
echo "================================================================="
terraform output
