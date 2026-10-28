# Cleanup

The workshop's resources keep incurring charges until you delete them. Choose one of the two options below.

> [!CAUTION]
> Both options are **irreversible**. Make sure you are in the right project: `echo ${PROJECT_ID}`.

## Option A (recommended): delete the project

If you used a dedicated project for the workshop, deleting it removes everything at once. Project deletion is final after a 30-day recovery window.

```bash skip
gcloud projects delete "${PROJECT_ID}"
```

## Option B: delete the resources one by one

Run the steps **in this order**. Run `source ./env.sh` first if you opened a new Cloud Shell session.

> [!NOTE]
> Did you build Labs 02 and 03 with the [Terraform appendix](../appendix-terraform/README.md#cleanup)? Then follow the cleanup section there instead: it runs some of the steps below and lets Terraform delete the rest.

### 1. Delete the application and the Gateway

Delete the Gateway **first**: the GKE Gateway controller then removes the load balancer it created (forwarding rules, proxies, URL maps, backend services, health checks and firewall rules). Deleting the cluster first can leave these behind.

```bash
kubectl delete -k 05-deploy-app/online-boutique --ignore-not-found --wait=false
kubectl delete gateway external-gateway -n gateway-infra --ignore-not-found
for i in $(seq 1 30); do
  LEFT="$(gcloud compute forwarding-rules list --global --filter="IPAddress=${GATEWAY_IP}" --format='value(name)' | wc -l)"
  if [ "${LEFT}" -eq 0 ]; then echo "Load balancer deleted."; break; fi
  echo "Waiting for the load balancer to be deleted..."; sleep 20
done
```

The frontend Service's **network endpoint groups** (NEGs) are deleted shortly after the load balancer. Wait for them too; leftover NEGs would prevent deleting the subnet in step 5:

```bash
for i in $(seq 1 45); do
  LEFT="$(gcloud compute network-endpoint-groups list --filter="network~/${VPC_NAME}\$" --format='value(name)' 2>/dev/null | wc -l)"
  if [ "${LEFT}" -eq 0 ]; then echo "Network endpoint groups deleted."; break; fi
  echo "Waiting for ${LEFT} network endpoint groups to be deleted..."; sleep 20
done
```

### 2. Delete Backup for GKE resources

Backups and restores must be deleted before their plans:

```bash
for R in $(gcloud beta container backup-restore restores list --restore-plan="${PREFIX}-shop-restore" --location="${REGION}" --format='value(name.basename())' 2>/dev/null); do
  gcloud beta container backup-restore restores delete "${R}" --restore-plan="${PREFIX}-shop-restore" --location="${REGION}" --quiet
done
gcloud beta container backup-restore restore-plans delete "${PREFIX}-shop-restore" --location="${REGION}" --quiet
for B in $(gcloud beta container backup-restore backups list --backup-plan="${PREFIX}-shop-plan" --location="${REGION}" --format='value(name.basename())' 2>/dev/null); do
  gcloud beta container backup-restore backups delete "${B}" --backup-plan="${PREFIX}-shop-plan" --location="${REGION}" --quiet
done
gcloud beta container backup-restore backup-plans delete "${PREFIX}-shop-plan" --location="${REGION}" --quiet
```

### 3. Delete the cluster

This takes about 5-10 minutes.

```bash
gcloud container clusters delete "${CLUSTER_NAME}" --location="${REGION}" --quiet
```

### 4. Delete the edge resources

```bash
gcloud compute security-policies delete "${ARMOR_POLICY}" --global --quiet
gcloud compute ssl-policies delete "${SSL_POLICY}" --global --quiet
gcloud compute addresses delete "${GATEWAY_IP_NAME}" --global --quiet
```

### 5. Delete the network

```bash
gcloud compute routers nats delete "${NAT_NAME}" --router="${ROUTER_NAME}" --region="${REGION}" --quiet
gcloud compute routers delete "${ROUTER_NAME}" --region="${REGION}" --quiet
gcloud compute addresses delete "${NAT_IP_NAME}" --region="${REGION}" --quiet
gcloud compute network-firewall-policies associations delete \
  --firewall-policy="${FW_POLICY_NAME}" --name="${FW_POLICY_NAME}-assoc" --global-firewall-policy
gcloud compute network-firewall-policies delete "${FW_POLICY_NAME}" --global --quiet
```

GKE deletes its own firewall rules with the cluster. Remove any leftovers, then the subnet and the VPC:

```bash
for RULE in $(gcloud compute firewall-rules list --filter="network~/${VPC_NAME}\$" --format='value(name)'); do
  gcloud compute firewall-rules delete "${RULE}" --quiet
done
gcloud compute networks subnets delete "${SUBNET_NAME}" --region="${REGION}" --quiet
gcloud compute networks delete "${VPC_NAME}" --quiet
```

### 6. Delete images, secrets, keys and identities

```bash
gcloud artifacts repositories delete "${AR_REPO}" --location="${REGION}" --quiet
gcloud secrets delete "${PREFIX}-db-password" --quiet
```

Remove the project-level roles of the two service accounts from Lab 02, then delete the service accounts:

```bash
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${NODE_SA_EMAIL}" \
  --role="roles/container.defaultNodeServiceAccount" \
  --condition=None --format=none
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${MIRROR_SA_EMAIL}" \
  --role="roles/logging.logWriter" \
  --condition=None --format=none
gcloud iam service-accounts delete "${NODE_SA_EMAIL}" --quiet
gcloud iam service-accounts delete "${MIRROR_SA_EMAIL}" --quiet
```

Cloud KMS key rings and keys can't be deleted. Schedule all key versions for destruction instead; versions are destroyed after a 30-day waiting period:

```bash
for V in $(gcloud kms keys versions list --key="${KMS_KEY}" --keyring="${KMS_KEYRING}" --location="${REGION}" --filter="state=ENABLED OR state=DISABLED" --format='value(name.basename())'); do
  gcloud kms keys versions destroy "${V}" --key="${KMS_KEY}" --keyring="${KMS_KEYRING}" --location="${REGION}" --quiet
done
```

### 7. Delete monitoring, audit logging and notification resources, and reset Binary Authorization

```bash
for P in $(gcloud monitoring policies list --filter='displayName:"GKE: command executed" OR displayName:"Cloud Armor: requests blocked" OR displayName:"Online Boutique: Deployment"' --format='value(name)'); do
  gcloud monitoring policies delete "${P}" --quiet
done
gcloud pubsub subscriptions delete "${PREFIX}-gke-notifications-sub" --quiet
gcloud pubsub topics delete "${PREFIX}-gke-notifications" --quiet
```

If you created an email notification channel in Lab 08, delete it too:

```bash skip
gcloud beta monitoring channels delete "${CHANNEL_ID}" --quiet
```

Delete the audit log sink and bucket from Lab 08, and turn the Data Access audit logs for Secret Manager, Cloud KMS and the Kubernetes Engine API off again. The `jq` filter removes only these three entries from the project's IAM policy:

```bash
gcloud logging sinks delete "${AUDIT_SINK}" --quiet
gcloud logging buckets delete "${AUDIT_BUCKET}" --location="${REGION}" --quiet
gcloud projects get-iam-policy "${PROJECT_ID}" --format=json > /tmp/iam-policy.json
jq '.auditConfigs = [(.auditConfigs // [])[] | select(.service != "secretmanager.googleapis.com" and .service != "cloudkms.googleapis.com" and .service != "container.googleapis.com")]' \
  /tmp/iam-policy.json > /tmp/iam-policy-audit.json
gcloud projects set-iam-policy "${PROJECT_ID}" /tmp/iam-policy-audit.json --format=none
gcloud projects get-iam-policy "${PROJECT_ID}" --format="yaml(auditConfigs)"
```

The last command prints `null`: no Data Access audit logs are configured any more (unless your project had them for other services before the workshop). The deleted log bucket stays in the `DELETE_REQUESTED` state for 7 days before Cloud Logging removes it.

The Binary Authorization policy from Lab 06 belongs to the **project** and would keep blocking images in future clusters that enforce it. Restore the default policy (allow everything), the one you exported at the start of Lab 06:

```bash
cat > /tmp/binauthz-default-policy.yaml <<EOF
name: projects/${PROJECT_ID}/policy
globalPolicyEvaluationMode: ENABLE
defaultAdmissionRule:
  evaluationMode: ALWAYS_ALLOW
  enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
EOF
gcloud container binauthz policy import /tmp/binauthz-default-policy.yaml
```

### 8. Verify

Nothing with your prefix should remain. Each command prints nothing (or only a warning that a filter key wasn't present, which means the list is empty):

```bash
gcloud container clusters list --format="value(name)"
gcloud compute addresses list --filter="name~^${PREFIX}-" --format="value(name)"
gcloud compute networks list --filter="name~^${PREFIX}-" --format="value(name)"
gcloud artifacts repositories list --location="${REGION}" --filter="name~${PREFIX}-" --format="value(name)"
gcloud iam service-accounts list --filter="email~^${PREFIX}-" --format="value(email)"
gcloud compute forwarding-rules list --format="value(name)"
```

The Cloud KMS key ring and key remain, because they can't be deleted. Their key versions are destroyed after the 30-day waiting period. The names stay taken, so use a new `PREFIX` if you run the workshop again in the same project.

Finally, delete the local copy of the self-signed key:

```bash
rm -rf tls/
```
