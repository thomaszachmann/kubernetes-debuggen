#import "../lib.typ": *

#kapitel(
  [Control Plane, etcd and Webhooks],
  ziel: [You check the API server and etcd on both distributions, back up etcd before every intervention, bring a crashed API server back, and recognize expired certificates, hanging webhooks and namespaces that refuse to die.],
  zeit: [90 minutes],
  braucht: [Chapters 2, 3 and 13],
)

== What Breaks in This Chapter

Everything you have investigated so far went through the API server. In this chapter, the API server itself is the problem, or something it asks on every request: etcd, a webhook, an aggregated API. Failures at this layer do not hit one pod, but all users of the cluster at the same time.

#tabelle(
  (auto, 1fr, 1fr),
  ([Scenario], [Symptom], [Where the answer is]),
  [API server does not start], [`connection refused` on every `kubectl`], [Log of the `kube-apiserver` container on the node],
  [Client certificate expired], [`You must be logged in to the server`], [`openssl x509 -enddate`, API server log],
  [Webhook unreachable], [`failed calling webhook` on create], [`ValidatingWebhookConfiguration`, endpoints of the Service],
  [Namespace hangs], [`Terminating` without end], [Conditions of the namespace, `kubectl get apiservice`],
)

The scenarios run in the namespace `dbg-14`. Two of them touch the control plane itself. So read the section on etcd snapshots before you start.

== Is the API Healthy?

The API server describes its own state through two endpoints. `/livez` answers whether the process is alive or should be restarted. `/readyz` says whether it can serve requests, which includes whether etcd answers. With `?verbose`, it lists every individual check.

#cmd("Mac")[```bash
kubectl --context rke2 get --raw='/readyz?verbose'
kubectl --context talos get --raw='/livez?verbose' | tail -n 3
```][Both calls use the same connection as every `kubectl get`, with your admin rights.]

```text
[+]ping ok
[+]log ok
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
...
[+]shutdown ok
readyz check passed
```

A failed check is marked with `[-]`, for example `[-]etcd failed: reason withheld`. The API server holds back the reason on purpose. It is in its own log. You can query individual checks directly, for example `/readyz/etcd`.

#warum[
  If you get no answer at all, but `The connection to the server 172.16.0.160:6443 was refused - did you specify the right host or port?`, no API server is running on this port. Then no `kubectl` helps anymore. You need a path that does not go through the Kubernetes API: SSH on RKE2, the Talos API on Talos.
]

== Before Every Intervention: Check and Back Up etcd

etcd is the memory of the cluster. Every object and every Secret lives there. Before you tinker with the control plane, you check whether etcd is healthy and take a snapshot. Both lab clusters have exactly one etcd member, on `rke2-cp` and `talos-cp`.

=== RKE2

RKE2 runs etcd as a static pod. `etcdctl` is in the image. The client certificates are on the node under `/var/lib/rancher/rke2/server/tls/etcd/` and are mounted into the pod.

#cmd("rke2-cp")[```bash
etcdcontainer=$(crictl ps --name etcd --quiet)
TLS="--cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt
  --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt
  --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key"
crictl exec "$etcdcontainer" etcdctl $TLS endpoint health
crictl exec "$etcdcontainer" etcdctl $TLS endpoint status -w table
crictl exec "$etcdcontainer" etcdctl $TLS alarm list
```][As root in the RKE2 environment from Chapter 2. `$TLS` is deliberately unquoted, because the shell is supposed to split it into separate arguments.]

```text
127.0.0.1:2379 is healthy: successfully committed proposal: took = 2.4ms
```

`endpoint status` shows the version, database size, leader and Raft index as a table. `alarm list` prints nothing as long as no alarm is active. A `NOSPACE` alarm means the database has reached its quota, and etcd no longer accepts writes.

#cmd("rke2-cp")[```bash
rke2 etcd-snapshot save --name vor-kapitel-14
rke2 etcd-snapshot list
```][A manual snapshot (`vor-kapitel-14` means "before chapter 14"). `list` (alias `ls`) shows the name, location, size and time of all snapshots.]

#pruefe[
  A line `vor-kapitel-14-rke2-cp-...` with the location `file:///var/lib/rancher/rke2/server/db/snapshots/...`. On top of that come the automatic snapshots, which RKE2 takes by default at midnight and noon, keeping five of them. RKE2 does not clean up manual snapshots automatically.
]

=== Talos

On Talos, etcd is not a pod but a Talos service. Everything goes through the Talos API, even when Kubernetes no longer answers at all.

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 service etcd
talosctl -n 172.16.0.170 etcd members
talosctl -n 172.16.0.170 etcd status
talosctl -n 172.16.0.170 etcd alarm list
```][Service status, member list, size and leader, and finally the alarms.]

```text
NODE           MEMBER             DB SIZE   IN USE            LEADER
172.16.0.170   3f1c2b9a7d4e6a10   28 MB     9.1 MB (32.50%)   3f1c2b9a7d4e6a10
```

#cmd("Mac")[```bash
mkdir -p ~/talos-backup
talosctl -n 172.16.0.170 etcd snapshot ~/talos-backup/etcd-$(date +%F).snapshot
```][Streams a consistent snapshot to the Mac. The file contains all Secrets of the cluster, so it does not belong in the repo.]

#distro(
  [Restore: `systemctl stop rke2-server`, then `rke2 server --cluster-reset --cluster-reset-restore-path=<snapshot>`, then `systemctl start rke2-server`. RKE2 takes snapshots on a schedule by itself.],
  [Restore: wipe the node's etcd data and bootstrap again with `talosctl bootstrap --recover-from=<snapshot>` (the procedure is in the "Disaster Recovery" guide). Talos has no built-in snapshot schedule. You build one yourself, for example as a cron job with `talosctl`.],
)

== The API Server Does Not Start

A common reason for a dead API server after an upgrade: an argument the new version no longer knows. Feature gates are especially prone to this. Once a feature has gone GA, its gate disappears after a few versions, and if you still set it, you get an API server that aborts at startup. You reproduce this with a made-up gate.

#datei("szenarien/14-controlplane/rke2-config-kaputt.yaml (excerpt)", ```yaml
kube-apiserver-arg:
  - "feature-gates=DebugBuchGate=true"
```, erklaerung: [A drop-in file for RKE2 (`kaputt` means "broken", `Buch` means "book"). It goes into `/etc/rancher/rke2/config.yaml.d/`, and RKE2 reads it after `config.yaml`. To undo it, you simply delete it.])

#datei("labor/talos/patch-apiserver-featuregate.yaml (excerpt)", ```yaml
apiVersion: v1alpha1
kind: KubeAPIServerConfig
extraArgs:
  feature-gates: DebugBuchGate=true
```, erklaerung: [The same for Talos. Since 1.14, the document `KubeAPIServerConfig` configures the API server, and `cluster.apiServer` is deprecated.])

#cmd("Mac")[```bash
scp szenarien/14-controlplane/rke2-config-kaputt.yaml <user>@172.16.0.160:/tmp/
ssh <user>@172.16.0.160
```][Copies the file to `rke2-cp` and logs you in there.]

#cmd("rke2-cp")[```bash
install -D -m 600 /tmp/rke2-config-kaputt.yaml \
  /etc/rancher/rke2/config.yaml.d/90-kaputt.yaml
systemctl restart rke2-server --no-block
```][As root. `--no-block` returns immediately instead of waiting for a start that never finishes. The workloads keep running, only the control plane is gone.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 patch mc \
  --patch @labor/talos/patch-apiserver-featuregate.yaml
```][Talos renders the API server's static pod again without rebooting the node.]

#symptom[
```text
$ kubectl --context rke2 get nodes
The connection to the server 172.16.0.160:6443 was refused - did you specify
the right host or port?
```
On the Talos cluster, the same with `172.16.0.170:6443`. Depending on the timing, you may also see a timeout or `EOF`.
]

=== Investigate on RKE2

The API server is a container like any other. `crictl` asks containerd directly and does not need an API server.

#cmd("rke2-cp")[```bash
crictl ps -a --name kube-apiserver
crictl logs $(crictl ps -a --name kube-apiserver --quiet | head -n 1) 2>&1 \
  | tail -n 5
journalctl -u rke2-server --since "5 min ago" --no-pager | tail -n 10
```][The container list shows `Exited` entries with a rising number in the `ATTEMPT` column. The log of the latest attempt names the reason. The journal shows that RKE2 is waiting for the API server.]

```text
Error: invalid argument "DebugBuchGate=true" for "--feature-gates" flag:
unrecognized feature gate: DebugBuchGate
```

The same logs are available as files under `/var/log/pods/kube-system_kube-apiserver-rke2-cp_*/kube-apiserver/`. The manifest that RKE2 generated from the configuration is in `/var/lib/rancher/rke2/agent/pod-manifests/kube-apiserver.yaml`. A `grep feature-gates` in it confirms where the argument comes from.

=== Investigate on Talos

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 containers --namespace cri | grep kube-apiserver
talosctl -n 172.16.0.170 logs --namespace cri \
  kube-system/kube-apiserver-talos-cp:kube-apiserver:<id>
```][The first line shows the pod sandbox and the API server container with its ID. Put the ID into the second line. Because the container keeps restarting, the ID changes with every attempt.]

The log contains the same message as on RKE2. To see which configuration Talos rendered, use `talosctl -n 172.16.0.170 get staticpods kube-apiserver -o yaml`. For a quick overall picture, run `talosctl -n 172.16.0.170 health`: it gets stuck at the check of the Kubernetes components.

#ursache[
  kube-apiserver aborts while parsing its flags, because it does not know the feature gate `DebugBuchGate`. The kubelet keeps restarting the static pod, and every attempt ends immediately. Without an API server, no Kubernetes interface answers anymore. Controllers, the scheduler and `kubectl` stand still, but the running pods keep working.
]

=== Fix

#cmd("rke2-cp")[```bash
rm /etc/rancher/rke2/config.yaml.d/90-kaputt.yaml
systemctl restart rke2-server
```][RKE2 rewrites the API server manifest on every start, now without the gate.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 edit mc
```][In the document `KubeAPIServerConfig`, delete the line `feature-gates: DebugBuchGate=true`. Talos renders the static pod again immediately.]

#pruefe[
  `kubectl --context rke2 get --raw='/readyz'` and the same for `talos` answer with `ok`. `talosctl -n 172.16.0.170 health` runs through without errors.
]

#distro(
  [Without an API server, you go to the node via SSH. `crictl`, `journalctl` and the files under `/var/log/pods/` work independently of Kubernetes. You correct the configuration in `config.yaml` or `config.yaml.d/`.],
  [The Talos API (port 50000) keeps running when Kubernetes is dead. `containers`, `logs`, `edit mc` and `etcd status` all go through it. If the Talos API is gone too, only the VM console remains.],
)

== Expired Client Certificate

Certificates expire, and they do it exactly when nobody is thinking about it. So you create a certificate that expires after ten minutes. The script `kurzlebiges-zertifikat.sh` ("short-lived certificate") sends a CertificateSigningRequest with `expirationSeconds: 600` to the cluster, approves it and builds a separate kubeconfig for the user `dbg14-user`.

#datei("szenarien/14-controlplane/kurzlebiges-zertifikat.sh (excerpt)", ```bash
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
```, erklaerung: [600 seconds is the smallest allowed `expirationSeconds`. The key and kubeconfig end up in `szenarien/14-controlplane/tmp-<kontext>/` (`kontext` is the context name), and Git ignores this directory.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/14-controlplane/kaputt-zertifikat.yaml
szenarien/14-controlplane/kurzlebiges-zertifikat.sh rke2
export KC=szenarien/14-controlplane/tmp-rke2/dbg14-user.kubeconfig
kubectl --kubeconfig $KC get configmaps
```][Creates the namespace, a ConfigMap and a RoleBinding, generates the certificate and uses it to read the ConfigMaps in `dbg-14`. That works. Now take a ten-minute break.]

#symptom[
```text
$ kubectl --kubeconfig $KC get configmaps
error: You must be logged in to the server (Unauthorized)
```
Depending on the kubectl version, the parentheses may also say `the server has asked for the client to provide credentials`. Nothing in the kubeconfig has changed.
]

=== Investigate

`Unauthorized` means the API server does not know who you are. With client certificates, the first suspect is the expiration date.

#cmd("Mac")[```bash
kubectl config view --kubeconfig $KC --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject -enddate
```][Extracts the certificate from the kubeconfig and shows the subject and expiration time.]

```text
subject=CN=dbg14-user
notAfter=Nov  9 21:50:12 2026 GMT
```

That time is in the past. The cross-check is in the API server log, which you can read with your admin access:

#cmd("Mac")[```bash
kubectl --context rke2 logs -n kube-system kube-apiserver-rke2-cp --since=15m \
  | grep -m 1 "certificate has expired"
```][On Talos, the pod is called `kube-apiserver-talos-cp`.]

It says something like `"Unable to authenticate the request" err="[x509: certificate has expired or is not yet valid: current time ... is after ...]"`.

#ursache[
  The client certificate has expired. The API server checks the validity on every request and rejects expired certificates. For security reasons, it only tells the client `Unauthorized` and writes the exact reason into its own log.
]

#tabelle(
  (auto, 1fr),
  ([Message on the client], [What is expired or wrong]),
  [`You must be logged in to the server (Unauthorized)`], [your client certificate (or token) from the kubeconfig],
  [`x509: certificate has expired or is not yet valid`], [the API server's serving certificate, or your computer's clock is wrong],
  [`x509: certificate signed by unknown authority`], [the CA in your kubeconfig does not match the cluster, for example after a reinstall],
)

=== Fix

For the test user, you simply create a new certificate by running the script again. The more important question is when the real certificates of your clusters expire.

#cmd("rke2-cp")[```bash
rke2 certificate check --output table
```][Lists all RKE2 certificates with expiration date, remaining time and status.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 get kubernetesdynamiccerts -o yaml | head -n 20
talosctl config info
kubectl config view --context talos --minify --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -enddate
```][The dynamic Kubernetes certificates of Talos in PEM format, then the lifetime of your `talosconfig` in the line `Certificate expires`, and finally the expiration date of your admin certificate for the context `talos`.]

#pruefe[
  After running the script again, `kubectl --kubeconfig $KC get configmaps` returns the ConfigMap `hallo` ("hello") again. You no longer need `$KC` for the rest of the chapter: `unset KC`.
]

#distro(
  [Certificates are valid for 365 days. At startup, RKE2 renews every certificate that has expired or expires in less than 120 days. By hand: `systemctl stop rke2-server`, `rke2 certificate rotate`, `systemctl start rke2-server`. After that, you have to copy `/etc/rancher/rke2/rke2.yaml` to the Mac again, because the admin certificate is new too.],
  [Talos renews the server certificates itself, and the kubelet needs at least one restart a year for that. Client certificates are your job: every `talosctl kubeconfig` creates a kubeconfig valid for one year. You renew the `talosconfig` with `talosctl config new` while the old one is still valid.],
)

== A Webhook Blocks the Namespace

The API server asks admission webhooks on every matching write. If the webhook is unreachable, `failurePolicy` decides: `Ignore` lets the request through, `Fail` rejects it. Kyverno is one example (Chapter 11). This section is about the general case.

#datei("szenarien/14-controlplane/kaputt-webhook.yaml (excerpt)", ```yaml
kind: ValidatingWebhookConfiguration
metadata:
  name: dbg14-pruefung
webhooks:
  - name: pruefung.dbg14.example.com
    failurePolicy: Fail
    timeoutSeconds: 5
    clientConfig:
      service:
        name: pruefer
        namespace: dbg-14
        path: /validate
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: dbg-14
    rules:
      - operations: ["CREATE", "UPDATE"]
        resources: ["configmaps"]
# ...
```, erklaerung: [The Service `pruefer` ("checker") does not have a single pod (`pruefung` means "check"). The `namespaceSelector` limits the damage to `dbg-14`.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/14-controlplane/kaputt-webhook.yaml
kubectl --context rke2 create configmap test -n dbg-14 --from-literal=a=b
```][Creates the webhook and the Service, then tries to create a ConfigMap.]

#symptom[
```text
error: failed to create configmap: Internal error occurred: failed calling webhook
"pruefung.dbg14.example.com": failed to call webhook: Post
"https://pruefer.dbg-14.svc:443/validate?timeout=5s": <Grund>
```
The actual reason (`<Grund>`) comes at the end. It depends on how the API server resolves the Service and what the network answers: `connect: connection refused`, `no endpoints available for service "pruefer"` or, with a backend that does not answer, `context deadline exceeded` after `timeoutSeconds`.
]

=== Investigate

The message names the webhook, not the configuration. You find both in the list:

#cmd("Mac")[```bash
kubectl --context rke2 get \
  validatingwebhookconfigurations,mutatingwebhookconfigurations
kubectl --context rke2 get validatingwebhookconfiguration dbg14-pruefung \
  -o jsonpath='{.webhooks[*].clientConfig.service}{"\n"}'
kubectl --context rke2 get endpointslices -n dbg-14
```][All webhook configurations, then the target of the webhook in question, and finally the endpoints of the target Service.]

```text
NAME            ADDRESSTYPE   PORTS     ENDPOINTS   AGE
pruefer-x8k2d   IPv4          <unset>   <unset>     2m
```

In k9s, open the list with `:validatingwebhookconfigurations` and the entry's YAML with `y`. No endpoints, so no pod behind the Service.

#ursache[
  For every ConfigMap in `dbg-14`, the API server has to ask the webhook. The Service behind it has no pods, so the call fails. Because of `failurePolicy: Fail`, the API server rejects the request. Without a `namespaceSelector`, this would hit every namespace, and with pods as the target, the cluster could not even restart its own components.
]

=== Fix

The right fix is to get the backend running again. If it is gone for good, you remove the configuration. In an emergency, you temporarily switch to `Ignore`:

#cmd("Mac")[```bash
kubectl --context rke2 patch validatingwebhookconfiguration dbg14-pruefung \
  --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
kubectl --context rke2 delete validatingwebhookconfiguration dbg14-pruefung
```][The first command is the emergency exit, the second one is the actual solution. Webhook configurations themselves never go through webhooks, so you can always change or delete them.]

#pruefe[
  `kubectl --context rke2 create configmap test -n dbg-14 --from-literal=a=b` reports `configmap/test created`.
]

== The Namespace Stays in Terminating

A namespace only disappears once the namespace controller has deleted everything in it. For that, it needs to know which resource types exist at all, so it asks the API server's discovery. If an aggregated API does not answer, the list is incomplete, and the controller does not delete the namespace, to be on the safe side. The classic case: someone removes the metrics-server, but the APIService `v1beta1.metrics.k8s.io` stays behind.

#datei("szenarien/14-controlplane/kaputt-apiservice.yaml (excerpt)", ```yaml
kind: APIService
metadata:
  name: v1alpha1.debug.dbg14.example.com
spec:
  group: debug.dbg14.example.com
  version: v1alpha1
  service:
    name: debug-api
    namespace: dbg-14
# ...
---
kind: ConfigMap
metadata:
  name: festgehalten
  namespace: dbg-14
  finalizers:
    - dbg14.example.com/aufraeumen
```, erklaerung: [An API group whose Service has no pods, and a ConfigMap `festgehalten` ("held") with a finalizer `aufraeumen` ("clean up") that no controller ever removes. Two typical reasons for hanging namespaces in one file.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/14-controlplane/kaputt-apiservice.yaml
kubectl --context rke2 delete ns dbg-14 --wait=false
```][`--wait=false`, because otherwise `kubectl` waits forever for the end.]

#symptom[
```text
$ kubectl --context rke2 get ns dbg-14
NAME     STATUS        AGE
dbg-14   Terminating   14m
```
No change even after minutes. Some `kubectl` commands report errors about the group `debug.dbg14.example.com` along the way.
]

=== Investigate

The namespace controller writes into the namespace's conditions what it is stuck on.

#cmd("Mac")[```bash
kubectl --context rke2 get ns dbg-14 -o json | jq -r \
  '.status.conditions[] | select(.status=="True") | "\(.reason): \(.message)"'
```][Only the conditions with status `True`, that is, the actual problems.]

```text
DiscoveryFailed: Discovery failed for some groups, 1 failing: unable to retrieve
  the complete list of server APIs: debug.dbg14.example.com/v1alpha1: ...
SomeResourcesRemain: Some resources are remaining: configmaps. has 1 resource
  instances
SomeFinalizersRemain: Some content in the namespace has finalizers remaining:
  dbg14.example.com/aufraeumen in 1 resource instances
```

#cmd("Mac")[```bash
kubectl --context rke2 get apiservice v1alpha1.debug.dbg14.example.com
kubectl --context rke2 get configmaps -n dbg-14
```][The APIService of the group and what is left in the namespace. Without a name, `get apiservice` lists all of them. Those served by the API server itself show `Local` in `SERVICE`.]

```text
NAME                               SERVICE            AVAILABLE                 AGE
v1alpha1.debug.dbg14.example.com   dbg-14/debug-api   False (ServiceNotFound)   15m
```

Before the deletion, it said `False (MissingEndpoints)`. Now the namespace controller has already removed the Service, and the APIService points into nothing. In k9s you find both lists under `:apiservices` and `:namespaces`.

#ursache[
  Two things hold on to the namespace. First, the APIService is not available, discovery stays incomplete, and the controller refuses the final deletion. Because the APIService applies cluster-wide, this affects every namespace you delete during this time. Second, the ConfigMap has a finalizer. The API server only deletes it once someone removes the finalizer, and that someone does not exist.
]

=== Fix

#cmd("Mac")[```bash
kubectl --context rke2 delete apiservice v1alpha1.debug.dbg14.example.com
kubectl --context rke2 patch configmap festgehalten -n dbg-14 \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```][First remove the orphaned APIService, then remove the finalizer. With real finalizers, first check which controller sets it and why it does not remove it.]

#pruefe[
  A few seconds later, `kubectl --context rke2 get ns dbg-14` reports `NotFound`. `kubectl --context rke2 get apiservice` shows only `True` in the `AVAILABLE` column.
]

#falle[
  A tip that circulates online is to remove the finalizer `kubernetes` directly from the namespace via `/finalize`. The namespace is then gone, but its objects are not necessarily: they stay orphaned in etcd and reappear as soon as someone creates a namespace with the same name. Always fix the cause.
]

#aufgabe[
  Reproduce the webhook scenario on `talos`, but first change `failurePolicy` to `Ignore` and `timeoutSeconds` to `10` in a copy of the file. Then, instead of no pod at all, start a pod in the Service `pruefer` that accepts connections but does not speak TLS (for example `nicolaka/netshoot:v0.15` with `nc -lk 8443`, adjust selector and label). How long does `kubectl create configmap` take now, and what is in the API server log?

  Hint: with `Ignore`, the ConfigMap goes through, but only after the timeout. A slow webhook with `Ignore` makes the cluster sluggish instead of broken. Clean up afterwards with `kubectl --context talos delete validatingwebhookconfiguration dbg14-pruefung` and `kubectl --context talos delete ns dbg-14`.
]

#gelernt(
  [`/readyz?verbose` and `/livez?verbose` show the API server's individual checks. If there is no answer at all, you need SSH or the Talos API.],
  [Before every intervention in the control plane: check etcd (`etcdctl` in the etcd container or `talosctl etcd status`) and take a snapshot (`rke2 etcd-snapshot save` or `talosctl etcd snapshot`).],
  [An API server that does not start writes the reason into its container log: on RKE2 through `crictl logs`, on Talos through `talosctl logs --namespace cri`.],
  [`Unauthorized` means your client certificate. `x509` on the client means the server's certificate or CA.],
  [A webhook with `failurePolicy: Fail` and no backend blocks every matching request. You can still always delete webhook configurations.],
  [Hanging namespaces explain themselves in their conditions. The most common causes: an unavailable APIService and finalizers without a controller.],
)
