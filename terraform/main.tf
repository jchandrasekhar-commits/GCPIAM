provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_compute_network" "vpc" {
  name = "gke-vpc"
}

resource "google_compute_subnetwork" "primary_subnet" {
  name          = "gke-primary-subnet"
  ip_cidr_range = "10.10.0.0/20"
  network       = google_compute_network.vpc.name
  region        = var.region
}

resource "google_container_cluster" "primary" {
  name                     = "gke-primary"
  location                 = var.region
  network                  = google_compute_network.vpc.name
  remove_default_node_pool = true
  initial_node_count       = 1
  node_locations           = ["us-central1-a", "us-central1-b", "us-central1-e"]
  ip_allocation_policy {}
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

resource "google_container_node_pool" "primary_pool" {
  name       = "primary-pool"
  cluster    = google_container_cluster.primary.name
  node_count = 3
  node_config {
    machine_type = "e2-small"
  }
  node_locations = ["us-central1-a", "us-central1-b", "us-central1-e"]
}

resource "google_service_account" "app_service" {
  account_id   = "webapp-sa"
  display_name = "Webapp workload identity service account"
}

resource "google_service_account" "cicd" {
  account_id   = var.cicd_service_account_id
  display_name = "CI/CD service account"
}

resource "google_bigquery_dataset" "logs" {
  dataset_id = var.bq_dataset
  location   = "US"
}

resource "google_logging_project_sink" "to_bq" {
  name                   = "export-to-bq"
  destination            = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.logs.dataset_id}"
  filter                 = "resource.type=\"k8s_container\""
  unique_writer_identity = true
}

resource "google_bigquery_dataset_iam_member" "sink_writer" {
  dataset_id = google_bigquery_dataset.logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.to_bq.writer_identity
}
