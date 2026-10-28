# Lab 09 - Day-2 Operations

A production cluster is never "done". This lab covers the operational tasks the platform team performs after go-live:

1. Understand versions and upcoming upgrades.
2. Control **when** upgrades happen: maintenance windows and exclusions.
3. Get notified about upgrades and security bulletins.
4. Make workloads resilient to node maintenance: replicas and PodDisruptionBudgets.
5. Choose a node upgrade strategy, and migrate workloads to a new node pool with no downtime.
6. Back up and restore an application with **Backup for GKE**.

**Estimated time:** 60-75 minutes

> [!NOTE]
> Run `source ./env.sh` first if you opened a new Cloud Shell session.

## 1. Versions and upgrade information

GKE upgrades the control plane and nodes automatically within your release channel (Regular). Check the current versions, the channel's targets and any upcoming end-of-support dates:

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" \
  --format="table(currentMasterVersion:label=CONTROL_PLANE,currentNodeVersion:label=NODES,releaseChannel.channel:label=CHANNEL)"
gcloud container clusters get-upgrade-info "${CLUSTER_NAME}" --location="${REGION}"
```

> [!NOTE]
> The control plane supports nodes up to two minor versions older than itself (version skew policy). Nodes can never be newer than the control plane.

## 2. Control when upgrades happen

The cluster has a **maintenance window** (weekends, 18:00-24:00 UTC) from Lab 03. A **maintenance exclusion** pauses automatic upgrades for a period, for example a peak sales season. Scope `no_minor_or_node_upgrades` still allows control plane **security patches**:

```bash
START="$(date -u -d '+7 days' +%Y-%m-%dT00:00:00Z)"
END="$(date -u -d '+10 days' +%Y-%m-%dT23:59:59Z)"
gcloud container clusters update "${CLUSTER_NAME}" --location="${REGION}" \
  --add-maintenance-exclusion-name=peak-season-freeze \
  --add-maintenance-exclusion-start="${START}" \
  --add-maintenance-exclusion-end="${END}" \
  --add-maintenance-exclusion-scope=no_minor_or_node_upgrades
```

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" --format="yaml(maintenancePolicy)"
```

Remove the exclusion again:

```bash
gcloud container clusters update "${CLUSTER_NAME}" --location="${REGION}" \
  --remove-maintenance-exclusion=peak-season-freeze
```

## 3. Get notified about upgrades and security bulletins

GKE can publish cluster events to **Pub/Sub**: upgrades available, upgrades started and security bulletins that affect your cluster. From there you can route them to email, chat or a ticketing system.

```bash
gcloud pubsub topics create "${PREFIX}-gke-notifications"
gcloud pubsub subscriptions create "${PREFIX}-gke-notifications-sub" --topic="${PREFIX}-gke-notifications"
gcloud container clusters update "${CLUSTER_NAME}" --location="${REGION}" \
  --notification-config="pubsub=ENABLED,pubsub-topic=projects/${PROJECT_ID}/topics/${PREFIX}-gke-notifications,filter=UpgradeEvent|UpgradeAvailableEvent|SecurityBulletinEvent"
```

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" --format="yaml(notificationConfig)"
```

Messages arrive only when an event occurs. Check the subscription from time to time (it is probably empty now):

```bash
gcloud pubsub subscriptions pull "${PREFIX}-gke-notifications-sub" --limit=5 --auto-ack
```

## 4. Make the application resilient to node maintenance

Node upgrades, repairs and scale-downs **drain** nodes: Pods are evicted and rescheduled elsewhere. Whole zones can fail, too. A service with a single replica is unavailable while its Pod restarts. Three things protect availability:

- **At least two replicas** of every stateless service. The frontend already has a minimum of 2 from the HPA in Lab 07.
- **Topology spread constraints**, added to every Deployment by the overlay in Lab 05: the replicas of a service run in different zones, and preferably on different nodes. Losing a node, or a whole zone, never takes down every replica.
- A **PodDisruptionBudget** (PDB) per service, so a drain never evicts the last running replica.

```bash
kubectl scale deployment -n onlineboutique --replicas=2 \
  adservice cartservice checkoutservice currencyservice emailservice \
  paymentservice productcatalogservice recommendationservice shippingservice
kubectl apply -f 09-day2-operations/manifests/pdbs.yaml
kubectl wait deployment --all -n onlineboutique --for=condition=Available --timeout=5m
kubectl get pdb -n onlineboutique
```

Check where the replicas run. [`show-zone-spread.sh`](../scripts/show-zone-spread.sh) lists the zone of every running Pod per service:

```bash
./scripts/show-zone-spread.sh
```

Every service with two Pods uses two different zones:

```text
APP                      PODS  NODES  ZONES
adservice                2     2      asia-southeast1-a asia-southeast1-c
cartservice              2     2      asia-southeast1-b asia-southeast1-a
...
redis-cart               1     1      asia-southeast1-c
```

> [!IMPORTANT]
> `redis-cart` keeps shopping carts **in memory** with a single replica. It can't be made highly available by adding replicas, and a PDB would block every drain forever. When it moves, active carts are lost. In production, use a managed, replicated data store such as [Memorystore for Redis](https://cloud.google.com/memorystore/docs/redis) for state, and keep Pods stateless. (Online Boutique provides a `memorystore` Kustomize component for exactly this.)

> [!NOTE]
> `kubectl scale` is used for speed. In a real setup the replica counts belong in the application's manifests.

## 5. Node upgrade strategies and node pool migration

GKE supports two automatic node upgrade strategies:

| Strategy | How it works | Use when |
|---|---|---|
| **Surge** (current) | Creates `maxSurge` new nodes, then drains and deletes old ones, a few at a time | Default; low extra cost |
| **Blue-green** | Creates a complete new set of nodes (green), drains the old set (blue) in batches, then soaks before deleting blue. Rollback is fast. | Critical workloads; needs temporary double capacity |

Inspect the default pool's current settings, then switch it to blue-green to see the configuration:

```bash
gcloud container node-pools describe default-pool --cluster="${CLUSTER_NAME}" --location="${REGION}" \
  --format="yaml(upgradeSettings)"
```

```bash
gcloud container node-pools update default-pool --cluster="${CLUSTER_NAME}" --location="${REGION}" \
  --enable-blue-green-upgrade \
  --node-pool-soak-duration=600s \
  --standard-rollout-policy=batch-node-count=1,batch-soak-duration=60s
gcloud container node-pools describe default-pool --cluster="${CLUSTER_NAME}" --location="${REGION}" \
  --format="yaml(upgradeSettings)"
```

Some changes, such as a new machine type or image, need a **new node pool**. Migrate the workloads yourself, the same way blue-green upgrades work, while measuring the storefront's availability.

Create the new pool `pool-v2` with the same hardening:

```bash
gcloud container node-pools create pool-v2 \
  --cluster="${CLUSTER_NAME}" \
  --location="${REGION}" \
  --machine-type=e2-standard-4 \
  --num-nodes=1 \
  --enable-autoscaling --min-nodes=1 --max-nodes=3 --location-policy=BALANCED \
  --service-account="${NODE_SA_EMAIL}" \
  --image-type=COS_CONTAINERD \
  --disk-type=pd-balanced \
  --disk-size=50 \
  --shielded-secure-boot \
  --shielded-integrity-monitoring \
  --workload-metadata=GKE_METADATA \
  --max-surge-upgrade=1 \
  --max-unavailable-upgrade=0
kubectl get nodes -L cloud.google.com/gke-nodepool
```

Start an availability probe in the background. It requests the storefront every 2 seconds for about 6 minutes:

```bash
( for i in $(seq 1 180); do
    curl -sk -o /dev/null --max-time 5 -w "%{http_code}\n" "https://${GATEWAY_IP}/" || true
    sleep 2
  done > /tmp/availability.log ) &
PROBE_PID=$!
```

**Cordon** the old nodes (no new Pods), then **drain** them one by one. Evictions respect the PDBs:

```bash
kubectl cordon -l cloud.google.com/gke-nodepool=default-pool
for NODE in $(kubectl get nodes -l cloud.google.com/gke-nodepool=default-pool -o name); do
  kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --force --timeout=600s
done
```

| Option | Why |
|---|---|
| `--ignore-daemonsets` | DaemonSet Pods (logging, networking) run on every node and are not moved |
| `--delete-emptydir-data` | Allows evicting Pods that use `emptyDir` scratch volumes; that data is lost |
| `--force` | Also deletes Pods that no controller manages, such as the `toolbox` test Pod. Without it, `drain` refuses, because those Pods are **deleted, not rescheduled**. This is one more reason to run real workloads as Deployments, StatefulSets or Jobs. |

All application Pods now run on `pool-v2`:

```bash
kubectl get pods -n onlineboutique -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase
```

The topology spread constraints still apply: every service with two replicas runs them in two different zones, now on the nodes of `pool-v2`:

```bash
./scripts/show-zone-spread.sh
```

The `toolbox` Pod was deleted by the drain. Create it again, on the new pool (Lab 10 uses it):

```bash
envsubst '${TOOLBOX_IMAGE}' < 04-cluster-post-provisioning/manifests/toolbox.yaml | kubectl apply -f -
kubectl wait pod/toolbox -n dev --for=condition=Ready --timeout=180s
```

Wait for the probe to finish and summarize the HTTP status codes it saw:

```bash
wait "${PROBE_PID}"
sort /tmp/availability.log | uniq -c
```

Nearly all requests return `200`. The frontend Pods move without errors thanks to the graceful shutdown from Lab 05: each Pod keeps serving for 20 seconds after it is asked to stop (`preStop` sleep), while the load balancer stops sending it new requests and lets requests in flight finish (connection draining). Without this, every frontend move costs a few failed requests (`502`/`503` or timeouts). An occasional error can still appear while `redis-cart`, the single stateful replica, restarts on a new node. That is the lesson from step 4: stateless replicas with PDBs and graceful shutdown survive maintenance, singletons don't.

Delete the old node pool (about 3-5 minutes):

```bash
gcloud container node-pools delete default-pool \
  --cluster="${CLUSTER_NAME}" --location="${REGION}" --quiet
gcloud container node-pools list --cluster="${CLUSTER_NAME}" --location="${REGION}"
```

> [!TIP]
> **Isolating GKE system components on a dedicated node pool:** Instead of deleting `default-pool`, larger or multi-tenant production clusters often repurpose a small 3-node pool (1 per zone) as a dedicated **system pool** by tainting it with `--node-taints=components.gke.io/gke-managed-components=true:NoSchedule` (`gcloud container node-pools update ... --node-taints=...`). Every GKE-managed Deployment and StatefulSet (`kube-dns`, `konnectivity-agent`, `metrics-server`, `gmp-operator`, `kube-state-metrics`, `hubble-relay`, `event-exporter-gke`, `l7-default-backend`) carries a built-in toleration for `components.gke.io/gke-managed-components`, while user Pods do not. Because those GKE system Pods have only a toleration (not `nodeAffinity`), also taint your application pool(s) (for example `--node-taints=workload=apps:NoSchedule --node-labels=workload=apps`) so GKE system Deployments can't land on app nodes. See [Lab 01 - Nodes](../01-cluster-design/README.md#5-nodes).

## 6. Backup and restore with Backup for GKE

[Backup for GKE](https://cloud.google.com/kubernetes-engine/docs/add-on/backup-for-gke/concepts/backup-for-gke) backs up Kubernetes resources, and optionally persistent volume data, so you can recover from mistakes such as a deleted namespace, or clone workloads to another cluster.

Backup for GKE needs its agent in the cluster. Enable the add-on (about 10 minutes; the cluster stays available):

```bash
gcloud container clusters update "${CLUSTER_NAME}" --location="${REGION}" \
  --update-addons=BackupRestore=ENABLED
```

Create a **backup plan** for the `onlineboutique` namespace. In production you would add a `--cron-schedule`, and possibly `--locked` retention.

```bash
gcloud beta container backup-restore backup-plans create "${PREFIX}-shop-plan" \
  --location="${REGION}" \
  --cluster="projects/${PROJECT_ID}/locations/${REGION}/clusters/${CLUSTER_NAME}" \
  --selected-namespaces=onlineboutique \
  --include-secrets \
  --include-volume-data \
  --backup-retain-days=7
```

Take a backup now (a few minutes):

```bash
export BACKUP_NAME="manual-$(date +%Y%m%d-%H%M%S)"
gcloud beta container backup-restore backups create "${BACKUP_NAME}" \
  --backup-plan="${PREFIX}-shop-plan" \
  --location="${REGION}" \
  --wait-for-completion
gcloud beta container backup-restore backups describe "${BACKUP_NAME}" \
  --backup-plan="${PREFIX}-shop-plan" --location="${REGION}" \
  --format="yaml(state,resourceCount,podCount,sizeBytes)"
```

Create a **restore plan** that restores the namespace into the same cluster:

```bash
gcloud beta container backup-restore restore-plans create "${PREFIX}-shop-restore" \
  --location="${REGION}" \
  --backup-plan="projects/${PROJECT_ID}/locations/${REGION}/backupPlans/${PREFIX}-shop-plan" \
  --cluster="projects/${PROJECT_ID}/locations/${REGION}/clusters/${CLUSTER_NAME}" \
  --selected-namespaces=onlineboutique \
  --namespaced-resource-restore-mode=fail-on-conflict
```

**Simulate a disaster:** delete the whole namespace. The storefront goes down: the load balancer answers `503` (no backends left) or `404` (route removed), depending on how far its update has progressed. Deleting the namespace takes several minutes (up to 15), because GKE first removes the load balancer backend and the network endpoint groups of the frontend Service:

```bash
kubectl delete namespace onlineboutique --wait=true --timeout=20m
curl -sk -o /dev/null -w "Storefront after deletion: HTTP %{http_code}\n" "https://${GATEWAY_IP}/"
```

Restore from the backup:

```bash
gcloud beta container backup-restore restores create "restore-$(date +%Y%m%d-%H%M%S)" \
  --location="${REGION}" \
  --restore-plan="${PREFIX}-shop-restore" \
  --backup="projects/${PROJECT_ID}/locations/${REGION}/backupPlans/${PREFIX}-shop-plan/backups/${BACKUP_NAME}" \
  --wait-for-completion
```

Everything in the namespace comes back: the Deployments and Services, the namespace's labels (Pod Security, Gateway access), quotas, network policies, RBAC, PDBs, autoscalers, and the Gateway route with its Cloud Armor attachment:

```bash
kubectl get namespace onlineboutique --show-labels
kubectl wait deployment --all -n onlineboutique --for=condition=Available --timeout=10m
kubectl get deploy,httproute,gcpbackendpolicy,networkpolicy,pdb -n onlineboutique
```

The load balancer reattaches to the restored Pods within 5-10 minutes:

```bash
OK=0
for i in $(seq 1 120); do
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' "https://${GATEWAY_IP}/" || true)"
  if [ "${CODE}" = "200" ]; then OK=$((OK + 1)); else OK=0; echo "Waiting for the storefront (HTTPS ${CODE})..."; sleep 10; fi
  if [ "${OK}" -ge 5 ]; then break; fi
done
curl -sk -o /dev/null -w "Storefront after restore: HTTP %{http_code}\n" "https://${GATEWAY_IP}/"
```

## Next Steps

[Lab 10 - Validate Scenarios](../10-validate-scenarios/README.md)

## Key Links

- [Cluster upgrades](https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-upgrades) and [node pool upgrade strategies](https://cloud.google.com/kubernetes-engine/docs/concepts/node-pool-upgrade-strategies)
- [Maintenance windows and exclusions](https://cloud.google.com/kubernetes-engine/docs/concepts/maintenance-windows-and-exclusions)
- [Cluster notifications](https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-notifications)
- [Specifying a disruption budget](https://kubernetes.io/docs/tasks/run-application/configure-pdb/) and [Pod topology spread constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- [Migrating workloads to different machine types](https://cloud.google.com/kubernetes-engine/docs/tutorials/migrating-node-pool)
- [Backup for GKE](https://cloud.google.com/kubernetes-engine/docs/add-on/backup-for-gke/concepts/backup-for-gke)
