# Pricing and Charging Model

Every billable thing the workshop creates, what you pay for, and how it is metered. Prices are **list prices in USD for `asia-southeast1` (Singapore)**, read from the [Cloud Billing Catalog API](https://cloud.google.com/billing/docs/reference/rest/v1/services.skus/list) and the product pricing pages on **2026-10-26**. Google changes prices and free tiers; the links in each section are the source of truth. Hourly items are prorated (Compute Engine bills per second with a one-minute minimum).

> [!IMPORTANT]
> Three rules explain most of the bill:
> 1. **You pay for time, not usage, for the core platform**: node VMs, the cluster fee, the load balancer, Cloud NAT, Cloud Armor and Binary Authorization accrue every hour until you delete them. That is why the [cleanup](99-cleanup/README.md) matters.
> 2. **Network logs cost twice**: VPC Flow Logs, firewall logs and Cloud NAT logs pay a *generation* fee (Network Telemetry) **and** a *storage* fee in Cloud Logging, with no free allotment.
> 3. **Free tiers are per billing account, not per project**: GKE, Binary Authorization, Artifact Registry, Cloud Build, Secret Manager and Logging free allotments are shared by every participant on the same billing account.

## 1. Cost at a glance

Always-on resources, at list price, once the platform is built (Labs 02-04). Variable items are listed below the table.

| Item (lab) | Pricing factor | Per hour | Per day |
|---|---|---|---|
| 3 × `e2-standard-4` nodes (Lab 03) | 4 vCPU × $0.026909 + 16 GiB × $0.003606, per node | $0.496 | $11.90 |
| GKE cluster management fee (Lab 03) | $0.10 per cluster-hour, regional | $0.100 | $2.40 |
| 3 × 50 GiB `pd-balanced` boot disks (Lab 03) | $0.11 per GiB-month | $0.023 | $0.54 |
| Global external Application Load Balancer (Lab 04) | First 5 forwarding rules $0.025/hour (the Gateway creates 2) | $0.025 | $0.60 |
| Cloud NAT gateway + 1 static IP (Lab 02) | $0.0014/hour per VM using it (3 nodes) + $0.005/hour per NAT IP | $0.009 | $0.22 |
| Cloud Armor Standard (Labs 04, 06) | $5/month per policy + $1/month per rule (8 rules) | $0.018 | $0.43 |
| Binary Authorization (Lab 03) | $0.01613 per cluster-hour; $12/month free credit per billing account | $0.016 | $0.39 |
| Backup for GKE plan (Lab 09 onward) | $9/month per protected namespace (1) | $0.012 | $0.30 |
| **Total, always on** | | **≈ $0.70** | **≈ $16.80** |

Variable items on top of that:

1. **Extra nodes:** the cluster autoscaler can grow the default pool to 9 nodes (Lab 07 load test); `pool-v2` runs next to `default-pool` during the migration (Lab 09); the Spot pool (Lab 07). Each `e2-standard-4` costs $0.165/hour, each Spot `e2-standard-2` about $0.050/hour.
2. **Logs and metrics:** the biggest unknowns. Standard logs are free up to 50 GiB per project per month; network logs and Prometheus-format metrics have no free allotment (section 6).
3. **One-time:** Artifact Analysis scans 14 images on push, $0.26 each = $3.64.
4. **Traffic:** Cloud NAT and load balancer data processing, internet egress, inter-zone traffic between Pods. Cents at workshop volumes.
5. **Requests:** Cloud Armor charges per million requests. Cents at workshop volumes.

The README's "a few tens of US dollars per participant for two days" follows from this: about $17 per day always-on, plus variable usage.

## 2. Compute: GKE cluster and nodes

Source: [GKE pricing](https://cloud.google.com/kubernetes-engine/pricing), [Compute Engine pricing](https://cloud.google.com/compute/all-pricing), [disk pricing](https://cloud.google.com/compute/disks-image-pricing).

| Resource | Charging model and pricing factors | List price (asia-southeast1) | Workshop notes |
|---|---|---|---|
| GKE cluster management fee | Flat fee per cluster-hour, same for zonal, regional and Autopilot. Covers the control plane (3 replicas in a regional cluster) and its storage; the pricing page lists no separate charge for Private Service Connect connectivity, the DNS endpoint or the GKE-managed add-ons. | $0.10/hour (SKU `Regional Kubernetes Clusters`) | The **GKE free tier ($74.40/month per billing account) applies only to zonal and Autopilot clusters**, not to this regional cluster. Clusters in the extended support period pay an extra $0.50/hour; the Regular channel never does. |
| Node VMs | Compute Engine on-demand: per vCPU-hour and per GiB-hour of RAM, per second with a 1-minute minimum. E2 machine types get **no sustained use discount**. | E2 vCPU $0.026909/hour, E2 RAM $0.003606/GiB-hour. `e2-standard-4` = $0.1653/hour, `e2-standard-2` = $0.0827/hour | `--num-nodes=1` is **per zone**: 3 nodes at start, up to 9 with `--max-nodes=3`. Shielded VM, Secure Boot, COS and Workload Identity add nothing. |
| Spot VMs (Lab 07) | Same units at the Spot rate. Spot prices can change up to once a month; VMs can be reclaimed. | Spot E2 vCPU $0.016150/hour, Spot E2 RAM $0.002164/GiB-hour. Spot `e2-standard-2` = $0.0496/hour (about 40% below on-demand on the date above) | The pool is deleted at the end of Lab 07. Scaled to zero it costs nothing. |
| Node boot disks | Persistent Disk, per GiB provisioned per month, prorated. | `pd-balanced` $0.11/GiB-month → 50 GiB = $5.50/month per node | Every node pool in the workshop uses 50 GiB `pd-balanced`. No PersistentVolumes are created: Online Boutique uses `emptyDir`, and `redis-cart` keeps data in memory. |
| Cluster autoscaler, HPA, VPA, cost allocation, labels | No charge. You pay for the nodes they add. | — | `optimize-utilization` (Lab 07) lowers node cost by scaling down faster. |
| Node pool migration (Lab 09) | Two pools run at the same time until `default-pool` is deleted. | Doubles node cost during the overlap | Blue-green upgrades behave the same way during a GKE upgrade: a full second set of nodes while the soak timer runs (`--node-pool-soak-duration=600s`). |
| GKE Sandbox pool (Lab 06 bonus) | Node VM cost only; gVisor adds no fee. | — | Optional. |

## 3. Networking

Source: [VPC pricing](https://cloud.google.com/vpc/network-pricing), [Cloud NAT pricing](https://cloud.google.com/nat/pricing), [Cloud NGFW pricing](https://cloud.google.com/firewall/pricing).

| Resource | Charging model and pricing factors | List price (asia-southeast1) | Workshop notes |
|---|---|---|---|
| VPC network, subnet, secondary ranges, routes, Private Google Access, Cloud Router (Lab 02) | No charge. Cloud Router is billed only through Cloud VPN or Cloud Interconnect, which the workshop doesn't use. | $0 | Private Google Access traffic to Google APIs (Artifact Registry, Logging, Secret Manager, `storage.googleapis.com`) carries no data transfer charge inside the region. |
| Cloud NAT gateway (Lab 02) | Three meters: (1) gateway uptime, per hour **per VM that has a NAT assignment**, capped at 32 VMs; (2) data processed through the gateway, in and out, per GiB; (3) each external IP used by the gateway, per hour. Plus internet data transfer (below). | $0.0014/hour per VM (max $0.044/hour); $0.045/GiB; $0.005/hour per NAT IP | Every node in the subnet counts as a VM: 3 at start, 9 at full autoscale, plus Spot and `pool-v2` nodes while they exist. Pod traffic is NATed directly (`--disable-default-snat`), which changes nothing about price. |
| Static external IP addresses (Lab 02) | Charged per hour while **reserved but not attached**. Free while attached to a load balancer forwarding rule; $0.005/hour while used by Cloud NAT (counted under NAT, above). | Unattached regional IP $0.011/hour (Singapore); unattached global IP about $0.01/hour | The Gateway IP is unattached from Lab 02 step 12 until the Gateway exists (Lab 04 step 10), and again after the Gateway is deleted in the cleanup until the address is deleted. |
| Cloud NGFW network firewall policy (Lab 02) | **Essentials** features (IP ranges, ports, protocols, network contexts, tags): no charge, and no per-VM fee for a global network firewall policy. **Standard** features (FQDN objects, geolocation, threat intelligence): data processing fee per GiB of north-south traffic (VM ↔ internet) evaluated by a rule that uses them. East-west traffic and traffic to Google APIs are never charged. | $0.0193/GiB (SKU `Cloud NGFW Standard Rules: Data Processing Fee`) | Only rule `1000` (`--dest-fqdns`) uses a Standard feature. Rule `2000` (deny, IP range plus the `INTERNET` network context) uses none of the Standard features (FQDN, geolocation, threat intelligence), so it is free. **Hierarchical** firewall policies, mentioned in the design docs but not created here, cost $1 per covered VM per month (≤500 attributes). VPC firewall rules, including the ones GKE creates, are free. |
| Firewall Rules Logging, Cloud NAT logging, VPC Flow Logs (Lab 02) | **Network Telemetry**: a generation fee per GiB of logs, charged even if you exclude the logs from Cloud Logging. The same logs are then stored as **vended network logs** in Cloud Logging at a reduced rate with **no free allotment** (section 6). | Generation $0.25/GiB (first 10 TiB per month), then $0.15, $0.075, $0.05. Storage $0.25/GiB | Rules `1000` and `2000` log every connection, NAT logs `ALL`, and flow logs sample 50% with 5-second aggregation and full metadata. These are workshop settings; the lab text already says production would log NAT `ERRORS_ONLY`. |
| Data transfer between zones | Per GiB sent between zones of the same region over internal IPs. Same-zone traffic is free. | $0.01/GiB | Online Boutique's replicas are spread across three zones on purpose (Lab 05 topology spread), so part of its service-to-service traffic crosses zones. So does the load generator's traffic while it runs in Lab 07. |
| Internet data transfer (egress) | Per GiB leaving Google's network, Premium Tier, tiered by monthly volume and destination. Inbound is free. | $0.12/GiB for the first TiB from Singapore to most destinations (China and Australia cost more), then $0.11 and $0.085 | Applies to NAT egress (the `curl` tests) and to the load balancer's responses to clients. |
| Control plane connectivity (PSC endpoint, Konnectivity, DNS endpoint) | Included in the cluster fee; the GKE pricing page lists no separate charge. | $0 | `--no-enable-ip-access` and the control plane egress mode are free settings. |

## 4. Edge: Gateway, load balancer, TLS and WAF

Source: [Cloud Load Balancing pricing](https://cloud.google.com/vpc/network-pricing#lb), [Cloud Armor pricing](https://cloud.google.com/armor/pricing).

| Resource | Charging model and pricing factors | List price (asia-southeast1) | Workshop notes |
|---|---|---|---|
| Global external Application Load Balancer, created by the Gateway (Lab 04) | (1) **Forwarding rules**: one hourly charge covers the first 5 rules in the project, then per additional rule. (2) **Data processing**: per GiB inbound and per GiB outbound through the proxy, priced by the region where it is processed. (3) **Internet data transfer** for responses (section 3). | $0.025/hour for the first 5 rules, $0.01/hour each additional; $0.009/GiB inbound and $0.009/GiB outbound in Singapore | `external-gateway` creates 2 forwarding rules (HTTP :80 redirect, HTTPS :443): one $0.025/hour charge. Backend services, URL maps, target proxies, health checks, container-native NEGs and the Gateway controller cost nothing. |
| TLS certificate and SSL policy (Lab 04) | A self-managed certificate uploaded from a Kubernetes Secret becomes a classic Compute Engine SSL certificate: no charge. SSL policies: no charge. | $0 | If you switch to **Certificate Manager** (Google-managed certificates), the first 100 certificates are free, then $0.20 per certificate per month. |
| Cloud Armor Standard security policy (Labs 04, 06) | Pay as you go: (1) per security policy per month; (2) per rule per month; (3) per million requests evaluated by a policy attached to a backend; (4) **preconfigured WAF rules (Managed Rules)**: an additional per-million-requests charge. All prorated hourly. Adaptive Protection basic alerts, verbose logging and JSON parsing add nothing in the Standard tier. | $5/policy-month ($0.006849/hour); $1/rule-month ($0.001370/hour); $0.75 per million requests; Managed Rules +$0.75 per million requests | One policy, 7 WAF rules from Lab 04 plus the throttle rule `2000` from Lab 06 (the temporary rule `900` is deleted again). **Cloud Armor Enterprise** (full Adaptive Protection, named IP lists, DDoS response) is a separate subscription, $200/month pay-as-you-go plus data processing; the workshop doesn't enroll. Cloud Armor's request logs are load balancer logs, billed by Cloud Logging. |

## 5. Security and supply chain

Source: [Artifact Registry pricing](https://cloud.google.com/artifact-registry/pricing), [Artifact Analysis pricing](https://cloud.google.com/artifact-analysis/pricing), [Cloud Build pricing](https://cloud.google.com/build/pricing), [Cloud KMS pricing](https://cloud.google.com/kms/pricing), [Secret Manager pricing](https://cloud.google.com/secret-manager/pricing), [Binary Authorization pricing](https://cloud.google.com/binary-authorization/pricing).

| Resource | Charging model and pricing factors | List price | Workshop notes |
|---|---|---|---|
| Artifact Registry repository (Lab 02) | Storage per GiB-month after a free allotment **per billing account**; data transfer per GiB when images leave the repository's location. Transfer within the same region is free. | $0.10/GiB-month after the first 0.5 GiB; same-region pulls $0 | 14 images, roughly 1-2 GiB. Nodes pull from the same region, so pulls are free. `--immutable-tags` is free. |
| Artifact Analysis vulnerability scanning (Labs 02, 06) | Per container image scanned when automatic scanning is on (the repository was created with `--allow-vulnerability-scanning`). Continuous re-analysis of already-scanned images has no separate charge on the pricing page. | $0.26 per image | 14 images → $3.64, once. `mirror-images.sh` skips images that already exist, so re-running it doesn't scan again. Security Command Center customers are billed differently. |
| Cloud Build image mirror job (Lab 02) | Per build-minute of the worker machine type, while the build runs (queue time is free), with a monthly free allotment **per billing account** for `e2-standard-2` in the default pool. Logs go to Cloud Logging (`CLOUD_LOGGING_ONLY`); `--no-source` means no Cloud Storage bucket. | `e2-standard-2` $0.006/minute after 2,500 free build-minutes per month | One build of 1-3 minutes runs the 14 copy steps in parallel: free. Pulling from `mirror.gcr.io` and the public Artifact Registry source costs nothing extra. |
| Cloud KMS key for Secrets encryption (Labs 02, 03) | (1) Per **active key version** per month, prorated. A version is active while **enabled, disabled, or scheduled for destruction**; only destroyed versions are free. (2) Cryptographic operations (encrypt, decrypt) per 10,000. Admin operations are free. | $0.06 per version-month (software key); $0.03 per 10,000 operations | One version now; the 90-day rotation adds a version each time, and old versions keep billing until you destroy them. GKE calls Encrypt/Decrypt when Secrets are written or read; the volume is small. **After the cleanup, the destroyed versions still bill for the 30-day destruction delay** (unless you delete the project). |
| Secret Manager (Lab 05) | (1) Per active secret version **per replica location** per month; (2) access operations per 10,000; (3) rotation notifications (Pub/Sub) each. Free allotments per billing account per month: 6 active versions, 10,000 accesses, 3 rotation notifications. Management operations are free. | $0.06 per version-location-month; $0.03 per 10,000 accesses; $0.05 per rotation notification | One secret, 2 versions, one location (`user-managed`, `${REGION}`). The Secret Manager add-on re-reads the secret about every 2 minutes (≈720 accesses per day per mounted Pod). `--enable-secret-manager-rotation` is the add-on polling, not Secret Manager rotation notifications. All inside the free allotment for a two-day workshop. |
| Binary Authorization (Labs 03, 06) | Flat fee per cluster-hour with enforcement enabled, billed per second, independent of cluster size. Free credit of $12 per month per billing account, enough for one cluster. | $0.01613 per cluster-hour (≈ $12/month) | Policy evaluations, break-glass and audit entries add nothing. The project's policy itself is free. |
| Workload Identity Federation, IAM, service accounts, organization policies, Pod Security Admission, ValidatingAdmissionPolicy, RBAC, ResourceQuotas, LimitRanges, NetworkPolicies, FQDN network policies | No charge. | $0 | Dataplane V2 (Cilium) is part of GKE. |
| GKE security posture dashboard (`--security-posture=standard`) | Workload configuration auditing and security bulletin surfacing: no extra charge. Findings written to Cloud Logging count as standard logs. | $0 | The retired "advanced vulnerability insights" tier is not used. |
| Policy Controller, Config Sync (Lab 06 bonus) | Included with GKE, as noted in Lab 06; fleet registration is free. | $0 | Optional. |

## 6. Observability: logs, metrics, alerts, audit

Source: [Google Cloud Observability pricing](https://cloud.google.com/stackdriver/pricing), [GKE metrics packages](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-metrics).

### Cloud Logging

| Log stream in this workshop | Class | Charging model | List price |
|---|---|---|---|
| GKE system and workload logs, API server / scheduler / controller-manager logs, Kubernetes events, network policy logs (`policy-action`), load balancer and Cloud Armor logs, Cloud Build logs, security posture findings | Standard logs | **Storage (ingestion)**: per GiB streamed into the `_Default` bucket or a user-defined bucket, measured before indexing. Includes 30 days of retention. Querying is free. | $0.50/GiB after the first **50 GiB per project per month** |
| Firewall Rules Logging, Cloud NAT logs, VPC Flow Logs | **Vended network logs** | Same storage meter at a lower rate, **no free allotment**, on top of the Network Telemetry generation fee (section 3). | $0.25/GiB |
| Admin Activity and System Event audit logs | `_Required` bucket | Free, 400-day retention, can't be changed. | $0 |
| Data Access audit logs (Lab 08: Secret Manager, Cloud KMS, and the GKE API including every Kubernetes `get`/`list`/`watch`) | Standard logs | Written to `_Default`: billed like other standard logs. The Kubernetes API stream is the largest log source in the workshop once enabled. | $0.50/GiB after the free 50 GiB |
| Copies in the audit log bucket (`${AUDIT_BUCKET}`, Lab 08) | User-defined bucket | **Each bucket a log entry is routed to is charged separately.** The sink copies every audit log, so Data Access entries are stored (and billed) twice, and Admin Activity entries, free in `_Required`, are billed in the copy. | $0.50/GiB after the free 50 GiB |
| Retention beyond 30 days | `_Default` and user buckets | Per GiB per month for logs kept longer than 30 days. The audit bucket keeps logs for 365 days. `_Required` is exempt. | $0.01/GiB-month |
| Log Router, sinks, exclusions, Log Analytics, Logs Explorer, `gcloud logging read` | — | No charge. | $0 |

### Cloud Monitoring and Managed Service for Prometheus

| Metric source in this workshop | Charging model | List price |
|---|---|---|
| GKE system metrics (`kubernetes.io/...`: node, Pod and container CPU, memory, disk, network) | **Free.** Cloud Monitoring doesn't charge for GKE system metrics. | $0 |
| Observability packages enabled with `--monitoring` (API server, scheduler, controller manager, kube-state: Pod, Deployment, StatefulSet, DaemonSet, HPA, storage; cAdvisor and kubelet) and Dataplane V2 metrics (`--enable-dataplane-v2-metrics`) | Ingested through **Managed Service for Prometheus** and billed **per sample ingested**, counted per billing account. No free allotment. Any `PodMonitoring` you add is billed the same way. | $0.06 per million samples for the first 50 billion per month, then $0.048, $0.036, $0.024 |
| Other custom or agent metrics (not used) | Per MiB ingested after 150 MiB free per billing account. | $0.2580/MiB |
| Alerting policies (Lab 08: two log-based, one PromQL) | **No charge today.** Google has announced alerting pricing starting **no sooner than 2027-09-01**: $0.35 per month per metric reference in a policy plus $0.50 per million points returned by metric conditions. Log-match conditions count as one metric reference. | $0 now |
| Notification channels (email) | No charge. | $0 |
| Monitoring read API calls (the `promql()` helper in Lab 08 calls the Prometheus API from Cloud Shell) | Per million time series returned, after 1 million free per billing account per month. Reads from the console (Metrics Explorer, dashboards) are free; reads from Cloud Shell are API calls. | $0.50 per million time series |
| Dashboards, Metrics Explorer, Hubble (`hubble observe`, Hubble Relay) | No charge. Hubble runs on your nodes. | $0 |

## 7. Day-2 operations

Source: [Backup for GKE pricing](https://cloud.google.com/kubernetes-engine/pricing#backup-for-gke), [Pub/Sub pricing](https://cloud.google.com/pubsub/pricing).

| Resource | Charging model and pricing factors | List price (asia-southeast1) | Workshop notes |
|---|---|---|---|
| Backup for GKE (Lab 09) | (1) **Management fee per protected non-system namespace** per backup plan, hourly, from the moment the plan exists. (2) **Backup storage** per GiB-month. Enabling the add-on, restore plans and restores add nothing; cross-region backup storage would add inter-region data transfer. | $0.012328767 per namespace-hour (= $9/month); $0.045/GiB-month | One plan protecting `onlineboutique` → $0.30/day while the plan exists. The backup holds Kubernetes resources and Secrets only (no volumes exist), so storage is a few MiB. |
| Pub/Sub cluster notifications (Lab 09) | Message delivery per TiB after a free allotment; topics and subscriptions are free; backlog storage per GiB-month. | $40/TiB after the first 10 GiB per month | A handful of messages: $0. |
| Maintenance windows, exclusions, release channel, surge or blue-green settings, PodDisruptionBudgets | Configuration only: no charge. Blue-green upgrades double the node count during an upgrade. | $0 | An automatic upgrade can only start in the weekend window. |
| Node pool migration (Lab 09) | Covered in section 2: two pools at once. | — | About 30-60 minutes of overlap: ≈ $0.50/hour extra. |

## 8. Things that look like they should cost something but don't

- Cloud Shell, the Cloud Shell editor and its 5 GB home directory.
- Enabling APIs, organization policy reads, IAM bindings, service accounts, Workload Identity Federation.
- VPC, subnets, routes, Cloud Router, Private Google Access, VPC firewall rules, Cloud NGFW Essentials rules, the firewall policy object and its association.
- GKE control plane HA (3 replicas), DNS endpoint, Private Service Connect, Dataplane V2, Shielded nodes, Workload Identity, Gateway API controller, Secret Manager add-on, Managed Prometheus collectors, Hubble, NodeLocal DNSCache, cluster autoscaler, HPA, VPA, cost allocation.
- Load balancer internals: backend services, health checks, NEGs, URL maps, proxies, self-managed SSL certificates, SSL policies.
- Kubernetes objects: namespaces, quotas, LimitRanges, RBAC, Pod Security Admission, ValidatingAdmissionPolicy, NetworkPolicies, FQDN network policies, PDBs.
- Admin Activity audit logs in `_Required`, Logs Explorer queries, Log Router, dashboards, alerting policies (until at least September 2027).
- Backup for GKE restores, the Binary Authorization policy document, Artifact Registry same-region pulls.

## 9. Cost traps specific to this workshop

1. **Not running the cleanup.** About $17 per day accrues while the platform idles; a cluster left at its 9-node autoscaling maximum costs about $42 per day.
2. **Kubernetes API Data Access logs (Lab 08).** Every `get`, `list` and `watch` by every controller is logged, then copied to the audit bucket. Fine for the last hours of a 3-node workshop, gigabytes per day on a busy production cluster. Lab 08 and the cleanup turn them off again.
3. **Network logs at full volume.** NAT `--log-filter=ALL`, firewall logging on both rules and 50% flow-log sampling each pay generation plus storage with no free allotment. Negligible here; expensive on busy VPCs.
4. **Leftovers after a partial cleanup.** Unattached static IPs ($0.011/hour each), a Backup for GKE plan ($9/month), the Cloud Armor policy and rules ($13/month), Artifact Registry images, and KMS key versions, which bill until the 30-day destruction delay ends. Deleting the project (cleanup option A) stops all of them.
5. **Shared billing accounts.** Twenty participants on one billing account share one 50 GiB Logging allotment, one 0.5 GiB Artifact Registry allotment, one 2,500-minute Cloud Build allotment and one $12 Binary Authorization credit, and GKE's $74.40 credit doesn't apply to regional clusters at all.

## 10. Check your own numbers

Billing data lags by several hours. To see the real cost of your run:

1. **Billing > Reports**, filter by project and group by SKU. The SKU names in this document match the report (for example `Regional Kubernetes Clusters`, `Networking Cloud Nat Gateway Uptime`, `Networking Telemetry`, `Vended Logs Storage`, `Prometheus Samples Ingested`, `Container Images Scanned`).
2. Node VMs and disks carry the cluster labels you set in Lab 03 (`env=workshop`, `owner=${PREFIX}`) plus GKE's `goog-k8s-cluster-name`, so **group by label** to separate participants in a shared project.
3. With `--enable-cost-allocation` and [billing export to BigQuery](https://cloud.google.com/billing/docs/how-to/export-data-bigquery), node cost is split by namespace and Kubernetes label (Lab 07).
4. Metrics volume: **Monitoring > Metrics management** lists samples ingested per metric. Logs volume: **Logging > Log storage** shows ingestion per bucket.
5. For a forecast, the [Pricing Calculator](https://cloud.google.com/products/calculator) uses the same list prices as this document.
