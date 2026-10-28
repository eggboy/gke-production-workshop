#!/usr/bin/env bash
# =============================================================================
# check-prereqs.sh - verifies tools, project access and regional quotas.
# Run from the repository root after 'source ./env.sh' (Lab 02).
# =============================================================================
set -uo pipefail
: "${PROJECT_ID:?Run 'source ./env.sh' first}"
: "${REGION:?Run 'source ./env.sh' first}"

FAILED=0
ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILED=1; }

echo "Tools:"
for t in gcloud kubectl gke-gcloud-auth-plugin openssl envsubst git curl jq python3; do
  if command -v "${t}" >/dev/null 2>&1; then ok "${t}"; else fail "${t} not found"; fi
done

echo "Identity and project:"
ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
if [ -n "${ACCOUNT}" ]; then ok "gcloud account: ${ACCOUNT}"; else fail "no active gcloud account (run: gcloud auth login)"; fi
if gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
  ok "project ${PROJECT_ID} is accessible (number ${PROJECT_NUMBER:-?})"
else
  fail "cannot access project ${PROJECT_ID}"
fi
ROLES="$(gcloud projects get-iam-policy "${PROJECT_ID}" --flatten='bindings[].members' \
  --filter="bindings.members:user:${ACCOUNT}" --format='value(bindings.role)' 2>/dev/null | tr '\n' ' ')"
if [[ "${ROLES}" == *"roles/owner"* ]]; then
  ok "user:${ACCOUNT} has roles/owner"
else
  warn "roles/owner not found for user:${ACCOUNT} (found: ${ROLES:-none}). The labs assume project Owner."
fi

echo "Regional quotas in ${REGION} (usage / limit, minimum needed by the labs):"
gcloud compute regions describe "${REGION}" --format=json | python3 -c '
import json, sys
need = {"E2_CPUS": 32, "CPUS": 32, "SSD_TOTAL_GB": 400, "STATIC_ADDRESSES": 2, "IN_USE_ADDRESSES": 2}
quotas = {q["metric"]: q for q in json.load(sys.stdin)["quotas"]}
bad = 0
for metric, minimum in need.items():
    q = quotas.get(metric)
    if q is None:
        print("  [INFO] %-18s not reported in this region" % metric)
        continue
    usage, limit = q["usage"], q["limit"]
    free = limit - usage
    tag = "OK  " if free >= minimum else "FAIL"
    if free < minimum:
        bad = 1
    print("  [%s] %-18s %7.0f / %-7.0f (need %d free)" % (tag, metric, usage, limit, minimum))
sys.exit(1 if bad else 0)
' || FAILED=1

echo "Versions:"
echo "  $(gcloud version 2>/dev/null | head -1)"
echo "  kubectl $(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"

if [ "${FAILED}" -ne 0 ]; then
  echo "RESULT: some checks failed - fix them before continuing."
  exit 1
fi
echo "RESULT: all prerequisite checks passed."
