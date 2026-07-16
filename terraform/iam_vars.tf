variable "dev_principal" {
  type    = string
  default = "group:devs@example.com" # Change to your actual Dev group, or use user:jchandrasekhar@gmail.com for direct access
}

variable "ops_principal" {
  type    = string
  default = "group:ops@example.com"
}

variable "sre_principal" {
  type    = string
  default = "group:sre@example.com"
}

variable "cicd_service_account_id" {
  type    = string
  default = "cicd-sa"
}

variable "k8s_namespace" {
  type    = string
  default = "default"
}
