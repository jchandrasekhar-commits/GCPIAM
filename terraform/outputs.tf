output "gke_primary_name" {
  value = google_container_cluster.primary.name
}

output "bq_dataset" {
  value = google_bigquery_dataset.logs.dataset_id
}

output "cicd_service_account_email" {
  value = google_service_account.cicd.email
}
