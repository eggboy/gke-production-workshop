# Lab 04 - Post-Provisioning (Platform Baseline)

The cluster is running, but a production platform needs more than a cluster. In this lab the **platform team** prepares everything application teams will rely on:

1. A Kubernetes baseline: namespaces, Pod Security, quotas, default resource limits, least-privilege RBAC and default-deny network policies.
2. Proof that the egress controls from Lab 02 work, with the logs to show it.
3. Edge security: a TLS policy and a Cloud Armor WAF policy.
4. A **shared Gateway** (one global external Application Load Balancer) with a TLS certificate and an HTTP-to-HTTPS redirect. Application teams attach their routes to it in Lab 05.

In production, this baseline is usually applied with **GitOps**: a controller such as Config Sync or Flux reconciles the files from a Git repository, so the cluster never drifts from source control. Here you apply the same configuration with `kubectl apply -k`; the files in [`cluster-config/`](../cluster-config) are ready for GitOps if you adopt it later. Config Sync and Policy Controller are included with GKE Standard at no additional cost (since September 2025); the workshop leaves them out to keep the scope on the cluster itself, not because they cost extra.

**Estimated time:** 75-90 minutes

> [!NOTE]
> Run `source ./env.sh` first if you opened a new Cloud Shell session. `kubectl` keeps using the context created by `get-credentials` in Lab 03.

## 1. Apply the cluster baseline

Review the baseline, then apply it:

| File | What it does |
|---|---|
| [`namespaces.yaml`](../cluster-config/namespaces.yaml) | Creates `gateway-infra`, `onlineboutique`, `secrets-demo` and `dev`, with **Pod Security Admission** labels: `restricted` is enforced everywhere except `dev`, which enforces `baseline` and only warns about `restricted` violations |
| [`resource-quotas.yaml`](../cluster-config/resource-quotas.yaml) | Caps CPU, memory and Pods per namespace, and allows **zero** `LoadBalancer`/`NodePort` Services, so apps can only be published through the shared Gateway |
| [`limit-ranges.yaml`](../cluster-config/limit-ranges.yaml) | Default requests and limits for containers that declare none, plus a per-container maximum |
| [`rbac.yaml`](../cluster-config/rbac.yaml) | An `app-developer` Role for the shop team: can view and roll out workloads; cannot read Secrets or exec into Pods |
| [`network-policies.yaml`](../cluster-config/network-policies.yaml) | **Default deny** (ingress and egress) in every application namespace, plus DNS. DNS must allow both the `kube-dns` and `node-local-dns` Pods, because NodeLocal DNSCache answers the queries. `dev` Pods labeled `egress=internet` may open HTTP(S) connections to public addresses. `secrets-demo` may reach the GKE metadata server (needed for Workload Identity). |

```bash
kubectl apply -k cluster-config/
```

```bash
kubectl get namespaces -L team,pod-security.kubernetes.io/enforce
```

```bash
kubectl get resourcequota,limitrange,networkpolicy -A | grep -v -E "^(kube-|gke-|gmp-)"
```

> [!NOTE]
> The `dev` namespace (baseline Pod Security, internet egress for labeled Pods) is a workshop convenience: it gives you a place to run test Pods such as `toolbox` without weakening the application namespaces. A real production cluster would not have it. The [cluster design](../01-cluster-design/README.md) recommends one cluster per environment, so development workloads get their own cluster.

## 2. Check the least-privilege RBAC

In GKE, **IAM** controls who can reach the cluster. With the DNS endpoint, users need the `container.clusters.connect` permission, which is included in `roles/container.clusterViewer`. **Kubernetes RBAC** controls what they can do inside it.

Use impersonation (`--as`) to check what the `developer@example.com` user from [`rbac.yaml`](../cluster-config/rbac.yaml) is allowed to do:

```bash no-fail
kubectl auth can-i list pods             -n onlineboutique --as=developer@example.com
kubectl auth can-i patch deployments     -n onlineboutique --as=developer@example.com
kubectl auth can-i get secrets           -n onlineboutique --as=developer@example.com
kubectl auth can-i create pods/exec      -n onlineboutique --as=developer@example.com
kubectl auth can-i list pods             -n dev            --as=developer@example.com
```

Expected answers: `yes`, `yes`, `no`, `no`, `no`.

> [!TIP]
> To onboard a real developer, grant them `roles/container.clusterViewer` in IAM and add them, or better a Google Group (see [Google Groups for RBAC](https://cloud.google.com/kubernetes-engine/docs/how-to/google-groups-rbac)), to the RoleBinding.

## 3. Test the egress controls

In Lab 02 (step 7) you allowed HTTPS to exactly two internet names, `ifconfig.me` and `api.github.com` (`ALLOWED_EGRESS_FQDNS` in `env.sh`), and denied every other internet destination. The four tests below prove each half of that rule, plus the Google API exception.

Start the `toolbox` test Pod in the `dev` namespace. The image comes from your Artifact Registry. [`toolbox.yaml`](manifests/toolbox.yaml) is a template, so render it with `envsubst` first:

```bash
envsubst '${TOOLBOX_IMAGE}' < 04-cluster-post-provisioning/manifests/toolbox.yaml | kubectl apply -f -
kubectl wait pod/toolbox -n dev --for=condition=Ready --timeout=180s
```

**Test 1: an allow-listed FQDN.** `ifconfig.me` returns the caller's public IP address, so this also proves that egress leaves through Cloud NAT. Compare the two values:

```bash
kubectl exec -n dev toolbox -- curl -sS --max-time 10 https://ifconfig.me; echo
gcloud compute addresses describe "${NAT_IP_NAME}" --region="${REGION}" --format="value(address)"
```

**Test 2: the second allow-listed FQDN.** This returns HTTP status `200`:

```bash
kubectl exec -n dev toolbox -- curl -sS --max-time 10 -o /dev/null -w "%{http_code}\n" https://api.github.com/zen
```

**Test 3: any other internet destination.** The connection is dropped by the firewall policy's deny rule, so this **times out**:

```bash no-fail
kubectl exec -n dev toolbox -- curl -sS --max-time 10 -o /dev/null -w "%{http_code}\n" https://example.com
```

```text
curl: (28) Connection timed out after 10001 milliseconds
000
command terminated with exit code 28
```

**Test 4: Google APIs.** These are `NON_INTERNET` traffic, reached through Private Google Access without Cloud NAT, so they still work. Any HTTP status code proves connectivity:

```bash
kubectl exec -n dev toolbox -- curl -sS --max-time 10 -o /dev/null -w "%{http_code}\n" https://storage.googleapis.com/
```

## 4. Find the evidence in Cloud Logging

Firewall policy rules 1000 and 2000 have logging enabled, so every allowed and denied connection is recorded. Logs appear 1-2 minutes after the traffic.

Denied connections (the `example.com` attempt, priority `2000`):

```bash
gcloud logging read \
  'log_id("compute.googleapis.com/firewall") AND jsonPayload.disposition="DENIED"' \
  --freshness=30m --limit=5 \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,jsonPayload.connection.src_ip:label=SOURCE,jsonPayload.connection.dest_ip:label=DESTINATION,jsonPayload.connection.dest_port:label=PORT,jsonPayload.rule_details.priority:label=RULE,jsonPayload.disposition:label=RESULT)"
```

Allowed connections to the FQDN allow-list (priority `1000`):

```bash
gcloud logging read \
  'log_id("compute.googleapis.com/firewall") AND jsonPayload.disposition="ALLOWED"' \
  --freshness=30m --limit=5 \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,jsonPayload.connection.src_ip:label=SOURCE,jsonPayload.connection.dest_ip:label=DESTINATION,jsonPayload.rule_details.priority:label=RULE,jsonPayload.disposition:label=RESULT)"
```

Cloud NAT translations show the Pod's address being translated to the NAT IP:

```bash
gcloud logging read \
  'log_id("compute.googleapis.com/nat_flows")' \
  --freshness=30m --limit=5 \
  --format="table(timestamp.date('%H:%M:%S'):label=TIME,jsonPayload.connection.src_ip:label=SOURCE,jsonPayload.connection.nat_ip:label=NAT_IP,jsonPayload.connection.dest_ip:label=DESTINATION,jsonPayload.allocation_status:label=STATUS)"
```

> [!NOTE]
> The `SOURCE` is the **Pod's** IP address (`10.20.x.x`, from the Pod secondary range), not the node's. Compare it with `kubectl get pod toolbox -n dev -o wide`. By default GKE masquerades (SNATs) Pod traffic behind the node's IP before it leaves the node, and Cloud NAT translates it a second time, so logs attribute every connection to the node. The cluster was created with `--disable-default-snat` (Lab 03), so Cloud NAT translates the Pod IP directly and the firewall policy and NAT logs identify the Pod. The `NAT_IP` column shows the translation to your static NAT address. The Google API call from Test 4 never appears in the NAT logs: Private Google Access doesn't use NAT.

## 5. Turn on network policy logging

Dataplane V2 can log the connections that NetworkPolicies allow or deny. Enable logging of **denied** connections cluster-wide, which is useful for troubleshooting and for detecting lateral movement. You'll query these logs in Lab 06.

```bash
kubectl patch networklogging default --type=merge \
  -p '{"spec":{"cluster":{"allow":{"log":false,"delegate":false},"deny":{"log":true,"delegate":false}}}}'
kubectl get networklogging default -o yaml | grep -A8 "^spec:"
```

## 6. Look at the admission chain

Every `kubectl apply` passes through the API server's **admission chain** before it is stored: built-in admission controllers, mutating webhooks, ValidatingAdmissionPolicies, validating webhooks. Pod Security Admission (step 1) is one of the built-in controllers. GKE adds a few webhooks of its own. List them:

```bash
kubectl get validatingwebhookconfigurations
```

One of them, `binauthz-admission-controller`, is how GKE enforces **Binary Authorization** (`--binauthz-evaluation-mode` in Lab 03; the policy itself is configured in Lab 06). Look at how it is wired:

```bash
kubectl get validatingwebhookconfiguration binauthz-admission-controller \
  -o jsonpath='{range .webhooks[*]}{.name}{"\n  url: "}{.clientConfig.url}{"\n  failurePolicy: "}{.failurePolicy}{"\n  timeoutSeconds: "}{.timeoutSeconds}{"\n"}{end}'
```

```text
imagepolicywebhook.image-policy.k8s.io
  url: https://binaryauthorization.googleapis.com/internal/projects/<PROJECT_ID>/policy/locations/<REGION>/clusters/<CLUSTER_NAME>:admissionReview
  failurePolicy: Ignore
  timeoutSeconds: 10
```

Three things to take from this:

1. The decision is made **outside the cluster**: for every Pod, the API server calls the Binary Authorization service over the network.
2. `failurePolicy: Ignore` means the webhook **fails open**. If the service can't be reached within 10 seconds, the Pod is admitted and the only trace is a `failed-open.validating.webhook.admission.k8s.io` label on the Pod's audit log entry.
3. This is why the cluster keeps the default control plane egress mode. GKE's `--control-plane-egress=NONE` blocks every outbound call from the API server, Google APIs included, and would turn Binary Authorization into a silent no-op. Lab 10 checks the audit log for that label.

> [!NOTE]
> Fail-open is the right default for a managed webhook: a fail-closed one would stop every deployment, including the ones that fix an outage. The price is that you must monitor for the fail-open label. Lab 08 shows how to alert on audit log entries.

## 7. Create the TLS (SSL) policy

An SSL policy controls which TLS versions and ciphers the load balancer accepts. `MODERN` with a minimum of TLS 1.2 rejects legacy clients and weak ciphers.

```bash
gcloud compute ssl-policies create "${SSL_POLICY}" \
  --profile=MODERN \
  --min-tls-version=1.2 \
  --global
```

## 8. Create the Cloud Armor WAF policy

[Google Cloud Armor](https://cloud.google.com/armor/docs/cloud-armor-overview) sits at the edge of Google's network in front of the load balancer. It is the platform's web application firewall (WAF): it inspects every request and blocks attacks before they reach the cluster. You create the policy now and attach it to the application in Lab 05.

```bash
gcloud compute security-policies create "${ARMOR_POLICY}" \
  --description="WAF policy for the Online Boutique storefront" \
  --global
```

Add the **preconfigured WAF rules** based on the OWASP ModSecurity Core Rule Set **4.22**: SQL injection, cross-site scripting, local and remote file inclusion, remote code execution, scanner detection and protocol attacks. Following Google's best practice, they start at **sensitivity level 1** (lowest false-positive risk) and in **preview mode**: matches are logged but not blocked, so you can check for false positives before enforcing (Lab 06).

```bash
PRIORITY=1000
for RULE in sqli xss lfi rfi rce scannerdetection protocolattack; do
  gcloud compute security-policies rules create "${PRIORITY}" \
    --security-policy="${ARMOR_POLICY}" \
    --expression="evaluatePreconfiguredWaf('${RULE}-v422-stable', {'sensitivity': 1})" \
    --action=deny-403 \
    --preview \
    --description="OWASP CRS 4.22 ${RULE}"
  PRIORITY=$((PRIORITY + 1))
done
```

Enable **Adaptive Protection** (machine-learning detection of layer-7 DDoS attacks), **verbose logging** (shows which signature matched, for tuning) and **JSON body parsing** (so WAF rules inspect JSON request bodies):

```bash
gcloud compute security-policies update "${ARMOR_POLICY}" \
  --enable-layer7-ddos-defense \
  --log-level=VERBOSE \
  --json-parsing=STANDARD
```

```bash
gcloud compute security-policies describe "${ARMOR_POLICY}" \
  --flatten="rules[]" \
  --format="table(rules.priority,rules.action,rules.preview,rules.description)"
```

> [!NOTE]
> The rule with priority `2147483647` is the policy's **default rule** (`allow`). Cloud Armor Standard is billed per policy, per rule and per million requests. Adaptive Protection gives Standard-tier users basic alerts; full alerts with suggested rules require Cloud Armor Enterprise.

## 9. Create a self-signed TLS certificate

The Gateway terminates HTTPS, so it needs a certificate and private key. In production you would use a **Google-managed certificate** from [Certificate Manager](https://cloud.google.com/certificate-manager/docs/overview), which is issued by a public CA and renewed automatically, but that requires a domain you own. For the workshop you create a **self-signed** certificate: the traffic is encrypted, but browsers show a warning because no trusted CA signed it.

Create a private key and a certificate valid for 90 days for the host name `${APP_HOST}` (`shop.example.com`):

```bash
mkdir -p tls
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 90 \
  -keyout tls/tls.key \
  -out tls/tls.crt \
  -subj "/CN=${APP_HOST}/O=GKE Production Workshop" \
  -addext "subjectAltName=DNS:${APP_HOST}"
```

| Option | Meaning |
|---|---|
| `req -x509` | Create a self-signed certificate directly, instead of a certificate signing request |
| `-newkey rsa:2048 -nodes` | Generate a new 2048-bit RSA private key and don't encrypt it with a passphrase (the load balancer needs it unencrypted) |
| `-sha256 -days 90` | Signature algorithm and validity period |
| `-subj "/CN=..."` | Subject. Browsers ignore the CN... |
| `-addext "subjectAltName=DNS:..."` | ...and only check the Subject Alternative Name, so the host name must be here |

Inspect the certificate:

```bash
openssl x509 -in tls/tls.crt -noout -subject -issuer -dates -ext subjectAltName
```

Subject and issuer are identical, which is what makes it self-signed.

Store the certificate and key as a Kubernetes TLS Secret in the platform namespace. The Gateway references it, and GKE uploads it to the load balancer. Thanks to application-layer secrets encryption (Lab 03), the private key is encrypted in etcd with your Cloud KMS key.

```bash
kubectl create secret tls shop-tls \
  --cert=tls/tls.crt \
  --key=tls/tls.key \
  -n gateway-infra
```

> [!WARNING]
> The `tls/` directory contains a private key. It is listed in `.gitignore`. Never commit keys to source control.

## 10. Deploy the shared Gateway

[`gateway.yaml`](manifests/gateway.yaml) contains three resources owned by the platform team:

| Resource | Purpose |
|---|---|
| `Gateway` `external-gateway` | A global external Application Load Balancer on the reserved static IP. The HTTP listener (port 80) accepts routes only from its own namespace. The HTTPS listener (port 443) uses the `shop-tls` certificate and accepts routes only from namespaces labeled `gateway-access: "true"`. |
| `GCPGatewayPolicy` | Attaches the `MODERN`/TLS 1.2 SSL policy to the load balancer |
| `HTTPRoute` `http-to-https-redirect` | Answers every HTTP request with a `301` redirect to HTTPS |

These objects configure the client-facing half of the load balancer (stages 1–3 of the [ingress flow](../01-cluster-design/IngressFlow.md)). Application teams add the backend half in Lab 05: route, health check, Cloud Armor attachment and network policy.

```bash
envsubst '${GATEWAY_IP_NAME} ${SSL_POLICY}' < 04-cluster-post-provisioning/manifests/gateway.yaml | kubectl apply -f -
```

The GKE Gateway controller now creates the load balancer: forwarding rules, target proxies, URL maps and the SSL certificate. This takes a few minutes:

```bash
kubectl wait gateway/external-gateway -n gateway-infra --for=condition=Programmed --timeout=15m
kubectl get gateway -n gateway-infra
```

The `ADDRESS` is your reserved static IP. Store it in a variable for the following steps (`env.sh` also sets it in new sessions):

```bash
export GATEWAY_IP="$(gcloud compute addresses describe "${GATEWAY_IP_NAME}" --global --format='value(address)')"
echo "${GATEWAY_IP}"
```

## 11. Test the Gateway

Programming the load balancer worldwide can take a few more minutes after the Gateway reports `Programmed`. Until the configuration has reached Google's edge locations, requests can't connect (`HTTP 000`) or get a `404`, and for a while some requests get a `404` and others the redirect. This loop waits until 5 requests in a row are answered with the redirect:

```bash
OK=0
for i in $(seq 1 120); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://${GATEWAY_IP}/" || true)"
  if [ "${CODE}" = "301" ]; then OK=$((OK + 1)); else OK=0; echo "Waiting for the load balancer (HTTP ${CODE})..."; sleep 10; fi
  if [ "${OK}" -ge 5 ]; then echo "The load balancer is ready."; break; fi
done
curl -s -o /dev/null -w "HTTP %{http_code} -> %{redirect_url}\n" "http://${GATEWAY_IP}/"
```

```text
The load balancer is ready.
HTTP 301 -> https://<GATEWAY_IP>:443/
```

Check the certificate served on port 443. It is your self-signed certificate:

```bash
echo | openssl s_client -connect "${GATEWAY_IP}:443" -servername "${APP_HOST}" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

Check that the SSL policy is enforced. A client that offers only TLS 1.1 is refused by the load balancer, and TLS 1.2 works:

```bash no-fail
echo | openssl s_client -connect "${GATEWAY_IP}:443" -tls1_1 -cipher 'DEFAULT:@SECLEVEL=0' 2>&1 | grep -o "alert protocol version"
echo | openssl s_client -connect "${GATEWAY_IP}:443" -tls1_2 2>/dev/null | grep "^New, "
```

```text
alert protocol version
New, TLSv1.2, Cipher is ECDHE-RSA-CHACHA20-POLY1305
```

> [!NOTE]
> OpenSSL 3 disables TLS 1.1 in the client by default. Without `-cipher 'DEFAULT:@SECLEVEL=0'`, the test would fail in the client ("no protocols available") without ever contacting the load balancer, which would prove nothing. The `alert protocol version` comes from the load balancer.

There are no application routes yet, so HTTPS requests return `404`. Lab 05 attaches the storefront.

```bash
curl -sk -o /dev/null -w "HTTPS %{http_code}\n" "https://${GATEWAY_IP}/"
```

## 12. Checkpoint

```bash
kubectl get gateway,httproute -A
```

```bash
kubectl get pods -n dev
```

You have a hardened baseline, proven egress controls with audit evidence, an edge WAF policy (in preview), and a shared HTTPS Gateway that is ready for applications.

## Next Steps

[Lab 05 - Deploy the Application](../05-deploy-app/README.md)

## Key Links

- [Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/) and [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Best practices for GKE RBAC](https://cloud.google.com/kubernetes-engine/docs/best-practices/rbac)
- [Firewall Rules Logging](https://cloud.google.com/firewall/docs/firewall-rules-logging) and [Cloud NAT logging](https://cloud.google.com/nat/docs/monitoring)
- [Network policy logging](https://cloud.google.com/kubernetes-engine/docs/how-to/network-policy-logging)
- [Deploying Gateways](https://cloud.google.com/kubernetes-engine/docs/how-to/deploying-gateways) and [Secure a Gateway](https://cloud.google.com/kubernetes-engine/docs/how-to/secure-gateway)
- [Cloud Armor preconfigured WAF rules](https://cloud.google.com/armor/docs/waf-rules) and [tuning](https://cloud.google.com/armor/docs/rule-tuning)
- [SSL policies](https://cloud.google.com/load-balancing/docs/ssl-policies-concepts)
