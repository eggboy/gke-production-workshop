# Lab 02, step 5: custom-mode VPC and the cluster subnet with secondary ranges
# for Pods and Services, Private Google Access and VPC Flow Logs.
# The enforcement order (Lab 02, step 7) evaluates the network firewall policy
# before VPC firewall rules, so a VPC rule can't bypass the egress deny.
resource "google_compute_network" "vpc" {
  name                                      = local.vpc_name
  auto_create_subnetworks                   = false
  routing_mode                              = "REGIONAL"
  network_firewall_policy_enforcement_order = "BEFORE_CLASSIC_FIREWALL"

  depends_on = [time_sleep.apis]
}

resource "google_compute_subnetwork" "gke" {
  name                     = local.subnet_name
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = local.subnet_range
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = local.pods_range_name
    ip_cidr_range = local.pods_range
  }

  secondary_ip_range {
    range_name    = local.services_range_name
    ip_cidr_range = local.services_range
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Lab 02, step 6: Cloud Router and Cloud NAT with a reserved static IP.
resource "google_compute_router" "router" {
  name    = local.router_name
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_address" "nat" {
  name   = local.nat_ip_name
  region = var.region

  depends_on = [time_sleep.apis]
}

resource "google_compute_router_nat" "nat" {
  name                                = local.nat_name
  router                              = google_compute_router.router.name
  region                              = var.region
  nat_ip_allocate_option              = "MANUAL_ONLY"
  nat_ips                             = [google_compute_address.nat.self_link]
  source_subnetwork_ip_ranges_to_nat  = "LIST_OF_SUBNETWORKS"
  enable_endpoint_independent_mapping = false
  enable_dynamic_port_allocation      = true
  min_ports_per_vm                    = 64
  max_ports_per_vm                    = 4096

  # NAT only this subnet: its primary range and both secondary ranges.
  subnetwork {
    name                    = google_compute_subnetwork.gke.self_link
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ALL"
  }
}

# Lab 02, step 12: global static IP for the Gateway (Lab 04).
resource "google_compute_global_address" "gateway" {
  name       = local.gateway_ip_name
  ip_version = "IPV4"

  depends_on = [time_sleep.apis]
}
