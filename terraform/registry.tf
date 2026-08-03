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
