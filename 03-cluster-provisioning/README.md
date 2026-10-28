# Lab 03 - Cluster Provisioning

In this lab you create the production GKE cluster with a single `gcloud` command. Every flag is explained, so you know **why** each setting exists and could reproduce it in any Infrastructure-as-Code tool. (A Terraform equivalent is available in the [Terraform appendix](../appendix-terraform/README.md).)

The cluster is a **regional GKE Standard** cluster:

- **High availability:** three control plane replicas and nodes spread over three zones (99.95% control plane SLA).
- **Private:** nodes have no external IP addresses, and the control plane has **no IP endpoints at all**. It is reachable only through an IAM-protected DNS endpoint.
- **Hardened:** least-privilege node identity, Shielded nodes with Secure Boot, Workload Identity Federation, CMEK-encrypted Secrets, Binary Authorization, and Dataplane V2 (eBPF) with network policy enforcement and observability.
- **Observable and cost-aware:** system, workload and control plane logs; managed Prometheus metrics; cost allocation; and vertical Pod autoscaling.

**Estimated time:** 45 minutes (cluster creation takes 10-15 minutes)

> [!NOTE]
> Run `source ./env.sh` first if you opened a new Cloud Shell session.

## 1. Pick the Kubernetes version (release channel)

Production clusters should be enrolled in a **release channel** so that Google keeps the control plane and nodes patched. Channels trade freshness for maturity: `rapid`, `regular`, `stable` and `extended` (24-month support). This workshop uses **Regular**, the recommended channel for most production workloads.

```bash
gcloud container get-server-config \
  --location="${REGION}" \
  --flatten="channels" \
  --filter="channels.channel=REGULAR" \
  --format="yaml(channels.channel,channels.defaultVersion)"
```

New clusters get the channel's default version, so you don't pin a version in the create command.

## 2. Create the cluster

Run the command below. It returns after about 10-15 minutes, while GKE provisions the regional control plane and three nodes.

```bash
gcloud container clusters create "${CLUSTER_NAME}" \
  --location="${REGION}" \
  --release-channel=regular \
  --patch-update=accelerated \
  --network="${VPC_NAME}" \
  --subnetwork="${SUBNET_NAME}" \
  --enable-ip-alias \
  --cluster-secondary-range-name="${PODS_RANGE_NAME}" \
  --services-secondary-range-name="${SERVICES_RANGE_NAME}" \
  --enable-private-nodes \
  --disable-default-snat \
  --enable-dns-access \
  --no-enable-ip-access \
  --enable-dataplane-v2 \
  --enable-dataplane-v2-metrics \
  --enable-dataplane-v2-flow-observability \
  --enable-fqdn-network-policy \
  --workload-pool="${PROJECT_ID}.svc.id.goog" \
  --service-account="${NODE_SA_EMAIL}" \
  --image-type=COS_CONTAINERD \
  --machine-type=e2-standard-4 \
  --disk-type=pd-balanced \
  --disk-size=50 \
  --num-nodes=1 \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=3 \
  --location-policy=BALANCED \
  --max-surge-upgrade=1 \
  --max-unavailable-upgrade=0 \
  --enable-autorepair \
  --enable-autoupgrade \
  --enable-shielded-nodes \
  --shielded-secure-boot \
  --shielded-integrity-monitoring \
  --no-enable-insecure-kubelet-readonly-port \
  --anonymous-authentication-config=LIMITED \
  --database-encryption-key="${KMS_KEY_ID}" \
  --binauthz-evaluation-mode=PROJECT_SINGLETON_POLICY_ENFORCE \
  --security-posture=standard \
  --enable-secret-manager \
  --enable-secret-manager-rotation \
  --gateway-api=standard \
  --logging=SYSTEM,WORKLOAD,API_SERVER,SCHEDULER,CONTROLLER_MANAGER \
  --monitoring=SYSTEM,API_SERVER,SCHEDULER,CONTROLLER_MANAGER,STORAGE,POD,DEPLOYMENT,STATEFULSET,DAEMONSET,HPA,CADVISOR,KUBELET \
  --enable-managed-prometheus \
  --enable-vertical-pod-autoscaling \
  --enable-cost-allocation \
  --maintenance-window-start="2026-01-03T18:00:00Z" \
  --maintenance-window-end="2026-01-04T00:00:00Z" \
  --maintenance-window-recurrence="FREQ=WEEKLY;BYDAY=SA,SU" \
  --labels="env=workshop,owner=${PREFIX}"
```

While you wait, read what each group of flags does:

| Area | Flags | Why |
|---|---|---|
| Availability | `--location=${REGION}` | A **regional** cluster runs the control plane in three zones and spreads nodes across them, so it survives a zone outage. |
| Upgrades | `--release-channel=regular`, `--patch-update=accelerated` | Google keeps the cluster on supported versions. Accelerated patching applies **security patches** as soon as they are available in the channel. |
| | `--maintenance-window-*` | Automatic upgrades only happen during your window: Saturday and Sunday, 18:00-24:00 UTC (02:00-08:00 Singapore time). |
| Networking | `--network`, `--subnetwork`, `--enable-ip-alias`, `--cluster-secondary-range-name`, `--services-secondary-range-name` | VPC-native cluster that uses the ranges you planned in Lab 02. Pods get routable VPC IPs, which container-native load balancing (Lab 04) relies on. |
| Private nodes | `--enable-private-nodes` | Nodes get only internal IPs, so they are unreachable from the internet. (Many organizations enforce this with the `compute.vmExternalIpAccess` [organization policy](../01-cluster-design/SecurityDesign.md#organization-guardrails), so a cluster with public nodes would fail to create.) Outbound internet goes through Cloud NAT and the firewall policy from Lab 02. |
| | `--disable-default-snat` | Nodes no longer masquerade Pod traffic behind their own IP before it leaves. Cloud NAT translates the **Pod IP** directly (the NAT from Lab 02 already covers the Pod range), so firewall and NAT logs show which Pod made a connection, and there is one translation instead of two. Google's networking best practices recommend this for private VPC-native clusters whose Pod range is already routable, as here. |
| Control plane access | `--enable-dns-access`, `--no-enable-ip-access` | The API server is reachable **only** through a DNS-based endpoint (`*.gke.goog`). Every request is authenticated and authorized by IAM, so you need no bastion host or authorized-networks maintenance. The IP-based endpoints (internal and external) are disabled. This is the current GKE hardening recommendation. |
| Dataplane | `--enable-dataplane-v2` | eBPF (Cilium-based) dataplane with **built-in NetworkPolicy enforcement and logging**, so you don't pass `--enable-network-policy`. |
| | `--enable-dataplane-v2-metrics`, `--enable-dataplane-v2-flow-observability` | Network flow metrics and Hubble-based flow visibility (Lab 08). |
| | `--enable-fqdn-network-policy` | Pod-level egress control by domain name (Lab 06). |
| Workload identity | `--workload-pool=${PROJECT_ID}.svc.id.goog` | **Workload Identity Federation for GKE.** Pods authenticate to Google Cloud as their Kubernetes service account, with no keys. This also hides the node's metadata server from Pods. |
| Node identity | `--service-account=${NODE_SA_EMAIL}` | The least-privilege node service account from Lab 02, instead of the Compute Engine default service account. |
| Node hardening | `--image-type=COS_CONTAINERD` | Container-Optimized OS: a minimal, read-only root file system hardened by Google. |
| | `--enable-shielded-nodes`, `--shielded-secure-boot`, `--shielded-integrity-monitoring` | Verifiable node identity, signed boot chain and boot-integrity attestation. Your organization may also enforce the `compute.requireShieldedVm` [organization policy](../01-cluster-design/SecurityDesign.md#organization-guardrails). |
| | `--no-enable-insecure-kubelet-readonly-port` | Disables the unauthenticated kubelet port 10255. This is the default since 1.32; it is set explicitly here so you know about it. |
| Node pool sizing | `--machine-type=e2-standard-4`, `--disk-type=pd-balanced`, `--disk-size=50` | General-purpose 4 vCPU / 16 GB nodes with SSD-backed boot disks. |
| | `--num-nodes=1`, `--enable-autoscaling`, `--min-nodes=1`, `--max-nodes=3`, `--location-policy=BALANCED` | Values are **per zone**: the cluster starts with 3 nodes and the cluster autoscaler can grow it to 9, keeping zones balanced. In larger or multi-tenant clusters, pair a small system pool tainted with `components.gke.io/gke-managed-components=true:NoSchedule` with tainted application pools so `kube-dns`, `konnectivity-agent` and metrics agents are isolated from app workloads ([Lab 01, Nodes](../01-cluster-design/README.md#5-nodes)). |
| Node lifecycle | `--max-surge-upgrade=1`, `--max-unavailable-upgrade=0` | Surge upgrades add a new node before removing an old one, so capacity never drops during upgrades. |
| | `--enable-autorepair`, `--enable-autoupgrade` | Unhealthy nodes are recreated automatically, and nodes follow the control plane version. |
| API server authentication | `--anonymous-authentication-config=LIMITED` | Anonymous requests can reach only `/healthz`, `/livez` and `/readyz`. This is the default for new clusters since 1.35. |
| Data protection | `--database-encryption-key=${KMS_KEY_ID}` | Application-layer encryption of Kubernetes Secrets with **your** Cloud KMS key. |
| Supply chain | `--binauthz-evaluation-mode=PROJECT_SINGLETON_POLICY_ENFORCE` | Enforces the project's Binary Authorization policy at deploy time. The policy still allows everything at this point; you restrict it to your registry in Lab 06. |
| Security posture | `--security-posture=standard` | Continuously audits workloads for risky configurations and shows the results in the GKE security posture dashboard. |
| Secrets | `--enable-secret-manager`, `--enable-secret-manager-rotation` | Managed Secret Manager CSI driver: mounts secrets from Secret Manager as files and refreshes them when they change (Lab 05). |
| Ingress | `--gateway-api=standard` | Installs the Gateway API CRDs and enables the GKE Gateway controller (Lab 04). |
| Observability | `--logging=...` | System and workload logs, plus API server, scheduler and controller-manager logs. |
| | `--monitoring=...`, `--enable-managed-prometheus` | System metrics, plus control plane, kube-state, storage and cAdvisor/kubelet metrics through Google Cloud Managed Service for Prometheus. |
| Cost | `--enable-vertical-pod-autoscaling`, `--enable-cost-allocation`, `--labels` | Right-sizing recommendations, and cost broken down by namespace and label in billing data (Lab 07). |

> [!NOTE]
> **Flags you will *not* find here**, and why:
> - `--enable-network-policy`: Dataplane V2 already enforces NetworkPolicy.
> - `--master-ipv4-cidr`: belongs to the legacy VPC-peering private cluster model. Clusters now use Private Service Connect automatically.
> - `--enable-master-authorized-networks`: there is no IP endpoint left to protect.
> - `--workload-vulnerability-scanning`: GKE's built-in vulnerability scanning has been retired. Images are scanned by Artifact Analysis instead (Lab 02 and Lab 06).
> - `--control-plane-egress=NONE`: blocks all outbound traffic from the API server, including its calls to Google APIs. GKE enforces Binary Authorization through an admission webhook that calls the Binary Authorization service, and that webhook **fails open**: with egress blocked, every image is admitted and the only trace is a `failed-open.validating.webhook.admission.k8s.io` label on the Pod's audit log entry. The cluster keeps the default egress mode (`VIA_CONTROL_PLANE`) so that Binary Authorization (Lab 06) works. Inbound access is unaffected: the IP endpoints stay disabled. See [control plane protection](../01-cluster-design/SecurityDesign.md#control-plane-protection).

> [!TIP]
> **Autopilot** clusters apply most of these settings automatically and are Google's recommended mode for many teams. This workshop uses Standard mode so that you see, and decide on, every production setting yourself.

## 3. Connect to the cluster through the DNS endpoint

`get-credentials` writes a kubeconfig entry that points at the DNS-based endpoint. Your identity is checked by IAM, through the `container.clusters.connect` permission, on every request.

```bash
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --location="${REGION}" \
  --dns-endpoint
```

Look at the server address: it is a `gke.goog` host name, not an IP address.

```bash
kubectl config view --minify --output="jsonpath={.clusters[0].cluster.server}{'\n'}"
```

```bash
kubectl get nodes -o wide
```

There are three nodes, one per zone. The `EXTERNAL-IP` column shows `<none>`:

```text
NAME                                         STATUS   ROLES    AGE   VERSION               INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                             ...
gke-gkews-cluster-default-pool-xxxxxxxx-xxxx   Ready    <none>   5m    v1.36.x-gke.xxxxxxx   10.10.0.x     <none>        Container-Optimized OS from Google   ...
```

> [!TIP]
> If `kubectl` ever answers `You must be logged in to the server` while `gcloud` still works, see [Troubleshooting](../README.md#troubleshooting).

## 4. Verify the security configuration

Inspect the control plane access configuration. The DNS endpoint is enabled, the IP endpoints are disabled, and the egress mode is the default `VIA_CONTROL_PLANE` (see the note above):

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" \
  --format="yaml(controlPlaneEndpointsConfig,controlPlaneEgress)"
```

Inspect the other hardening settings:

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" \
  --format="yaml(releaseChannel,databaseEncryption,workloadIdentityConfig,binaryAuthorization,securityPostureConfig,networkConfig.datapathProvider,networkConfig.defaultSnatStatus,secretManagerConfig,nodeConfig.serviceAccount,nodeConfig.shieldedInstanceConfig,nodeConfig.imageType)"
```

Confirm that the node VMs have no external IP address (the `EXTERNAL_IP` column is empty):

```bash
gcloud compute instances list \
  --filter="name~^gke-${CLUSTER_NAME}" \
  --format="table(name,zone.basename(),networkInterfaces[0].networkIP:label=INTERNAL_IP,networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP,shieldedInstanceConfig.enableSecureBoot:label=SECURE_BOOT)"
```

## 5. See what GKE created for you

GKE adds a few **VPC firewall rules** to your network:

- `gke-...-all`: allows traffic from the Pod range.
- `gke-...-vms`: allows traffic from the node range.

There is no rule for the control plane: it reaches the nodes through Private Service Connect and the Konnectivity tunnel. Rules for load balancer health checks are added later, when you create the Gateway (Lab 04). Your egress firewall policy from Lab 02 is evaluated **before** these rules, because you set the VPC's enforcement order to `BEFORE_CLASSIC_FIREWALL`: a VPC firewall rule can't open an egress path that the policy denies.

```bash
gcloud compute firewall-rules list \
  --filter="network~${VPC_NAME}" \
  --format="table(name,direction,sourceRanges.list():label=SOURCES,allowed[].map().firewall_rule().list():label=ALLOW)"
```

The managed add-ons you enabled run as system workloads. List the DaemonSets that actually run Pods (GKE ships extra variants, for example for GPUs, that stay at zero) and the Deployments:

```bash
kubectl get daemonsets -n kube-system | awk 'NR==1 || $2 > 0'
kubectl get deployments -n kube-system
```

```bash
kubectl get namespaces
```

The Gateway controller installs its GatewayClasses a few minutes after cluster creation. Wait for them, then list them:

```bash
until kubectl get gatewayclass gke-l7-global-external-managed >/dev/null 2>&1; do echo "Waiting for GatewayClasses..."; sleep 15; done
kubectl get gatewayclasses
```

Some components to recognize:

| Component | What it is |
|---|---|
| `anetd` | GKE Dataplane V2: eBPF networking and network policy enforcement |
| `gke-metadata-server` | Workload Identity Federation metadata server on every node |
| `csi-secrets-store-gke`, `csi-secrets-store-provider-gke` | Secret Manager add-on (CSI driver and Secret Manager provider) |
| `node-local-dns` | NodeLocal DNSCache, enabled by default since GKE 1.34. Dataplane V2 redirects each Pod's DNS queries to the cache on the same node, so DNS network policies must allow these Pods as well as `kube-dns` (see Lab 04). |
| `konnectivity-agent` | Secure tunnel that the control plane uses to reach nodes (for example for `kubectl exec` and `logs`) |
| `fluentbit-gke`, `gke-metrics-agent` | Ship logs and system metrics to Cloud Logging and Cloud Monitoring |
| `gmp-system` namespace | Google Cloud Managed Service for Prometheus collectors |
| `gke-managed-dpv2-observability` namespace | Hubble relay for Dataplane V2 flow observability |
| `gke-l7-global-external-managed` GatewayClass | Global external Application Load Balancer, used in Lab 04 |

> [!NOTE]
> In the `describe` output above, `securityPostureConfig.mode: BASIC` is the API name of the **standard** security posture tier you requested.

## Next Steps

[Lab 04 - Post-Provisioning](../04-cluster-post-provisioning/README.md)

## Key Links

- [Best practices for hardening your cluster](https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster)
- [About network isolation in GKE](https://cloud.google.com/kubernetes-engine/docs/concepts/network-isolation) and [Customize network isolation](https://cloud.google.com/kubernetes-engine/docs/how-to/latest/network-isolation)
- [Restrict egress traffic from the API server](https://cloud.google.com/kubernetes-engine/networking/docs/restrict-egress-control-plane)
- [Release channels](https://cloud.google.com/kubernetes-engine/docs/concepts/release-channels) and [maintenance windows and exclusions](https://cloud.google.com/kubernetes-engine/docs/concepts/maintenance-windows-and-exclusions)
- [GKE Dataplane V2](https://cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2)
- [IP masquerade agent and default SNAT](https://cloud.google.com/kubernetes-engine/docs/concepts/ip-masquerade-agent) and [best practices for GKE networking](https://cloud.google.com/kubernetes-engine/docs/best-practices/networking)
- [`gcloud container clusters create` reference](https://cloud.google.com/sdk/gcloud/reference/container/clusters/create)
