#!/usr/bin/env bash
# =============================================================================
# show-zone-spread.sh - shows how the running Pods of each workload are spread
# across zones and nodes (Labs 05, 09 and 10).
#
# Usage (from the repository root):
#   ./scripts/show-zone-spread.sh [NAMESPACE]      # default: onlineboutique
#
# Workloads are identified by their "app" label, which every Online Boutique
# Pod has. A workload with 2 replicas is zone-redundant when its ZONES column
# lists two different zones.
# =============================================================================
set -euo pipefail
NAMESPACE="${1:-onlineboutique}"

NODE_ZONES="$(mktemp)"
trap 'rm -f "${NODE_ZONES}"' EXIT

# "node zone" pairs
kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' \
  > "${NODE_ZONES}"

printf '%-24s %-5s %-6s %s\n' "APP" "PODS" "NODES" "ZONES"
# "app node" pairs of the running Pods, joined with the node's zone
kubectl get pods -n "${NAMESPACE}" --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.labels.app}{" "}{.spec.nodeName}{"\n"}{end}' \
  | awk -v nodefile="${NODE_ZONES}" '
      BEGIN { while ((getline line < nodefile) > 0) { split(line, f, " "); zone[f[1]] = f[2] } }
      $1 != "" {
        pods[$1]++
        if (!seen_node[$1, $2]++) nodes[$1]++
        zones[$1] = zones[$1] " " zone[$2]
      }
      END { for (app in pods) printf "%-24s %-5d %-6d%s\n", app, pods[app], nodes[app], zones[app] }' \
  | sort
