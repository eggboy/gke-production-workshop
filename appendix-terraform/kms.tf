# Lab 02, step 8: Cloud KMS key for application-layer secrets encryption.
#
# Key rings and keys can't be deleted. `terraform destroy` removes them from the
# Terraform state and schedules every key version for destruction (after 30
# days); the key ring and key names stay in use in the project.
resource "google_kms_key_ring" "gke" {
  name     = local.kms_keyring
  location = var.region

  depends_on = [time_sleep.apis]
}

resource "google_kms_crypto_key" "gke_secrets" {
  name            = local.kms_key
  key_ring        = google_kms_key_ring.gke.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days
}

# Make sure the GKE service agent exists (gcloud beta services identity create).
resource "google_project_service_identity" "gke" {
  provider = google-beta

  service = "container.googleapis.com"

  depends_on = [time_sleep.apis]
}

resource "google_kms_crypto_key_iam_member" "gke_service_agent" {
  crypto_key_id = google_kms_crypto_key.gke_secrets.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = google_project_service_identity.gke.member
}
