#!/usr/bin/env bash
# =============================================================================
# mirror-images.sh - copies every container image used in this workshop into
# your own Artifact Registry repository (Lab 02), using Cloud Build.
#
# Why: the cluster can only pull from the approved registry. Internet egress is
# blocked by the firewall policy, and Binary Authorization (Lab 06) only admits
# images from ${AR_PATH}. Artifact Analysis scans every image when it is pushed.
#
# How: the script generates a Cloud Build configuration with one step per image
# (docker pull, tag and push, all in parallel) and runs it in ${REGION} as the
# dedicated service account ${MIRROR_SA_EMAIL}. The images travel over Google's
# network instead of through your Cloud Shell VM, the way a CI pipeline would
# copy them.
#
# Safe to re-run: images that already exist in the repository are skipped. A
# failed build is retried up to two times, for example while IAM roles that were
# granted a moment ago are still propagating.
# =============================================================================
set -euo pipefail
: "${PROJECT_ID:?Run 'source ./env.sh' first}"
: "${REGION:?Run 'source ./env.sh' first}"
: "${AR_PATH:?Run 'source ./env.sh' first}"
: "${OB_VERSION:?Run 'source ./env.sh' first}"
: "${MIRROR_SA_EMAIL:?Run 'source ./env.sh' first}"

OB_SOURCE="us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo"
OB_IMAGES="adservice cartservice checkoutservice currencyservice emailservice frontend loadgenerator paymentservice productcatalogservice recommendationservice shippingservice"
MAX_ATTEMPTS=3

# "source|target" pairs
PAIRS=()
for image in ${OB_IMAGES}; do
  PAIRS+=("${OB_SOURCE}/${image}:${OB_VERSION}|${image}:${OB_VERSION}")
done
# Docker Hub images are pulled through Google's Docker Hub cache (mirror.gcr.io) to avoid rate limits.
PAIRS+=("mirror.gcr.io/library/redis:8.10.2-alpine|redis:8.10.2-alpine")
PAIRS+=("mirror.gcr.io/library/busybox:1.38.0|busybox:1.38.0")
PAIRS+=("mirror.gcr.io/curlimages/curl:8.23.0|curl:8.23.0")

CONFIG="$(mktemp)"
trap 'rm -f "${CONFIG}"' EXIT

# Writes a Cloud Build configuration for the images that are not in the
# repository yet, and sets MISSING to their number.
write_build_config() {
  echo "steps:" > "${CONFIG}"
  MISSING=0
  for pair in "${PAIRS[@]}"; do
    local src="${pair%%|*}"
    local target="${pair##*|}"
    local dst="${AR_PATH}/${target}"
    if gcloud artifacts docker images describe "${dst}" >/dev/null 2>&1; then
      echo ">>> ${target} already exists - skipping"
      continue
    fi
    echo ">>> ${src}  ->  ${dst}"
    MISSING=$((MISSING + 1))
    cat >> "${CONFIG}" <<EOF
- id: '${target}'
  name: gcr.io/cloud-builders/docker
  entrypoint: bash
  args: ['-c', 'docker pull --quiet ${src} && docker tag ${src} ${dst} && docker push --quiet ${dst}']
  waitFor: ['-']
EOF
  done
  cat >> "${CONFIG}" <<EOF
options:
  logging: CLOUD_LOGGING_ONLY
EOF
}

attempt=1
while true; do
  write_build_config
  if [ "${MISSING}" -eq 0 ]; then
    break
  fi
  echo
  echo ">>> Copying ${MISSING} image(s) with Cloud Build (usually 1-3 minutes)..."
  if gcloud builds submit --no-source \
      --region="${REGION}" \
      --config="${CONFIG}" \
      --service-account="projects/${PROJECT_ID}/serviceAccounts/${MIRROR_SA_EMAIL}"; then
    break
  fi
  if [ "${attempt}" -ge "${MAX_ATTEMPTS}" ]; then
    echo "ERROR: the build failed ${MAX_ATTEMPTS} times. Open the logs link above to see why." >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  echo ">>> The build failed. Retrying the missing images in 60 seconds (attempt ${attempt} of ${MAX_ATTEMPTS})..."
  sleep 60
done

echo
echo "Images now in ${AR_PATH}:"
gcloud artifacts docker images list "${AR_PATH}" --include-tags \
  --format="table(package.basename():label=IMAGE,tags.list():label=TAGS)"
