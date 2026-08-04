terraform {
  # GCS remote backend — state is stored in a versioned GCS bucket so it is
  # shared across the team, locked during apply, and never lost. The bucket
  # name is supplied via -backend-config at init time (partial configuration)
  # so this file stays project-agnostic and can be committed safely.
  #
  # One-time bucket bootstrap (run once per project):
  #   gsutil mb -l us-central1 gs://<PROJECT_ID>-tfstate
  #   gsutil versioning set on gs://<PROJECT_ID>-tfstate
  #   gsutil uniformbucketlevelaccess set on gs://<PROJECT_ID>-tfstate
  #
  # Initialise Terraform:
  #   terraform init \
  #     -backend-config="bucket=<PROJECT_ID>-tfstate" \
  #     -backend-config="prefix=gcpiam/state"
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      # >= 5.34 required for google_container_cluster.secret_manager_config
      # (GKE managed Secret Manager add-on / Secrets Store CSI driver).
      version = "~> 5.34"
    }
  }
  required_version = ">= 1.4.0"
}
