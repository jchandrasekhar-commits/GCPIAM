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
# Toggle the symmetric second GKE cluster on/off. Off by default to stay within
# the free tier (a second zonal/Autopilot cluster incurs the GKE management fee).
variable "enable_secondary" {
  type        = bool
  default     = false
  description = "Set true to provision the symmetric secondary GKE cluster in var.secondary_region."
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
