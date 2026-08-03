# Artifact Registry Docker repo holding the voting app images (vote/worker/result).
# cloudbuild.yaml builds and pushes here; GKE nodes pull from here.
resource "google_artifact_registry_repository" "webapps" {
  location      = var.region
  repository_id = "webapps"
  format        = "DOCKER"
  description   = "Container images for the voting app (vote, worker, result)."
}

# GKE nodes run as the default compute service account; grant it pull access.
data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_iam_member" "nodes_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

# --- Cloud Build service account permissions --------------------------------
# The default Cloud Build SA (PROJECT_NUMBER@cloudbuild.gserviceaccount.com)
# needs to push images to Artifact Registry and deploy to GKE via kubectl.
locals {
  cloudbuild_sa = "serviceAccount:${data.google_project.this.number}@cloudbuild.gserviceaccount.com"
}

resource "google_project_iam_member" "cloudbuild_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = local.cloudbuild_sa
}

resource "google_project_iam_member" "cloudbuild_container_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = local.cloudbuild_sa
}

resource "google_project_iam_member" "cloudbuild_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = local.cloudbuild_sa
}

# Read the source archive that `gcloud builds submit` uploads to the
# *_cloudbuild staging bucket (fixes "storage.objects.get access" denied).
resource "google_project_iam_member" "cloudbuild_storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = local.cloudbuild_sa
}

# Newer Cloud Build can run builds as the default compute SA instead of the
# legacy Cloud Build SA; grant it the same source-read + push/deploy access so
# either runner works.
resource "google_project_iam_member" "compute_sa_storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "compute_sa_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "compute_sa_logs_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}
