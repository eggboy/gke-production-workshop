# Lab 03: the hardened GKE Standard cluster and its node pool.
#
# The control plane keeps GKE's default egress mode (VIA_CONTROL_PLANE): the
# Binary Authorization admission webhook calls a Google API and fails open when
# the API server has no egress (see Lab 03 and the security design).

# IAM grants are eventually consistent. GKE checks the KMS permission of its
# service agent when it creates the cluster, so give the grants time to
# propagate first.
resource "time_sleep" "iam" {
  depends_on = [
    google_project_iam_member.gke_nodes_default_sa,
    google_artifact_registry_repository_iam_member.gke_nodes_reader,
    google_kms_crypto_key_iam_member.gke_service_agent,
  ]

  create_duration = "60s"
}

resource "google_container_cluster" "gke" {
  name     = local.cluster_name
  location = var.region

  # A workshop cluster must be easy to delete. In production, keep the default
  # (true) so that the cluster can't be destroyed by accident.
  deletion_protection = false

  # Release channel and accelerated patch upgrades
  release_channel {
    channel = "REGULAR"
  }

  gke_auto_upgrade_config {
    patch_mode = "ACCELERATED"
  }

  # VPC-native networking on the subnet from Lab 02
  network         = google_compute_network.vpc.id
  subnetwork      = google_compute_subnetwork.gke.id
  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = local.pods_range_name
    services_secondary_range_name = local.services_range_name
    stack_type                    = "IPV4"
  }

  # Private nodes, DNS-based control plane endpoint only
  private_cluster_config {
    enable_private_nodes = true
  }

  # No double SNAT: Cloud NAT translates Pod IPs directly, so firewall and NAT
  # logs show the Pod, not the node (--disable-default-snat in Lab 03).
  default_snat_status {
    disabled = true
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }

    ip_endpoints_config {
      enabled = false
    }
  }

  # Dataplane V2 with metrics, flow observability (Hubble) and FQDN network policies
  datapath_provider          = "ADVANCED_DATAPATH"
  enable_fqdn_network_policy = true

  # Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  anonymous_authentication_config {
    mode = "LIMITED"
  }

  # Node security defaults
  enable_shielded_nodes = true

  node_pool_defaults {
    node_config_defaults {
      insecure_kubelet_readonly_port_enabled = "FALSE"
    }
  }

  node_pool_auto_config {
    node_kubelet_config {
      insecure_kubelet_readonly_port_enabled = "FALSE"
    }
  }

  # Supply chain and data protection
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  database_encryption {
    state    = "ALL_OBJECTS_ENCRYPTION_ENABLED"
    key_name = google_kms_crypto_key.gke_secrets.id
  }

  security_posture_config {
    mode = "BASIC"
  }

  secret_manager_config {
    enabled = true

    rotation_config {
      enabled           = true
      rotation_interval = "120s"
    }
  }

  # Ingress through the GKE Gateway controller
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  # Add-ons. These mirror what gcloud enables on a new cluster, so that both
  # paths produce the same cluster. NodeLocal DNSCache matters: the DNS network
  # policies of Lab 04 expect it.
  addons_config {
    http_load_balancing {
      disabled = false
    }

    horizontal_pod_autoscaling {
      disabled = false
    }

    dns_cache_config {
      enabled = true
    }

    gce_persistent_disk_csi_driver_config {
      enabled = true
    }

    gcp_filestore_csi_driver_config {
      enabled = true
    }

    network_policy_config {
      disabled = true
    }
  }

  # Observability
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS", "APISERVER", "SCHEDULER", "CONTROLLER_MANAGER"]
  }

  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "APISERVER",
      "SCHEDULER",
      "CONTROLLER_MANAGER",
      "STORAGE",
      "POD",
      "DEPLOYMENT",
      "STATEFULSET",
      "DAEMONSET",
      "HPA",
      "CADVISOR",
      "KUBELET",
    ]

    managed_prometheus {
      enabled = true
    }

    advanced_datapath_observability_config {
      enable_metrics = true
      enable_relay   = true
    }
  }

  # Cost
  vertical_pod_autoscaling {
    enabled = true
  }

  cost_management_config {
    enabled = true
  }

  # Weekend maintenance window, 18:00-24:00 UTC
  maintenance_policy {
    recurring_window {
      start_time = "2026-01-03T18:00:00Z"
      end_time   = "2026-01-04T00:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  resource_labels = local.labels

  # GKE always creates a default node pool with a new cluster. Terraform deletes
  # it right away and creates the managed "default-pool" below instead. Until
  # then, the temporary pool also uses the dedicated node service account, so
  # nothing ever runs as the Compute Engine default service account.
  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  lifecycle {
    # node_config only describes the temporary default pool. The real nodes are
    # configured in google_container_node_pool.default_pool.
    ignore_changes = [node_config]
  }

  depends_on = [
    time_sleep.iam,
    google_compute_router_nat.nat,
    google_compute_network_firewall_policy_association.vpc,
  ]
}

resource "google_container_node_pool" "default_pool" {
  name     = "default-pool"
  cluster  = google_container_cluster.gke.id
  location = var.region

  # One node per zone to start, autoscaling between 1 and 3 nodes per zone
  initial_node_count = 1

  autoscaling {
    min_node_count  = 1
    max_node_count  = 3
    location_policy = "BALANCED"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Surge upgrades: add one node before removing one, so capacity never drops
  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = "e2-standard-4"
    image_type      = "COS_CONTAINERD"
    disk_type       = "pd-balanced"
    disk_size_gb    = 50
    service_account = google_service_account.gke_nodes.email

    # The same scopes gcloud sets for a custom service account. Access is
    # controlled by the service account's IAM roles.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/userinfo.email",
    ]

    metadata = {
      disable-legacy-endpoints = "true"
    }

    resource_labels = local.labels

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    kubelet_config {
      insecure_kubelet_readonly_port_enabled = "FALSE"
    }
  }
}
