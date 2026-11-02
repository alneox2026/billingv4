# SuperApp Central Billing API Service

> **V4 rollout status:** This template now applies debt-aware wallet credits. The middleware templates still need their v4 updates to record known usage shortfalls in `usage_debt_nanos`; until those are deployed, end-to-end usage-debt recovery is not active. Existing `_v3` Firestore collection names remain unchanged for shared-data compatibility.

Production-ready standalone **Billing & Stripe Integration Service** for the SuperApp ecosystem.

This service acts as the **single source of truth for payments, customer wallets, and Stripe subscriptions** across all 100+ agents and multiple Agent Middleware clusters.

---

## 🏛️ Architecture Overview

```
                        [ FlutterFlow Mobile / Web SuperApp ]
                                     │         │
             ┌───────────────────────┘         └─────────────────────────┐
             ▼ (Top-ups & Subscriptions)                                 ▼ (Chat & Streaming)
   ┌───────────────────────────┐                         ┌──────────────────────────────────┐
   │    CENTRAL BILLING API    │                         │     AGENT CLUSTER MIDDLEWARES    │
   │  (This Standalone Svc)    │                         │  - Gateway Cloud Run             │
   │  - Stripe Checkout        │                         │  - Persistence Worker Cloud Run  │
   │  - 1 Stripe Webhook       │                         └─────────────────┬────────────────┘
   │  - 1 Reconciler Scheduler │                                           │
   └─────────────┬─────────────┘                                           ▼
                 │                                       ┌──────────────────────────────────┐
                 │                                       │   OTHER AGENT CLUSTER (1..N)     │
                 │                                       │  - Gateway Cloud Run             │
                 │                                       │  - Persistence Worker Cloud Run  │
                 │                                       └─────────────────┬────────────────┘
                 ▼                                                         │
   ════════════════════════════════════════════════════════════════════════▼═════════════════
                                   SHARED FIRESTORE DATABASE
     • customer_wallets_v3          (GLOBAL: 1 wallet per user across all agents)
     • customer_billing_accounts_v3 (GLOBAL: 1 Stripe customer per user)
     • stripe_webhook_events_v3     (GLOBAL: Webhook idempotency)
     • subscription_cancellation... (GLOBAL: Pending cancellations)
   ══════════════════════════════════════════════════════════════════════════════════════════
```

### Key Architectural Benefits:
1. **Single Stripe Webhook:** Exactly one webhook URL registered in the Stripe Dashboard. Zero webhook limits or multi-service collision issues.
2. **Strict Security Isolation:** Only this service's service account (`superapp-billing-sa`) has IAM permissions to access Stripe secret keys. Agent clusters have zero access to Stripe credentials.
3. **Decoupled Agent Clusters:** In the v4 middleware flow, gateways perform a fast minimum-balance check and workers batch-settle priced usage, recording any known overage as usage debt. They do not make synchronous HTTP calls to the Billing API during chat; verified wallet credits repay that debt before adding spendable funds.

---

## 🚀 API Endpoints

### 1. FlutterFlow App Facing (Authenticated via Firebase Auth)
* `POST /v1/billing/topups/checkout-session`: Generates a Stripe Checkout URL for prepaid credit top-up packages (e.g. $5, $10, $25) or starts the monthly platform fee subscription.
* `GET /ready` & `GET /health`: Health checks.

### 2. Stripe Facing (Authenticated via Stripe Signature)
* `POST /v1/billing/stripe/webhook`: Receives and processes the canonical 9 Stripe events:
  - `checkout.session.completed`: Credits user wallet in Firestore upon immediate payment.
  - `checkout.session.async_payment_succeeded`: Credits user wallet when delayed payment methods (e.g. ACH, SEPA) settle.
  - `invoice.paid`: Settles recurring monthly platform service fee and advances customer billing period.
  - `invoice.payment_failed`: Records subscription payment failure for grace-period handling.
  - `customer.subscription.updated`: Syncs active/past_due subscription status changes.
  - `customer.subscription.deleted`: Revokes subscription benefits upon cancellation or non-payment.
  - `refund.created`: Debits wallet for refunded token packages.
  - `charge.dispute.created`: Records dispute holds and audit trail.
  - `charge.dispute.closed`: Settles dispute outcome (won/lost).

> [!NOTE]
> **Event Dispatch & Pre-Dispatch Validation**:
> - **Canonical 9 Events**: The service explicitly handles the 9 events listed above. `customer.subscription.created` is **not** one of the configured events, and the service does not treat it as a subscription-state event. If a valid, matching-environment event of that type is delivered anyway, it reaches the `_record_ignored_event` fallback path and is recorded idempotently in the configured Stripe webhook idempotency collection (default: `stripe_webhook_events_v3`) with outcome `"ignored"` (returning `200 OK` to Stripe without mutating subscription state).
> - **Pre-Dispatch Rejection vs. Ignored Events**: Events only reach the ignored-event path if they pass pre-dispatch validation:
>   1. The endpoint strictly validates the `Stripe-Signature` header (`BillingApiError(400, "stripe_signature_invalid")`).
>   2. The endpoint verifies that the event's `livemode` matches the configured catalog environment (`BillingApiError(400, "stripe_environment_mismatch")`).
>   Invalid signatures and mode mismatches are actively rejected with HTTP 400, **not** ignored. Furthermore, unexpected Firestore transaction failures or processing exceptions will fail with 5xx to trigger Stripe delivery retries.
> - **Subscription-state account mismatches**: `customer.subscription.updated` and `customer.subscription.deleted` are non-financial state-sync events. If the signed, matching-environment event refers to a missing/invalid billing account or a different Stripe customer, do not return 4xx and do not mutate the account. Persist an idempotent receipt with outcome `ignored` and an `ignored_reason`, emit a warning with the stable reason code, and return 200. These terminal linkage problems cannot be repaired by redelivering the same event. Keep financial events (Checkout fulfillment, invoice settlement, refunds, and disputes) fail-closed; do not apply this acknowledgement policy to them.

### 3. Internal Automation (Authenticated via Cloud Run OIDC)
* `POST /v1/billing/internal/cancellation/reconcile`: Cloud Scheduler endpoint that reconciles pending Stripe subscription cancellations every hour.

### V4 wallet-credit accounting
Every verified Stripe top-up is applied by the shared Firestore wallet-credit operation inside the same transaction as its idempotency record. It allocates the paid package amount in this order:

1. `gross_credit_nanos`: the full credit purchased, retained in the legacy `amount_nanos` field as well.
2. `usage_debt_repaid_nanos`: the portion applied to known, priced usage debt (`usage_debt_nanos` on the wallet).
3. `net_credit_nanos`: the remainder added to `available_credit_nanos` after usage-debt repayment.

The wallet also tracks `lifetime_usage_debt_repaid_nanos`. Existing wallets without `usage_debt_nanos` are treated as having zero usage debt and receive the additive fields on their next credit; no collection rename or backfill is required. The operation uses the wallet transaction document ID as an idempotency key, so Stripe retries and the paired Checkout completion/async-success events cannot credit the same session twice. New server-side credit sources (for example, an approved promotional credit) must call `apply_wallet_credit_in_transaction` from their Firestore transaction with a stable transaction ID; do not implement another direct `available_credit_nanos += amount` path or expose a client-writable credit route.

Refund and chargeback accounting remains separate: the refund/dispute handlers are not usage-debt credits and do not change `usage_debt_nanos`. The monthly subscription invoice is a service-fee payment, not wallet credit. This billing-template change establishes the debt-aware credit contract; middleware templates must also be updated to use the v4 minimum-balance gate and batch settlement that writes `usage_debt_nanos` before this behavior can recover known usage shortfalls. During a staged rollout, do not assume old reservation-based middleware has this debt-recovery behavior.

---

## 🔐 Secret Management (Secret Manager)

The billing service relies on two secrets in Google Secret Manager. Because registering a Stripe webhook endpoint requires the deployed Cloud Run URL, deployment follows a **two-phase bootstrap sequence**:

1. **Phase 1 (Pre-Deployment)**: `stripe-secret-key` is **mandatory** before initial deployment.
2. **Phase 2 (Post-Deployment)**: `stripe-webhook-signing-secret` is created **after** the initial deploy once the Cloud Run service URL is known and registered in Stripe.

To prevent secrets from being recorded in your terminal shell history, use `read -s` instead of inline `echo`:

### Phase 1: Stripe Secret Key (Required Before Initial Deploy)

#### Option A: Create New Secret (Initial Setup, Version 1)
If the secret does not exist yet in your GCP project:
```bash
read -s -p "Enter Stripe Secret Key: " STRIPE_KEY
echo -n "$STRIPE_KEY" | gcloud secrets create stripe-secret-key --data-file=-
unset STRIPE_KEY
```

#### Option B: Rotate Existing Secret (Adding a New Version)
If `stripe-secret-key` already exists in your GCP project, add a new version:
```bash
read -s -p "Enter New Secret Key: " STRIPE_KEY
echo -n "$STRIPE_KEY" | gcloud secrets versions add stripe-secret-key --data-file=-
unset STRIPE_KEY
```
Note the version number printed in the output (e.g. `Created version [3]`). Export that specific secret's version before deploying:
```bash
export STRIPE_SECRET_KEY_SECRET_VERSION="3"
```

---

### Phase 2: Stripe Webhook Signing Secret (Created After Initial Deploy)
Once Cloud Run is initially deployed and you have registered `https://<billing_api_url>/v1/billing/stripe/webhook` in the Stripe Dashboard, Stripe generates a signing secret (`whsec_...`).

#### Option A: Create New Secret (Initial Setup, Version 1)
```bash
read -s -p "Enter Stripe Webhook Signing Secret: " STRIPE_WHSEC
echo -n "$STRIPE_WHSEC" | gcloud secrets create stripe-webhook-signing-secret --data-file=-
unset STRIPE_WHSEC
```

#### Option B: Rotate Existing Secret (Adding a New Version)
If `stripe-webhook-signing-secret` already exists in your GCP project, add a new version:
```bash
read -s -p "Enter New Webhook Signing Secret: " STRIPE_WHSEC
echo -n "$STRIPE_WHSEC" | gcloud secrets versions add stripe-webhook-signing-secret --data-file=-
unset STRIPE_WHSEC
```
Note the version number printed in the output (e.g. `Created version [2]`). Export that specific secret's version before deploying:
```bash
export STRIPE_WEBHOOK_SIGNING_SECRET_VERSION="2"
```

> [!IMPORTANT]
> **Terraform Secret Version Pinning**:
> By default, Terraform pins Cloud Run secret mounts to version `"1"`.
> - If you created fresh secrets via Option A, both are version `"1"`, so no version overrides are needed.
> - If you rotated an existing secret via Option B, **do not assume both secrets share the same version number**—their versions can differ depending on rotation history. Set each override to the **actual version number** for that specific secret (for example, API key `3`, webhook secret `2`):
>   ```bash
>   export STRIPE_SECRET_KEY_SECRET_VERSION="3"
>   export STRIPE_WEBHOOK_SIGNING_SECRET_VERSION="2"
>   ```

---

## 🛠️ Deployment via Google Cloud Shell

### Clone-specific deployment defaults

The Cloud Shell scripts derive a stack identity from `BILLING_STACK_NAME` (when set), otherwise from the Git repository name. This prevents a fresh repository such as `billing1` from silently reusing another billing deployment's Terraform state, image tag, or service name. Firestore collection names are configured separately and default to the shared canonical `_v3` collections.

For a repository named `billing1`, the defaults are:

| Item | Default |
| --- | --- |
| Cloud Run service | `billing1-api` |
| Artifact Registry image | `billing1-billing-api:latest` |
| API service account | `billing1-sa` |
| Reconciler service account | `billing1-recon-sa` |
| Terraform state prefix | `superapp-billing/stacks/billing1/<environment>/terraform/state` |
| Firestore collections | Read from `terraform.tfvars` or `variables.tf` (canonical `_v3` defaults) |

The build and deploy scripts resolve the same identity. Set `BILLING_STACK_NAME` explicitly if you want a different identity than the Git repository name; keep it the same for build and deploy. A long identity is kept in the state path, while resource names use a stable shortened form to satisfy service-account ID limits. `BILLING_SERVICE_NAME`, `BILLING_SERVICE_ACCOUNT_NAME`, `BILLING_RECONCILER_SERVICE_ACCOUNT_NAME`, `IMAGE_NAME`, and `TF_STATE_PREFIX` can also be explicitly overridden.

The deployment scripts do not derive or replace Firestore collection names from the clone name. Terraform configuration is authoritative: `terraform.tfvars` values take precedence over `variables.tf` defaults, and explicit `FIRESTORE_*_COLLECTION` environment variables take precedence over both. The template defaults to the canonical `_v3` collections used by the middleware templates, so a new billing clone shares those records unless you deliberately configure different names. For your `service43` setup, set the same collection names in this billing service and both middleware clusters' `variables.tf` or `terraform.tfvars`. If you use the shipped `firestore.rules`, keep the `customer_wallets_`, `wallet_transactions_`, `customer_billing_periods_`, and `customer_billing_accounts_` name prefixes so the owner-read rules continue to match. The subscription-cancellation composite index is managed by Terraform against the configured collection; do not deploy a separate Firebase index manifest.

For an isolated test deployment, set unique collection names in `terraform.tfvars` or export the appropriate `FIRESTORE_*_COLLECTION` variables. The deploy banner prints the resolved stack, service, image, and state; review Terraform's plan for the final collection values before applying.

> [!WARNING]
> Existing deployments created with the old shared state prefix are not automatically migrated. Do not apply a new clone-specific state to manage an existing service. For an existing deployment, explicitly restore its original `TF_STATE_PREFIX` and resource overrides, set `ALLOW_SHARED_BILLING_TERRAFORM_STATE=true` only when you intentionally mean to use the legacy state, and review the complete Terraform plan before applying. A fresh clone should normally keep the new isolated defaults.

### Service-account IDs

Google Cloud service-account IDs must be 6-30 characters and use lowercase letters, digits, and hyphens. The Terraform variables validate both IDs before creating IAM resources. The script derives a compact reconciler name for each stack. For Cloud Shell, override it with `BILLING_RECONCILER_SERVICE_ACCOUNT_NAME`; the script's resolved values take precedence over `terraform.tfvars`. If running Terraform directly, set the Terraform variable in `terraform.tfvars` yourself.

### Step 1: Build the Container Image
```bash
export PROJECT_ID="ceo-dev123"
export REGION="us-central1"
# Optional; otherwise derived from the Git repository name (e.g. billing1).
# export BILLING_STACK_NAME="billing1"
./scripts/cloudshell_build_billing.sh
```

### Step 2: Initial Deploy (Bootstrap Without Webhook Secret)
The initial deployment provisions the Cloud Run service, IAM roles, and Firestore collections without requiring a webhook signing secret:
```bash
export PROJECT_ID="ceo-dev123"
export REGION="us-central1"
# Ensure STRIPE_WEBHOOK_SIGNING_SECRET_ID is empty/unset for initial deploy
unset STRIPE_WEBHOOK_SIGNING_SECRET_ID
./scripts/cloudshell_deploy_billing.sh
```
At the end of deployment, Terraform prints `billing_api_url` for the newly named service (for example, the `billing1-api` service for a `billing1` stack). Use that output URL for the Stripe webhook destination; do not reuse a URL from another deployment.

### Step 3: Register Webhook in Stripe & Redeploy
1. In your **Stripe Dashboard > Developers > Webhooks**, create an endpoint pointing to `https://<billing_api_url>/v1/billing/stripe/webhook` and subscribe to the canonical 9 events.
2. Stripe will provide a signing secret (`whsec_...`). Store it in Secret Manager as shown in [Phase 2 above](#phase-2-stripe-webhook-signing-secret-created-after-initial-deploy).
3. Redeploy with the webhook secret ID attached (along with each secret's actual version if rotated):
```bash
export STRIPE_WEBHOOK_SIGNING_SECRET_ID="stripe-webhook-signing-secret"
# If secrets were rotated, export each secret's actual version:
# export STRIPE_SECRET_KEY_SECRET_VERSION="3"
# export STRIPE_WEBHOOK_SIGNING_SECRET_VERSION="2"
./scripts/cloudshell_deploy_billing.sh
```

---

## 🚀 Production Go-Live Checklist

Follow this checklist before approving and executing a live production rollout:

1. **GCP Project Isolation**:
   * Set your active production Google Cloud Project:
     ```bash
     gcloud config set project <PRODUCTION_PROJECT_ID>
     export PROJECT_ID="<PRODUCTION_PROJECT_ID>"
     ```
   * Confirm that the deploy script banner prints `<PRODUCTION_PROJECT_ID>` and not `ceo-dev123`. Do not use `ALLOW_DEV_PROJECT_IN_PROD=true`.
   * Confirm the six Firestore collection values in Terraform configuration match the intended production data model and the middleware wallet, transaction, and billing-period collection names exactly.

2. **Browser Origins (CORS)**:
   * Export your exact production domain(s) as a plain string without markdown formatting:
     ```bash
     export ALLOWED_ORIGINS="https://app.yourdomain.com"
     # Multiple origins: export ALLOWED_ORIGINS="https://app.yourdomain.com,https://admin.yourdomain.com"
     ```

3. **Stripe Checkout Return URLs**:
   * Set your real client application redirect URLs so users return to your web/mobile app rather than `example.com` after completing or cancelling Stripe Checkout:
     ```bash
     export CHECKOUT_SUCCESS_URL="https://app.yourdomain.com/billing-complete?session_id={CHECKOUT_SESSION_ID}"
     export CHECKOUT_CANCEL_URL="https://app.yourdomain.com/billing/cancel"
     ```

4. **Live Stripe Catalog & Credentials**:
   * In your **Stripe Live Dashboard**, create the corresponding top-up packages ($5, $10, $25) and monthly recurring subscription fee.
   * Update `config/billing.prod.yaml`:
     - Change `stripe_mode: test` to `stripe_mode: live`.
     - Replace each `price_...` placeholder with the real live Stripe Price IDs.
   * Securely store your live Stripe restricted key (`rk_live_...`) in Secret Manager without shell history leakage:
     - **If creating a new secret:**
       ```bash
       read -s -p "Enter Live Stripe Secret Key: " STRIPE_KEY
       echo -n "$STRIPE_KEY" | gcloud secrets create stripe-secret-key --data-file=-
       unset STRIPE_KEY
       ```
     - **If rotating an existing secret (adding a new version):**
       ```bash
       read -s -p "Enter Live Stripe Secret Key: " STRIPE_KEY
       echo -n "$STRIPE_KEY" | gcloud secrets versions add stripe-secret-key --data-file=-
       unset STRIPE_KEY
       ```
       Note the resulting version number printed by `gcloud` (e.g. `Created version [3]`). Export that secret's actual version override before deploying:
       ```bash
       export STRIPE_SECRET_KEY_SECRET_VERSION="3"
       ```

5. **Live Stripe Webhook Destination**:
   * **Important**: Do not route end-user traffic to the billing service until the webhook signing secret is configured. Without it, the webhook handler returns `503 stripe_webhook_not_configured`.
   * Deploy the service initially without the webhook signing secret:
     ```bash
     export DEPLOYMENT_ENV="production"
     unset STRIPE_WEBHOOK_SIGNING_SECRET_ID
     ./scripts/cloudshell_deploy_billing.sh
     ```
   * Copy the output `billing_api_url` and register a live endpoint in your **Stripe Live Dashboard > Developers > Webhooks**:
     `https://<billing_api_url>/v1/billing/stripe/webhook`
     Subscribing to these exact 9 events:
     - `charge.dispute.closed`
     - `charge.dispute.created`
     - `checkout.session.async_payment_succeeded`
     - `checkout.session.completed`
     - `customer.subscription.deleted`
     - `customer.subscription.updated`
     - `invoice.paid`
     - `invoice.payment_failed`
     - `refund.created`
   * Securely store the live webhook signing secret (`whsec_...`) in Secret Manager:
     - **If creating a new secret:**
       ```bash
       read -s -p "Enter Live Stripe Webhook Signing Secret: " STRIPE_WHSEC
       echo -n "$STRIPE_WHSEC" | gcloud secrets create stripe-webhook-signing-secret --data-file=-
       unset STRIPE_WHSEC
       ```
     - **If rotating an existing secret (adding a new version):**
       ```bash
       read -s -p "Enter Live Stripe Webhook Signing Secret: " STRIPE_WHSEC
       echo -n "$STRIPE_WHSEC" | gcloud secrets versions add stripe-webhook-signing-secret --data-file=-
       unset STRIPE_WHSEC
       ```
       Note the resulting version number printed by `gcloud` (e.g. `Created version [2]`). Export that secret's actual version override before deploying:
       ```bash
       export STRIPE_WEBHOOK_SIGNING_SECRET_VERSION="2"
       ```

   * Redeploy passing `STRIPE_WEBHOOK_SIGNING_SECRET_ID="stripe-webhook-signing-secret"` (and set each override to the actual version if rotated):
     ```bash
     export STRIPE_WEBHOOK_SIGNING_SECRET_ID="stripe-webhook-signing-secret"
     # If secrets were rotated, export each secret's actual version (numbers may differ):
     # export STRIPE_SECRET_KEY_SECRET_VERSION="3"
     # export STRIPE_WEBHOOK_SIGNING_SECRET_VERSION="2"
     ./scripts/cloudshell_deploy_billing.sh
     ```
   * **Webhook Verification & Dispatch Qualification**:
     - Signature verification and Stripe-mode validation happen before event dispatch. Invalid signatures fail with `400 stripe_signature_invalid`, and mode mismatches fail with `400 stripe_environment_mismatch` (e.g. synthetic test events sent against a `stripe_mode: live` deployment). These are actively rejected, not ignored.
     - If a valid, matching-environment event of an unconfigured type (such as `customer.subscription.created`) is delivered, it falls through to `_record_ignored_event` and is recorded idempotently in the configured Stripe webhook idempotency collection (default: `stripe_webhook_events_v3`) with outcome `"ignored"` (`200 OK` response with no billing state mutation).
     - Any Firestore transaction or processing failures will return 5xx errors so Stripe can retry.
     - Verify the live endpoint status directly in the Stripe Live Dashboard, or test synthetic flows against your staging deployment (`stripe_mode: test`).

6. **Manual Terraform Review**:
   * Ensure `TERRAFORM_AUTO_APPROVE` is unset or `false`.
   * Manually review the output plan in Cloud Shell, verify resource names and IAM roles, then type `yes` when prompted.

---

## 🧪 Local Testing

Run all unit and integration tests:
```bash
python -m pytest -q
```
All tests use fakes and mocks; no live Stripe or GCP connection is required.
