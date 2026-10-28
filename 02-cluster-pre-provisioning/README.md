# Lab 02 - Cluster Pre-Provisioning

This lab builds the foundation the cluster needs **before** it exists. Most organizations deploy GKE into a network that already has addressing, egress controls, encryption keys and an approved image registry. You will build exactly that, so the cluster is born into a locked-down environment (the "outside-in" approach of this workshop).

By the end of this lab you will have:

| Component | Purpose |
|---|---|
| Custom VPC, subnet and secondary ranges | IP plan for nodes, Pods and Services (VPC-native cluster) |
| Cloud Router and Cloud NAT with a static IP | Controlled outbound internet access for **private** nodes |
| Cloud NGFW network firewall policy | Egress allow-list of two domain names, `ifconfig.me` and `api.github.com` (`ALLOWED_EGRESS_FQDNS` in `env.sh`). All other internet traffic is denied and logged. |
| Least-privilege service accounts | Identities for the nodes (not the default Compute Engine SA) and for the build that copies the images |
| Cloud KMS key | Customer-managed key for application-layer encryption of Kubernetes Secrets in etcd |
| Artifact Registry repository and mirrored images | The only registry the cluster may pull from. Cloud Build copies the images in; they are scanned on push. |
| Global static IP | Stable public address for the Gateway (load balancer) |

**Estimated time:** 45-60 minutes

> [!NOTE]
> All commands are meant to be run in **Cloud Shell**, from the repository root, after `source ./env.sh`.
> If your Cloud Shell session restarts, `cd` back into the repository and run `source ./env.sh` again.

## 1. Prepare your Cloud Shell session

Open [Cloud Shell](https://shell.cloud.google.com/) and clone the workshop repository (skip this if you already did it from the main README):

```bash skip
git clone https://github.com/<your-org>/gke-production-cluster.git
cd gke-production-cluster
```

Edit `env.sh` and set `PROJECT_ID` (and optionally `PREFIX` and `REGION`). You can use the Cloud Shell editor (`cloudshell edit env.sh`) or `sed`:

```bash skip
sed -i 's/REPLACE_WITH_YOUR_PROJECT_ID/<your-project-id>/' env.sh
```

While the file is open, note `ALLOWED_EGRESS_FQDNS="ifconfig.me,api.github.com"`. These are the **only internet destinations** the cluster will be allowed to reach (step 7 builds the firewall rule from this variable). `ifconfig.me` echoes the caller's public IP address, which Lab 04 uses to prove that egress leaves through the Cloud NAT address; `api.github.com` stands in for a partner API. Keep both for the workshop.

Load the variables and point `gcloud` at your project:

```bash
source ./env.sh
gcloud config set project "${PROJECT_ID}"
gcloud config set compute/region "${REGION}"
```

## 2. Enable the required APIs

Every Google Cloud service used in the workshop is enabled up front. This takes 1-2 minutes.

```bash
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  orgpolicy.googleapis.com \
  artifactregistry.googleapis.com \
  containerscanning.googleapis.com \
  cloudbuild.googleapis.com \
  binaryauthorization.googleapis.com \
  secretmanager.googleapis.com \
  cloudkms.googleapis.com \
  containersecurity.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  dns.googleapis.com \
  gkebackup.googleapis.com \
  pubsub.googleapis.com
```

| API | Used for |
|---|---|
| `container` | Google Kubernetes Engine |
| `compute` | VPC, Cloud NAT, firewall policies, load balancers, Cloud Armor |
| `orgpolicy` | Read the organization policies that apply to your project (step 3) |
| `artifactregistry`, `containerscanning` | Private image registry and automatic vulnerability scanning |
| `cloudbuild` | Copies the workshop images into your registry (step 11) |
| `binaryauthorization` | Deploy-time image allow-listing (Lab 06) |
| `secretmanager`, `cloudkms` | Secret storage (Lab 05) and customer-managed encryption keys |
| `containersecurity` | GKE security posture dashboard (Lab 06) |
| `logging`, `monitoring` | Cloud Logging, Cloud Monitoring, Managed Service for Prometheus (Lab 08) |
| `dns` | Used by Cloud NGFW to resolve the FQDNs in firewall rules |
| `gkebackup`, `pubsub` | Backup for GKE and cluster notifications (Lab 09) |

## 3. Check prerequisites, quotas and organization policies

The script checks the required tools, your access to the project and the regional quotas the labs need (for example, enough E2 vCPUs for the node pool migration in Lab 09):

```bash
./scripts/check-prereqs.sh
```

Every line should show `[OK]`. If a quota check fails, request an increase in the console under **IAM & Admin > Quotas** or pick another `REGION`.

Next, look at the outermost guardrails: **organization policies**. Your organization's administrators set them, every project inherits them, and they apply even to project owners (see [Organization guardrails](../01-cluster-design/SecurityDesign.md#organization-guardrails)). Check which of the recommended constraints are in effect for your project. You only read them here; changing them requires a role on the organization.

```bash
for C in compute.vmExternalIpAccess compute.requireShieldedVm compute.skipDefaultNetworkCreation \
         iam.disableServiceAccountKeyCreation iam.automaticIamGrantsForDefaultServiceAccounts \
         iam.allowedPolicyMemberDomains gcp.resourceLocations \
         container.managed.enablePrivateNodes container.managed.enableControlPlaneDNSOnlyAccess \
         container.managed.restrictControlPlaneEgress; do
  RULES="$(gcloud org-policies describe "${C}" --project="${PROJECT_ID}" --effective --format=json \
    | jq -r '[.spec.rules[]? | if .enforce == true then "enforced" elif .enforce == false then "not enforced"
             elif .denyAll then "deny all" elif .allowAll then "allow all" else "restricted list" end] | join(", ")')"
  printf '%-52s %s\n' "${C}" "${RULES}"
done
```

The result depends on your organization, for example:

```text
compute.vmExternalIpAccess                           deny all
compute.requireShieldedVm                            enforced
compute.skipDefaultNetworkCreation                   enforced
iam.disableServiceAccountKeyCreation                 enforced
iam.automaticIamGrantsForDefaultServiceAccounts      enforced
iam.allowedPolicyMemberDomains                       restricted list
gcp.resourceLocations                                allow all
container.managed.enablePrivateNodes                 not enforced
container.managed.enableControlPlaneDNSOnlyAccess    not enforced
container.managed.restrictControlPlaneEgress         not enforced
```

The workshop's design complies with all of these constraints except the last one, so it works whether or not they are enforced. If `gcp.resourceLocations` shows a restricted list, make sure that your `REGION` is one of the allowed locations.

> [!WARNING]
> `container.managed.restrictControlPlaneEgress` must show `not enforced`. It requires `--control-plane-egress=NONE`, which blocks the API server's calls to Google APIs, including the Binary Authorization check that Lab 06 relies on (the check fails open, so every image would be admitted). If your organization enforces it, ask for an exception for the workshop project, or see the [security design](../01-cluster-design/SecurityDesign.md#organization-guardrails) for the alternative.

## 4. Create the service accounts

Production environments give every workload its **own identity**, with only the permissions it needs. You create two service accounts:

| Service account | Used by | Instead of |
|---|---|---|
| `${NODE_SA_NAME}` | The cluster's nodes: kubelet, logging and monitoring agents, image pulls | The **Compute Engine default service account**, which usually has the broad Editor role |
| `${MIRROR_SA_NAME}` | The Cloud Build job that copies the workshop images into your registry (step 11) | Cloud Build's default service account, which often has broad permissions |

```bash
gcloud iam service-accounts create "${NODE_SA_NAME}" \
  --display-name="GKE nodes for ${CLUSTER_NAME}"
gcloud iam service-accounts create "${MIRROR_SA_NAME}" \
  --display-name="Image mirror builds for ${CLUSTER_NAME}"
```

You grant their permissions in step 10, after the image repository exists.

> [!NOTE]
> IAM is **eventually consistent**: a new service account can take a minute or more to become usable everywhere. Granting it a role immediately after creating it can fail with `Service account ... does not exist`. Creating the accounts now and granting the roles a few steps later avoids this.
> Your applications never use these identities. They get their own identities through Workload Identity Federation for GKE (Lab 05).

## 5. Create the VPC network and subnet

You create a **custom-mode** VPC with one subnet for the cluster. A VPC-native GKE cluster takes its IP addresses from three ranges of that subnet:

| Range | CIDR | Used by | Sizing |
|---|---|---|---|
| Primary | `10.10.0.0/24` | Nodes, plus the control plane's private endpoint | 252 usable addresses |
| Secondary `pods` | `10.20.0.0/16` | Pods | GKE assigns a /24 per node (110 Pods max), so 256 nodes |
| Secondary `services` | `10.30.0.0/20` | ClusterIP Services | 4,096 Services |

```bash
gcloud compute networks create "${VPC_NAME}" \
  --subnet-mode=custom \
  --bgp-routing-mode=regional
```

The subnet also enables **Private Google Access** (private nodes reach Google APIs such as Artifact Registry without internet access) and **VPC Flow Logs** (network telemetry for troubleshooting and forensics):

```bash
gcloud compute networks subnets create "${SUBNET_NAME}" \
  --network="${VPC_NAME}" \
  --region="${REGION}" \
  --range="${SUBNET_RANGE}" \
  --secondary-range="${PODS_RANGE_NAME}=${PODS_RANGE},${SERVICES_RANGE_NAME}=${SERVICES_RANGE}" \
  --enable-private-ip-google-access \
  --enable-flow-logs \
  --logging-aggregation-interval=interval-5-sec \
  --logging-flow-sampling=0.5 \
  --logging-metadata=include-all
```

> [!TIP]
> In production, agree on these ranges with your network team. They must not overlap with on-premises or peered networks. GKE also supports non-RFC 1918 ranges (for example `100.64.0.0/10`) for Pods if private address space is scarce.

## 6. Create Cloud Router and Cloud NAT

The cluster's nodes will have **no external IP addresses** (private nodes). Cloud NAT gives them controlled outbound access to the internet, for example to call a partner API. A **reserved static IP** means partners can allow-list your egress address.

```bash
gcloud compute routers create "${ROUTER_NAME}" \
  --network="${VPC_NAME}" \
  --region="${REGION}"
```

```bash
gcloud compute addresses create "${NAT_IP_NAME}" \
  --region="${REGION}"
```

```bash
gcloud compute routers nats create "${NAT_NAME}" \
  --router="${ROUTER_NAME}" \
  --region="${REGION}" \
  --nat-external-ip-pool="${NAT_IP_NAME}" \
  --nat-custom-subnet-ip-ranges="${SUBNET_NAME}:ALL" \
  --no-enable-endpoint-independent-mapping \
  --enable-dynamic-port-allocation \
  --min-ports-per-vm=64 \
  --max-ports-per-vm=4096 \
  --enable-logging \
  --log-filter=ALL
```

| Flag | Why |
|---|---|
| `--nat-custom-subnet-ip-ranges=SUBNET:ALL` | NAT only this subnet's primary and secondary (Pod) ranges, not the whole VPC |
| `--enable-dynamic-port-allocation` | Nodes get more NAT ports when they need them. This avoids port exhaustion on busy nodes. |
| `--enable-logging --log-filter=ALL` | Log every translation. Useful in this workshop; in production you would usually log `ERRORS_ONLY`. |

## 7. Lock down egress with a firewall policy

A common way to control egress is to force all outbound traffic through a central firewall appliance with custom routes. On Google Cloud you get the same control with a **Cloud Next Generation Firewall (Cloud NGFW) network firewall policy** attached to the VPC. It is enforced on every VM's network interface, so no extra appliance or routing is needed.

The policy has two rules:

1. **Priority 1000: allow** HTTPS to an allow-list of internet domain names, using FQDN objects. The list is `${ALLOWED_EGRESS_FQDNS}` from `env.sh`: `ifconfig.me` (returns the caller's public IP; Lab 04 uses it to show the Cloud NAT address) and `api.github.com` (a stand-in for a partner API).
2. **Priority 2000: deny** all other traffic whose destination is **the internet**.

Check the list before you build the rule from it:

```bash
echo "${ALLOWED_EGRESS_FQDNS}"
```

```text
ifconfig.me,api.github.com
```

> [!IMPORTANT]
> Rule 2000 uses the `INTERNET` **destination network context**. Traffic from your nodes to **Google APIs** (Artifact Registry, Cloud Logging, Secret Manager and others, through Private Google Access) belongs to the `NON_INTERNET` context. It is therefore **not** blocked, so GKE keeps working while every other internet destination is denied. The flip side: a compromised Pod can still reach **any** Google API in **any** project, for example to upload data to a Cloud Storage bucket it controls (Lab 04, test 4, shows such a call succeeding). The firewall can't close that path; [VPC Service Controls](../01-cluster-design/NetworkDesign.md#do-you-need-to-stop-data-exfiltration-through-google-apis) can.

```bash
gcloud compute network-firewall-policies create "${FW_POLICY_NAME}" \
  --global \
  --description="Egress allow-list for ${CLUSTER_NAME}"
```

```bash
gcloud compute network-firewall-policies rules create 1000 \
  --firewall-policy="${FW_POLICY_NAME}" \
  --global-firewall-policy \
  --direction=EGRESS \
  --action=allow \
  --layer4-configs=tcp:443 \
  --dest-fqdns="${ALLOWED_EGRESS_FQDNS}" \
  --enable-logging \
  --description="Allow HTTPS to approved internet FQDNs"
```

```bash
gcloud compute network-firewall-policies rules create 2000 \
  --firewall-policy="${FW_POLICY_NAME}" \
  --global-firewall-policy \
  --direction=EGRESS \
  --action=deny \
  --layer4-configs=all \
  --dest-ip-ranges=0.0.0.0/0 \
  --dest-network-context=INTERNET \
  --enable-logging \
  --description="Deny all other internet egress"
```

Attach (associate) the policy to the VPC:

```bash
gcloud compute network-firewall-policies associations create \
  --firewall-policy="${FW_POLICY_NAME}" \
  --network="${VPC_NAME}" \
  --name="${FW_POLICY_NAME}-assoc" \
  --global-firewall-policy
```

Make the policy's deny rule final. By default a VPC evaluates its own **VPC firewall rules before** the network firewall policy (`AFTER_CLASSIC_FIREWALL`), so anyone who can create a VPC firewall rule could add an egress allow and bypass rule 2000. Switch the order so that the policy is evaluated first:

```bash
gcloud compute networks update "${VPC_NAME}" \
  --network-firewall-policy-enforcement-order=BEFORE_CLASSIC_FIREWALL
```

The evaluation order is now: hierarchical firewall policies (organization and folder, if any), then this network firewall policy, then VPC firewall rules. A rule in the policy that allows or denies a connection ends the evaluation; only connections the policy passes on (`goto_next`) are evaluated against the VPC firewall rules, including the ones GKE creates. GKE's own rules are ingress-only, so they are not affected.

> [!NOTE]
> There are no ingress rules to add. A new VPC denies all ingress by default. When the cluster is created, GKE adds only the VPC firewall rules it needs (control plane to nodes, Pod-to-Pod and load balancer health checks).
> FQDN objects are a **Cloud NGFW Standard** feature, billed per GB of evaluated internet traffic. The cost is negligible for this workshop.

## 8. Create a Cloud KMS key for Secrets encryption

GKE encrypts all data at rest by default. **Application-layer secrets encryption** adds a second layer: Kubernetes Secrets in the cluster database (etcd) are encrypted with a key **you** control in Cloud KMS. The key must be in the same region as the cluster.

```bash
gcloud kms keyrings create "${KMS_KEYRING}" \
  --location="${REGION}"
```

```bash
gcloud kms keys create "${KMS_KEY}" \
  --keyring="${KMS_KEYRING}" \
  --location="${REGION}" \
  --purpose=encryption \
  --rotation-period=90d \
  --next-rotation-time="$(date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ)"
```

The GKE service agent (a Google-managed identity in your project) needs permission to use the key. The first command ensures that the service agent exists:

```bash
gcloud beta services identity create \
  --service=container.googleapis.com \
  --project="${PROJECT_ID}"
```

```bash
gcloud kms keys add-iam-policy-binding "${KMS_KEY}" \
  --keyring="${KMS_KEYRING}" \
  --location="${REGION}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@container-engine-robot.iam.gserviceaccount.com" \
  --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
  --format=none
```

> [!WARNING]
> Key rings and keys cannot be deleted, only disabled or scheduled for destruction. Never destroy a key version that a running cluster still uses: the cluster can no longer read its Secrets.

## 9. Create the Artifact Registry repository

The cluster will only run images from **your** repository. With `containerscanning.googleapis.com` enabled, **Artifact Analysis** scans every image for known vulnerabilities when it is pushed. `--immutable-tags` prevents a tag, for example `v0.10.7`, from being silently overwritten.

```bash
gcloud artifacts repositories create "${AR_REPO}" \
  --repository-format=docker \
  --location="${REGION}" \
  --description="Approved images for ${CLUSTER_NAME}" \
  --immutable-tags \
  --allow-vulnerability-scanning
```

## 10. Grant the service accounts least-privilege access

Grant each service account from step 4 only the roles it needs, on the smallest possible scope. Access to the images is granted on **your repository only**, not on the whole project:

| Service account | Role | Scope | Allows |
|---|---|---|---|
| Nodes | `roles/container.defaultNodeServiceAccount` | Project | Writing logs and metrics: the minimum that a GKE node needs |
| Nodes | `roles/artifactregistry.reader` | Repository | Pulling images from `${AR_REPO}` |
| Image mirror | `roles/logging.logWriter` | Project | Writing the build's logs |
| Image mirror | `roles/artifactregistry.writer` | Repository | Pushing images to `${AR_REPO}` |

```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${NODE_SA_EMAIL}" \
  --role="roles/container.defaultNodeServiceAccount" \
  --condition=None \
  --format=none
gcloud artifacts repositories add-iam-policy-binding "${AR_REPO}" \
  --location="${REGION}" \
  --member="serviceAccount:${NODE_SA_EMAIL}" \
  --role="roles/artifactregistry.reader" \
  --format=none
```

```bash
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${MIRROR_SA_EMAIL}" \
  --role="roles/logging.logWriter" \
  --condition=None \
  --format=none
gcloud artifacts repositories add-iam-policy-binding "${AR_REPO}" \
  --location="${REGION}" \
  --member="serviceAccount:${MIRROR_SA_EMAIL}" \
  --role="roles/artifactregistry.writer" \
  --format=none
```

Check the result at both scopes:

```bash
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members~^serviceAccount:${PREFIX}-" \
  --format="table(bindings.members:label=MEMBER,bindings.role:label=ROLE)"
gcloud artifacts repositories get-iam-policy "${AR_REPO}" --location="${REGION}" \
  --flatten="bindings[].members" \
  --format="table(bindings.members:label=MEMBER,bindings.role:label=ROLE)"
```

Each service account has exactly one role at each scope:

```text
MEMBER                                                                  ROLE
serviceAccount:gkews-gke-nodes@<PROJECT_ID>.iam.gserviceaccount.com     roles/container.defaultNodeServiceAccount
serviceAccount:gkews-image-mirror@<PROJECT_ID>.iam.gserviceaccount.com  roles/logging.logWriter
MEMBER                                                                  ROLE
serviceAccount:gkews-gke-nodes@<PROJECT_ID>.iam.gserviceaccount.com     roles/artifactregistry.reader
serviceAccount:gkews-image-mirror@<PROJECT_ID>.iam.gserviceaccount.com  roles/artifactregistry.writer
```

## 11. Mirror the workshop images

Copy every image the workshop uses into your repository: 11 Online Boutique services, Redis, BusyBox and a small `curl` toolbox for testing. From now on, the cluster pulls images only from here.

The script doesn't download the images into Cloud Shell. It submits a **Cloud Build** job that copies all images in parallel inside Google's network, running as the image mirror service account, the way a CI pipeline would import approved images. Review the script first, then run it (usually 1-3 minutes):

```bash skip
cat scripts/mirror-images.sh
```

```bash
./scripts/mirror-images.sh
```

The build's status is `SUCCESS`, and the output ends with a table similar to this:

```text
IMAGE                  TAGS
adservice              v0.10.7
busybox                1.38.0
cartservice            v0.10.7
...
curl                   8.23.0
redis                  8.10.2-alpine
shippingservice        v0.10.7
```

> [!NOTE]
> - Docker Hub images (`redis`, `busybox`, `curlimages/curl`) are pulled through `mirror.gcr.io`, Google's cache of popular Docker Hub images. This avoids Docker Hub's anonymous rate limits.
> - `gcloud` prints a link to the build in the console, where you can follow every copy step. It also prints `gcloud builds submit only displays logs from Cloud Storage`, which is expected: builds that run as your own service account write their logs to Cloud Logging (`logging: CLOUD_LOGGING_ONLY` in the generated configuration).
> - The script is safe to re-run: images that already exist in the repository are skipped. If the build fails, for example because the roles you just granted are still propagating, the script retries the missing images up to two times.

## 12. Reserve a global static IP for the Gateway

The application is published through a **global external Application Load Balancer** created by the GKE Gateway controller (Lab 04). A reserved global IP keeps the address stable, so DNS records and allow-lists don't change when the Gateway is recreated.

```bash
gcloud compute addresses create "${GATEWAY_IP_NAME}" \
  --global \
  --ip-version=IPV4
```

## 13. Checkpoint

Verify what you built:

```bash
gcloud compute networks subnets describe "${SUBNET_NAME}" --region="${REGION}" \
  --format="yaml(ipCidrRange,secondaryIpRanges,privateIpGoogleAccess)"
```

```bash
gcloud compute network-firewall-policies describe "${FW_POLICY_NAME}" --global \
  --flatten="rules[]" \
  --format="table(rules.priority,rules.direction,rules.action,rules.match.destFqdns.list(),rules.match.destIpRanges.list(),rules.enableLogging)"
```

```bash
gcloud compute networks describe "${VPC_NAME}" \
  --format="value(networkFirewallPolicyEnforcementOrder)"
```

```bash
gcloud compute addresses list \
  --filter="name~^${PREFIX}-" \
  --format="table(name,address,region.basename(),status)"
```

```bash
gcloud artifacts docker images list "${AR_PATH}" --include-tags \
  --format="table(package.basename():label=IMAGE,tags.list():label=TAGS)"
```

You should see the subnet with two secondary ranges, the two firewall policy rules (rule `1000` listing `ifconfig.me` and `api.github.com`, rule `2000` denying `0.0.0.0/0`, plus the policy's default rules at the lowest priorities), the enforcement order `BEFORE_CLASSIC_FIREWALL`, the NAT and Gateway IP addresses, and 14 images.

## Next Steps

[Lab 03 - Cluster Provisioning](../03-cluster-provisioning/README.md)

## Key Links

- [Best practices for GKE networking](https://cloud.google.com/kubernetes-engine/docs/best-practices/networking)
- [VPC-native clusters and IP address planning](https://cloud.google.com/kubernetes-engine/docs/concepts/alias-ips)
- [Cloud NAT overview](https://cloud.google.com/nat/docs/overview)
- [Cloud NGFW firewall policy rules](https://cloud.google.com/firewall/docs/firewall-policies-rule-details), [network contexts](https://cloud.google.com/firewall/docs/understand-network-contexts) and [FQDN objects](https://cloud.google.com/firewall/docs/fqdn-objects-overview)
- [Use least-privilege node service accounts](https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster#use_least_privilege_sa)
- [Encrypt secrets at the application layer](https://cloud.google.com/kubernetes-engine/docs/how-to/encrypting-secrets)
- [Artifact Analysis container scanning](https://cloud.google.com/artifact-analysis/docs/container-scanning-overview)
