# ============================================================================
# Web Application B backing services.
#
# The brief states Web App B "can use GCP services like Pub/Sub, Cloud SQL, or
# MemoryStore (Redis)" and be resilient. This file provisions, over the Private
# Service Access peering created in main.tf:
#   - Cloud SQL (PostgreSQL) with REGIONAL availability (synchronous HA standby)
#     and automated backups + point-in-time recovery  -> satisfies stateful DR
#   - Memorystore for Redis in STANDARD_HA tier (replicated) -> cache resilience
#   - A Pub/Sub topic + subscription                    -> async messaging option
#
# All are toggled by var.enable_stateful_services (default false) to stay in the
# free tier. Connection details are surfaced as outputs and injected into
# webapp-b via the app ConfigMap.
# ============================================================================

# --- Cloud SQL (PostgreSQL) HA instance -------------------------------------
resource "google_sql_database_instance" "webapp_b" {
  count               = var.enable_stateful_services ? 1 : 0
  name                = "webapp-b-db"
  database_version    = "POSTGRES_15"
  region              = var.region
  deletion_protection = false
  depends_on          = [google_service_networking_connection.psa]

  settings {
    tier              = "db-custom-1-3840"
    availability_type = "REGIONAL" # synchronous HA standby in another zone
    disk_autoresize   = true
    disk_type         = "PD_SSD"

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true # WAL archiving for PITR
      start_time                     = "03:00"
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled    = false # private IP only, reached via PSA
      private_network = google_compute_network.vpc.id
    }
  }
}

resource "google_sql_database" "app" {
  count    = var.enable_stateful_services ? 1 : 0
  name     = "webappb"
  instance = google_sql_database_instance.webapp_b[0].name
}

resource "google_sql_user" "app" {
  count    = var.enable_stateful_services ? 1 : 0
  name     = "webappb"
  instance = google_sql_database_instance.webapp_b[0].name
  password = var.db_password
}

# --- Memorystore for Redis (HA) ---------------------------------------------
resource "google_redis_instance" "cache" {
  count              = var.enable_stateful_services ? 1 : 0
  name               = "webapp-b-cache"
  tier               = "STANDARD_HA" # primary + replica for failover
  memory_size_gb     = 1
  region             = var.region
  redis_version      = "REDIS_7_0"
  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  authorized_network = google_compute_network.vpc.id
  depends_on         = [google_service_networking_connection.psa]
}

# --- Pub/Sub (async messaging option) ---------------------------------------
resource "google_pubsub_topic" "webapp_b" {
  count = var.enable_stateful_services ? 1 : 0
  name  = "webapp-b-events"
}

resource "google_pubsub_subscription" "webapp_b" {
  count                      = var.enable_stateful_services ? 1 : 0
  name                       = "webapp-b-events-sub"
  topic                      = google_pubsub_topic.webapp_b[0].name
  ack_deadline_seconds       = 20
  message_retention_duration = "86400s"
}

# Allow the app's workload-identity service account to use these services.
resource "google_project_iam_member" "webapp_sql_client" {
  count   = var.enable_stateful_services ? 1 : 0
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.app_service.email}"
}

resource "google_pubsub_subscription_iam_member" "webapp_subscriber" {
  count        = var.enable_stateful_services ? 1 : 0
  subscription = google_pubsub_subscription.webapp_b[0].name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.app_service.email}"
}

resource "google_pubsub_topic_iam_member" "webapp_publisher" {
  count  = var.enable_stateful_services ? 1 : 0
  topic  = google_pubsub_topic.webapp_b[0].name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.app_service.email}"
}
