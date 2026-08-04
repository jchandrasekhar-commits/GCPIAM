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

output "webapp_b_sql_private_ip" {
  value       = var.enable_stateful_services ? google_sql_database_instance.webapp_b[0].private_ip_address : null
  description = "Private IP of Web App B's HA Cloud SQL instance (null when enable_stateful_services = false)."
}

output "webapp_b_redis_host" {
  value       = var.enable_stateful_services ? google_redis_instance.cache[0].host : null
  description = "Host of Web App B's Memorystore (Redis) HA cache (null when disabled)."
}

output "webapp_b_pubsub_topic" {
  value       = var.enable_stateful_services ? google_pubsub_topic.webapp_b[0].name : null
  description = "Pub/Sub topic available to Web App B (null when disabled)."
}

output "mci_config_membership" {
  value       = var.enable_multicluster_ingress ? google_gke_hub_membership.primary[0].membership_id : null
  description = "Fleet membership used as the Multi-Cluster Ingress config cluster (null when MCI disabled)."
}

output "mci_enabled" {
  value       = var.enable_multicluster_ingress
  description = "Whether Multi-Cluster Ingress + Multi-Cluster Services are enabled."
}
