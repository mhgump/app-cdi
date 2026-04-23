locals {
  prefix = "cluster-${var.cluster_name}"

  # Embed the supervisor script (base64) into the startup template so instances
  # can decode it without needing a GCS dependency at boot time.
  supervisor_b64 = base64encode(file("${path.module}/../../supervisor/supervisor.sh"))

  # supervisor-http is a compiled Go binary too large to embed in the startup script.
  # deploy.sh builds it for linux/amd64 and uploads it to GCS; instances download it at boot.
  supervisor_http_gcs_uri = "gs://${var.state_bucket}/supervisor-http"

  startup_script = templatefile("${path.module}/../../supervisor/startup.sh", {
    supervisor_b64          = local.supervisor_b64
    supervisor_http_gcs_uri = local.supervisor_http_gcs_uri
  })
}

# ── Service account for cluster instances ─────────────────────────────────────

resource "google_service_account" "cluster" {
  account_id   = substr("${local.prefix}-sa", 0, 30)
  display_name = "Cluster ${var.cluster_name} instances"
}

resource "google_project_iam_member" "cluster_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.cluster.email}"
}

resource "google_project_iam_member" "cluster_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.cluster.email}"
}

resource "google_project_iam_member" "cluster_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.cluster.email}"
}

# Grant instances read access to the state bucket so they can download the
# supervisor-http binary that deploy.sh uploads there.
resource "google_storage_bucket_iam_member" "cluster_gcs_reader" {
  bucket = var.state_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.cluster.email}"
}

# Instances need to read their own metadata (rebuild-trigger) and update it
# via the rebuild script (which runs as a local user, not the instance SA).
# No extra compute permissions needed here.

# ── Instance template ─────────────────────────────────────────────────────────

resource "google_compute_instance_template" "cluster" {
  name_prefix  = "${local.prefix}-"
  machine_type = var.machine_type
  region       = var.region

  disk {
    source_image = "debian-cloud/debian-12"
    disk_size_gb = var.disk_size_gb
    disk_type    = "pd-ssd"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = var.subnet_self_link
    # No public IP — instances reach the internet via Cloud NAT
  }

  service_account {
    email  = google_service_account.cluster.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    # Supervisor reads these at boot and on each iteration
    cluster-name             = var.cluster_name
    git-repo-url             = var.git_repo_url
    build-context            = var.build_context
    dockerfile               = var.dockerfile
    git-deploy-key-secret    = var.git_deploy_key_secret
    git-token-secret         = var.git_token_secret
    container-port           = tostring(var.container_port)
    # Postgres / Redis passed as env to the container via supervisor
    postgres-host            = var.postgres_host
    postgres-user            = var.postgres_user
    postgres-schema          = var.data_namespace != "" ? var.data_namespace : var.cluster_name
    postgres-password-secret = var.postgres_password_secret
    redis-host               = var.redis_host
    redis-port               = tostring(var.redis_port)
    redis-prefix             = "${var.data_namespace != "" ? var.data_namespace : var.cluster_name}:"
    # Rebuild trigger — updated by scripts/rebuild.sh to trigger a rolling redeploy
    rebuild-trigger          = ""
  }

  # Dedicated field for the startup script (not subject to per-key 256KB limit)
  metadata_startup_script = local.startup_script

  tags = [local.prefix, "allow-health-check"]

  lifecycle {
    create_before_destroy = true
  }
}

# ── Managed instance group ─────────────────────────────────────────────────────

resource "google_compute_region_instance_group_manager" "cluster" {
  name   = local.prefix
  region = var.region

  base_instance_name = local.prefix

  version {
    instance_template = google_compute_instance_template.cluster.id
  }

  named_port {
    name = "http"
    port = var.container_port
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.cluster.id
    initial_delay_sec = 180
  }

  distribution_policy_zones = length(var.zones) > 0 ? var.zones : null

  update_policy {
    type                         = "PROACTIVE"
    minimal_action               = "REPLACE"
    replacement_method           = "SUBSTITUTE"
    max_surge_fixed              = 3
    max_unavailable_fixed        = 0
  }

}

# ── Autoscaler ────────────────────────────────────────────────────────────────

resource "google_compute_region_autoscaler" "cluster" {
  name   = "${local.prefix}-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.cluster.id

  autoscaling_policy {
    min_replicas    = var.min_instances
    max_replicas    = var.max_instances
    cooldown_period = var.autoscale_cooldown_sec

    load_balancing_utilization {
      target = var.target_cpu_utilization
    }
  }
}

# ── Health check ──────────────────────────────────────────────────────────────

resource "google_compute_health_check" "cluster" {
  name               = "${local.prefix}-hc"
  check_interval_sec = 15
  timeout_sec        = 5
  healthy_threshold  = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = var.container_port
    request_path = "/health/local"
  }
}

# ── Backend service ───────────────────────────────────────────────────────────

resource "google_compute_backend_service" "cluster" {
  name        = "${local.prefix}-backend"
  protocol    = "HTTP"
  port_name   = "http"
  timeout_sec = 86400  # 24 h — keeps WebSocket connections alive

  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group           = google_compute_region_instance_group_manager.cluster.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  health_checks = [google_compute_health_check.cluster.id]
}

# ── Load balancer ─────────────────────────────────────────────────────────────

resource "google_compute_url_map" "cluster" {
  name            = "${local.prefix}-urlmap"
  default_service = google_compute_backend_service.cluster.id
}

# HTTP→HTTPS redirect URL map (only when a domain is configured)
resource "google_compute_url_map" "cluster_http_redirect" {
  count = var.domain != "" ? 1 : 0
  name  = "${local.prefix}-http-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

# Shared static IP so HTTP (port 80) and HTTPS (port 443) resolve from the same address
resource "google_compute_global_address" "cluster" {
  count = var.domain != "" ? 1 : 0
  name  = "${local.prefix}-ip"
}

# HTTP (always created)
resource "google_compute_target_http_proxy" "cluster" {
  name    = "${local.prefix}-http-proxy"
  url_map = var.domain != "" ? google_compute_url_map.cluster_http_redirect[0].id : google_compute_url_map.cluster.id
}

resource "google_compute_global_forwarding_rule" "cluster_http" {
  name                  = "${local.prefix}-http"
  target                = google_compute_target_http_proxy.cluster.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = var.domain != "" ? google_compute_global_address.cluster[0].id : null
}

# HTTPS (only when a domain is provided)
resource "google_compute_managed_ssl_certificate" "cluster" {
  count = var.domain != "" ? 1 : 0
  name  = "${local.prefix}-cert-${substr(md5(var.domain), 0, 8)}"

  managed {
    domains = [var.domain]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# mTLS: trust config + server TLS policy (only when mtls_ca_cert is provided)
resource "google_certificate_manager_trust_config" "cluster" {
  count    = var.mtls_ca_cert != "" ? 1 : 0
  name     = "${local.prefix}-trust-config"
  location = "global"

  trust_stores {
    trust_anchors {
      pem_certificate = var.mtls_ca_cert
    }
  }
}

resource "google_network_security_server_tls_policy" "cluster" {
  count    = var.mtls_ca_cert != "" ? 1 : 0
  provider = google-beta
  name     = "${local.prefix}-tls-policy"
  location = "global"

  mtls_policy {
    client_validation_mode         = "REJECT_INVALID"
    client_validation_trust_config = google_certificate_manager_trust_config.cluster[0].id
  }
}

resource "google_compute_target_https_proxy" "cluster" {
  count   = var.domain != "" ? 1 : 0
  name    = "${local.prefix}-https-proxy"
  url_map = google_compute_url_map.cluster.id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.cluster[0].id,
  ]
  server_tls_policy = var.mtls_ca_cert != "" ? google_network_security_server_tls_policy.cluster[0].id : null
}

resource "google_compute_global_forwarding_rule" "cluster_https" {
  count                 = var.domain != "" ? 1 : 0
  name                  = "${local.prefix}-https"
  target                = google_compute_target_https_proxy.cluster[0].id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.cluster[0].id
}

# ── Firewall: LB → instances ──────────────────────────────────────────────────

resource "google_compute_firewall" "cluster_from_lb" {
  name    = "${local.prefix}-allow-lb"
  network = var.network_name

  allow {
    protocol = "tcp"
    ports    = [tostring(var.container_port)]
  }

  # GCP LB proxy and health-check source ranges
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = [local.prefix]
}
