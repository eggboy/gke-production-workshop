# Names and settings, mirroring section 2 of env.sh. Keep them in sync: the labs
# after Lab 03 read the names from env.sh.
locals {
  cluster_name = "${var.prefix}-cluster"

  # Networking (Lab 02, steps 5-7)
  vpc_name             = "${var.prefix}-vpc"
  subnet_name          = "${var.prefix}-gke-subnet"
  subnet_range         = "10.10.0.0/24"
  pods_range_name      = "pods"
  pods_range           = "10.20.0.0/16"
  services_range_name  = "services"
  services_range       = "10.30.0.0/20"
  router_name          = "${var.prefix}-router"
  nat_name             = "${var.prefix}-nat"
  nat_ip_name          = "${var.prefix}-nat-ip"
  fw_policy_name       = "${var.prefix}-egress-policy"
  allowed_egress_fqdns = ["ifconfig.me", "api.github.com"]

  # Identity, encryption and registry (Lab 02, steps 4 and 8-10)
  node_sa_name   = "${var.prefix}-gke-nodes"
  mirror_sa_name = "${var.prefix}-image-mirror"
  kms_keyring    = "${var.prefix}-keyring"
  kms_key        = "gke-secrets"
  ar_repo        = "${var.prefix}-repo"

  # Edge (Lab 02, step 12)
  gateway_ip_name = "${var.prefix}-gateway-ip"

  # Labels of the cluster and its nodes (Lab 03)
  labels = {
    env   = "workshop"
    owner = var.prefix
  }

  # APIs (Lab 02, step 2)
  services = [
    "container.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "orgpolicy.googleapis.com",
    "artifactregistry.googleapis.com",
    "containerscanning.googleapis.com",
    "cloudbuild.googleapis.com",
    "binaryauthorization.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudkms.googleapis.com",
    "containersecurity.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "dns.googleapis.com",
    "gkebackup.googleapis.com",
    "pubsub.googleapis.com",
  ]
}

# Enable the APIs. disable_on_destroy = false: destroying this configuration
# never disables APIs, which other resources in the project may still use.
resource "google_project_service" "apis" {
  for_each = toset(local.services)

  service            = each.value
  disable_on_destroy = false
}

# Newly enabled APIs can take a short while before every operation succeeds.
resource "time_sleep" "apis" {
  depends_on = [google_project_service.apis]

  create_duration = "60s"
}
