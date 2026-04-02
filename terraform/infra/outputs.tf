output "network_self_link" {
  value = google_compute_network.main.self_link
}

output "subnet_self_link" {
  value = google_compute_subnetwork.main.self_link
}

output "network_name" {
  value = google_compute_network.main.name
}

output "postgres_host" {
  value       = google_sql_database_instance.main.private_ip_address
  description = "Private IP of the Cloud SQL instance"
}

output "postgres_connection_name" {
  value = google_sql_database_instance.main.connection_name
}

output "postgres_user" {
  value = google_sql_user.app.name
}

output "postgres_password_secret" {
  value       = google_secret_manager_secret.postgres_password.secret_id
  description = "Secret Manager secret ID containing the Postgres password"
}

output "redis_host" {
  value = google_redis_instance.main.host
}

output "redis_port" {
  value = google_redis_instance.main.port
}
