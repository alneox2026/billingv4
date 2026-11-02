locals {
  billing_reconciliation_audience = var.billing_api_reconciliation_audience != "" ? var.billing_api_reconciliation_audience : "https://${var.billing_api_service_name}-${var.project_id}.internal"

  billing_api_env = {
    GOOGLE_CLOUD_PROJECT                                     = var.project_id
    GOOGLE_CLOUD_REGION                                      = var.region
    BILLING_API_LOG_LEVEL                                    = var.billing_api_log_level
    BILLING_ALLOWED_ORIGINS                                  = join(",", var.billing_api_allowed_origins)
    BILLING_CATALOG_PATH                                     = var.billing_api_catalog_path
    BILLING_CHECKOUT_SUCCESS_URL                             = var.billing_api_checkout_success_url
    BILLING_CHECKOUT_CANCEL_URL                              = var.billing_api_checkout_cancel_url
    BILLING_CHECKOUT_SESSION_TTL_SECONDS                     = tostring(var.billing_api_checkout_session_ttl_seconds)
    STRIPE_WEBHOOK_TOLERANCE_SECONDS                         = tostring(var.billing_api_stripe_webhook_tolerance_seconds)
    FIRESTORE_CUSTOMER_WALLETS_COLLECTION                   = var.firestore_customer_wallets_collection
    FIRESTORE_WALLET_TRANSACTIONS_COLLECTION                = var.firestore_wallet_transactions_collection
    FIRESTORE_CUSTOMER_BILLING_PERIODS_COLLECTION           = var.firestore_customer_billing_periods_collection
    FIRESTORE_CUSTOMER_BILLING_ACCOUNTS_COLLECTION          = var.firestore_customer_billing_accounts_collection
    FIRESTORE_STRIPE_WEBHOOK_EVENTS_COLLECTION              = var.firestore_stripe_webhook_events_collection
    FIRESTORE_SUBSCRIPTION_CANCELLATION_REQUESTS_COLLECTION = var.firestore_subscription_cancellation_requests_collection
    BILLING_RECONCILIATION_REQUIRE_AUTH                     = tostring(var.billing_api_require_reconciliation_auth)
    BILLING_RECONCILIATION_ALLOWED_SERVICE_ACCOUNT          = var.billing_api_reconciliation_allowed_service_account != "" ? var.billing_api_reconciliation_allowed_service_account : google_service_account.billing_reconciler.email
    BILLING_RECONCILIATION_AUDIENCE                         = local.billing_reconciliation_audience
    BILLING_CANCELLATION_RECONCILIATION_BATCH_SIZE          = tostring(var.billing_cancellation_reconciliation_batch_size)
  }

  # Pin a numbered secret version. Do not use latest for environment-variable
  # secrets because an existing Cloud Run instance resolves them at startup.
  billing_api_secret_env = merge(
    {
      STRIPE_SECRET_KEY = {
        secret  = var.billing_api_stripe_secret_key_secret_id
        version = var.billing_api_stripe_secret_key_secret_version
      }
    },
    var.billing_api_stripe_webhook_signing_secret_id == "" ? {} : {
      STRIPE_WEBHOOK_SIGNING_SECRET = {
        secret  = var.billing_api_stripe_webhook_signing_secret_id
        version = var.billing_api_stripe_webhook_signing_secret_version
      }
    },
  )
}
