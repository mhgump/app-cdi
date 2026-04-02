variable "cluster_name" {
  description = "Unique name for this cluster (used to namespace all resources)"
  type        = string
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "GCP zones for instance distribution (empty = all zones in region)"
  type        = list(string)
  default     = []
}

variable "machine_type" {
  description = "GCE machine type"
  type        = string
  default     = "e2-standard-2"
}

variable "disk_size_gb" {
  description = "Boot disk size for each instance"
  type        = number
  default     = 50
}

variable "min_instances" {
  description = "Minimum number of instances in the group"
  type        = number
  default     = 1
}

variable "max_instances" {
  description = "Maximum number of instances in the group"
  type        = number
  default     = 10
}

variable "target_cpu_utilization" {
  description = "CPU utilization target for autoscaling (0.0–1.0). Maps to target clients/worker."
  type        = number
  default     = 0.6
}

variable "autoscale_cooldown_sec" {
  description = "Seconds to wait before autoscaling after last scale event"
  type        = number
  default     = 90
}

variable "git_repo_url" {
  description = "Git repository URL — SSH (git@github.com:org/repo.git) for private repos, HTTPS for public repos"
  type        = string
}

variable "git_deploy_key_secret" {
  description = "Secret Manager secret name holding the SSH private deploy key. Empty string for public repos (HTTPS clone, no key needed)."
  type        = string
  default     = ""
}

variable "container_port" {
  description = "Port the Docker container listens on (also the LB backend port)"
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "HTTP path for backend health checks"
  type        = string
  default     = "/health"
}

variable "data_namespace" {
  description = "Postgres schema name and Redis key prefix. Defaults to cluster_name, allowing multiple deployments to share one data namespace."
  type        = string
  default     = ""
}

variable "build_context" {
  description = "Subdirectory within the repo to use as the Docker build context (empty = repo root)"
  type        = string
  default     = ""
}

variable "dockerfile" {
  description = "Path to Dockerfile relative to repo root (empty = Dockerfile in build context)"
  type        = string
  default     = ""
}

variable "domain" {
  description = "Domain for a GCP-managed SSL certificate (leave empty for HTTP only)"
  type        = string
  default     = ""
}

variable "network_self_link" {
  description = "Self-link of the VPC network (from infra outputs)"
  type        = string
}

variable "subnet_self_link" {
  description = "Self-link of the subnet (from infra outputs)"
  type        = string
}

variable "network_name" {
  description = "Name of the VPC network (from infra outputs)"
  type        = string
}

variable "postgres_host" {
  description = "Private IP of the shared Cloud SQL instance"
  type        = string
}

variable "postgres_user" {
  description = "PostgreSQL user"
  type        = string
}

variable "postgres_password_secret" {
  description = "Secret Manager secret name holding the Postgres password"
  type        = string
}

variable "redis_host" {
  description = "Memorystore Redis host"
  type        = string
}

variable "redis_port" {
  description = "Memorystore Redis port"
  type        = number
  default     = 6379
}

variable "mtls_ca_cert" {
  description = "PEM-encoded CA certificate for mTLS client validation on the HTTPS load balancer. Empty string disables mTLS."
  type        = string
  default     = ""
}
