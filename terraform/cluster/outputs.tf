output "cluster_name" {
  value = var.cluster_name
}

output "lb_ip" {
  value       = var.domain != "" ? google_compute_global_address.cluster[0].address : google_compute_global_forwarding_rule.cluster_http.ip_address
  description = "Load balancer IP. Point DNS here. When a domain is set, HTTP and HTTPS share this address."
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
