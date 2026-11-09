#!/usr/bin/env bash
# Kapitel 15, Szenario Helm-Release hängt.
# Simuliert einen CI-Job, der mitten in "helm upgrade --wait" hart
# abgebrochen wird (kill -9, wie bei einem Runner-Timeout).
# Danach steht das Release auf pending-upgrade.
# Aufruf aus dem Repo-Wurzelverzeichnis:
#   szenarien/15-rollouts/haenger.sh rke2
set -euo pipefail

CTX="${1:?Kontext angeben: rke2 oder talos}"
CHART="szenarien/15-rollouts/demo-chart"

# Revision 1: funktioniert.
helm --kube-context "$CTX" upgrade --install demo "$CHART" \
  -n dbg-15 --create-namespace --wait --timeout 2m

# Revision 2: Readiness-Probe auf falschem Port, helm wartet ...
helm --kube-context "$CTX" upgrade demo "$CHART" \
  -n dbg-15 --set readinessPort=9999 --wait --timeout 5m &
HELM_PID=$!

sleep 15
# ... und wird hart beendet. SIGKILL lässt helm keine Chance aufzuräumen.
kill -9 "$HELM_PID"
wait "$HELM_PID" 2>/dev/null || true
echo "helm upgrade (PID $HELM_PID) wurde mit SIGKILL beendet."
