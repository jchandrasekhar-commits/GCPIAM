# Enable the Google Cloud APIs required by this configuration. Kept with
# disable_on_destroy = false so `terraform destroy` does not disrupt other
# workloads that may share the project. These complement the APIs enabled
# manually via `gcloud services enable ...` in docs/deployment-steps.md.
locals {
  required_services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "bigquery.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com", # Private Service Access
    "dns.googleapis.com",               # Cloud DNS
    "cloudtrace.googleapis.com",        # Cloud Trace
    "cloudprofiler.googleapis.com",     # Cloud Profiler
    "clouderrorreporting.googleapis.com",
    "binaryauthorization.googleapis.com",
    "sqladmin.googleapis.com",  # Cloud SQL (Web App B)
    "redis.googleapis.com",     # Memorystore for Redis (Web App B)
    "pubsub.googleapis.com",    # Pub/Sub (Web App B)
    "artifactregistry.googleapis.com", # container images (vote/worker/result)
    "cloudbuild.googleapis.com",       # CI: build/push the three images
    "gkehub.googleapis.com",                        # GKE Fleet (register both clusters)
    "multiclusteringress.googleapis.com",           # Multi-Cluster Ingress (global L7)
    "multiclusterservicediscovery.googleapis.com",  # Multi-Cluster Services (cross-cluster east-west)
    "trafficdirector.googleapis.com",               # data plane used by MCS/MCI
  ]
}

resource "google_project_service" "enabled" {
  for_each           = toset(local.required_services)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
