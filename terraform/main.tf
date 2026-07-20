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

# --- Outbound egress: Cloud NAT for the primary region ----------------------
resource "google_compute_router" "primary" {
  name    = "gke-primary-router"
  network = google_compute_network.vpc.name
  region  = var.region
}

resource "google_compute_router_nat" "primary" {
  name                               = "gke-primary-nat"
  router                             = google_compute_router.primary.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Firewall: allow intra-VPC (east-west) traffic + GCP health checks ------
resource "google_compute_firewall" "allow_internal" {
  name    = "gke-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.10.0.0/20", "10.20.0.0/20"]
}

resource "google_compute_firewall" "allow_health_checks" {
  name    = "gke-allow-health-checks"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
  }

  # Google front-end / health-check probe ranges.
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
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

  # Private nodes (no public IPs); egress via Cloud NAT. Control-plane endpoint
  # stays public but is restricted by master_authorized_networks_config.
  dynamic "private_cluster_config" {
    for_each = var.enable_private_nodes ? [1] : []
    content {
      enable_private_nodes    = true
      enable_private_endpoint = false
      master_ipv4_cidr_block  = "172.16.0.0/28"
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
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

# Cloud NAT for the secondary region (only when the secondary cluster is on).
resource "google_compute_router" "secondary" {
  count   = var.enable_secondary ? 1 : 0
  name    = "gke-secondary-router"
  network = google_compute_network.vpc.name
  region  = var.secondary_region
}

resource "google_compute_router_nat" "secondary" {
  count                              = var.enable_secondary ? 1 : 0
  name                               = "gke-secondary-nat"
  router                             = google_compute_router.secondary[0].name
  region                             = var.secondary_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
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

  dynamic "private_cluster_config" {
    for_each = var.enable_private_nodes ? [1] : []
    content {
      enable_private_nodes    = true
      enable_private_endpoint = false
      master_ipv4_cidr_block  = "172.16.0.16/28"
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
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

# --- Secret Manager: managed secret consumed by the app at runtime ----------
# Satisfies "Secrets handled via Secret Manager". The app's Google SA
# (webapp-sa) is mapped to the KSA via Workload Identity and granted accessor.
resource "google_secret_manager_secret" "app_secret" {
  secret_id = "webapp-api-token"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "app_secret_v1" {
  secret      = google_secret_manager_secret.app_secret.id
  secret_data = var.app_secret_value
}

resource "google_secret_manager_secret_iam_member" "app_accessor" {
  secret_id = google_secret_manager_secret.app_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app_service.email}"
}

# Bind the Kubernetes SA (default/webapp-ksa) to the Google SA for Workload Identity.
resource "google_service_account_iam_member" "webapp_wi" {
  service_account_id = google_service_account.app_service.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/webapp-ksa]"
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
