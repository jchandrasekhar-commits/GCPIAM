# ============================================================================
# Global External HTTPS Load Balancer, Cloud Armor WAF, Cloud DNS, and
# uptime/alerting. The container-native (NEG) data plane is wired up by the
# GKE Ingress + BackendConfig/FrontendConfig/ManagedCertificate manifests in
# ../k8s. The resources below are the Google-Cloud-side pieces those manifests
# reference by name (static IP + Cloud Armor policy).
# ============================================================================

# --- Reserved global anycast IP for the external HTTPS load balancer --------
# The Ingress references this by name via the
# `kubernetes.io/ingress.global-static-ip-name` annotation.
resource "google_compute_global_address" "webapps_lb_ip" {
  name        = "webapps-lb-ip"
  ip_version  = "IPV4"
  description = "Static anycast frontend IP for the global external HTTPS load balancer."
  depends_on  = [google_project_service.enabled]
}

# --- Cloud Armor WAF security policy ----------------------------------------
# Referenced by the k8s BackendConfig (securityPolicy.name = webapps-waf).
resource "google_compute_security_policy" "webapps_waf" {
  name        = "webapps-waf"
  description = "Cloud Armor WAF for the global external HTTPS load balancer."

  # Default rule: allow everything not matched by a deny rule above.
  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow"
  }

  # Preconfigured WAF: block common SQL injection attempts (OWASP CRS).
  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
    description = "Block SQL injection (OWASP CRS)"
  }

  # Preconfigured WAF: block common cross-site scripting attempts.
  rule {
    action   = "deny(403)"
    priority = 1001
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }
    description = "Block XSS (OWASP CRS)"
  }

  # Per-IP rate limiting to blunt volumetric / brute-force traffic.
  rule {
    action   = "rate_based_ban"
    priority = 1002
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 100
        interval_sec = 60
      }
      ban_duration_sec = 300
    }
    description = "Rate limit: 100 req/min per source IP"
  }

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable = true
    }
  }
}

# --- Cloud DNS managed zone + A record --------------------------------------
resource "google_dns_managed_zone" "app_zone" {
  count       = var.enable_cloud_dns ? 1 : 0
  name        = "app-zone"
  dns_name    = var.dns_domain
  description = "Public managed zone for the web applications."
}

resource "google_dns_record_set" "app_a" {
  count        = var.enable_cloud_dns ? 1 : 0
  name         = "${var.app_hostname}."
  type         = "A"
  ttl          = 300
  managed_zone = google_dns_managed_zone.app_zone[0].name
  rrdatas      = [google_compute_global_address.webapps_lb_ip.address]
}

# --- Uptime check + alerting ------------------------------------------------
resource "google_monitoring_uptime_check_config" "app_https" {
  display_name = "webapps-https-uptime"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.app_hostname
    }
  }
}

resource "google_monitoring_notification_channel" "email" {
  count        = var.uptime_alert_email == "" ? 0 : 1
  display_name = "Uptime alert email"
  type         = "email"
  labels = {
    email_address = var.uptime_alert_email
  }
}

resource "google_monitoring_alert_policy" "uptime_failure" {
  count        = var.uptime_alert_email == "" ? 0 : 1
  display_name = "webapps uptime failure"
  combiner     = "OR"

  conditions {
    display_name = "Uptime check failing"
    condition_threshold {
      filter          = "resource.type=\"uptime_url\" AND metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.app_https.uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"
      trigger {
        count = 1
      }
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_NEXT_OLDER"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}

# --- HTTP 5xx error rate alert -----------------------------------------------
# Fires when the load balancer records more than 5 HTTP 5xx responses in a
# 60-second window, sustained for 2 minutes.
resource "google_monitoring_alert_policy" "error_rate" {
  count        = var.uptime_alert_email == "" ? 0 : 1
  display_name = "webapps HTTP 5xx error rate elevated"
  combiner     = "OR"

  conditions {
    display_name = "LB 5xx responses > 5 per minute"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type=\"https_lb_rule\"",
        "metric.type=\"loadbalancing.googleapis.com/https/request_count\"",
        "metric.label.response_code_class=\"500\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "120s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}

# --- p99 backend latency alert -----------------------------------------------
# Fires when the 99th-percentile backend latency reported by the load balancer
# exceeds 2 000 ms, sustained for 2 minutes.
resource "google_monitoring_alert_policy" "p99_latency" {
  count        = var.uptime_alert_email == "" ? 0 : 1
  display_name = "webapps p99 backend latency > 2 s"
  combiner     = "OR"

  conditions {
    display_name = "LB backend p99 latency > 2000 ms"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type=\"https_lb_rule\"",
        "metric.type=\"loadbalancing.googleapis.com/https/backend_latencies\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 2000
      duration        = "120s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_PERCENTILE_99"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
}
