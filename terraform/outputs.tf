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

output "lb_static_ip" {
  value       = google_compute_global_address.webapps_lb_ip.address
  description = "Reserved global anycast IP for the external HTTPS load balancer. Point your DNS A record here and use it in the Ingress annotation."
}

output "cloud_armor_policy" {
  value       = google_compute_security_policy.webapps_waf.name
  description = "Cloud Armor WAF policy name referenced by the k8s BackendConfig."
}
