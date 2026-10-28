# Lab 10 - Validate Scenarios

Now that everything is implemented, go back to the customer's requirements from the [README](../README.md#customer-requirements) and validate that each one is met.

**Estimated time:** 30 minutes

> [!NOTE]
> Run `source ./env.sh` first if you opened a new Cloud Shell session. Commands marked as expected failures **must** fail. That is the proof.

## Requirements to Technology Matrix

| # | Requirement | Technology used | Lab |
|---|---|---|---|
| 1 | Use the existing identity system; no static credentials | Google Cloud IAM identities, short-lived tokens through `gke-gcloud-auth-plugin`, the DNS endpoint authorized by IAM, Workload Identity Federation for GKE | 03, 05 |
| 2 | Least privilege everywhere | IAM plus namespace-scoped Kubernetes RBAC, least-privilege service accounts for the nodes and the image build, repository-scoped registry access, per-secret IAM bindings for Kubernetes ServiceAccounts | 02, 04, 05 |
| 3 | Nothing reachable except the published app | Private nodes, DNS-only control plane (IP endpoints disabled), no public `LoadBalancer` Services (quota and admission policy) | 02, 03, 04, 06 |
| 4 | Egress only to approved destinations, logged | Cloud NAT with a static IP, Cloud NGFW firewall policy (FQDN allow-list, internet deny, logging), FQDN network policies | 02, 04, 06 |
| 5 | TLS, WAF and rate limiting | Gateway API with a TLS certificate, MODERN SSL policy, HTTP-to-HTTPS redirect, Cloud Armor (OWASP CRS 4.22, throttling, Adaptive Protection) | 04, 05, 06 |
| 6 | Network isolation between teams | Namespaces, Dataplane V2 network policies (default deny), network policy logging | 04, 06 |
| 7 | Only approved, scanned images | Artifact Registry, Binary Authorization allow-list with audited break-glass, Artifact Analysis vulnerability scanning | 02, 06 |
| 8 | Secrets outside the cluster; Kubernetes Secrets encrypted with a customer-managed key | Secret Manager add-on with Workload Identity and rotation; application-layer secrets encryption with Cloud KMS (other data at rest uses Google-managed keys, see the [security design](../01-cluster-design/SecurityDesign.md#data-protection)) | 02, 03, 05 |
| 9 | Guardrails against insecure workloads | Organization policies (checked in Lab 02), Pod Security Admission (`restricted`), ValidatingAdmissionPolicy (pinned images, resource requests, no public LBs) | 02, 04, 06 |
| 10 | Everything logged; alerts on suspicious activity | Cloud Audit Logs (Admin Activity; Data Access for Secret Manager, Cloud KMS and the Kubernetes API, including `kubectl get secret`), audit logs routed to a dedicated log bucket, Cloud Logging, log-based alerts (`kubectl exec`, WAF blocks), PromQL alert, Hubble flows | 08 |
| 11 | Cost visibility and right-sizing | GKE cost allocation, team labels, VPA recommendations, HPA, autoscaler profile, Spot VMs | 07 |
| 12 | Controlled, zero-downtime upgrades; backup and restore | Release channel, maintenance window and exclusions, notifications, replicas spread across zones with topology spread constraints, PDBs, graceful shutdown, surge and blue-green, node pool migration, Backup for GKE | 03, 05, 09 |

The rest of this lab shows how to validate each requirement.

## 1. Existing identity, no static credentials

You are authenticated to Kubernetes as your Google identity. kubectl uses short-lived OAuth tokens from `gke-gcloud-auth-plugin`; there are no static passwords or certificates in your kubeconfig:

```bash
kubectl auth whoami
kubectl config view --minify -o jsonpath='{.users[0].user.exec.command}{"\n"}'
```

## 2. Least privilege

The developer role can roll out workloads, but can't read Secrets or exec into Pods. Expected answers: `yes`, `no`, `no`:

```bash no-fail
kubectl auth can-i patch deployments -n onlineboutique --as=developer@example.com
kubectl auth can-i get secrets      -n onlineboutique --as=developer@example.com
kubectl auth can-i create pods/exec -n onlineboutique --as=developer@example.com
```

The workshop's service accounts hold exactly one project role each: `roles/container.defaultNodeServiceAccount` for the nodes and `roles/logging.logWriter` for the image mirror build. Their registry access is granted on the repository only:

```bash
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members~^serviceAccount:${PREFIX}-" \
  --format="table(bindings.members:label=MEMBER,bindings.role:label=ROLE)"
```

## 3. Private by default

The control plane has a DNS endpoint only (`ipEndpointsConfig.enabled: false`), and the nodes have no external IPs:

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" \
  --format="yaml(controlPlaneEndpointsConfig.ipEndpointsConfig.enabled,controlPlaneEndpointsConfig.dnsEndpointConfig.endpoint)"
kubectl get nodes -o custom-columns=NODE:.metadata.name,EXTERNAL_IP:.status.addresses[?\(@.type==\"ExternalIP\"\)].address
```

A public load balancer can't be created. Expected failure:

```bash no-fail
kubectl create service loadbalancer public-lb-test -n dev --tcp=80:8080 --dry-run=server
```

## 4. Controlled egress

Approved destinations work through the static NAT IP. Everything else times out (expected failure for the second command):

```bash no-fail
kubectl exec -n dev toolbox -- curl -sS --max-time 10 https://ifconfig.me; echo
kubectl exec -n dev toolbox -- curl -sS --max-time 10 -o /dev/null https://example.com
```

## 5. TLS, WAF and rate limiting

```bash no-fail
curl -s -o /dev/null -w "HTTP  -> %{http_code} %{redirect_url}\n" "http://${GATEWAY_IP}/"
curl -sk -o /dev/null -w "HTTPS -> %{http_code}\n" "https://${GATEWAY_IP}/"
curl -sk -o /dev/null -w "SQLi  -> %{http_code}\n" "https://${GATEWAY_IP}/?id=1%27%20OR%20%271%27=%271"
echo | openssl s_client -connect "${GATEWAY_IP}:443" -tls1_1 -cipher 'DEFAULT:@SECLEVEL=0' 2>&1 | grep -o "alert protocol version"
```

Expected: `301`, `200`, `403`, and `alert protocol version`: the load balancer refuses TLS 1.1 because of the MODERN SSL policy (TLS 1.2+).

## 6. Network isolation

A Pod in `dev` can't reach the shop. Expected failure (timeout):

```bash no-fail
kubectl exec -n dev toolbox -- curl -sS --max-time 5 -o /dev/null http://frontend.onlineboutique.svc.cluster.local
```

## 7. Only approved images

An image from outside your registry is rejected by Binary Authorization. Expected failure:

```bash no-fail
kubectl run unapproved-image -n dev --image=nginx:1.29 --restart=Never
```

The rejection was a real decision, not a fail-open (Lab 04, step 6, explains the difference). The audit log entry of the denied request names the webhook in its status message, and its `labels` contain no `failed-open` entry:

```bash
sleep 60
gcloud logging read --freshness=10m --limit=1 \
  'log_id("cloudaudit.googleapis.com/activity") AND protoPayload.methodName="io.k8s.core.v1.pods.create" AND protoPayload.resourceName="core/v1/namespaces/dev/pods/unapproved-image"' \
  --format="yaml(protoPayload.status.message,labels)"
```

Your repository's images are scanned:

```bash
gcloud artifacts docker images list "${AR_PATH}" --show-occurrences --show-occurrences-from=20 \
  --format="table(package.basename():label=IMAGE,vuln_counts.CRITICAL:label=CRITICAL,vuln_counts.HIGH:label=HIGH)"
```

## 8. Secrets outside the cluster, customer-managed key for Kubernetes Secrets

The application namespaces hold **no** Kubernetes Secrets. The database password comes from Secret Manager:

```bash
kubectl get secrets -n onlineboutique
kubectl get secrets -n secrets-demo
gcloud secrets list --filter="name~${PREFIX}-" --format="table(name.basename(),replication.userManaged.replicas[0].location:label=LOCATION)"
```

Kubernetes Secrets in etcd are encrypted with your Cloud KMS key:

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" --format="yaml(databaseEncryption)"
```

## 9. Guardrails

```bash
kubectl get validatingadmissionpolicybindings
kubectl get namespaces -L pod-security.kubernetes.io/enforce | grep -E "NAME|onlineboutique|secrets-demo|dev|gateway-infra"
```

A privileged Pod is rejected. Expected failure:

```bash no-fail
kubectl run privileged-test -n onlineboutique --image="${TOOLBOX_IMAGE}" --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"privileged-test","image":"'"${TOOLBOX_IMAGE}"'","securityContext":{"privileged":true}}]}}'
```

## 10. Audit logging and alerting

Every `kubectl exec` is recorded, with who ran which command:

```bash
gcloud logging read --freshness=24h --limit=3 \
  'log_id("cloudaudit.googleapis.com/activity") AND protoPayload.methodName=~"io.k8s.core.v1.pods.exec.*"' \
  --format="table(timestamp.date('%m-%d %H:%M'):label=TIME,protoPayload.authenticationInfo.principalEmail:label=WHO,labels.\"command.gke.io/command\":label=COMMAND)"
```

```bash
gcloud monitoring policies list --format="table(displayName,enabled)"
```

Reads of the database password are recorded as Data Access audit logs, and a copy of every audit log entry is kept in your dedicated audit log bucket:

```bash
gcloud projects get-iam-policy "${PROJECT_ID}" --format="yaml(auditConfigs)"
gcloud logging sinks describe "${AUDIT_SINK}" --format="value(destination,filter)"
gcloud logging read --bucket="${AUDIT_BUCKET}" --location="${REGION}" --view=_AllLogs --freshness=1h --limit=3 \
  'protoPayload.methodName="google.cloud.secretmanager.v1.SecretManagerService.AccessSecretVersion"' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,protoPayload.authenticationInfo.principalSubject:label=CALLER)"
```

Reads of Kubernetes Secrets through the API server are recorded too (the `auditConfigs` output above lists `container.googleapis.com`). Read the shop namespace's Secrets, then find the entry:

```bash
kubectl get secrets -n onlineboutique
sleep 60
gcloud logging read --freshness=10m --limit=3 \
  'log_id("cloudaudit.googleapis.com/data_access") AND protoPayload.serviceName="k8s.io" AND protoPayload.methodName=~"io.k8s.core.v1.secrets.(get|list)" AND NOT protoPayload.authenticationInfo.principalEmail=~"^system:"' \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,protoPayload.authenticationInfo.principalEmail:label=WHO,protoPayload.methodName:label=METHOD,protoPayload.resourceName:label=RESOURCE)"
```

## 11. Cost visibility

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" --format="value(costManagementConfig.enabled)"
kubectl get vpa,hpa -n onlineboutique
```

## 12. Controlled upgrades, backup and restore

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" \
  --format="yaml(releaseChannel,maintenancePolicy.window,notificationConfig.pubsub.enabled)"
kubectl get pdb -n onlineboutique
gcloud beta container backup-restore backups list --backup-plan="${PREFIX}-shop-plan" --location="${REGION}" \
  --format="table(name.basename(),state,createTime.date('%m-%d %H:%M'))"
```

Every service with two replicas runs them in two different zones, so it survives the loss of a zone:

```bash
./scripts/show-zone-spread.sh
```

## Congratulations

You have built a production-grade GKE platform from scratch. It is private by default, its egress and ingress are controlled and logged, workloads are guarded at admission time, secrets live outside the cluster, everything is observable, costs are visible, and operations are routine.

## Next Steps

[Cleanup](../99-cleanup/README.md)

## Key Links

- [GKE best practices](https://cloud.google.com/kubernetes-engine/docs/best-practices)
- [Best practices for hardening your cluster](https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster)
- [Google Cloud Well-Architected Framework](https://cloud.google.com/architecture/framework)
