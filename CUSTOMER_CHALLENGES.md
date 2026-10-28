# Customer Challenges

Instead of following the labs step by step, you can run this workshop as a set of **challenges**: teams get the requirement, not the answer. This encourages self-learning and collaboration, which is a great way to learn. Each challenge links to the lab that contains a reference solution.

Use the same project setup as the regular workshop (see the [README](README.md#getting-started)).

## Challenges

1. **Know your guardrails.** List the organization policies that apply to your project, and explain how the platform complies with each of them. *([Lab 01](01-cluster-design/SecurityDesign.md#organization-guardrails), [Lab 02](02-cluster-pre-provisioning/README.md))*
2. **Plan the network.** Create a custom VPC for a VPC-native cluster with separate ranges for nodes, Pods and Services. Justify the size of each range. *([Lab 02](02-cluster-pre-provisioning/README.md))*
3. **Private by default.** Nodes must have no external IP addresses, but may call one approved partner API on the internet through a fixed egress IP. *([Lab 02](02-cluster-pre-provisioning/README.md))*
4. **Lock down egress.** Only HTTPS to an allow-list of domain names may leave the VPC. Everything else is blocked and logged, and the cluster must keep working. Prove it with logs. *([Lab 02](02-cluster-pre-provisioning/README.md), [Lab 04](04-cluster-post-provisioning/README.md))*
5. **No IP-based control plane access.** Administrators must reach the API server from anywhere, with no bastion host and no IP allow-lists. *([Lab 03](03-cluster-provisioning/README.md))*
6. **Least privilege for machines.** Nodes may not run as the Compute Engine default service account, and workloads may not use node credentials. *([Lab 02](02-cluster-pre-provisioning/README.md), [Lab 03](03-cluster-provisioning/README.md))*
7. **Bring your own key.** Kubernetes Secrets must be encrypted with a key the security team controls. *([Lab 02](02-cluster-pre-provisioning/README.md), [Lab 03](03-cluster-provisioning/README.md))*
8. **Tenant guardrails.** Give the shop team a namespace with quotas, default limits, the `restricted` Pod Security level and a Role that can't read Secrets or exec into Pods. *([Lab 04](04-cluster-post-provisioning/README.md))*
9. **Default deny.** Pods in one namespace must not reach another namespace unless explicitly allowed. Show the denied connections in the logs. *([Lab 04](04-cluster-post-provisioning/README.md), [Lab 06](06-cluster-security/README.md))*
10. **Publish securely.** Expose the storefront on HTTPS only (HTTP redirects), with TLS 1.2+. The platform team owns the load balancer; the app team owns its route. *([Lab 04](04-cluster-post-provisioning/README.md), [Lab 05](05-deploy-app/README.md))*
11. **Web application firewall.** Block SQL injection, XSS and scanners at the edge, without false positives on normal traffic, and throttle scrapers. *([Lab 04](04-cluster-post-provisioning/README.md), [Lab 06](06-cluster-security/README.md))*
12. **Approved images only.** Only images from the company registry may run, never with a `:latest` tag. There must be an audited emergency override. *([Lab 06](06-cluster-security/README.md))*
13. **No public load balancers.** Prevent anyone from creating a public `LoadBalancer` Service in the cluster. *([Lab 04](04-cluster-post-provisioning/README.md), [Lab 06](06-cluster-security/README.md))*
14. **Secrets outside the cluster.** Deliver a database password to exactly one workload without a Kubernetes Secret, and rotate it without restarting the Pod. *([Lab 05](05-deploy-app/README.md))*
15. **Alert on a shell in a container.** Get notified when someone runs `kubectl exec` in the cluster. *([Lab 08](08-cluster-monitoring/README.md))*
16. **Alert on attacks.** Get notified when the WAF starts blocking requests. *([Lab 08](08-cluster-monitoring/README.md))*
17. **Who read the password?** Record every read of the database password, including denied attempts, and keep a copy of all audit logs in a dedicated bucket for a year. Prove that the always-on audit logs can't be deleted. *([Lab 08](08-cluster-monitoring/README.md))*
18. **Chargeback.** Show costs per namespace and team, and find over-provisioned workloads. *([Lab 07](07-cost-governance/README.md))*
19. **Survive a zone outage.** Every stateless service must keep serving if one zone fails, and planned maintenance must never stop all of its replicas. Show in which zones the replicas run. *([Lab 05](05-deploy-app/README.md), [Lab 09](09-day2-operations/README.md))*
20. **Zero-downtime node changes.** Move all workloads to a new node pool while the storefront keeps serving. *([Lab 09](09-day2-operations/README.md))*
21. **Disaster recovery.** Back up the shop namespace, delete it, and restore it. *([Lab 09](09-day2-operations/README.md))*

## Prerequisites

- Google Cloud project with billing enabled, and the Owner role
- [Cloud Shell](https://shell.cloud.google.com/), which has every required tool preinstalled
- Enough regional quota (run `./scripts/check-prereqs.sh` after `source ./env.sh`)
