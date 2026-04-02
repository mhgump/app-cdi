locals {
  # All GCP resource names are prefixed with the namespace to avoid conflicts
  # with other deployments sharing the same GCP project.
  net    = "${var.namespace}--network"
  pg     = "${var.namespace}--postgres"
  redis  = "${var.namespace}--redis"
  secret = "${var.namespace}--postgres-password"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "google_compute_network" "main" {
  name                    = local.net
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "${local.net}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.main.id
}

# Allocate an IP range for private service access (Cloud SQL, Memorystore)
resource "google_compute_global_address" "private_service_range" {
  name          = "${local.net}-private-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private_vpc" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range.name]
}

# ── Cloud NAT (outbound internet for instances without public IPs) ────────────

resource "google_compute_router" "main" {
  name    = "${local.net}-router"
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  name                               = "${local.net}-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ── Firewall rules ────────────────────────────────────────────────────────────

# Allow internal traffic between instances
resource "google_compute_firewall" "allow_internal" {
  name    = "${local.net}-allow-internal"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/8"]
}

# Allow GCP health checkers to reach instances
resource "google_compute_firewall" "allow_health_check" {
  name    = "${local.net}-allow-health-check"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
  }

  # GCP health check and LB proxy source ranges
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["allow-health-check"]
}

# ── PostgreSQL (Cloud SQL) ────────────────────────────────────────────────────

resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "google_sql_database_instance" "main" {
  name             = local.pg
  database_version = var.postgres_version
  region           = var.region

  depends_on = [google_service_networking_connection.private_vpc]

  settings {
    tier              = var.postgres_tier
    availability_type = "ZONAL"

    disk_autoresize = true
    disk_size       = var.postgres_disk_size_gb
    disk_type       = "PD_SSD"

    backup_configuration {
      enabled            = true
      start_time         = "03:00"
      binary_log_enabled = false
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main.id
    }

    database_flags {
      name  = "max_connections"
      value = "200"
    }
  }

  deletion_protection = false
}

resource "google_sql_user" "app" {
  name     = "app"
  instance = google_sql_database_instance.main.name
  password = random_password.postgres.result
}

resource "google_secret_manager_secret" "postgres_password" {
  secret_id = local.secret
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "postgres_password" {
  secret      = google_secret_manager_secret.postgres_password.id
  secret_data = random_password.postgres.result
}

# ── Redis (Memorystore) ───────────────────────────────────────────────────────

resource "google_redis_instance" "main" {
  name           = local.redis
  memory_size_gb = var.redis_memory_size_gb
  region         = var.region

  authorized_network = google_compute_network.main.id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  redis_version      = var.redis_version

  depends_on = [google_service_networking_connection.private_vpc]
}
