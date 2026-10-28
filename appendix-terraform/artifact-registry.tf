# Lab 02, steps 9 and 10: private image repository with immutable tags and
# automatic vulnerability scanning (Artifact Analysis). The node service account
# may pull from it, and the image mirror service account may push to it.
resource "google_artifact_registry_repository" "repo" {
  repository_id = local.ar_repo
  location      = var.region
  format        = "DOCKER"
  description   = "Approved images for ${local.cluster_name}"

  docker_config {
    immutable_tags = true
  }

  vulnerability_scanning_config {
    enablement_config = "INHERITED"
  }

  depends_on = [time_sleep.apis]
}

resource "google_artifact_registry_repository_iam_member" "gke_nodes_reader" {
  repository = google_artifact_registry_repository.repo.name
  location   = google_artifact_registry_repository.repo.location
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.gke_nodes.member
}

resource "google_artifact_registry_repository_iam_member" "image_mirror_writer" {
  repository = google_artifact_registry_repository.repo.name
  location   = google_artifact_registry_repository.repo.location
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.image_mirror.member
}
