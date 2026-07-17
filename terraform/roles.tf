locals {
  dev_principals  = var.dev_principals
  ops_principals  = var.ops_principals
  sre_principals  = var.sre_principals
  cicd_principals = ["serviceAccount:${google_service_account.cicd.email}"]
}

resource "google_project_iam_binding" "dev_container_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  members = local.dev_principals
}

resource "google_project_iam_binding" "dev_logging_viewer" {
  project = var.project_id
  role    = "roles/logging.viewer"
  members = local.dev_principals
}

resource "google_project_iam_binding" "dev_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  members = local.dev_principals
}

resource "google_service_account_iam_binding" "dev_service_account_user" {
  service_account_id = google_service_account.app_service.name
  role               = "roles/iam.serviceAccountUser"
  members            = local.dev_principals
}

resource "google_project_iam_binding" "ops_cluster_admin" {
  project = var.project_id
  role    = "roles/container.clusterAdmin"
  members = local.ops_principals
}

resource "google_project_iam_binding" "ops_network_admin" {
  project = var.project_id
  role    = "roles/compute.networkAdmin"
  members = local.ops_principals
}

resource "google_bigquery_dataset_iam_member" "ops_data_owner" {
  for_each   = toset(local.ops_principals)
  dataset_id = google_bigquery_dataset.logs.dataset_id
  role       = "roles/bigquery.dataOwner"
  member     = each.value
}

resource "google_project_iam_binding" "ops_logging_config_writer" {
  project = var.project_id
  role    = "roles/logging.configWriter"
  members = local.ops_principals
}

resource "google_project_iam_binding" "ops_monitoring_editor" {
  project = var.project_id
  role    = "roles/monitoring.editor"
  members = local.ops_principals
}

resource "google_project_iam_binding" "sre_logging_viewer" {
  project = var.project_id
  role    = "roles/logging.viewer"
  members = local.sre_principals
}

resource "google_project_iam_binding" "sre_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  members = local.sre_principals
}

resource "google_project_iam_binding" "sre_cluster_viewer" {
  project = var.project_id
  role    = "roles/container.clusterViewer"
  members = local.sre_principals
}

resource "google_bigquery_dataset_iam_member" "sre_data_viewer" {
  for_each   = toset(local.sre_principals)
  dataset_id = google_bigquery_dataset.logs.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = each.value
}

resource "google_project_iam_binding" "cicd_cloudbuild_builder" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.builder"
  members = local.cicd_principals
}

resource "google_project_iam_binding" "cicd_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  members = local.cicd_principals
}

resource "google_project_iam_binding" "cicd_container_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  members = local.cicd_principals
}

resource "google_project_iam_binding" "cicd_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  members = local.cicd_principals
}

resource "google_project_iam_binding" "cicd_monitoring_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  members = local.cicd_principals
}

resource "google_service_account_iam_binding" "cicd_service_account_user" {
  service_account_id = google_service_account.app_service.name
  role               = "roles/iam.serviceAccountUser"
  members            = local.cicd_principals
}
