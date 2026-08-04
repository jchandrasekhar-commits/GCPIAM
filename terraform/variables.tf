variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "bq_dataset" {
  type    = string
  default = "logs_dataset_us"
}

variable "app_secret_value" {
  type        = string
  default     = "replace-me-with-a-real-secret"
  sensitive   = true
  description = "Initial value stored in the Secret Manager secret webapp-api-token. Override with -var or a tfvars file; do not commit real secrets."
}

# --- Secondary (DR) cluster -------------------------------------------------
# Toggle the symmetric second GKE cluster on/off. On by default because the
# assignment requires TWO GKE clusters (primary + secondary DR region). Set to
# false to run a single cluster and avoid the second cluster's GKE management fee.
variable "enable_secondary" {
  type        = bool
  default     = true
  description = "Provision the symmetric secondary GKE cluster in var.secondary_region. On by default to satisfy the two-cluster requirement; set false for a single-cluster (cheaper) deploy."
}

variable "secondary_region" {
  type        = string
  default     = "us-east1"
  description = "Region for the secondary (DR) cluster."
}

variable "secondary_node_locations" {
  type        = list(string)
  default     = ["us-east1-b", "us-east1-c"]
  description = "Zones for the secondary cluster node pool (must be within secondary_region)."
}

variable "secondary_subnet_cidr" {
  type        = string
  default     = "10.20.0.0/20"
  description = "Non-overlapping CIDR for the secondary subnet."
}

# --- Multi-Cluster Ingress / Services (global traffic + cross-cluster) -------
# Registers both clusters into a GKE Fleet and enables Multi-Cluster Ingress
# (one global anycast L7 LB fanning out to healthy pods in BOTH clusters with
# automatic regional failover) and Multi-Cluster Services (cross-cluster
# east-west service discovery). Requires enable_secondary = true. Off by default
# because it enables project-wide Fleet features and a second cluster's cost.
variable "enable_multicluster_ingress" {
  type        = bool
  default     = false
  description = "Register both GKE clusters into a Fleet and enable Multi-Cluster Ingress + Multi-Cluster Services. Requires enable_secondary = true."
}

# --- Private cluster hardening ----------------------------------------------
variable "enable_private_nodes" {
  type        = bool
  default     = true
  description = "Give nodes private IPs only (egress via Cloud NAT). Control-plane endpoint stays public but restricted by master_authorized_cidrs."
}

variable "master_authorized_cidrs" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default     = [{ cidr_block = "0.0.0.0/0", display_name = "all (demo - tighten for prod)" }]
  description = "CIDRs allowed to reach the GKE control-plane API. Default is open for the demo; restrict to your admin IP in production."
}

# --- Load balancer / DNS / security ----------------------------------------
variable "enable_binary_authorization" {
  type        = bool
  default     = false
  description = "Enforce Binary Authorization (only attested images run). Off by default so the demo images still deploy without attestation."
}

variable "enable_cloud_dns" {
  type        = bool
  default     = false
  description = "Create a Cloud DNS managed zone for the app domain. Off by default (requires an owned domain)."
}

variable "dns_domain" {
  type        = string
  default     = "example.com."
  description = "Fully qualified DNS domain (trailing dot) for the managed zone, e.g. yourapp.com."
}

variable "app_hostname" {
  type        = string
  default     = "app.example.com"
  description = "Hostname served by the global HTTPS load balancer / managed certificate."
}

variable "uptime_alert_email" {
  type        = string
  default     = ""
  description = "Email address for the uptime-check alert notification channel. Leave empty to skip creating the channel."
}

# --- Web App B stateful backing services (Cloud SQL HA + Memorystore) -------
variable "enable_stateful_services" {
  type        = bool
  default     = false
  description = "Provision Web App B's backing services: a regional (HA) Cloud SQL instance with automated backups/PITR and a Memorystore (Redis) HA cache. Off by default to stay within the free tier."
}

variable "db_password" {
  type        = string
  default     = "replace-me-with-a-real-password"
  sensitive   = true
  description = "Password for the Cloud SQL application user. Override with -var or a tfvars file; do not commit real secrets."
}
