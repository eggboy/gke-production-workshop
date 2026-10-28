# Lab 07 - Cost Governance

Cost governance is the continuous process of making cloud spend **visible**, **attributable** and **efficient**. For Kubernetes that means knowing what each team and namespace costs, requesting the right amount of CPU and memory, scaling with demand, and using cheaper capacity where it's safe.

In this lab you will:

1. See how GKE attributes costs to namespaces and labels (cost allocation).
2. Start simulated shoppers, so the next steps have real usage to measure.
3. Compare what workloads request with what they actually use.
4. Get right-sizing recommendations from the Vertical Pod Autoscaler.
5. Scale the storefront with demand using the Horizontal Pod Autoscaler, then stop the simulated shoppers.
6. Tune the cluster autoscaler for utilization.
7. Run a batch job on cheaper **Spot VMs**.

**Estimated time:** 45 minutes

> [!NOTE]
> Run `source ./env.sh` first if you opened a new Cloud Shell session.

## 1. Cost allocation: costs per namespace and team

The cluster was created with `--enable-cost-allocation`. GKE then adds **namespace** and **Kubernetes label** information to your Cloud Billing data, so the cost of each Pod's requested CPU and memory can be attributed to a namespace and team. This is what makes chargeback per team possible (requirement 11).

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" \
  --format="yaml(costManagementConfig,resourceLabels)"
```

The namespaces carry a `team` label (Lab 04), which becomes a cost dimension:

```bash
kubectl get namespaces -L team | grep -v -E "^(kube-|gke-|gmp-)"
```

To analyze these costs, a billing administrator enables [Cloud Billing export to BigQuery](https://cloud.google.com/billing/docs/how-to/export-data-bigquery) (detailed usage cost). GKE costs then appear per cluster, namespace and label. You can also open **Billing > Reports** and group by the label keys, or use the **Kubernetes Engine > Cost optimization** page.

> [!NOTE]
> Billing export is configured on the **billing account**, which usually needs billing-admin permissions. In a classroom, the instructor typically demonstrates this part. Cost data appears in Cloud Billing with a delay of several hours.

## 2. Start simulated shoppers

Usage numbers, VPA recommendations and the HPA all need traffic. Online Boutique ships a **load generator** ([Locust](https://locust.io/)) that simulates shoppers browsing, adding to cart and checking out. It calls the `frontend` Service from inside the cluster, not through the load balancer. Lab 05 left it out so it doesn't run, and fill the logs, all day. [`loadgenerator.yaml`](manifests/loadgenerator.yaml) starts it with 10 concurrent shoppers; you delete it again at the end of step 5.

```bash
envsubst '${AR_PATH} ${OB_VERSION}' < 07-cost-governance/manifests/loadgenerator.yaml | kubectl apply -f -
kubectl rollout status deployment/loadgenerator -n onlineboutique --timeout=300s
```

The rollout waits for the init container to reach the storefront, then for Locust to start. Give it a minute of traffic before the next step, so `metrics-server` has fresh usage data:

```bash
sleep 60
kubectl logs -n onlineboutique deploy/loadgenerator --tail=5
```

## 3. Requests versus actual usage

The scheduler reserves capacity based on **requests**, and that's what you pay for. Compare the requests of each Online Boutique service with its actual usage (from `metrics-server`):

```bash
kubectl get pods -n onlineboutique \
  -o custom-columns=POD:.metadata.name,CPU_REQUEST:.spec.containers[0].resources.requests.cpu,MEMORY_REQUEST:.spec.containers[0].resources.requests.memory
```

```bash
kubectl top pods -n onlineboutique --sort-by=cpu
```

Most services use far less than they request. The difference is **idle cost**, and right-sizing reduces it.

> [!IMPORTANT]
> Requests also decide the **Quality of Service** class:
> - **Guaranteed:** requests equal limits for every container.
> - **Burstable:** some requests or limits are set.
> - **BestEffort:** none are set.
>
> Under memory pressure, BestEffort Pods are evicted first. A container that exceeds its **memory limit** is OOM-killed; one that exceeds its **CPU limit** is throttled. The LimitRange from Lab 04 makes sure no container in the application namespaces runs without requests.

## 4. Right-sizing with Vertical Pod Autoscaler recommendations

The cluster was created with `--enable-vertical-pod-autoscaling`. A `VerticalPodAutoscaler` in **`Off` mode** only *observes* a workload and recommends requests; it never restarts Pods. Create VPAs for three services, together with an HPA for the frontend (used in the next step):

```bash
kubectl apply -f 07-cost-governance/manifests/autoscaling.yaml
```

The recommender needs a few minutes of usage data. Then compare the recommendation (`TARGET`) with the current requests:

```bash
for i in $(seq 1 20); do
  if kubectl get vpa frontend -n onlineboutique -o jsonpath='{.status.recommendation.containerRecommendations[0].target}' 2>/dev/null | grep -q cpu; then break; fi
  echo "Waiting for VPA recommendations..."; sleep 30
done
kubectl get vpa -n onlineboutique
```

```bash
kubectl get vpa frontend -n onlineboutique \
  -o jsonpath='{range .status.recommendation.containerRecommendations[*]}{.containerName}: target={.target} lowerBound={.lowerBound} upperBound={.upperBound}{"\n"}{end}'
```

```text
server: target={"cpu":"25m","memory":"20Mi"} lowerBound={"cpu":"20m","memory":"20Mi"} upperBound={"cpu":"60m","memory":"48Mi"}
```

The frontend requests `100m` CPU and `64Mi` memory, but the VPA recommends a fraction of that for the current traffic.

> [!TIP]
> The same recommendations appear in the console under **Kubernetes Engine > Workloads > (workload) > Actions > Scale > Edit resource requests**, and on the **Cost optimization** page. Apply them through your manifests, not by hand.

## 5. Scale with demand: Horizontal Pod Autoscaler

The HPA you just created keeps **at least 2** frontend replicas, for availability, and adds replicas when average CPU utilization exceeds 60% of the requested CPU:

```bash
kubectl get hpa frontend -n onlineboutique
```

Generate more traffic by turning up the load generator from step 2. Raise it from 10 to 150 concurrent shoppers:

```bash
kubectl set env deployment/loadgenerator -n onlineboutique USERS=150 RATE=10
kubectl rollout status deployment/loadgenerator -n onlineboutique --timeout=180s
```

Watch the HPA react. It evaluates metrics every 15 seconds and scales out within a few minutes:

```bash
for i in $(seq 1 16); do
  echo "$(date +%H:%M:%S)  $(kubectl get hpa frontend -n onlineboutique \
    -o jsonpath='cpu={.status.currentMetrics[0].resource.current.averageUtilization}% (target 60%)  replicas={.status.currentReplicas}')"
  sleep 15
done
```

The output looks like this (your numbers will differ). CPU utilization jumps above the target, the HPA adds replicas, and utilization drops back to around 60%. The HPA tolerates a deviation of up to 10% from the target, so it doesn't keep adding replicas for, say, 63%:

```text
02:04:35  cpu=16% (target 60%)  replicas=2
02:04:50  cpu=96% (target 60%)  replicas=2
02:05:06  cpu=96% (target 60%)  replicas=4
02:06:07  cpu=56% (target 60%)  replicas=4
```

The load generator has done its job: the VPA has usage data and you've seen the HPA scale out. **Delete it**, so it doesn't keep generating traffic and logs for the rest of the workshop:

```bash
envsubst '${AR_PATH} ${OB_VERSION}' < 07-cost-governance/manifests/loadgenerator.yaml | kubectl delete -f -
kubectl get deployment loadgenerator -n onlineboutique --ignore-not-found
```

The second command prints nothing. Without the load, the HPA scales the frontend back to its minimum of 2 replicas after its stabilization window (5 minutes by default). If the extra replicas didn't fit on the existing nodes, the **cluster autoscaler** added nodes; it removes them again when they are no longer needed.

## 6. Tune the cluster autoscaler

The cluster autoscaler has two profiles:

| Profile | Behavior |
|---|---|
| `balanced` (default) | Keeps some headroom, scales down conservatively |
| `optimize-utilization` | Scales down faster and packs Pods more tightly. Cheaper, with slightly more Pod churn. |

Switch the cluster to `optimize-utilization`. The update takes up to 10 minutes; the cluster and the application stay available while GKE applies it:

```bash
gcloud container clusters update "${CLUSTER_NAME}" --location="${REGION}" \
  --autoscaling-profile=optimize-utilization
```

## 7. Run batch work on Spot VMs

**Spot VMs** cost far less than regular VMs, but Compute Engine can reclaim them at any time with a short notice. They are a good fit for batch jobs, CI runners and other interruptible work, but **not** for the storefront.

Create a small Spot node pool in a single zone. It is **tainted**, so only workloads that explicitly tolerate Spot capacity land on it. It uses the same hardening as the default pool:

```bash
ZONE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/zone}')"
gcloud container node-pools create spot-pool \
  --cluster="${CLUSTER_NAME}" \
  --location="${REGION}" \
  --node-locations="${ZONE}" \
  --spot \
  --machine-type=e2-standard-2 \
  --num-nodes=1 \
  --enable-autoscaling --min-nodes=0 --max-nodes=2 \
  --node-taints=cloud.google.com/gke-spot=true:NoSchedule \
  --service-account="${NODE_SA_EMAIL}" \
  --image-type=COS_CONTAINERD \
  --disk-type=pd-balanced \
  --disk-size=50 \
  --shielded-secure-boot \
  --shielded-integrity-monitoring
```

Run a batch Job ([`spot-job.yaml`](manifests/spot-job.yaml)) that selects Spot nodes and tolerates the taint:

```bash
envsubst '${AR_PATH}' < 07-cost-governance/manifests/spot-job.yaml | kubectl apply -f -
kubectl wait job/spot-batch -n dev --for=condition=Complete --timeout=10m
kubectl get pods -n dev -l app=spot-batch -o wide
```

All three Pods ran on the `spot-pool` node. Check the node's labels:

```bash
kubectl get nodes -l cloud.google.com/gke-spot=true -L cloud.google.com/gke-nodepool,cloud.google.com/gke-spot
```

Clean up the Job and the Spot pool. The pool could also stay and scale to zero when idle.

```bash
kubectl delete job spot-batch -n dev
gcloud container node-pools delete spot-pool \
  --cluster="${CLUSTER_NAME}" --location="${REGION}" --quiet
```

## 8. Quotas keep teams within budget

The ResourceQuotas from Lab 04 cap what each namespace can request:

```bash
kubectl describe resourcequota onlineboutique-quota -n onlineboutique
```

## Next Steps

[Lab 08 - Cluster Monitoring](../08-cluster-monitoring/README.md)

## Key Links

- [GKE cost allocation](https://cloud.google.com/kubernetes-engine/docs/how-to/cost-allocations)
- [Best practices for running cost-optimized Kubernetes applications on GKE](https://cloud.google.com/architecture/best-practices-for-running-cost-effective-kubernetes-applications-on-gke)
- [Vertical Pod autoscaling](https://cloud.google.com/kubernetes-engine/docs/concepts/verticalpodautoscaler) and [Horizontal Pod autoscaling](https://cloud.google.com/kubernetes-engine/docs/concepts/horizontalpodautoscaler)
- [Cluster autoscaler profiles](https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler#autoscaling_profiles)
- [Spot VMs on GKE](https://cloud.google.com/kubernetes-engine/docs/concepts/spot-vms)
