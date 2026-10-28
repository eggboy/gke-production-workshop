# Lab 06 - Cluster Security

The Kubernetes community describes cloud-native security in layers ([Overview of Cloud Native Security](https://kubernetes.io/docs/concepts/security/overview/)): cloud, cluster, container and code. The previous labs secured the cloud and cluster layers. In this lab you put **guardrails** around workloads and **prove** that every control works by attempting to violate it:

| # | Control | Question it answers |
|---|---|---|
| 1 | Pod Security Admission | Can someone run a privileged container? |
| 2 | ValidatingAdmissionPolicy | Can someone deploy `:latest` images, skip resource requests or open a public load balancer? |
| 3 | Binary Authorization | Can someone run an image that doesn't come from the approved registry? |
| 4 | Network policies (east-west) | Can a compromised Pod in `dev` reach the shop's backend services? |
| 5 | FQDN network policy | Can a Pod reach internet domains its team was not approved for? |
| 6 | Cloud Armor WAF | Can an attacker exploit the storefront with SQL injection or XSS, or scrape it? |
| 7 | Image vulnerability scanning | Do the running images contain known vulnerabilities? |
| 8 | Security posture | How is the cluster doing against Google's recommendations? |

**Estimated time:** 90 minutes

> [!NOTE]
> Run `source ./env.sh` first if you opened a new Cloud Shell session. Several commands in this lab are **expected to fail**. That is the point.

## 1. Pod Security Admission

Pod Security Admission (PSA) is built into Kubernetes and replaces the removed PodSecurityPolicy. The `onlineboutique` namespace enforces the **restricted** standard (Lab 04). Try to run a privileged Pod there:

```bash no-fail
kubectl run privileged-test -n onlineboutique --image="${TOOLBOX_IMAGE}" --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"privileged-test","image":"'"${TOOLBOX_IMAGE}"'","command":["sleep","60"],"securityContext":{"privileged":true}}]}}'
```

```text
Error from server (Forbidden): pods "privileged-test" is forbidden: violates PodSecurity "restricted:latest": privileged (container "privileged-test" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (...), unrestricted capabilities (...), runAsNonRoot != true (...), seccompProfile (...)
```

Before tightening a namespace, ask the API server which **existing** Pods would violate the stricter level. A server-side dry run changes nothing. Here, `dev` enforces only `baseline`:

```bash
kubectl label --dry-run=server --overwrite namespace dev pod-security.kubernetes.io/enforce=restricted
```

The `toolbox` Pod from Lab 04 already complies with `restricted`, so no warnings are printed. Every Pod you write for this workshop is restricted-compliant.

## 2. Guardrails with ValidatingAdmissionPolicy

[ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) (GA since Kubernetes 1.30) evaluates [CEL](https://kubernetes.io/docs/reference/using-api/cel/) rules **inside the API server**. There is no webhook to deploy, scale or open firewall ports for. Review [`validating-admission-policies.yaml`](policies/validating-admission-policies.yaml). It contains three policies, each bound to all namespaces that have a `team` label:

| Policy | Rule |
|---|---|
| `require-pinned-image-tags` | Containers must use an explicit tag or digest, never `:latest` |
| `require-resource-requests` | Workloads must declare CPU and memory requests and a memory limit |
| `deny-external-load-balancers` | `LoadBalancer` Services must be internal, so there are no public IPs from inside the cluster |

```bash
kubectl apply -f 06-cluster-security/policies/validating-admission-policies.yaml
kubectl get validatingadmissionpolicies,validatingadmissionpolicybindings
```

Besides your three policies, the list shows policies that **GKE** manages itself (their names start with `gke-`). They protect GKE-managed components and system namespaces, and you can't edit them.

Test each guardrail with a server-side dry run (nothing is created even if it passes):

```bash no-fail
kubectl create deployment latest-test -n dev --image="${AR_PATH}/busybox:latest" --dry-run=server -o name
```

```bash no-fail
kubectl create deployment no-requests-test -n dev --image="${AR_PATH}/busybox:1.38.0" --dry-run=server -o name
```

```bash no-fail
kubectl create service loadbalancer public-lb-test -n dev --tcp=80:8080 --dry-run=server -o name
```

Each request is denied with the policy's message, for example:

```text
error: failed to create deployment: deployments.apps "latest-test" is forbidden: ValidatingAdmissionPolicy 'require-pinned-image-tags' with binding 'require-pinned-image-tags' denied request: Every container image must be pinned to a tag or digest, and ':latest' is not allowed.
```

> [!NOTE]
> Quick test workloads created with `kubectl create` or `kubectl run` in `dev` also print `Warning: would violate PodSecurity "restricted:latest": ...`. That's expected in this lab: `dev` **enforces** only `baseline` and **warns** about `restricted`, and these one-line test commands don't set a security context.

The running application already complies. A server-side dry run of the whole overlay passes:

```bash
kubectl apply -k 05-deploy-app/online-boutique --dry-run=server | tail -3
```

> [!TIP]
> For larger policy libraries (for example CIS or Pod Security bundles with a compliance dashboard), GKE includes **Policy Controller** at no extra cost. See the optional [bonus section](#bonus-a---policy-controller) at the end of this lab.

## 3. Binary Authorization: only approved images may run

The cluster has enforced the project's Binary Authorization policy since Lab 03, but that policy still allows everything. Export it:

```bash
gcloud container binauthz policy export
```

```text
defaultAdmissionRule:
  enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
  evaluationMode: ALWAYS_ALLOW
globalPolicyEvaluationMode: ENABLE
name: projects/<your-project>/policy
```

Replace it with [`binauthz-policy.yaml`](policies/binauthz-policy.yaml). The new policy denies everything by default, exempts Google-maintained system images, and allows only images from **your** Artifact Registry repository:

```bash
mkdir -p 06-cluster-security/policies/rendered
envsubst '${PROJECT_ID} ${AR_PATH}' < 06-cluster-security/policies/binauthz-policy.yaml \
  > 06-cluster-security/policies/rendered/binauthz-policy.yaml
cat 06-cluster-security/policies/rendered/binauthz-policy.yaml
gcloud container binauthz policy import 06-cluster-security/policies/rendered/binauthz-policy.yaml
```

Wait a moment for the policy to propagate, then try to run a Docker Hub image:

```bash no-fail
sleep 30
kubectl run binauthz-denied -n dev --image=nginx:1.29 --restart=Never
```

```text
Error from server (VIOLATES_POLICY): admission webhook "imagepolicywebhook.image-policy.k8s.io" denied the request: Image nginx:1.29 denied by Binary Authorization default admission rule. Denied by always_deny admission rule
```

An image from your repository is admitted. This server-side dry run goes through every admission check without creating the Pod:

```bash
kubectl run binauthz-allowed -n dev --image="${TOOLBOX_IMAGE}" --restart=Never --dry-run=server -o name -- sleep 60
```

Running workloads are not affected. Binary Authorization is evaluated when Pods are created, and all Online Boutique images come from your repository.

> [!IMPORTANT]
> **If the `nginx` Pod was admitted anyway**, the API server couldn't reach the Binary Authorization service. The webhook fails open (Lab 04, step 6), so there is no error, only a label on the Pod's audit log entry:
>
> ```bash
> gcloud logging read --freshness=15m --limit=1 \
>   'log_id("cloudaudit.googleapis.com/activity") AND protoPayload.methodName="io.k8s.core.v1.pods.create" AND protoPayload.resourceName="core/v1/namespaces/dev/pods/binauthz-denied"' \
>   --format="yaml(labels)" | grep failed-open
> ```
>
> The usual cause is a cluster whose control plane egress was set to `NONE` (`gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" --format="value(controlPlaneEgress.mode)"`). Set it back to the default with `gcloud container clusters update "${CLUSTER_NAME}" --location="${REGION}" --control-plane-egress=VIA_CONTROL_PLANE` (about 10 minutes), delete the Pod, and run the test again.

### Break-glass

In an emergency, an operator can bypass the policy with the `image-policy.k8s.io/break-glass` label. The Pod is admitted, but the event is **always recorded in Cloud Audit Logs** so security can follow up. The image is pulled, too: GKE nodes fetch Docker Hub images through `mirror.gcr.io`, Google's cache of Docker Hub, which the firewall policy allows as Google API traffic. The egress firewall never stood between this Pod and `nginx`; Binary Authorization did, and the audit entry is the record that someone switched it off for one Pod.

```bash
kubectl run breakglass-demo -n dev --image=nginx:1.29 --restart=Never \
  --labels="image-policy.k8s.io/break-glass=true"
```

```bash
sleep 60
gcloud logging read --freshness=15m --limit=1 \
  'resource.type="k8s_cluster" AND logName:"cloudaudit.googleapis.com%2Factivity" AND protoPayload.methodName="io.k8s.core.v1.pods.create" AND "image-policy.k8s.io/break-glass"' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,protoPayload.authenticationInfo.principalEmail:label=WHO,protoPayload.resourceName:label=RESOURCE)"
kubectl delete pod breakglass-demo -n dev --wait=false
```

## 4. Network policies: east-west isolation

Simulate a compromised Pod in `dev` trying to reach the shop's backend services. Dataplane V2 enforces the default-deny policies from Lab 04, so these connections time out:

```bash no-fail
kubectl exec -n dev toolbox -- curl -sS --max-time 5 -o /dev/null -w "%{http_code}\n" http://frontend.onlineboutique.svc.cluster.local
kubectl exec -n dev toolbox -- nc -z -v -w 5 cartservice.onlineboutique.svc.cluster.local 7070
```

From **inside** `onlineboutique` the same services are reachable, because the app's `allow-same-namespace` policy permits it:

```bash
envsubst '${TOOLBOX_IMAGE}' < 06-cluster-security/manifests/test-clients.yaml | kubectl apply -f -
kubectl wait pod/shop-client -n onlineboutique --for=condition=Ready --timeout=180s
kubectl exec -n onlineboutique shop-client -- curl -sS --max-time 5 -o /dev/null -w "frontend HTTP %{http_code}\n" http://frontend.onlineboutique.svc.cluster.local
kubectl exec -n onlineboutique shop-client -- nc -z -v -w 5 cartservice.onlineboutique.svc.cluster.local 7070
```

The denied attempts were recorded by **network policy logging** (enabled in Lab 04). Logs appear within a minute or two. Show the denied connections that came from `dev`:

```bash
sleep 60
gcloud logging read --freshness=15m --limit=5 \
  'resource.type="k8s_node" AND log_id("policy-action") AND jsonPayload.disposition="deny" AND jsonPayload.src.namespace="dev"' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,jsonPayload.src.pod_name:label=SRC_POD,jsonPayload.dest.namespace:label=DEST_NS,jsonPayload.dest.pod_name:label=DEST_POD,jsonPayload.connection.dest_port:label=PORT,jsonPayload.connection.direction:label=DIRECTION)"
```

The `toolbox` Pod's attempts to reach `frontend` (port `8080`, the Pod port behind the Service) and `cartservice` (port `7070`) were denied.

> [!TIP]
> Remove the `jsonPayload.src.namespace="dev"` condition and you'll also see the `frontend` Pods trying to reach `169.254.169.254:80`, the metadata server. The frontend uses it to show the cluster name and zone in its page footer. A default-deny policy surfaces every connection nobody planned for; this one is harmless, so it stays blocked and the shop works without it.

## 5. FQDN network policy: per-workload egress allow-lists

The VPC firewall policy (Lab 02) allows `ifconfig.me` and `api.github.com` for **the whole cluster**. An **FQDN network policy** narrows this per workload. The `fqdn-client` Pod (created in the previous step, without the `egress=internet` label) can't reach anything yet:

```bash no-fail
kubectl exec -n dev fqdn-client -- curl -sS --max-time 5 https://ifconfig.me; echo
```

Apply [`fqdn-network-policy.yaml`](policies/fqdn-network-policy.yaml), which allows only `ifconfig.me:443` for Pods labeled `app=fqdn-client`:

```bash
kubectl apply -f 06-cluster-security/policies/fqdn-network-policy.yaml
kubectl get fqdnnetworkpolicies -n dev
sleep 10
```

```bash
kubectl exec -n dev fqdn-client -- curl -sS --max-time 10 https://ifconfig.me; echo
```

```bash no-fail
kubectl exec -n dev fqdn-client -- curl -sS --max-time 10 -o /dev/null -w "%{http_code}\n" https://api.github.com/zen
```

`ifconfig.me` works; `api.github.com` is blocked for this Pod, even though the cluster-wide firewall allows it. Policies combine: the VPC firewall defines what the **cluster** may reach, and FQDN policies define what each **workload** may reach.

## 6. Cloud Armor: enforce the WAF

In Lab 04 you created the WAF rules in **preview** mode. Send a few typical attacks to the storefront. They still succeed (HTTP 200), but Cloud Armor logs what it **would** have done:

```bash
curl -sk -o /dev/null -w "SQLi  %{http_code}\n" "https://${GATEWAY_IP}/?id=1%27%20OR%20%271%27=%271"
curl -sk -o /dev/null -w "XSS   %{http_code}\n" "https://${GATEWAY_IP}/?q=%3Cscript%3Ealert(1)%3C/script%3E"
curl -sk -o /dev/null -w "LFI   %{http_code}\n" "https://${GATEWAY_IP}/?file=../../../../etc/passwd"
```

Check the preview decisions in the load balancer logs:

```bash
sleep 60
gcloud logging read --freshness=15m --limit=5 \
  'resource.type="http_load_balancer" AND jsonPayload.previewSecurityPolicy.outcome="DENY"' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,jsonPayload.previewSecurityPolicy.priority:label=RULE,jsonPayload.previewSecurityPolicy.preconfiguredExprIds.list():label=SIGNATURES,httpRequest.status:label=STATUS)"
```

No false positives from normal shopping traffic? Then switch every WAF rule to **enforcement**. Note the order: the SQL injection rule `1000` is updated **last**.

```bash
for PRIORITY in 1006 1005 1004 1003 1002 1001 1000; do
  gcloud compute security-policies rules update "${PRIORITY}" \
    --security-policy="${ARMOR_POLICY}" \
    --no-preview
done
```

Every rule update creates a new version of the policy, and each version takes a few minutes to reach all of Google's edge locations. Because rule `1000` changed last, the edge location serving you has received **all** the changes once it blocks SQL injection attempts. This loop waits until it does so 5 times in a row:

```bash
OK=0
for i in $(seq 1 60); do
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' "https://${GATEWAY_IP}/?id=1%27%20OR%20%271%27=%271" || true)"
  if [ "${CODE}" = "403" ]; then OK=$((OK + 1)); else OK=0; echo "Waiting for the policy change to propagate (HTTP ${CODE})..."; sleep 10; fi
  if [ "${OK}" -ge 5 ]; then echo "The WAF is enforcing."; break; fi
done
```

Now the attacks are **blocked with HTTP 403** at Google's edge, before they reach the cluster, while normal requests still work:

```bash
curl -sk -o /dev/null -w "SQLi     %{http_code}\n" "https://${GATEWAY_IP}/?id=1%27%20OR%20%271%27=%271"
curl -sk -o /dev/null -w "XSS      %{http_code}\n" "https://${GATEWAY_IP}/?q=%3Cscript%3Ealert(1)%3C/script%3E"
curl -sk -o /dev/null -w "LFI      %{http_code}\n" "https://${GATEWAY_IP}/?file=../../../../etc/passwd"
curl -sk -o /dev/null -w "RCE      %{http_code}\n" "https://${GATEWAY_IP}/?cmd=%3Bcat%20/etc/passwd"
curl -sk -o /dev/null -w "Scanner  %{http_code}\n" -A "sqlmap/1.8 (https://sqlmap.org)" "https://${GATEWAY_IP}/"
curl -sk -o /dev/null -w "Normal   %{http_code}\n" "https://${GATEWAY_IP}/"
```

### Rate limiting (anti-scraping)

Add a **throttle** rule. Each client IP may request at most 30 product pages per minute; extra requests get HTTP 429:

```bash
gcloud compute security-policies rules create 2000 \
  --security-policy="${ARMOR_POLICY}" \
  --expression="request.path.startsWith('/product/')" \
  --action=throttle \
  --rate-limit-threshold-count=30 \
  --rate-limit-threshold-interval-sec=60 \
  --conform-action=allow \
  --exceed-action=deny-429 \
  --enforce-on-key=IP \
  --description="Throttle product page scraping: 30 requests per minute per client IP"
```

Send 60 product page requests in a row and count the answers. While the new rule is still reaching Google's edge locations, few or none of the requests are throttled, so the loop repeats the test every 60 seconds until at least 20 requests get HTTP 429:

```bash
for ATTEMPT in $(seq 1 15); do
  RESULT="$(for i in $(seq 1 60); do
    curl -sk -o /dev/null -w "%{http_code}\n" "https://${GATEWAY_IP}/product/OLJCESPC7Z"
  done | sort | uniq -c)"
  THROTTLED="$(echo "${RESULT}" | awk '$2 == "429" {print $1}')"
  if [ "${THROTTLED:-0}" -ge 20 ]; then echo "${RESULT}"; break; fi
  echo "${THROTTLED:-0} of 60 requests throttled, the rule is still propagating. Retrying in 60 seconds..."; sleep 60
done
```

```text
     30 200
     30 429
```

Rate limiting is applied per edge location, and the counts are approximate, so your split may differ from exactly 30/30.

### Investigate blocked requests

Every decision Cloud Armor makes is in the load balancer logs, which arrive within a minute or two. Count the denied requests per rule and HTTP status:

```bash
sleep 60
gcloud logging read --freshness=30m --limit=500 \
  'resource.type="http_load_balancer" AND jsonPayload.enforcedSecurityPolicy.outcome="DENY"' \
  --format="value(jsonPayload.enforcedSecurityPolicy.priority,httpRequest.status)" | sort | uniq -c
```

```text
      6 1000	403
      1 1001	403
      2 1002	403
      1 1005	403
     30 2000	429
```

The WAF rules (`1000`-`1006`) answered with `403`, and the throttle rule (`2000`) with `429`. Your counts depend on how often you ran the tests; rule `1000` also counts the SQL injection attempts of the wait loop. Rule `1002` (local file inclusion) appears twice: the "RCE" request also contains `/etc/passwd`, and the rule with the lowest priority number that matches decides. For the WAF denials, the log also names the OWASP CRS signature that matched, which is what you need to tune false positives:

```bash
gcloud logging read --freshness=30m --limit=5 \
  'resource.type="http_load_balancer" AND jsonPayload.enforcedSecurityPolicy.outcome="DENY" AND jsonPayload.enforcedSecurityPolicy.priority<2000' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,jsonPayload.enforcedSecurityPolicy.priority:label=RULE,jsonPayload.enforcedSecurityPolicy.preconfiguredExprIds.list():label=SIGNATURE,httpRequest.requestUrl:label=URL)"
```

```text
TIME      RULE  SIGNATURE                                     URL
01:50:56  1005  owasp-crs-v042200-id913100-scannerdetection   https://<GATEWAY_IP>/
01:50:56  1002  owasp-crs-v042200-id930120-lfi                https://<GATEWAY_IP>/?cmd=%3Bcat%20/etc/passwd
...
```

### Block a specific client

Cloud Armor rules can also allow or deny by IP range, region (`origin.region_code`), ASN, header and more. Block **your own** Cloud Shell IP for a moment, and wait until the block is effective (usually 2-5 minutes):

```bash
MY_IP="$(curl -4 -s https://ifconfig.me)"
gcloud compute security-policies rules create 900 \
  --security-policy="${ARMOR_POLICY}" \
  --src-ip-ranges="${MY_IP}/32" \
  --action=deny-403 \
  --description="Temporary block of a single client"
for i in $(seq 1 60); do
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' "https://${GATEWAY_IP}/" || true)"
  echo "From ${MY_IP}: HTTP ${CODE}"
  if [ "${CODE}" = "403" ]; then break; fi
  sleep 10
done
```

Remove the rule again, and wait until your requests are allowed. Later labs need the storefront from Cloud Shell, so don't skip the wait:

```bash
gcloud compute security-policies rules delete 900 --security-policy="${ARMOR_POLICY}" --quiet
OK=0
for i in $(seq 1 60); do
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' "https://${GATEWAY_IP}/" || true)"
  if [ "${CODE}" = "200" ]; then OK=$((OK + 1)); else OK=0; echo "Still blocked (HTTP ${CODE}), waiting for the change to propagate..."; sleep 10; fi
  if [ "${OK}" -ge 5 ]; then echo "Unblocked."; break; fi
done
```

## 7. Image vulnerability scanning

Artifact Analysis scanned every image when Cloud Build pushed it in Lab 02, and it keeps re-analyzing them as new vulnerabilities are published. Get a summary for every image in the repository (an empty cell means no findings of that severity):

```bash
gcloud artifacts docker images list "${AR_PATH}" --show-occurrences --show-occurrences-from=20 \
  --format="table(package.basename():label=IMAGE,vuln_counts.CRITICAL:label=CRITICAL,vuln_counts.HIGH:label=HIGH,vuln_counts.MEDIUM:label=MEDIUM)"
```

`--show-occurrences-from=20` summarizes the 20 most recent images. The default of 10 would leave out some of the 14 images in your repository.

List the critical and high findings of one image, for example the Node.js-based `paymentservice`, with the package and the version that fixes it:

```bash
gcloud artifacts vulnerabilities list "${AR_PATH}/paymentservice:${OB_VERSION}" \
  --filter="occurrence.vulnerability.effectiveSeverity:(CRITICAL HIGH)" --limit=10 \
  --format="table(occurrence.vulnerability.effectiveSeverity:label=SEVERITY,occurrence.vulnerability.shortDescription:label=CVE,occurrence.vulnerability.packageIssue.affectedPackage:label=PACKAGE,occurrence.vulnerability.packageIssue.affectedVersion.name:label=VERSION,occurrence.vulnerability.packageIssue.fixedVersion.name:label=FIXED_IN)"
```

The findings change over time as new vulnerabilities are disclosed, so your list will differ from your neighbor's a few weeks later. That's exactly why continuous analysis matters.

> [!TIP]
> Scanning is only useful if you act on it. In a delivery pipeline you would fail the build, or refuse to attest the image for Binary Authorization, when critical vulnerabilities are found. You would also rebuild images regularly to pick up patched base images.

## 8. Security posture dashboard

GKE continuously audits your workloads for risky configurations, such as Pods running as root or missing resource limits, and surfaces relevant security bulletins. Open it in the console:

- **Kubernetes Engine > Security Posture**, select your cluster, then review **Concerns**.

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" --format="yaml(securityPostureConfig)"
echo "https://console.cloud.google.com/kubernetes/security/dashboard?project=${PROJECT_ID}"
```

> [!NOTE]
> GKE's built-in *workload vulnerability scanning* tiers were retired in 2025-2026. Image vulnerabilities are now covered by Artifact Analysis (above) and, if you activate it, Security Command Center.

## 9. Clean up the test Pods

```bash
kubectl delete pod fqdn-client -n dev --wait=false
kubectl delete pod shop-client -n onlineboutique --wait=false
```

## Bonus A - Policy Controller

[Policy Controller](https://cloud.google.com/kubernetes-engine/policy-controller/docs/overview) is Google's managed distribution of OPA Gatekeeper. It is included with GKE at no extra cost. It adds a library of constraint templates, policy **bundles** (for example CIS Kubernetes Benchmark and Pod Security Standards), audit of existing resources and a compliance dashboard. It requires registering the cluster to a **fleet**:

```bash skip
gcloud services enable anthospolicycontroller.googleapis.com gkehub.googleapis.com
gcloud container clusters update "${CLUSTER_NAME}" --location="${REGION}" --enable-fleet
gcloud container fleet policycontroller enable --memberships="${CLUSTER_NAME}"
gcloud container fleet policycontroller content bundles set pss-baseline-v2022 --memberships="${CLUSTER_NAME}"
```

After a few minutes, check **Kubernetes Engine > Posture management > Policy** in the console for audit results across the bundle's constraints.

## Bonus B - GKE Sandbox

For workloads that run **untrusted code**, GKE Sandbox runs Pods in a gVisor user-space kernel, so a container escape doesn't reach the node's kernel. Create a sandboxed node pool and a Pod that uses it:

```bash skip
gcloud container node-pools create sandbox-pool \
  --cluster="${CLUSTER_NAME}" --location="${REGION}" \
  --machine-type=e2-standard-2 --num-nodes=1 --image-type=COS_CONTAINERD \
  --service-account="${NODE_SA_EMAIL}" --shielded-secure-boot \
  --sandbox="type=gvisor"
```

Then add `runtimeClassName: gvisor` to a Pod spec. Delete the node pool when you are done to save costs.

## Next Steps

[Lab 07 - Cost Governance](../07-cost-governance/README.md)

## Key Links

- [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/)
- [Binary Authorization for GKE](https://cloud.google.com/binary-authorization/docs/overview) and [breakglass](https://cloud.google.com/binary-authorization/docs/using-breakglass)
- [GKE network policy](https://cloud.google.com/kubernetes-engine/docs/how-to/network-policy) and [FQDN network policies](https://cloud.google.com/kubernetes-engine/docs/how-to/fqdn-network-policies)
- [Cloud Armor security policies](https://cloud.google.com/armor/docs/security-policy-overview), [rate limiting](https://cloud.google.com/armor/docs/rate-limiting-overview) and [request logging](https://cloud.google.com/armor/docs/request-logging)
- [Artifact Analysis container scanning](https://cloud.google.com/artifact-analysis/docs/container-scanning-overview)
- [GKE security posture dashboard](https://cloud.google.com/kubernetes-engine/docs/concepts/about-security-posture-dashboard)
