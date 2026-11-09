#!/usr/bin/env bash
# Kapitel 14: erzeugt ein Client-Zertifikat für dbg14-user, das nach
# 10 Minuten abläuft (expirationSeconds: 600, das erlaubte Minimum),
# und baut daraus eine eigene kubeconfig.
# Aufruf aus dem Repo-Wurzelverzeichnis:
#   szenarien/14-controlplane/kurzlebiges-zertifikat.sh rke2
set -euo pipefail

CTX="${1:?Kontext angeben: rke2 oder talos}"
DIR="szenarien/14-controlplane/tmp-${CTX}"
KC="${DIR}/dbg14-user.kubeconfig"
NAME="dbg14-user"

mkdir -p "$DIR"
chmod 700 "$DIR"

openssl genrsa -out "${DIR}/${NAME}.key" 2048 2>/dev/null
openssl req -new -key "${DIR}/${NAME}.key" -subj "/CN=${NAME}" \
  -out "${DIR}/${NAME}.csr"

kubectl --context "$CTX" delete csr "$NAME" --ignore-not-found
kubectl --context "$CTX" apply -f - <<YAML
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${NAME}
spec:
  request: $(base64 < "${DIR}/${NAME}.csr" | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 600
  usages:
    - client auth
YAML
kubectl --context "$CTX" certificate approve "$NAME"

# Warten, bis der Controller-Manager das Zertifikat ausgestellt hat.
for _ in $(seq 1 20); do
  CRT=$(kubectl --context "$CTX" get csr "$NAME" -o jsonpath='{.status.certificate}')
  [ -n "$CRT" ] && break
  sleep 1
done
if [ -z "$CRT" ]; then
  echo "Zertifikat wurde nicht ausgestellt: kubectl --context $CTX describe csr $NAME" >&2
  exit 1
fi
printf '%s' "$CRT" | base64 -d > "${DIR}/${NAME}.crt"

SERVER=$(kubectl --context "$CTX" config view --minify --raw \
  -o jsonpath='{.clusters[0].cluster.server}')
kubectl --context "$CTX" config view --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > "${DIR}/ca.crt"

rm -f "$KC"
kubectl config --kubeconfig "$KC" set-cluster "$CTX" \
  --server "$SERVER" --certificate-authority "${DIR}/ca.crt" --embed-certs
kubectl config --kubeconfig "$KC" set-credentials "$NAME" \
  --client-certificate "${DIR}/${NAME}.crt" \
  --client-key "${DIR}/${NAME}.key" --embed-certs
kubectl config --kubeconfig "$KC" set-context dbg14 \
  --cluster "$CTX" --user "$NAME" --namespace dbg-14
kubectl config --kubeconfig "$KC" use-context dbg14
chmod 600 "$KC"

openssl x509 -in "${DIR}/${NAME}.crt" -noout -subject -enddate
echo "kubeconfig: $KC"
