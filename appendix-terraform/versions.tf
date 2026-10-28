# Terraform and provider versions. The configuration was validated with exactly
# these versions; update them deliberately and run `terraform plan` to review
# the effect.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "8.7.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.14.2"
    }
  }
}

# By default, the provider adds the label goog-terraform-provisioned=true to
# every resource that supports labels. It is turned off so that the resources
# are identical to the ones that Labs 02 and 03 create with gcloud.
provider "google" {
  project                         = var.project_id
  region                          = var.region
  add_terraform_attribution_label = false
}

# Used only for google_project_service_identity (kms.tf), which exists only in
# the beta provider.
provider "google-beta" {
  project                         = var.project_id
  region                          = var.region
  add_terraform_attribution_label = false
}
