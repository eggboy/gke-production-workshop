# Lab 08 - Cluster Monitoring

This lab covers monitoring, logging and alerting for the cluster and the application, using **Google Cloud Observability**: Cloud Logging, Cloud Monitoring and Google Cloud Managed Service for Prometheus. Google manages the collection agents on the nodes, and there is no Prometheus server or log store for you to run. The lab ends with audit logging for compliance: Data Access audit logs and a dedicated audit log bucket.

| Signal | What GKE collects in this cluster | Where |
|---|---|---|
| System metrics | CPU, memory, disk and network for nodes, Pods and containers (free) | Cloud Monitoring (`kubernetes.io/...`) |
| Prometheus metrics | Control plane (API server, scheduler, controller manager), kube-state metrics, cAdvisor and kubelet metrics, and anything your apps expose | Managed Service for Prometheus (query with **PromQL**) |
| Logs | System, workload (`stdout`/`stderr`), API server, scheduler and controller manager logs | Cloud Logging |
| Audit logs | Every Kubernetes API call that changes something (Admin Activity), plus GKE and other Google Cloud API calls. Reads of secrets and keys, and `get`, `list` and `watch` on the Kubernetes API, once you enable Data Access logs (step 7). | Cloud Logging (`cloudaudit.googleapis.com/activity` and `/data_access`), plus a dedicated audit log bucket (step 7) |
| Network | Firewall, Cloud NAT, network policy, load balancer and Cloud Armor logs, and Dataplane V2 flows (Hubble) | Cloud Logging and Hubble |

**Estimated time:** 75 minutes

> [!NOTE]
> Run `source ./env.sh` first if you opened a new Cloud Shell session. Logs and metrics take 1-3 minutes to arrive, and alerts a few minutes more. Some steps include short waits.

## 1. Explore the built-in dashboards

Open the console and look around. Everything here works without any configuration:

- **Kubernetes Engine > Clusters > `gkews-cluster` > Observability**: cluster, node and workload dashboards (CPU, memory, restarts, control plane health)
- **Kubernetes Engine > Workloads > `frontend` > Observability**: per-workload metrics and logs
- **Monitoring > Dashboards > GKE**: fleet-wide dashboards

```bash
echo "https://console.cloud.google.com/kubernetes/clusters/details/${REGION}/${CLUSTER_NAME}/observability?project=${PROJECT_ID}"
```

## 2. Create alerting policies

Create the alerting policies first. A new log-based alerting policy only starts matching log entries a few minutes after it's created (2-3 minutes in our tests), so creating them now means they are active by the time you trigger them in step 5.

You'll create three alerting policies, each defined as a JSON file:

| Policy | Type | Fires when |
|---|---|---|
| [`exec-alert.json`](alerting/exec-alert.json) | Log-based | Someone runs `kubectl exec` in the cluster: a shell in a container. The Kubernetes audit log records every `exec` with its command, so no runtime agent is needed for this signal |
| [`waf-alert.json`](alerting/waf-alert.json) | Log-based | Cloud Armor blocks a request |
| [`unavailable-replicas-alert.json`](alerting/unavailable-replicas-alert.json) | PromQL | A Deployment in `onlineboutique` has fewer available replicas than desired (`kube_deployment_spec_replicas - kube_deployment_status_replicas_available > 0`) for 2 minutes |

**Optional:** to receive emails, create an email notification channel. It sends to your own account here; adjust as needed. If you skip this, alerts still show up in the console.

```bash skip
export CHANNEL_ID="$(gcloud beta monitoring channels create \
  --display-name="Workshop alerts" \
  --type=email \
  --channel-labels=email_address="$(gcloud config get-value account)" \
  --format='value(name)')"
echo "${CHANNEL_ID}"
```

Render the policy files and create the policies. `${CHANNEL_ID:+...}` adds the notification channel only if you created one, and `ALERTS_CREATED_AT` remembers when you created them:

```bash
mkdir -p 08-cluster-monitoring/alerting/rendered
for POLICY in exec-alert waf-alert unavailable-replicas-alert; do
  envsubst '${CLUSTER_NAME} ${ARMOR_POLICY}' < "08-cluster-monitoring/alerting/${POLICY}.json" \
    > "08-cluster-monitoring/alerting/rendered/${POLICY}.json"
  gcloud monitoring policies create \
    --policy-from-file="08-cluster-monitoring/alerting/rendered/${POLICY}.json" \
    ${CHANNEL_ID:+--notification-channels="${CHANNEL_ID}"}
done
export ALERTS_CREATED_AT="$(date +%s)"
```

```bash
gcloud monitoring policies list --format="table(displayName,enabled,conditions[0].displayName:label=CONDITION)"
```

## 3. Query logs

[Logging query language](https://cloud.google.com/logging/docs/view/logging-query-language) is used in the console's **Logs Explorer** and in `gcloud logging read`.

Application logs from the frontend (Online Boutique logs structured JSON, so Cloud Logging indexes the fields). The load generator was removed in Lab 07, so these entries come from the load balancer's health checks (`/_healthz`, every 10 seconds) and your own requests:

```bash
gcloud logging read --freshness=10m --limit=5 \
  'resource.type="k8s_container" AND resource.labels.namespace_name="onlineboutique" AND resource.labels.container_name="server" AND labels."k8s-pod/app"="frontend"' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,severity,jsonPayload.message:label=MESSAGE)"
```

Kubernetes events, for example scheduling or image pull problems:

```bash
gcloud logging read --freshness=60m --limit=5 \
  'log_id("events") AND resource.labels.cluster_name="'"${CLUSTER_NAME}"'"' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,jsonPayload.reason:label=REASON,jsonPayload.involvedObject.kind:label=KIND,jsonPayload.involvedObject.name:label=OBJECT)"
```

Control plane (API server) logs. Each entry is an API request, with its verb, URI, latency and client:

```bash
gcloud logging read --freshness=10m --limit=3 \
  'resource.type="k8s_control_plane_component" AND resource.labels.component_name="apiserver" AND resource.labels.cluster_name="'"${CLUSTER_NAME}"'"' \
  --format="value(timestamp.date('%H:%M:%S'),severity,jsonPayload.message)" | cut -c1-160
```

Audit logs answer **who did what, and when**. For example, the Deployments that people (not Kubernetes system components) changed in the last 12 hours:

```bash
gcloud logging read --freshness=12h --limit=5 \
  'log_id("cloudaudit.googleapis.com/activity") AND resource.type="k8s_cluster" AND protoPayload.methodName=~"io.k8s.apps.v1.deployments.(create|update|patch)" AND NOT protoPayload.authenticationInfo.principalEmail:"system:"' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,protoPayload.authenticationInfo.principalEmail:label=WHO,protoPayload.methodName.basename():label=ACTION,protoPayload.resourceName:label=RESOURCE)"
```

You'll see your own changes from earlier labs, such as `kubectl set env` on the load generator in Lab 07.

## 4. Query metrics with PromQL

Managed Service for Prometheus stores the control plane, kube-state and cAdvisor metrics you enabled at cluster creation. Query them with **PromQL**, either in the console (**Monitoring > Metrics Explorer > PromQL**) or through the Prometheus-compatible API:

```bash
PROM_API="https://monitoring.googleapis.com/v1/projects/${PROJECT_ID}/location/global/prometheus/api/v1"
promql() { curl -sG -H "Authorization: Bearer $(gcloud auth print-access-token)" --data-urlencode "query=$1" "${PROM_API}/query"; }
```

CPU usage per namespace, in cores (cAdvisor metrics; `container!=""` skips the node-level and Pod-level totals so nothing is counted twice):

```bash
promql "sum by (namespace) (rate(container_cpu_usage_seconds_total{cluster=\"${CLUSTER_NAME}\", container!=\"\"}[5m]))" \
  | jq -r '.data.result[] | "\(.metric.namespace)\t\(.value[1])"' | sort -k2 -rn | head -8
```

Available replicas per Online Boutique Deployment (kube-state metrics):

```bash
promql "kube_deployment_status_replicas_available{cluster=\"${CLUSTER_NAME}\", namespace=\"onlineboutique\"}" \
  | jq -r '.data.result[] | "\(.metric.deployment)\t\(.value[1])"' | sort
```

99th percentile API server request latency per verb (control plane metrics). Long-running `WATCH` and `CONNECT` requests are excluded, because their duration is not latency:

```bash
promql "histogram_quantile(0.99, sum by (le, verb) (rate(apiserver_request_duration_seconds_bucket{cluster=\"${CLUSTER_NAME}\", verb!~\"WATCH|CONNECT\"}[5m])))" \
  | jq -r '.data.result[] | "\(.metric.verb)\t\(.value[1])s"'
```

> [!TIP]
> Applications that expose Prometheus metrics can be scraped by adding a `PodMonitoring` resource. You don't need to run your own Prometheus server. See [Managed collection](https://cloud.google.com/stackdriver/docs/managed-prometheus/setup-managed).

## 5. Trigger the alerts

Make sure the policies from step 2 have existed for at least 5 minutes. This returns immediately if they have:

```bash
WAIT=$(( ${ALERTS_CREATED_AT:-0} + 300 - $(date +%s) ))
if [ "${WAIT}" -gt 0 ]; then echo "Waiting ${WAIT} seconds until the new alerting policies are active..."; sleep "${WAIT}"; fi
```

**A shell in a container.** Run a command in the `toolbox` Pod. The audit log entry includes the full command (label `command.gke.io/command`):

```bash
kubectl exec -n dev toolbox -- sh -c 'id; hostname'
```

**A web attack.** The WAF rules are enforced since Lab 06:

```bash
curl -sk -o /dev/null -w "SQLi attempt: HTTP %{http_code}\n" "https://${GATEWAY_IP}/?id=1%27%20OR%20%271%27=%271"
```

**A broken rollout.** [`broken-app.yaml`](manifests/broken-app.yaml) references an image tag that doesn't exist:

```bash
envsubst '${AR_PATH}' < 08-cluster-monitoring/manifests/broken-app.yaml | kubectl apply -f -
sleep 30
kubectl get pods -n onlineboutique -l app=broken-app
```

Wait a few minutes, then list the open alerts. You can also check **Monitoring > Alerting** in the console:

```bash
for i in $(seq 1 20); do
  OPEN="$(gcloud beta monitoring alerts list --filter='state=OPEN' --format='value(name)' | wc -l)"
  if [ "${OPEN}" -ge 3 ]; then break; fi
  echo "Open alerts: ${OPEN} - waiting..."; sleep 30
done
gcloud beta monitoring alerts list --filter='state=OPEN' \
  --format="table(openTime.date('%H:%M:%S'):label=OPENED,policy.displayName:label=POLICY,state)"
```

```text
OPENED    POLICY                                                STATE
02:57:10  Online Boutique: Deployment has unavailable replicas  OPEN
02:53:48  Cloud Armor: requests blocked at the edge             OPEN
02:53:48  GKE: command executed in a container (kubectl exec)   OPEN
```

The two log-based alerts open within a minute of the log entry. The PromQL alert takes longer, because the condition must hold for 2 minutes.

Look at the details of the `kubectl exec` audit entry that fired the first alert:

```bash
gcloud logging read --freshness=30m --limit=1 \
  'log_id("cloudaudit.googleapis.com/activity") AND protoPayload.methodName=~"io.k8s.core.v1.pods.exec.*"' \
  --format="yaml(protoPayload.authenticationInfo.principalEmail,protoPayload.resourceName,labels)"
```

Remove the broken Deployment. The PromQL alert closes automatically once the condition clears:

```bash
kubectl delete deployment broken-app -n onlineboutique
```

## 6. Network observability with Dataplane V2 (Hubble)

The cluster was created with `--enable-dataplane-v2-flow-observability`, which runs **Hubble Relay** in the `gke-managed-dpv2-observability` namespace. The `hubble` CLI is built into the relay Pod. Look at recent network flows in the shop namespace:

```bash
kubectl exec -n gke-managed-dpv2-observability deployment/hubble-relay -c hubble-cli -- \
  hubble observe --namespace onlineboutique --last 15
```

Hubble keeps only a small buffer of recent flows in memory. Check how many flows it holds and how fast new ones arrive:

```bash
kubectl exec -n gke-managed-dpv2-observability deployment/hubble-relay -c hubble-cli -- hubble status
```

With more than 100 flows per second, the buffer covers only the last second or two. So watch for **dropped** traffic live: start `hubble observe --follow` in the background, repeat the blocked connection from Lab 06 (`dev` to the shop), then stop the observer:

```bash
kubectl exec -n gke-managed-dpv2-observability deployment/hubble-relay -c hubble-cli -- \
  hubble observe --follow --verdict DROPPED > /tmp/hubble-drops.txt 2>&1 &
HUBBLE_PID=$!
sleep 5
kubectl exec -n dev toolbox -- curl -sS --max-time 5 -o /dev/null http://frontend.onlineboutique.svc.cluster.local || true
sleep 3
kill "${HUBBLE_PID}"
head -4 /tmp/hubble-drops.txt
```

```text
Oct 22 03:09:23.548: dev/toolbox:43060 (ID:2776) <> onlineboutique/frontend-5449749bf7-k2dzg:8080 (ID:12283) policy-verdict:none TRAFFIC_DIRECTION_UNKNOWN DENIED (TCP Flags: SYN)
Oct 22 03:09:23.548: dev/toolbox:43060 (ID:2776) <> onlineboutique/frontend-5449749bf7-k2dzg:8080 (ID:12283) Policy denied DROPPED (TCP Flags: SYN)
```

Each retransmitted SYN of the blocked connection is dropped by the network policy. For long-term analysis, use the network policy logs in Cloud Logging (Lab 06) instead of Hubble's short in-memory buffer.

> [!TIP]
> Run the same experiment with `--pod dev/toolbox` instead of `--verdict DROPPED` to see every flow of the toolbox Pod. Its DNS lookups go to a `node-local-dns` Pod on the same node: that's NodeLocal DNSCache at work, and the reason the DNS network policy in Lab 04 allows both `kube-dns` and `node-local-dns`.

## 7. Audit logging for compliance

Cloud Audit Logs answer **who did what, where and when**, for every Google Cloud API and for the Kubernetes API of your cluster. The [security design](../01-cluster-design/SecurityDesign.md#audit-logging) describes the four types of audit logs. In this step you check that the always-on Admin Activity logs can't be tampered with, turn on Data Access logs for your secrets, keys and the Kubernetes API, and route all audit logs to a dedicated log bucket.

### Admin Activity audit logs can't be deleted

Admin Activity and System Event audit logs record every configuration change, including each `kubectl apply` and `kubectl exec`. They are stored in your project's `_Required` log bucket for 400 days, at no charge. That bucket is **locked**: nobody, not even a project owner, can shorten its retention or delete it. Try both. Expected failures:

```bash no-fail
gcloud logging buckets update _Required --location=global --retention-days=1
gcloud logging buckets delete _Required --location=global --quiet
```

```text
ERROR: (gcloud.logging.buckets.update) FAILED_PRECONDITION: This bucket is locked. Locked buckets are immutable
ERROR: (gcloud.logging.buckets.delete) PERMISSION_DENIED: Bucket _Required cannot be deleted. ...
```

### Turn on Data Access audit logs for secrets, keys and the Kubernetes API

**Data Access** audit logs record reads, for example who read the database password from Secret Manager, who used a Cloud KMS key, or who ran `kubectl get secret`. They are disabled by default because they can be high-volume, so you enable them where sensitive data lives.

The Secret Manager add-on reads `${PREFIX}-db-password` for the `secret-reader` app every minute or two, to pick up new versions (Lab 05). None of these reads is recorded yet, so this query prints nothing (unless your organization already enables these logs):

```bash
gcloud logging read --freshness=30m --limit=5 \
  'protoPayload.methodName="google.cloud.secretmanager.v1.SecretManagerService.AccessSecretVersion"' \
  --format="value(timestamp)"
```

The same applies to the Kubernetes API. GKE writes `create`, `update`, `patch` and `delete` requests to the always-on Admin Activity log, but `get`, `list` and `watch` go to the Data Access log, which is off. Reading a Secret with `kubectl` therefore leaves no trace yet:

```bash
kubectl get secrets -n onlineboutique
gcloud logging read --freshness=30m --limit=5 \
  'log_id("cloudaudit.googleapis.com/data_access") AND protoPayload.serviceName="k8s.io" AND protoPayload.methodName=~"io.k8s.core.v1.secrets.(get|list)"' \
  --format="value(timestamp)"
```

Data Access audit logs are configured in the `auditConfigs` section of the project's IAM policy. Read the policy, use `jq` to add Data Access logging (`DATA_READ`) for Secret Manager and Cloud KMS, and `ADMIN_READ` plus `DATA_READ` for the Kubernetes Engine API (which covers both the GKE API and the Kubernetes API of your clusters), and write the policy back:

```bash
gcloud projects get-iam-policy "${PROJECT_ID}" --format=json > /tmp/iam-policy.json
jq '.auditConfigs = ([(.auditConfigs // [])[] | select(.service != "secretmanager.googleapis.com" and .service != "cloudkms.googleapis.com" and .service != "container.googleapis.com")]
    + [{"service": "secretmanager.googleapis.com", "auditLogConfigs": [{"logType": "DATA_READ"}]},
       {"service": "cloudkms.googleapis.com", "auditLogConfigs": [{"logType": "DATA_READ"}]},
       {"service": "container.googleapis.com", "auditLogConfigs": [{"logType": "ADMIN_READ"}, {"logType": "DATA_READ"}]}])' \
  /tmp/iam-policy.json > /tmp/iam-policy-audit.json
gcloud projects set-iam-policy "${PROJECT_ID}" /tmp/iam-policy-audit.json --format=none
gcloud projects get-iam-policy "${PROJECT_ID}" --format="yaml(auditConfigs)"
```

```text
auditConfigs:
- auditLogConfigs:
  - logType: DATA_READ
  service: secretmanager.googleapis.com
- auditLogConfigs:
  - logType: DATA_READ
  service: cloudkms.googleapis.com
- auditLogConfigs:
  - logType: ADMIN_READ
  - logType: DATA_READ
  service: container.googleapis.com
```

> [!CAUTION]
> `set-iam-policy` replaces the project's whole IAM policy. The `jq` filter changes only `auditConfigs` and keeps the role bindings and the `etag` exactly as they were read. If someone changed the policy in the meantime, the `etag` no longer matches and the command fails without changing anything; then run the commands again.

> [!WARNING]
> **Cost.** Kubernetes API Data Access logs are **high-volume**: every `get`, `list` and `watch` by every controller, kubelet and operator is recorded, which on a busy cluster is gigabytes per day. In production, keep them for clusters that hold regulated data, route them to a bucket with a retention you can afford, and use [exclusion filters](https://cloud.google.com/logging/docs/routing/overview#exclusions) to drop the noisy system principals you don't need. For the few hours the three-node workshop cluster runs after this step, the volume stays well inside the free 50 GiB per project and month.

The next reads by the add-on are now recorded. Wait for the first entry (a few minutes), then look at who read the secret:

```bash
for i in $(seq 1 20); do
  N="$(gcloud logging read --freshness=10m --limit=1 \
    'protoPayload.methodName="google.cloud.secretmanager.v1.SecretManagerService.AccessSecretVersion"' \
    --format='value(timestamp)' | wc -l)"
  if [ "${N}" -gt 0 ]; then break; fi
  echo "Waiting for the first Data Access log entry..."; sleep 30
done
gcloud logging read --freshness=10m --limit=3 \
  'protoPayload.methodName="google.cloud.secretmanager.v1.SecretManagerService.AccessSecretVersion"' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,protoPayload.authenticationInfo.principalSubject:label=CALLER,protoPayload.resourceName.segment(-3):label=SECRET)"
```

The caller is the Kubernetes ServiceAccount `secret-reader` in namespace `secrets-demo`, identified through Workload Identity Federation for GKE:

```text
TIME      CALLER                                                          SECRET
04:18:15  serviceAccount:<PROJECT_ID>.svc.id.goog[secrets-demo/secret-reader]  gkews-db-password
```

Denied attempts are recorded too. Start the unauthorized reader from Lab 05 again; it runs as the namespace's `default` ServiceAccount, which has no access. Status code `7` means `PERMISSION_DENIED`:

```bash
envsubst '${AR_PATH}' < 05-deploy-app/secrets-demo/unauthorized-reader.yaml | kubectl apply -f -
FILTER='protoPayload.methodName="google.cloud.secretmanager.v1.SecretManagerService.AccessSecretVersion" AND protoPayload.status.code=7'
for i in $(seq 1 20); do
  N="$(gcloud logging read --freshness=10m --limit=1 "${FILTER}" --format='value(timestamp)' | wc -l)"
  if [ "${N}" -gt 0 ]; then break; fi
  echo "Waiting for the denied attempt to be logged..."; sleep 30
done
gcloud logging read --freshness=10m --limit=1 "${FILTER}" \
  --format="yaml(protoPayload.authenticationInfo.principalSubject,protoPayload.status.code,protoPayload.status.message)"
kubectl delete pod unauthorized-reader -n secrets-demo
```

```text
protoPayload:
  authenticationInfo:
    principalSubject: serviceAccount:<PROJECT_ID>.svc.id.goog[secrets-demo/default]
  status:
    code: 7
    message: Permission 'secretmanager.versions.access' denied on resource (or it
      may not exist).
```

The Cloud KMS Data Access logs show every use of your key. Here, the GKE service agent encrypts and decrypts Kubernetes Secrets with it (application-layer secrets encryption from Lab 03):

```bash
gcloud logging read --freshness=10m --limit=3 \
  'log_id("cloudaudit.googleapis.com/data_access") AND protoPayload.serviceName="cloudkms.googleapis.com"' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,protoPayload.authenticationInfo.principalEmail:label=CALLER,protoPayload.methodName:label=METHOD,protoPayload.resourceName.segment(-1):label=KEY)"
```

```text
TIME      CALLER                                                                  METHOD   KEY
04:26:05  service-<PROJECT_NUMBER>@container-engine-robot.iam.gserviceaccount.com  Decrypt  gke-secrets
04:26:05  service-<PROJECT_NUMBER>@container-engine-robot.iam.gserviceaccount.com  Encrypt  gke-secrets
```

Reads through the Kubernetes API are recorded now too. Read the Secrets of the shop namespace again (there are none, but the request itself is what gets audited), then find your own `list` in the Data Access log, together with the `get` and `list` calls that system components make:

```bash
kubectl get secrets -n onlineboutique
FILTER='log_id("cloudaudit.googleapis.com/data_access") AND protoPayload.serviceName="k8s.io" AND protoPayload.methodName=~"io.k8s.core.v1.secrets.(get|list)"'
for i in $(seq 1 20); do
  N="$(gcloud logging read --freshness=10m --limit=1 "${FILTER} AND NOT protoPayload.authenticationInfo.principalEmail=~\"^system:\"" --format='value(timestamp)' | wc -l)"
  if [ "${N}" -gt 0 ]; then break; fi
  echo "Waiting for the Kubernetes API Data Access log entry..."; sleep 30
done
gcloud logging read --freshness=10m --limit=5 "${FILTER}" \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,protoPayload.authenticationInfo.principalEmail:label=WHO,protoPayload.methodName:label=METHOD,protoPayload.resourceName:label=RESOURCE)"
```

```text
TIME      WHO                                   METHOD                         RESOURCE
04:27:40  <your account>                        io.k8s.core.v1.secrets.list    core/v1/namespaces/onlineboutique/secrets
04:27:31  system:serviceaccount:kube-system:... io.k8s.core.v1.secrets.get     core/v1/namespaces/kube-system/secrets/...
```

This is the entry that requirement 10 needs: a person reading a Secret in production is now visible, with their identity, the namespace and the Secret's name. The `app-developer` Role from Lab 04 can't read Secrets at all, so for that team the log would show a `403` instead.

### Route all audit logs to a dedicated log bucket

In production, an **organization-level aggregated sink** copies the audit logs of every project to a central logging project that only the security team can access, and the bucket's retention is **locked**. You build the same pattern inside your project: a log bucket in your region that keeps audit logs for a year, and a sink that routes every audit log entry to it.

```bash
gcloud logging buckets create "${AUDIT_BUCKET}" \
  --location="${REGION}" \
  --retention-days=365 \
  --description="Audit logs of ${CLUSTER_NAME}"
```

```bash
gcloud logging sinks create "${AUDIT_SINK}" \
  "logging.googleapis.com/projects/${PROJECT_ID}/locations/${REGION}/buckets/${AUDIT_BUCKET}" \
  --log-filter='logName:"cloudaudit.googleapis.com"' \
  --description="All audit logs of the project, copied to ${AUDIT_BUCKET}"
```

The sink only copies entries written after it was created. Make a change that is audited, then wait until the bucket has received both your change and new Data Access entries:

```bash
kubectl annotate namespace dev workshop.example.com/audit-check="$(date +%s)" --overwrite
for i in $(seq 1 20); do
  CHANGE="$(gcloud logging read --bucket="${AUDIT_BUCKET}" --location="${REGION}" --view=_AllLogs \
    --freshness=10m --limit=1 'protoPayload.resourceName="core/v1/namespaces/dev"' --format='value(timestamp)')"
  READ="$(gcloud logging read --bucket="${AUDIT_BUCKET}" --location="${REGION}" --view=_AllLogs \
    --freshness=10m --limit=1 'log_id("cloudaudit.googleapis.com/data_access")' --format='value(timestamp)')"
  if [ -n "${CHANGE}" ] && [ -n "${READ}" ]; then break; fi
  echo "Waiting for audit logs to arrive in ${AUDIT_BUCKET}..."; sleep 30
done
```

Count the entries in the bucket per audit log and service:

```bash
gcloud logging read --bucket="${AUDIT_BUCKET}" --location="${REGION}" --view=_AllLogs \
  --freshness=10m --limit=1000 'logName:"cloudaudit.googleapis.com"' \
  --format="value(logName.segment(-1),protoPayload.serviceName)" | sort | uniq -c
```

```text
     90 activity	k8s.io
    310 data_access	k8s.io
      4 data_access	cloudkms.googleapis.com
      2 data_access	secretmanager.googleapis.com
```

Most Admin Activity entries (`activity`) come from Kubernetes components that renew their leases. The `data_access` entries are the secret reads, the uses of your Cloud KMS key, and, by far the largest group, the `get`, `list` and `watch` calls of system components on the Kubernetes API (your counts will differ). Your own change is there too, with your identity:

```bash
gcloud logging read --bucket="${AUDIT_BUCKET}" --location="${REGION}" --view=_AllLogs \
  --freshness=10m --limit=1 'protoPayload.resourceName="core/v1/namespaces/dev"' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,protoPayload.authenticationInfo.principalEmail:label=WHO,protoPayload.methodName:label=METHOD)"
```

```text
TIME      WHO                 METHOD
04:23:51  <your account>      io.k8s.core.v1.namespaces.patch
```

In production you would also **lock** the bucket, so that nobody can shorten its retention or delete it, and create the sink at the organization level. Don't run these commands in the workshop: locking is irreversible, and you couldn't delete the bucket during the cleanup.

```bash skip
gcloud logging buckets update "${AUDIT_BUCKET}" --location="${REGION}" --locked
```

```bash skip
# An organization administrator routes the audit logs of every project in the organization
# to a bucket in the central logging project, then grants the writer identity that the
# command prints the Logs Bucket Writer role (roles/logging.bucketWriter) on that bucket.
gcloud logging sinks create org-audit-logs \
  "logging.googleapis.com/projects/LOGGING_PROJECT_ID/locations/${REGION}/buckets/audit-logs" \
  --organization=ORGANIZATION_ID --include-children \
  --log-filter='logName:"cloudaudit.googleapis.com"'
```

> [!NOTE]
> Also restrict who can read the central bucket: anyone who can read a log bucket can read the Data Access logs in it. Add a customer-managed encryption key (`--cmek-kms-key-name`) if your regulator requires it, and forward the logs to your SIEM through Pub/Sub. Audit logs that you route to your own bucket count as log ingestion; the first 50 GiB per project and month are free, and this workshop produces a few megabytes.

## Next Steps

[Lab 09 - Day-2 Operations](../09-day2-operations/README.md)

## Key Links

- [Observability for GKE](https://cloud.google.com/kubernetes-engine/docs/concepts/observability)
- [Configure metrics collection](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-metrics)
- [Managed Service for Prometheus](https://cloud.google.com/stackdriver/docs/managed-prometheus)
- [Log-based alerting policies](https://cloud.google.com/logging/docs/alerting/log-based-alerts) and [PromQL alerting policies](https://cloud.google.com/monitoring/promql/create-promql-alerts-console)
- [GKE audit logging](https://cloud.google.com/kubernetes-engine/docs/how-to/audit-logging)
- [Enable Data Access audit logs](https://cloud.google.com/logging/docs/audit/configure-data-access), [GKE audit policy](https://cloud.google.com/kubernetes-engine/docs/concepts/audit-policy) (which Kubernetes verbs go to which log), [configure log buckets](https://cloud.google.com/logging/docs/buckets) and [aggregated sinks](https://cloud.google.com/logging/docs/export/aggregated_sinks)
- [Dataplane V2 observability](https://cloud.google.com/kubernetes-engine/docs/how-to/configure-dpv2-observability)
