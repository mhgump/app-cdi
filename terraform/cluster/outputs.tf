output "cluster_name" {
  value = var.cluster_name
}

output "lb_ip" {
  value       = google_compute_global_forwarding_rule.cluster_http.ip_address
  description = "Load balancer IP (HTTP). Point DNS here."
}

output "lb_ip_https" {
  value       = var.domain != "" ? google_compute_global_forwarding_rule.cluster_https[0].ip_address : ""
  description = "Load balancer IP (HTTPS, empty if no domain configured)"
}

output "instance_group" {
  value = google_compute_region_instance_group_manager.cluster.instance_group
}

output "mig_name" {
  value = google_compute_region_instance_group_manager.cluster.name
}

output "service_account_email" {
  value = google_service_account.cluster.email
}
