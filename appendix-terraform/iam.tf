# Lab 02, steps 4 and 10: a dedicated, least-privilege service account for the
# nodes. The read access to the image repository is granted on the repository
# only (artifact-registry.tf).
resource "google_service_account" "gke_nodes" {
  account_id   = local.node_sa_name
  display_name = "GKE nodes for ${local.cluster_name}"

  depends_on = [time_sleep.apis]
}

resource "google_project_iam_member" "gke_nodes_default_sa" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = google_service_account.gke_nodes.member
}

# Lab 02, steps 4 and 10: the identity of the Cloud Build job that copies the
# workshop images (scripts/mirror-images.sh). At the project level it may only
# write the build's logs; the push access is granted on the repository only
# (artifact-registry.tf).
resource "google_service_account" "image_mirror" {
  account_id   = local.mirror_sa_name
  display_name = "Image mirror builds for ${local.cluster_name}"

  depends_on = [time_sleep.apis]
}

resource "google_project_iam_member" "image_mirror_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.image_mirror.member
}
