# Lab 02, step 7: Cloud NGFW network firewall policy that locks down egress.
#   Priority 1000: allow HTTPS to an allow-list of internet FQDNs.
#   Priority 2000: deny everything else whose destination is the internet.
# Traffic to Google APIs through Private Google Access is NON_INTERNET, so it is
# not affected by rule 2000.
resource "google_compute_network_firewall_policy" "egress" {
  name        = local.fw_policy_name
  description = "Egress allow-list for ${local.cluster_name}"

  depends_on = [time_sleep.apis]
}

resource "google_compute_network_firewall_policy_rule" "allow_fqdns" {
  firewall_policy = google_compute_network_firewall_policy.egress.name
  priority        = 1000
  direction       = "EGRESS"
  action          = "allow"
  enable_logging  = true
  description     = "Allow HTTPS to approved internet FQDNs"

  match {
    dest_fqdns = local.allowed_egress_fqdns

    layer4_configs {
      ip_protocol = "tcp"
      ports       = ["443"]
    }
  }
}

resource "google_compute_network_firewall_policy_rule" "deny_internet" {
  firewall_policy = google_compute_network_firewall_policy.egress.name
  priority        = 2000
  direction       = "EGRESS"
  action          = "deny"
  enable_logging  = true
  description     = "Deny all other internet egress"

  match {
    dest_ip_ranges       = ["0.0.0.0/0"]
    dest_network_context = "INTERNET"

    layer4_configs {
      ip_protocol = "all"
    }
  }
}

resource "google_compute_network_firewall_policy_association" "vpc" {
  name              = "${local.fw_policy_name}-assoc"
  firewall_policy   = google_compute_network_firewall_policy.egress.id
  attachment_target = google_compute_network.vpc.self_link
}
