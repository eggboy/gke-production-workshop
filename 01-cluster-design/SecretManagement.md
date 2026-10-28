# Secret Management

Applications need passwords, API keys, tokens and certificates. Compare the options for storing and delivering them on GKE against your requirements:

1. Plain Kubernetes Secrets
2. Kubernetes Secrets encrypted with your own key (application-layer secrets encryption)
3. Secret Manager, accessed from application code with Workload Identity
4. Secret Manager, mounted as files by the **Secret Manager add-on** (CSI driver)
5. Secret Manager, synchronized into Kubernetes Secrets
6. Third-party secret managers (for example HashiCorp Vault, or External Secrets Operator)

GKE's [hardening guide](https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster#store_secrets_outside_your_cluster) recommends, in order of preference: the Secret Manager client libraries, then the Secret Manager add-on, then third-party tools. Plain Kubernetes Secrets are the last resort.

## Kubernetes Secrets

Kubernetes Secrets are simple and supported by every tool. But anyone who can create Pods in a namespace can read every Secret in it, and anyone with broad read access to the API can read them all. Secrets also end up in manifests and pipelines unless you add tooling around them.

Trade-offs:

- Simple and compatible with the whole ecosystem
- Must be locked down with RBAC and rotated through a separate process
- No audit trail of who read which secret value

## Application-layer secrets encryption (Cloud KMS)

GKE encrypts etcd at rest by default. With [application-layer secrets encryption](https://cloud.google.com/kubernetes-engine/docs/how-to/encrypting-secrets), Secrets are additionally encrypted with a key in Cloud KMS that **you** control. You can disable or rotate it, and key usage appears in Cloud Audit Logs. This protects against access to the underlying storage, but not against someone who is allowed to read Secrets through the API.

Trade-offs:

- Transparent to applications; the workshop enables it in Lab 03
- Customer-managed key, rotation and audit of key usage
- Doesn't change who can read Secrets through the Kubernetes API

## Secret Manager with the client libraries

Applications call [Secret Manager](https://cloud.google.com/secret-manager/docs/overview) directly using Workload Identity Federation for GKE. IAM is granted per Kubernetes ServiceAccount, per secret.

Trade-offs:

- Secrets never touch the cluster
- Per-access audit logs, versioning, rotation and CMEK
- Requires a code change, and the application must handle refresh

## Secret Manager add-on (CSI driver)

The managed [Secret Manager add-on](https://cloud.google.com/secret-manager/docs/secret-manager-managed-csi-component) mounts secret versions as **files** in the Pod, authenticating as the Pod's Kubernetes ServiceAccount. With rotation enabled, files are refreshed automatically when a new version is added. You use it in Lab 05.

Trade-offs:

- No code change: the application reads a file
- Same IAM, audit and rotation benefits as the client libraries
- Files only, not environment variables, and the application must re-read the file to pick up a rotation

## Secret Manager synchronized to Kubernetes Secrets

[Secret synchronization](https://cloud.google.com/secret-manager/docs/sync-k8-secrets) copies Secret Manager secrets into Kubernetes Secrets, for applications that can only consume environment variables or Secret volumes.

Trade-offs:

- Works with any existing application
- Secret Manager stays the source of truth
- The value is stored in the cluster again, so RBAC and CMEK matter

## Third-party secret managers

Tools such as HashiCorp Vault offer dynamic secrets and multi-cloud support, but you operate them. If they run in a cluster, use a separate cluster from your workloads.

## Workshop choice

- **Secret Manager add-on** with Workload Identity Federation: one Kubernetes ServiceAccount can read one secret, rotation is enabled, and the negative test proves that other identities are denied (Lab 05).
- **Application-layer secrets encryption** with Cloud KMS for anything that still lives in Kubernetes Secrets, such as the Gateway's TLS key (Lab 03 and Lab 04).

## Next Steps

[Back to Cluster Design](README.md)

## Key Links

- [Secret Manager overview](https://cloud.google.com/secret-manager/docs/overview)
- [Use Secret Manager add-on with GKE](https://cloud.google.com/secret-manager/docs/secret-manager-managed-csi-component)
- [Kubernetes Secrets good practices](https://kubernetes.io/docs/concepts/security/secrets-good-practices/)
