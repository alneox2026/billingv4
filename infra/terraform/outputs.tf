output "billing_api_uri" {
  description = "Public URL for Central Billing API (for FlutterFlow top-up calls and Stripe webhooks)."
  value       = google_cloud_run_v2_service.billing_api.uri
}

output "billing_api_service_account_email" {
  description = "Service account email running Central Billing API."
  value       = google_service_account.billing_api.email
}

output "billing_reconciler_service_account_email" {
  description = "Service account email running scheduled cancellation reconciliation."
  value       = google_service_account.billing_reconciler.email
}

output "stripe_webhook_url" {
  description = "Endpoint to configure in Stripe Dashboard Webhooks."
  value       = "${google_cloud_run_v2_service.billing_api.uri}/v1/billing/stripe/webhook"
}
