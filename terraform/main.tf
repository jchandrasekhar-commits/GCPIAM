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
  subnetwork               = google_compute_subnetwork.primary_subnet.name
  remove_default_node_pool = false
  initial_node_count       = 1
  node_locations           = ["us-central1-a", "us-central1-b"]
  ip_allocation_policy {}
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

resource "google_container_node_pool" "default_pool" {
  name           = "default-pool"
  cluster        = google_container_cluster.primary.name
  location       = var.region
  node_locations = ["us-central1-a", "us-central1-b"]

  autoscaling {
    min_node_count = 0
    max_node_count = 1
  }

  node_config {
    machine_type = "e2-small"
    disk_type    = "pd-standard"
    disk_size_gb = 30
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  lifecycle {
    ignore_changes = [
      node_config[0].resource_labels,
      node_config[0].kubelet_config,
    ]
  }
}

# --- Secondary (DR) cluster: symmetric copy of the primary ------------------
# Enabled only when var.enable_secondary = true. Same VPC, dedicated subnet in
# the secondary region, matching node pool + Workload Identity for symmetry.
resource "google_compute_subnetwork" "secondary_subnet" {
  count         = var.enable_secondary ? 1 : 0
  name          = "gke-secondary-subnet"
  ip_cidr_range = var.secondary_subnet_cidr
  network       = google_compute_network.vpc.name
  region        = var.secondary_region
}

resource "google_container_cluster" "secondary" {
  count                    = var.enable_secondary ? 1 : 0
  name                     = "gke-secondary"
  location                 = var.secondary_region
  network                  = google_compute_network.vpc.name
  subnetwork               = google_compute_subnetwork.secondary_subnet[0].name
  remove_default_node_pool = false
  initial_node_count       = 1
  node_locations           = var.secondary_node_locations
  ip_allocation_policy {}
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

resource "google_container_node_pool" "secondary_pool" {
  count          = var.enable_secondary ? 1 : 0
  name           = "default-pool"
  cluster        = google_container_cluster.secondary[0].name
  location       = var.secondary_region
  node_locations = var.secondary_node_locations

  autoscaling {
    min_node_count = 0
    max_node_count = 1
  }

  node_config {
    machine_type = "e2-small"
    disk_type    = "pd-standard"
    disk_size_gb = 30
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  lifecycle {
    ignore_changes = [
      node_config[0].resource_labels,
      node_config[0].kubelet_config,
    ]
  }
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
  # Use multi-region US to avoid Cloud Logging->BigQuery table_invalid_schema issues seen with regional datasets.
  location   = "US"
}

resource "google_logging_project_sink" "to_bq" {
  name                   = "export-to-bq"
  destination            = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.logs.dataset_id}"
  filter                 = "resource.type=\"k8s_container\" OR resource.type=\"http_load_balancer\""
  unique_writer_identity = true
}

resource "google_bigquery_dataset_iam_member" "sink_writer" {
  dataset_id = google_bigquery_dataset.logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.to_bq.writer_identity
}
