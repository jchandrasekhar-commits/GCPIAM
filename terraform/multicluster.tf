# ============================================================================
# Multi-Cluster Ingress (MCI) + Multi-Cluster Services (MCS) via GKE Fleet.
#
# This closes the "global traffic + cross-cluster failover" gap: instead of a
# single-cluster GKE Ingress that only reaches gke-primary, MCI programs ONE
# global anycast L7 load balancer that load-balances to healthy pods in BOTH
# gke-primary (us-central1) and gke-secondary (us-east1), with automatic
# proximity routing and regional failover. MCS provides cross-cluster east-west
# service discovery (a Service in one cluster is reachable from the other).
#
# Enabled by var.enable_multicluster_ingress (requires var.enable_secondary).
# The MCI/MCS custom resources themselves live in ../k8s/multicluster and are
# applied to the CONFIG cluster (gke-primary) after these Fleet features exist.
# ============================================================================

# --- Fleet memberships: register both clusters ------------------------------
resource "google_gke_hub_membership" "primary" {
  count         = var.enable_multicluster_ingress ? 1 : 0
  membership_id = "gke-primary"
  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${google_container_cluster.primary.id}"
    }
  }
  depends_on = [google_project_service.enabled]

  lifecycle {
    precondition {
      condition     = var.enable_secondary
      error_message = "enable_multicluster_ingress = true requires enable_secondary = true (there must be a second cluster to fan out to)."
    }
  }
}

resource "google_gke_hub_membership" "secondary" {
  count         = var.enable_multicluster_ingress ? 1 : 0
  membership_id = "gke-secondary"
  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${google_container_cluster.secondary[0].id}"
    }
  }
  depends_on = [google_project_service.enabled]
}

# --- Multi-Cluster Ingress feature (config cluster = gke-primary) -----------
resource "google_gke_hub_feature" "mci" {
  count    = var.enable_multicluster_ingress ? 1 : 0
  name     = "multiclusteringress"
  location = "global"

  spec {
    multiclusteringress {
      config_membership = google_gke_hub_membership.primary[0].id
    }
  }

  depends_on = [google_project_service.enabled]
}

# --- Multi-Cluster Services feature (cross-cluster east-west discovery) ------
# Enabling this feature provisions the MCS service agents and the
# ServiceExport/ServiceImport CRDs used by ../k8s/multicluster. Google manages
# the required IAM bindings for the MCS importer service account automatically.
resource "google_gke_hub_feature" "mcs" {
  count    = var.enable_multicluster_ingress ? 1 : 0
  name     = "multiclusterservicediscovery"
  location = "global"

  depends_on = [google_project_service.enabled]
}
