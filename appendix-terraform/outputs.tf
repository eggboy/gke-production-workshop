output "cluster_name" {
  description = "Name of the GKE cluster (CLUSTER_NAME in env.sh)."
  value       = google_container_cluster.gke.name
}

output "dns_endpoint" {
  description = "DNS-based endpoint of the control plane."
  value       = google_container_cluster.gke.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint
}

output "nat_ip" {
  description = "Static IP address that the cluster's internet egress uses (Cloud NAT)."
  value       = google_compute_address.nat.address
}

output "gateway_ip" {
  description = "Global static IP address for the Gateway (GATEWAY_IP in env.sh)."
  value       = google_compute_global_address.gateway.address
}

output "artifact_registry_path" {
  description = "Image path prefix of the repository (AR_PATH in env.sh)."
  value       = google_artifact_registry_repository.repo.registry_uri
}

output "kms_key_id" {
  description = "Cloud KMS key that encrypts Kubernetes Secrets (KMS_KEY_ID in env.sh)."
  value       = google_kms_crypto_key.gke_secrets.id
}
