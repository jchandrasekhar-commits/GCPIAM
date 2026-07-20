output "gke_primary_name" {
  value = google_container_cluster.primary.name
}

output "gke_secondary_name" {
  value       = var.enable_secondary ? google_container_cluster.secondary[0].name : null
  description = "Secondary cluster name (null when enable_secondary = false)."
}

output "bq_dataset" {
  value = google_bigquery_dataset.logs.dataset_id
}

output "cicd_service_account_email" {
  value = google_service_account.cicd.email
}

output "app_secret_name" {
  value       = google_secret_manager_secret.app_secret.secret_id
  description = "Secret Manager secret consumed by the app via Workload Identity."
}
