# All team principal lists default to empty — no access is granted until you
# supply real identifiers. This enforces meaningful separation between teams
# and prevents accidental access. Set values in terraform.tfvars or -var flags.
# Prefer group: principals so membership is managed in your IdP, not Terraform.

variable "dev_principals" {
  type        = list(string)
  default     = []
  description = "Dev team principals (e.g. group:devs@your-domain.com). Receive container.developer, logging.viewer, monitoring.viewer."
}

variable "ops_principals" {
  type        = list(string)
  default     = []
  description = "Ops team principals (e.g. group:ops@your-domain.com). Receive container.clusterAdmin, compute.networkAdmin, logging.configWriter, monitoring.editor, BigQuery dataOwner."
}

variable "sre_principals" {
  type        = list(string)
  default     = []
  description = "SRE team principals (e.g. group:sre@your-domain.com). Receive logging.viewer, monitoring.viewer, container.clusterViewer, BigQuery dataViewer."
}

variable "cicd_user_principals" {
  type        = list(string)
  default     = []
  description = "Human CI/CD operators who need container.developer and serviceAccountUser (e.g. user:cicd-admin@your-domain.com). The CI/CD service account is wired separately via the cicd_service_account_principals local."
}

variable "cicd_service_account_id" {
  type    = string
  default = "cicd-sa"
}

variable "k8s_namespace" {
  type    = string
  default = "default"
}
