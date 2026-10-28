# Lab 01 - Cluster Design

Before a single resource is created, a production cluster needs a set of design decisions. This lab is a guided discussion of those decisions and the trade-offs behind them. Each topic ends with the choice this workshop makes, so the following labs implement a consistent design.

**Estimated time:** 45-60 minutes (discussion, no commands)

> Reference architecture: [GKE best practices](https://cloud.google.com/kubernetes-engine/docs/best-practices) and the [enterprise foundations blueprint](https://cloud.google.com/architecture/security-foundations).

## 1. How many clusters and environments?

A few large clusters are easier to operate and use resources more efficiently. Many small clusters give stronger isolation and smaller blast radius. Common patterns are one cluster per environment (dev, staging, prod) per region, with teams separated by **namespaces** inside each cluster.

- [Guidance on the number of clusters](https://learnk8s.io/how-many-clusters)
- [Guidance on node sizing](https://learnk8s.io/kubernetes-node-size)
- [GKE enterprise multi-tenancy best practices](https://cloud.google.com/kubernetes-engine/docs/best-practices/enterprise-multitenancy)

**Workshop choice:** one production cluster. Teams are isolated by namespace with RBAC, quotas, Pod Security and network policies.

## 2. Autopilot or Standard?

| | Autopilot | Standard |
|---|---|---|
| Nodes | Managed by Google, billed per Pod resource request | You manage node pools, billed per node VM |
| Security defaults | Hardened by default (Workload Identity, Shielded nodes, no privileged Pods, and more) | You choose and configure every setting |
| Flexibility | Some node-level customizations are not available | Full control: machine types, node images, kernel settings, GPUs/TPUs, DaemonSets |
| Best for | Most teams that want Kubernetes without node operations | Teams that need node-level control, or want to learn every knob |

Google recommends **Autopilot** for most workloads. This workshop uses **Standard**, because the goal is to understand, decide on and configure every production setting yourself. Many of the flags in Lab 03 are things Autopilot sets for you.

**Workshop choice:** GKE Standard.

## 3. Zonal or regional?

| | Zonal cluster | Regional cluster |
|---|---|---|
| Control plane | 1 replica in 1 zone | 3 replicas in 3 zones |
| Control plane SLA | 99.5% | **99.95%** |
| Control plane upgrades | API unavailable during the upgrade | API stays available |
| Nodes | One zone by default | Spread across three zones |

A regional cluster spreads its **nodes** across zones, but not automatically your **Pods**. The scheduler's built-in spreading is only a soft preference, so two replicas of a service can end up in the same zone, and a zone outage then takes the service down. Production workloads therefore combine:

- **Several replicas** of every stateless service.
- **Topology spread constraints** that require the replicas to run in different zones (`topology.kubernetes.io/zone`) and prefer different nodes (`kubernetes.io/hostname`).
- **PodDisruptionBudgets**, so planned maintenance never evicts the last running replica.

**Workshop choice:** a regional cluster in `asia-southeast1`, with nodes in three zones. Every Online Boutique Deployment gets topology spread constraints (Lab 05); Lab 09 adds a second replica and PodDisruptionBudgets.

## 4. Versions and upgrades

GKE upgrades clusters automatically. Your job is to choose **how fast** and **when**:

- **Release channel:** `rapid` (newest), `regular` (recommended for most production clusters), `stable` (most mature) or `extended` (stay on a minor version for up to 24 months, with an extra fee during extended support).
- **Accelerated patch updates** (`--patch-update=accelerated`) apply security patches as soon as they reach your channel.
- **Maintenance windows** limit automatic upgrades to agreed times. **Maintenance exclusions** pause them, for example during a sales event.
- **Node pool upgrade strategy:** surge upgrades (rolling, with extra nodes) or blue-green upgrades (a full new set of nodes, with a soak time and fast rollback).

**Workshop choice:** Regular channel with accelerated patches, a weekend maintenance window, and surge upgrades with `maxSurge=1, maxUnavailable=0`. Blue-green and node pool migration are covered in Lab 09.

## 5. Nodes

- **Machine family:** general-purpose E2 (cost-optimized), N2/N4/C3/C4 (performance), and Spot VMs for fault-tolerant workloads (up to 91% cheaper, can be preempted).
- **Node image:** Container-Optimized OS (`COS_CONTAINERD`) is Google's hardened, minimal, read-only OS, and the recommended default.
- **Node identity:** a dedicated, least-privilege service account, never the Compute Engine default service account.
- **Scaling:** the cluster autoscaler adds and removes nodes. Node pools can also be created automatically (node auto-provisioning or custom compute classes).
- **System vs. application node pools:** in larger or multi-tenant clusters, [isolate GKE system workloads](https://cloud.google.com/kubernetes-engine/docs/how-to/isolate-workloads-dedicated-nodes) (`kube-dns`, `konnectivity-agent`, `metrics-server`, `gmp-operator`, `kube-state-metrics`, `hubble-relay`, `event-exporter-gke`, `l7-default-backend`) onto a dedicated system pool so noisy or untrusted application Pods can't starve cluster DNS, metrics or control-plane tunnels. Every GKE-managed Deployment and StatefulSet carries a built-in toleration for `components.gke.io/gke-managed-components` (newer GKE add-ons do **not** tolerate the legacy `CriticalAddonsOnly` taint), but **no** `nodeAffinity` for it. Isolating them therefore takes **both** pools working together:
  1. **System pool** (at least 1 node per zone = 3 nodes): taint with `--node-taints=components.gke.io/gke-managed-components=true:NoSchedule` so user Pods can't schedule there.
  2. **Application pool(s)**: taint with your own workload taint (for example `--node-taints=workload=apps:NoSchedule --node-labels=workload=apps`) and add the matching `tolerations` and `nodeSelector` to application manifests. Because GKE system Deployments don't tolerate `workload=apps:NoSchedule`, the scheduler places them on the system pool. (Node-level DaemonSets such as `anetd`, `fluentbit-gke`, `gke-metadata-server` and `pdcsi-node` tolerate all taints and still run on every node.)

**Workshop choice:** one `e2-standard-4` node pool with autoscaling from 1 to 3 nodes per zone, running Container-Optimized OS with Shielded nodes and Secure Boot under a custom service account. Using a single shared pool keeps the regional HA baseline at 3 nodes instead of 6 (3 system + 3 app) and avoids adding workload tolerations to every manifest in Labs 04-09. A tainted Spot pool is added temporarily in Lab 07, and a gVisor sandbox pool is shown in Lab 06.

## 6. Networking

How the cluster gets its IP addresses, who can reach the control plane, how traffic leaves and enters the cluster, how workloads are isolated from each other, and how VPC Service Controls stop data from leaving through Google APIs.

[Read the network design](NetworkDesign.md)

[Follow one request end to end: the ingress flow](IngressFlow.md)

## 7. Security

Organization guardrails, identity and access, node and control plane hardening, software supply chain, admission control, data protection and audit logging.

[Read the security design](SecurityDesign.md)

## 8. Secrets management

How applications get passwords, API keys and certificates without putting them in images, manifests or plain Kubernetes Secrets.

[Read the secrets management design](SecretManagement.md)

## Summary of design decisions

| Area | Decision |
|---|---|
| Organization | Organization policies as guardrails (for example no external IPs, Shielded VMs, no service account keys, GKE managed constraints); VPC Service Controls perimeter for regulated data (design only) |
| Cluster | Regional GKE Standard, Regular release channel, accelerated patches, weekend maintenance window |
| Availability | Replicas spread across zones and nodes with topology spread constraints, PodDisruptionBudgets, graceful shutdown |
| Network | Custom VPC, VPC-native cluster, private nodes, Cloud NAT with a static IP |
| Control plane access | DNS-based endpoint only (IAM-authorized), IP endpoints disabled |
| Egress | Cloud NGFW network firewall policy: FQDN allow-list, deny all other internet traffic. Per-workload FQDN network policies. |
| Ingress | Gateway API (global external Application Load Balancer), TLS 1.2+, HTTP-to-HTTPS redirect, Cloud Armor WAF |
| East-west | Dataplane V2 network policies, default deny per namespace, with logging |
| Identity | IAM for cluster access, Kubernetes RBAC per namespace, Workload Identity Federation for workloads |
| Nodes | Container-Optimized OS, Shielded nodes with Secure Boot, least-privilege service account, auto-upgrade and auto-repair |
| Supply chain | Artifact Registry with vulnerability scanning, Binary Authorization allow-list, pinned image tags |
| Admission | Pod Security Admission (restricted), ValidatingAdmissionPolicy guardrails |
| Data | Secret Manager add-on, application-layer secrets encryption with Cloud KMS |
| Operations | Cloud Logging and Monitoring, Managed Service for Prometheus, alerting, Backup for GKE, cost allocation |
| Audit | Admin Activity audit logs (always on, immutable), Data Access audit logs for Secret Manager and Cloud KMS, audit logs routed to a dedicated log bucket (in production: a central, locked bucket in a separate logging project) |

## Next Steps

[Lab 02 - Cluster Pre-Provisioning](../02-cluster-pre-provisioning/README.md)

## Key Links

- [GKE overview](https://cloud.google.com/kubernetes-engine/docs/concepts/kubernetes-engine-overview)
- [Compare Autopilot and Standard](https://cloud.google.com/kubernetes-engine/docs/resources/autopilot-standard-feature-comparison)
- [Regional clusters](https://cloud.google.com/kubernetes-engine/docs/concepts/regional-clusters)
- [Release channels](https://cloud.google.com/kubernetes-engine/docs/concepts/release-channels)
- [GKE pricing](https://cloud.google.com/kubernetes-engine/pricing)
