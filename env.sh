#!/usr/bin/env bash
# =============================================================================
#  GKE Production Cluster Workshop - environment variables
#
#  Usage (from the repository root, in EVERY new Cloud Shell session):
#      source ./env.sh
#
#  Only edit section 1. Everything else is derived from it.
# =============================================================================

# ---- 1. EDIT THESE ----------------------------------------------------------
export PROJECT_ID="REPLACE_WITH_YOUR_PROJECT_ID"  # Your Google Cloud project ID
export PREFIX="gkews"                             # Lowercase letters/digits, start with a letter, max 10 chars
export REGION="asia-southeast1"                   # Region for every regional resource

# ---- 2. Names and settings (do not edit) -------------------------------------
export CLUSTER_NAME="${PREFIX}-cluster"

# Networking
export VPC_NAME="${PREFIX}-vpc"
export SUBNET_NAME="${PREFIX}-gke-subnet"
export SUBNET_RANGE="10.10.0.0/24"          # Nodes (and the control plane's private endpoint)
export PODS_RANGE_NAME="pods"
export PODS_RANGE="10.20.0.0/16"            # Pods      (secondary range)
export SERVICES_RANGE_NAME="services"
export SERVICES_RANGE="10.30.0.0/20"        # Services  (secondary range)
export ROUTER_NAME="${PREFIX}-router"
export NAT_NAME="${PREFIX}-nat"
export NAT_IP_NAME="${PREFIX}-nat-ip"
export FW_POLICY_NAME="${PREFIX}-egress-policy"
export ALLOWED_EGRESS_FQDNS="ifconfig.me,api.github.com"   # Internet FQDNs the cluster may reach

# Identity, encryption and registry
export NODE_SA_NAME="${PREFIX}-gke-nodes"
export NODE_SA_EMAIL="${NODE_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
export KMS_KEYRING="${PREFIX}-keyring"
export KMS_KEY="gke-secrets"
export KMS_KEY_ID="projects/${PROJECT_ID}/locations/${REGION}/keyRings/${KMS_KEYRING}/cryptoKeys/${KMS_KEY}"
export AR_REPO="${PREFIX}-repo"
export AR_HOST="${REGION}-docker.pkg.dev"
export AR_PATH="${AR_HOST}/${PROJECT_ID}/${AR_REPO}"
export MIRROR_SA_NAME="${PREFIX}-image-mirror"   # Cloud Build identity that copies the workshop images (Lab 02)
export MIRROR_SA_EMAIL="${MIRROR_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Edge (ingress, TLS, WAF)
export GATEWAY_IP_NAME="${PREFIX}-gateway-ip"
export SSL_POLICY="${PREFIX}-ssl-policy"
export ARMOR_POLICY="${PREFIX}-waf-policy"
export APP_HOST="shop.example.com"          # Host name in the self-signed TLS certificate

# Audit logging (Lab 08)
export AUDIT_BUCKET="${PREFIX}-audit-logs"  # Log bucket that keeps a copy of all audit logs
export AUDIT_SINK="${PREFIX}-audit-sink"    # Log sink that routes the audit logs to it

# Application
export APP_NAMESPACE="onlineboutique"
export OB_VERSION="v0.10.7"                  # Online Boutique release (pinned)
export TOOLBOX_IMAGE="${AR_PATH}/curl:8.23.0"   # Small test image (curl + busybox), mirrored in Lab 02

# ---- 3. Values looked up from your project ------------------------------------
if [ -z "${PROJECT_ID}" ] || [[ "${PROJECT_ID}" == REPLACE_WITH* ]]; then
  echo "ERROR: edit env.sh and set PROJECT_ID before sourcing it." >&2
  return 1 2>/dev/null || exit 1
fi
if ! [[ "${PREFIX}" =~ ^[a-z][a-z0-9]{0,9}$ ]]; then
  echo "ERROR: PREFIX must be 1-10 lowercase letters/digits and start with a letter." >&2
  return 1 2>/dev/null || exit 1
fi
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || true)"
export PROJECT_NUMBER
# Empty until the address is reserved in Lab 02
GATEWAY_IP="$(gcloud compute addresses describe "${GATEWAY_IP_NAME}" --global --project="${PROJECT_ID}" --format='value(address)' 2>/dev/null || true)"
export GATEWAY_IP

echo "PROJECT_ID=${PROJECT_ID}  PROJECT_NUMBER=${PROJECT_NUMBER:-<not found>}  REGION=${REGION}  PREFIX=${PREFIX}  CLUSTER_NAME=${CLUSTER_NAME}  GATEWAY_IP=${GATEWAY_IP:-<not reserved yet>}"
