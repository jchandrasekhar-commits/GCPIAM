variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "bq_dataset" {
  type    = string
  default = "logs_dataset"
}
