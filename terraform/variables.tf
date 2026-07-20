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
