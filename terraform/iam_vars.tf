variable "dev_principals" {
  type    = list(string)
  default = ["user:jchandrasekhar@gmail.com"]
  description = "List of principals for the Dev team, such as user:alice@example.com or group:devs@your-domain.com."
}

variable "ops_principals" {
  type    = list(string)
  default = ["user:jchandrasekhar@gmail.com"]
  description = "List of principals for the Ops team, such as user:bob@example.com or group:ops@your-domain.com."
}

variable "sre_principals" {
  type    = list(string)
  default = ["user:jchandrasekhar@gmail.com"]
  description = "List of principals for the SRE team, such as user:carol@example.com or group:sre@your-domain.com."
}

variable "cicd_service_account_id" {
  type    = string
  default = "cicd-sa"
}

variable "k8s_namespace" {
  type    = string
  default = "default"
}
