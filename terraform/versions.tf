terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      # >= 5.34 required for google_container_cluster.secret_manager_config
      # (GKE managed Secret Manager add-on / Secrets Store CSI driver).
      version = "~> 5.34"
    }
  }
  required_version = ">= 1.4.0"
}
