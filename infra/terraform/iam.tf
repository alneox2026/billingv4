resource "google_service_account" "billing_api" {
  account_id   = var.billing_api_service_account_name
  display_name = "SuperApp Central Billing API"
}

resource "google_service_account" "billing_reconciler" {
  account_id   = var.billing_reconciler_service_account_name
  display_name = "SuperApp Billing Cancellation Reconciler"
}

locals {
  billing_api_roles = toset([
    "roles/datastore.user",
    "roles/logging.logWriter",
  ])
}

resource "google_project_iam_member" "billing_api_roles" {
  for_each = local.billing_api_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.billing_api.email}"
}

# The Stripe secret is created manually in Secret Manager so its value never
# enters Terraform state. Terraform manages only this service account binding.
resource "google_secret_manager_secret_iam_member" "billing_api_stripe_secret_key_accessor" {
  project   = var.project_id
  secret_id = var.billing_api_stripe_secret_key_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.billing_api.email}"
}

resource "google_secret_manager_secret_iam_member" "billing_api_stripe_webhook_signing_secret_accessor" {
  count = var.billing_api_stripe_webhook_signing_secret_id == "" ? 0 : 1

  project   = var.project_id
  secret_id = var.billing_api_stripe_webhook_signing_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.billing_api.email}"
}
