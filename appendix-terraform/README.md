# Appendix - Provision Labs 02 and 03 with Terraform

Labs 02 and 03 build the environment and the cluster step by step with `gcloud`, so you see and decide every setting. In production, you would describe the same infrastructure as code, review changes before they are applied, and recreate environments consistently.

This appendix provisions **exactly the same resources as Labs 02 and 03** with Terraform: APIs, service accounts for the nodes and the image mirror, VPC, subnet, Cloud NAT, egress firewall policy, Cloud KMS key, Artifact Registry repository, Gateway IP address and the hardened GKE cluster. Use it **instead of** Labs 02 and 03, for example to set up the environment quickly before Lab 04, or as a starting point for your own infrastructure code.

> [!IMPORTANT]
> This is an alternative to Labs 02 and 03, not an addition. If you already built the environment with `gcloud`, don't apply this configuration with the same `PREFIX` in the same project: every name would collide.

| File | Creates | Same as |
|---|---|---|
| [`versions.tf`](versions.tf), [`variables.tf`](variables.tf) | Pinned Terraform and provider versions (with checksums in `.terraform.lock.hcl`); the inputs `project_id`, `region` and `prefix` | `env.sh`, section 1 |
| [`main.tf`](main.tf) | Resource names (mirroring `env.sh`) and the APIs | Lab 02, step 2 |
| [`iam.tf`](iam.tf) | Node service account with `roles/container.defaultNodeServiceAccount`; image mirror service account with `roles/logging.logWriter` | Lab 02, steps 4 and 10 |
| [`network.tf`](network.tf) | VPC, subnet with secondary ranges and flow logs, Cloud Router, Cloud NAT with a static IP, Gateway IP | Lab 02, steps 5, 6 and 12 |
| [`firewall.tf`](firewall.tf) | Network firewall policy: FQDN allow-list (1000), internet deny (2000), association | Lab 02, step 7 |
| [`kms.tf`](kms.tf) | Key ring, key with 90-day rotation, permission for the GKE service agent | Lab 02, step 8 |
| [`artifact-registry.tf`](artifact-registry.tf) | Docker repository with immutable tags and scanning; read access for the nodes, write access for the image mirror | Lab 02, steps 9 and 10 |
| [`gke.tf`](gke.tf) | The cluster with every Lab 03 setting, and the `default-pool` node pool | Lab 03, step 2 |
| [`outputs.tf`](outputs.tf) | Cluster name, DNS endpoint, NAT and Gateway IPs, repository path, KMS key | |

**Estimated time:** 35 minutes (creating the cluster takes 10-15 minutes)

> [!NOTE]
> Run every command in Cloud Shell, from the **repository root**. The commands use `terraform -chdir=appendix-terraform`, so you never need to change directories.

## 1. Prepare your Cloud Shell session

Set `PROJECT_ID` (and optionally `PREFIX` and `REGION`) in `env.sh` as described in the [README](../README.md#getting-started). Then load the variables and point `gcloud` at your project:

```bash
source ./env.sh
gcloud config set project "${PROJECT_ID}"
gcloud config set compute/region "${REGION}"
```

## 2. Install Terraform

Cloud Shell comes with Terraform, but its version changes over time. Install the version this configuration was validated with into `~/bin`, and verify the download against HashiCorp's checksums:

```bash
TF_VERSION="1.16.6"
mkdir -p "${HOME}/bin"
( cd "$(mktemp -d)" \
  && curl -sSLO "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" \
  && curl -sSLO "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_SHA256SUMS" \
  && sha256sum --ignore-missing -c "terraform_${TF_VERSION}_SHA256SUMS" \
  && unzip -o -q "terraform_${TF_VERSION}_linux_amd64.zip" terraform -d "${HOME}/bin" )
export PATH="${HOME}/bin:${PATH}"
terraform version
```

The first line of the output shows `Terraform v1.16.6`. New Cloud Shell sessions put `~/bin` first in the `PATH` automatically.

## 3. Check prerequisites and quotas

The prerequisite script reads your regional quotas through the Compute Engine API, so enable that API first. Terraform enables all the other APIs in step 5.

```bash
gcloud services enable compute.googleapis.com
./scripts/check-prereqs.sh
```

Every line should show `[OK]`.

## 4. Set the input variables

`terraform.tfvars` holds the same three values as section 1 of `env.sh`. Create it from your environment:

```bash
cat > appendix-terraform/terraform.tfvars <<EOF
project_id = "${PROJECT_ID}"
region     = "${REGION}"
prefix     = "${PREFIX}"
EOF
cat appendix-terraform/terraform.tfvars
```

## 5. Plan and apply

Download the providers, then create a plan and review it. Terraform shows every resource it will create; nothing changes yet. `-parallelism=2` limits Terraform to two API operations at a time (the default is 10), because Cloud Shell can refuse bursts of parallel connections (`connect: connection refused`). Use it with every `plan` and `apply` in this appendix.

```bash
terraform -chdir=appendix-terraform init
terraform -chdir=appendix-terraform plan -parallelism=2 -out=apply.tfplan
```

The plan ends with `Plan: 42 to add, 0 to change, 0 to destroy.` Apply exactly this plan (about 15-20 minutes):

```bash
terraform -chdir=appendix-terraform apply -parallelism=2 apply.tfplan
terraform -chdir=appendix-terraform output
```

> [!TIP]
> If a `plan` or `apply` stops with an error anyway, nothing is lost: Terraform has saved everything it created so far in its state. Run the `plan` command again, review the remaining changes, and apply the new plan. Terraform continues where it stopped.

> [!NOTE]
> Terraform keeps track of what it created in a **state file**, `appendix-terraform/terraform.tfstate`. It stays in your Cloud Shell home directory, and you need it to delete the resources at the end. Don't delete it. In production, store the state in a [Cloud Storage backend](https://cloud.google.com/docs/terraform/resource-management/store-state) with versioning, so that a team can share it safely.

## 6. Connect to the cluster and verify it

Load `env.sh` again (it looks up the Gateway IP that now exists), then connect through the DNS endpoint:

```bash
source ./env.sh
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --location="${REGION}" \
  --dns-endpoint
kubectl get nodes -o wide
```

There are three nodes, one per zone, without external IPs. Check the security configuration, which is the same as at the end of Lab 03:

```bash
gcloud container clusters describe "${CLUSTER_NAME}" --location="${REGION}" \
  --format="yaml(controlPlaneEndpointsConfig.ipEndpointsConfig,controlPlaneEgress,privateClusterConfig.enablePrivateNodes,databaseEncryption.state,binaryAuthorization,networkConfig.datapathProvider,networkConfig.enableFqdnNetworkPolicy,secretManagerConfig,securityPostureConfig.mode,workloadIdentityConfig)"
```

Wait for the Gateway controller to install its GatewayClasses, which Lab 04 uses:

```bash
until kubectl get gatewayclass gke-l7-global-external-managed >/dev/null 2>&1; do echo "Waiting for GatewayClasses..."; sleep 15; done
kubectl get gatewayclasses
```

The real infrastructure now matches the configuration. A new plan proves it:

```bash
terraform -chdir=appendix-terraform plan -parallelism=2 -detailed-exitcode
```

`No changes. Your infrastructure matches the configuration.` (exit code 0) means there's no drift.

## 7. Mirror the workshop images

Like at the end of Lab 02, copy the workshop images into your repository with Cloud Build (usually 1-3 minutes). See [Lab 02, step 11](../02-cluster-pre-provisioning/README.md#11-mirror-the-workshop-images) for how the script works.

```bash
./scripts/mirror-images.sh
```

You are now at the same point as at the end of Lab 03. Continue with [Lab 04](../04-cluster-post-provisioning/README.md).

## Terraform during the rest of the workshop

The later labs change some of the resources Terraform created with `gcloud`, on purpose, to teach day-2 operations. For example, Lab 09 switches `default-pool` to blue-green upgrades and then replaces it with `pool-v2`. After that, `terraform plan` shows **drift**: it would recreate `default-pool` and switch the upgrade strategy back.

`terraform plan` is always safe to run. Don't run `terraform apply` again after Lab 04 unless you want to revert those changes. In a real team, you would make such changes in the Terraform code instead and let a pipeline apply them.

## Cleanup

When you're done with the workshop, delete everything in this order. If you used a dedicated project, deleting the whole project is simpler (see [Cleanup](../99-cleanup/README.md#option-a-recommended-delete-the-project)).

**1.** Delete what the later labs created that Terraform doesn't manage. Run steps 1, 2 and 7 of [Cleanup, Option B](../99-cleanup/README.md#option-b-delete-the-resources-one-by-one) first: the application and Gateway (which releases the Gateway IP), the Backup for GKE resources, and the monitoring, audit logging and Pub/Sub resources. Then delete the Cloud Armor and SSL policies and the secret:

```bash no-fail
gcloud compute security-policies delete "${ARMOR_POLICY}" --global --quiet
gcloud compute ssl-policies delete "${SSL_POLICY}" --global --quiet
gcloud secrets delete "${PREFIX}-db-password" --quiet
```

Don't delete the cluster, the network, the Gateway IP, the repository or the key yourself: Terraform does that next.

**2.** Plan and apply the destruction of everything Terraform created (about 10-15 minutes):

```bash
terraform -chdir=appendix-terraform plan -parallelism=2 -destroy -out=destroy.tfplan
terraform -chdir=appendix-terraform apply -parallelism=2 destroy.tfplan
```

> [!NOTE]
> Cloud KMS key rings and keys can't be deleted. `terraform destroy` removes them from the state and schedules all key versions for destruction after 30 days, but the names stay taken. To build the environment again in the same project, choose a new `PREFIX`.

**3.** Run step 8 of [Cleanup, Option B](../99-cleanup/README.md#8-verify) to verify that nothing with your prefix remains, and delete the local key of the self-signed certificate.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `KeyRing ... already exists` | A key ring with this name exists from an earlier run, and key rings can't be deleted. Set a new `PREFIX` in `env.sh`, run `source ./env.sh`, and repeat from step 4. |
| `dial tcp ...:443: connect: connection refused` | Cloud Shell refused one of Terraform's parallel connections. Create a new plan and apply it again (with `-parallelism=2`). |
| An error says that an API isn't enabled, or that a permission is missing on a just-created resource | Changes take a moment to propagate. Create a new plan and apply it again; Terraform continues where it stopped. |
| `Saved plan is stale` | The plan no longer matches the state, for example after a failed apply. Run the `plan -out=apply.tfplan` command again, then apply. |
| A quota error | See `./scripts/check-prereqs.sh`. |

## Next Steps

[Lab 04 - Post-Provisioning](../04-cluster-post-provisioning/README.md)

## Key Links

- [Terraform on Google Cloud](https://cloud.google.com/docs/terraform)
- [Google provider: `google_container_cluster`](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster) and [`google_container_node_pool`](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_node_pool)
- [Store Terraform state in a Cloud Storage bucket](https://cloud.google.com/docs/terraform/resource-management/store-state)
- [Terraform best practices on Google Cloud](https://cloud.google.com/docs/terraform/best-practices/general-style-structure)
