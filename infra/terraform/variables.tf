variable "project_id" {
  description = "Google Cloud project ID."
  type        = string
}

variable "region" {
  description = "Google Cloud region for Cloud Run and Cloud Scheduler."
  type        = string
  default     = "us-central1"
}

variable "deployment_environment" {
  description = "Deployment stage (development, staging, or production)."
  type        = string
  default     = "development"

  validation {
    condition     = contains(["development", "staging", "production"], var.deployment_environment)
    error_message = "deployment_environment must be development, staging, or production."
  }
}

variable "cloud_run_execution_environment" {
  description = "Cloud Run execution environment for Billing API."
  type        = string
  default     = "EXECUTION_ENVIRONMENT_GEN2"
}

variable "cloud_run_request_based_billing" {
  description = "Whether Cloud Run throttles CPU when no requests are active."
  type        = bool
  default     = true
}

variable "billing_api_service_name" {
  description = "Cloud Run service name for Central Billing API."
  type        = string
  default     = "billingv4-api"
}

variable "billing_api_service_account_name" {
  description = "Billing API service-account ID (6-30 lowercase letters, digits, or hyphens)."
  type        = string
  default     = "billingv4-api-sa"

  validation {
    condition = (
      length(var.billing_api_service_account_name) >= 6 &&
      length(var.billing_api_service_account_name) <= 30 &&
      can(regex("^[a-z]([-a-z0-9]*[a-z0-9])$", var.billing_api_service_account_name))
    )
    error_message = "billing_api_service_account_name must be 6-30 characters, start with a lowercase letter, and contain only lowercase letters, digits, or hyphens (with no trailing hyphen)."
  }
}

variable "billing_reconciler_service_account_name" {
  description = "Billing Reconciler service-account ID (6-30 lowercase letters, digits, or hyphens)."
  type        = string
  default     = "billingv4-recon-sa"

  validation {
    condition = (
      length(var.billing_reconciler_service_account_name) >= 6 &&
      length(var.billing_reconciler_service_account_name) <= 30 &&
      can(regex("^[a-z]([-a-z0-9]*[a-z0-9])$", var.billing_reconciler_service_account_name))
    )
    error_message = "billing_reconciler_service_account_name must be 6-30 characters, start with a lowercase letter, and contain only lowercase letters, digits, or hyphens (with no trailing hyphen). For example, use 'billing31-recon-sa' rather than 'billing31-billing-reconciler-sa'."
  }
}

variable "billing_api_image" {
  description = "Artifact Registry container image URI for Billing API."
  type        = string
  default     = "us-central1-docker.pkg.dev/ceo-dev123/ceo-agent-repo/billing-api:latest"
}

variable "billing_api_min_instances" {
  description = "Minimum instances for Billing API."
  type        = number
  default     = 0
}

variable "billing_api_max_instances" {
  description = "Maximum instances for Billing API."
  type        = number
  default     = 10
}

variable "billing_api_concurrency" {
  description = "Maximum concurrent requests per Billing API instance."
  type        = number
  default     = 16
}

variable "billing_api_cpu" {
  description = "Billing API CPU limit."
  type        = string
  default     = "1"
}

variable "billing_api_memory" {
  description = "Billing API memory limit."
  type        = string
  default     = "1Gi"
}

variable "billing_api_timeout" {
  description = "Billing API request timeout; includes bounded cancellation reconciliation work."
  type        = string
  default     = "180s"
}

variable "billing_api_deletion_protection" {
  description = "Whether Terraform blocks deletion of the Billing API Cloud Run service."
  type        = bool
  default     = false
}

variable "billing_api_log_level" {
  description = "Log level for the Billing API service."
  type        = string
  default     = "INFO"
}

variable "billing_api_allowed_origins" {
  description = "Allowed origins for CORS in Billing API."
  type        = list(string)
  default     = ["https://ceoappdev.flutterflow.app"]
}

variable "billing_api_catalog_path" {
  description = "Path to billing catalog YAML within the container or host filesystem."
  type        = string
  default     = "/app/config/billing.prod.yaml"
}

variable "billing_api_checkout_success_url" {
  description = "Client redirect URL when Stripe Checkout completes."
  type        = string
  default     = "https://ceoappdev.flutterflow.app/billing-complete?session_id={CHECKOUT_SESSION_ID}"
}

variable "billing_api_checkout_cancel_url" {
  description = "Client redirect URL when user cancels Stripe Checkout."
  type        = string
  default     = "https://ceoappdev.flutterflow.app/billing/cancel"
}

variable "billing_api_checkout_session_ttl_seconds" {
  description = "Stripe Checkout session TTL."
  type        = number
  default     = 1800
}

variable "billing_api_stripe_webhook_tolerance_seconds" {
  description = "Stripe webhook signature timestamp tolerance."
  type        = number
  default     = 300
}

variable "billing_api_stripe_secret_key_secret_id" {
  description = "Secret Manager secret ID containing Stripe Secret Key."
  type        = string
  default     = "stripe-secret-key"
}

variable "billing_api_stripe_secret_key_secret_version" {
  description = "Pinned numeric version of Stripe Secret Key."
  type        = string
  default     = "1"
}

variable "billing_api_stripe_webhook_signing_secret_id" {
  description = "Secret Manager secret ID containing Stripe Webhook Signing Secret."
  type        = string
  default     = "stripe-webhook-signing-secret-billingv4"
}

variable "billing_api_stripe_webhook_signing_secret_version" {
  description = "Pinned numeric version of Stripe Webhook Signing Secret."
  type        = string
  default     = "1"
}

variable "billing_api_require_reconciliation_auth" {
  description = "Whether reconciliation endpoints require OIDC auth in application code."
  type        = bool
  default     = true
}

variable "billing_api_reconciliation_allowed_service_account" {
  description = "Service account email allowed to invoke internal reconciliation."
  type        = string
  default     = ""
}

variable "billing_api_reconciliation_audience" {
  description = "Custom audience for internal reconciliation OIDC token verification."
  type        = string
  default     = ""
}

variable "billing_reconciliation_enabled" {
  description = "Whether to schedule subscription cancellation reconciliation."
  type        = bool
  default     = false
}

variable "billing_reconciliation_schedule" {
  description = "Five-field UTC cron schedule for subscription cancellation reconciliation."
  type        = string
  default     = "0 * * * *"

  validation {
    condition = can(regex(
      "^[-A-Za-z0-9*/?,]+([[:space:]]+[-A-Za-z0-9*/?,]+){4}$",
      trimspace(var.billing_reconciliation_schedule)
    ))
    error_message = "billing_reconciliation_schedule must be a five-field Cloud Scheduler cron expression, for example \"0 * * * *\"."
  }
}

variable "billing_cancellation_reconciliation_batch_size" {
  description = "Maximum cancellation intents processed per reconciliation run."
  type        = number
  default     = 5

  validation {
    condition     = var.billing_cancellation_reconciliation_batch_size >= 1 && var.billing_cancellation_reconciliation_batch_size <= 5
    error_message = "billing_cancellation_reconciliation_batch_size must be between 1 and 5."
  }
}

# --- Shared Firestore Collections ---

variable "firestore_customer_wallets_collection" {
  description = "Firestore collection for user credit wallets."
  type        = string
  default     = "customer_wallets_billingv4"
}

variable "firestore_wallet_transactions_collection" {
  description = "Firestore collection for wallet top-up and audit transactions."
  type        = string
  default     = "wallet_transactions_billingv4"
}

variable "firestore_customer_billing_periods_collection" {
  description = "Firestore collection for customer monthly billing periods."
  type        = string
  default     = "customer_billing_periods_billingv4"
}

variable "firestore_customer_billing_accounts_collection" {
  description = "Firestore collection linking Firebase UIDs to Stripe customer IDs."
  type        = string
  default     = "customer_billing_accounts_billingv4"
}

variable "firestore_stripe_webhook_events_collection" {
  description = "Global Firestore collection for Stripe webhook idempotency."
  type        = string
  default     = "stripe_webhook_events_billingv4"
}

variable "firestore_subscription_cancellation_requests_collection" {
  description = "Firestore collection for subscription cancellation intents."
  type        = string
  default     = "subscription_cancellation_requests_billingv4"
}
