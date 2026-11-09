#import "../lib.typ": *

#kapitel(
  [RBAC and Pod Security],
  ziel: [You read `Forbidden` messages like a log entry, check permissions with `kubectl auth can-i`, find wrongly bound roles and recognize when Pod Security Admission rejects a pod even though the Deployment was accepted.],
  zeit: [60 minutes],
  braucht: [Chapters 2 and 3],
)

== What Breaks in This Chapter

Two mechanisms say “no” in the cluster, and both answer with `Forbidden`. RBAC decides *who* may perform an action on the API. Pod Security Admission (PSA) decides *which* pods may exist at all, no matter who creates them. The messages look alike, but troubleshooting them is completely different.

#tabelle(
  (auto, 1fr, 1fr),
  ([Scenario], [Symptom], [Where the answer is]),
  [RoleBinding in the wrong namespace], [Pod in `CrashLoopBackOff`, log: `cannot list resource "pods"`], [`kubectl auth can-i --as`, `get rolebindings -A`],
  [Role instead of ClusterRole], [Log: `... at the cluster scope`], [`kubectl api-resources --namespaced=false`],
  [hostPath on Talos], [DaemonSet `0/2`, no pod], [Event `FailedCreate` on the DaemonSet],
  [Namespace with `restricted`], [Deployment `0/2`, no pod], [Event `FailedCreate` on the ReplicaSet],
)

All scenarios run in the namespace `dbg-10`. Play them in the order of the chapter. The PSA scenarios set labels on the namespace, and these apply to everything in it.

== Reading a Forbidden Message

Every RBAC rejection follows the same sentence structure. Once you know it, you do not have to guess:

```text
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:dbg-10:app"
cannot list resource "pods" in API group "" in the namespace "dbg-10"
```

#tabelle(
  (auto, 1fr),
  ([Part], [Meaning]),
  [`User "system:serviceaccount:dbg-10:app"`], [The identity. For ServiceAccounts it is always `system:serviceaccount:<namespace>:<name>`.],
  [`cannot list`], [The verb: `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`.],
  [`resource "pods"`], [The resource in the plural. For subresources, for example `pods/log` or `pods/exec`.],
  [`in API group ""`], [The API group. `""` is the core group (pods, Services, ConfigMaps). Deployments live in `apps`.],
  [`in the namespace "dbg-10"`], [The scope. For cluster-wide resources it says `at the cluster scope` here.],
)

You translate these five parts one to one into a rule of a Role. If one of them is missing from the role, or if the role is bound to the wrong identity, you get `Forbidden`.

== RoleBinding in the Wrong Namespace

A Role only applies in its namespace, and so does a RoleBinding. A common copy-and-paste mistake: the RoleBinding comes from another project, and nobody changed its `metadata.namespace`.

#datei("szenarien/10-rbac-psa/kaputt-binding.yaml (excerpt)", ```yaml
kind: RoleBinding
metadata:
  name: pod-reader
  namespace: default        # ERROR: copied, namespace not changed
subjects:
  - kind: ServiceAccount
    name: app
    namespace: dbg-10
roleRef:
  kind: Role
  name: pod-reader
# ...
      containers:
        - name: kubectl
          image: registry.k8s.io/kubectl:v1.36.6
          args: ["get", "pods", "-n", "dbg-10", "--watch"]
```, erklaerung: [The container runs `kubectl get pods --watch` with the token of the ServiceAccount `app`. If that works, it keeps running. If it fails, `kubectl` exits with exit code 1. The pod meets `restricted`, so PSA does not get in your way later.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/kaputt-binding.yaml
kubectl --context talos apply -f szenarien/10-rbac-psa/kaputt-binding.yaml
```][Creates the namespace, the ServiceAccount, the Role, the wrong RoleBinding and the Deployment `pod-lister`.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-10
NAME                         READY   STATUS             RESTARTS      AGE
pod-lister-7d9f6c8b5-k2x8w   0/1     CrashLoopBackOff   3 (28s ago)   75s
```
A crash loop like the ones in Chapter 6. Only the log shows that this is not a bug in the program.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 logs -n dbg-10 deploy/pod-lister
```][During a restart cycle, the container may be gone at that moment. Then `--previous` helps.]

```text
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:dbg-10:app"
cannot list resource "pods" in API group "" in the namespace "dbg-10"
```

Now you ask the API server itself whether this identity is allowed to do this. `--as` lets you act as someone else without knowing their token. Your admin account may do that, normal users may not.

#cmd("Mac")[```bash
kubectl --context rke2 auth can-i list pods -n dbg-10 \
  --as=system:serviceaccount:dbg-10:app
```][Answers with `yes` or `no`. This is the same check that the API server runs for real requests.]

```text
no
```

What is the ServiceAccount allowed to do at all? `--list` shows all rules that apply to it in this namespace:

#cmd("Mac")[```bash
kubectl --context rke2 auth can-i --list -n dbg-10 \
  --as=system:serviceaccount:dbg-10:app
```][This shows only the basic permissions every authenticated user has (`selfsubjectaccessreviews`, `/api/*` and similar), but no pods.]

The Role does exist, though. So you look for the binding, in all namespaces:

#cmd("Mac")[```bash
kubectl --context rke2 get rolebindings -A -o wide | grep -E 'NAMESPACE|pod-reader'
```][`-o wide` shows the role and the subjects. That way you see where the binding really is.]

```text
NAMESPACE   NAME         ROLE              AGE   USERS   GROUPS   SERVICEACCOUNTS
default     pod-reader   Role/pod-reader   3m                     dbg-10/app
```

The binding is in `default` and refers to a Role `pod-reader` in `default`. That Role does not exist there. The API server does not check this when you create the binding. A RoleBinding to a missing role is allowed and has no effect.

#cmd("k9s")[```text
:sa dbg-10⏎        select app, Enter = effective rules
:rolebindings⏎     0 = all namespaces, d = describe
```][In the ServiceAccount view, `Enter` shows the rules that apply to the account through bindings. If the list stays empty, no binding applies. `u` shows which pods use the account.]

#ursache[
  Role and RoleBinding are namespaced, and a RoleBinding always refers to a Role in its *own* namespace. The binding in `default` looks for a Role `pod-reader` there, finds none and therefore grants nothing. The ServiceAccount in `dbg-10` has no permissions.
]

=== Fix

#datei("szenarien/10-rbac-psa/fix-binding.yaml (excerpt)", ```yaml
kind: RoleBinding
metadata:
  name: pod-reader
  namespace: dbg-10
```)

#cmd("Mac")[```bash
kubectl --context rke2 delete rolebinding pod-reader -n default
kubectl --context rke2 apply -f szenarien/10-rbac-psa/fix-binding.yaml
kubectl --context rke2 rollout restart deploy/pod-lister -n dbg-10
```][Deletes the stray binding and creates the correct one. RBAC is checked again on every request. The restart only saves you from waiting for the backoff to end. On Talos, run the same commands with `--context talos`.]

#pruefe[
`kubectl --context rke2 auth can-i list pods -n dbg-10 --as=system:serviceaccount:dbg-10:app` answers `yes`. The pod runs, and its log shows the pod list:
```text
NAME                         READY   STATUS    RESTARTS   AGE
pod-lister-6b8d7f9c4-q7tlm   1/1     Running   0          5s
```
]

== Role Instead of ClusterRole

Some resources do not belong to any namespace: nodes, PersistentVolumes, namespaces themselves, StorageClasses, ClusterRoles. A Role cannot grant permissions on them. The API server still accepts such a Role, because it does not check whether rules make sense.

#datei("szenarien/10-rbac-psa/kaputt-clusterrole.yaml (excerpt)", ```yaml
kind: Role
metadata:
  name: node-reader
  namespace: dbg-10
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
```, erklaerung: [The file also contains a ServiceAccount `node-reader`, a matching RoleBinding in `dbg-10` and a Deployment that runs `kubectl get nodes --watch`.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/kaputt-clusterrole.yaml
```][This time the binding is in the right namespace.]

#symptom[
  The pod `node-lister` goes into `CrashLoopBackOff`. The log:
```text
Error from server (Forbidden): nodes is forbidden: User "system:serviceaccount:dbg-10:node-reader"
cannot list resource "nodes" in API group "" at the cluster scope
```
]

=== Investigate

The key part is `at the cluster scope`. The request has no namespace, so only cluster-wide bindings can help. `api-resources` tells you whether a resource is namespaced:

#cmd("Mac")[```bash
kubectl --context rke2 api-resources --namespaced=false | grep -E 'NAME|^nodes'
```][Lists only cluster-wide resources. With `--namespaced=true` you get the opposite list.]

```text
NAME    SHORTNAMES   APIVERSION   NAMESPACED   KIND
nodes   no           v1           false        Node
```

`kubectl auth can-i list nodes -n dbg-10 --as=system:serviceaccount:dbg-10:node-reader` answers `no`, even though the Role names exactly this permission. Adding `-n` changes nothing, because nodes have no namespace.

#ursache[
  RBAC evaluates a Role only for requests *inside* its namespace. `list nodes` is a request without a namespace, and for those only ClusterRoleBindings count. A RoleBinding that points to a ClusterRole does not help either: it grants the ClusterRole's permissions only inside the namespace of the binding.
]

=== Fix

#datei("szenarien/10-rbac-psa/fix-clusterrole.yaml (excerpt)", ```yaml
kind: ClusterRole
metadata:
  name: dbg-10-node-reader
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
---
kind: ClusterRoleBinding
metadata:
  name: dbg-10-node-reader
subjects:
  - kind: ServiceAccount
    name: node-reader
    namespace: dbg-10
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/fix-clusterrole.yaml
kubectl --context rke2 rollout restart deploy/node-lister -n dbg-10
```][Grants read access to nodes cluster-wide, but only to this one ServiceAccount.]

#pruefe[
  `auth can-i list nodes --as=system:serviceaccount:dbg-10:node-reader` answers `yes`, and `kubectl --context rke2 logs -n dbg-10 deploy/node-lister` shows `rke2-cp` and `rke2-w1`.
]

#falle[
  ClusterRole and ClusterRoleBinding do not belong to any namespace, so `kubectl delete ns dbg-10` does not remove them. Forgotten ClusterRoleBindings are a classic finding in audits: if someone later creates a ServiceAccount with the same name, it inherits the permissions.
]

== Pod Security: What the Distributions Set

PSA checks pods against one of three levels: `privileged` (everything allowed), `baseline` (no known escapes such as `privileged`, `hostPath` or host namespaces) and `restricted` (in addition no root, all capabilities dropped, seccomp). Per namespace, labels set the level for three modes: `enforce` rejects, `warn` returns a warning to `kubectl`, `audit` writes to the audit log. If a label is missing, the cluster-wide default of the API server applies. And that default is exactly what differs in the lab:

#distro(
  [Without `profile` in `/etc/rancher/rke2/config.yaml`, RKE2 writes only `enforce: privileged` to `/etc/rancher/rke2/rke2-pss.yaml`. There is no default for `warn` and `audit`, so there are no warnings either. With `profile: cis`, this becomes `restricted` for all three modes, with `kube-system`, `compliance-operator-system` and `tigera-operator` exempted. You set your own file with `pod-security-admission-config-file`.],
  [In the machine config under `cluster.apiServer.admissionControl`, Talos sets `enforce: baseline`, `audit: restricted` and `warn: restricted` cluster-wide. Only `kube-system` is exempted. That is why on Talos you see warnings `would violate PodSecurity "restricted:latest"` for many manifests, and they block nothing. You can change the default with a machine config patch.],
)

So the same manifest can run on RKE2 and fail on Talos. Check your cluster's default before you look for a problem elsewhere:

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 get machineconfig -o yaml | grep -A 14 'name: PodSecurity'
```][Shows the PSA block from the active machine config of the control plane node. On RKE2 you read the file `/etc/rancher/rke2/rke2-pss.yaml` on `rke2-cp` instead.]

== hostPath: Runs on RKE2, Not on Talos

A small log collector should read `/var/log` on every node. A typical candidate for a DaemonSet with `hostPath`. The name `log-sammler` means "log collector".

#datei("szenarien/10-rbac-psa/kaputt-hostpath.yaml (excerpt)", ```yaml
kind: DaemonSet
metadata:
  name: log-sammler
  namespace: dbg-10
# ...
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/kaputt-hostpath.yaml
kubectl --context talos apply -f szenarien/10-rbac-psa/kaputt-hostpath.yaml
```][On RKE2 there is no complaint. On Talos, `kubectl` prints a warning.]

```text
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false
(container "sammler" must set securityContext.allowPrivilegeEscalation=false), ...
restricted volume types (volume "varlog" uses restricted volume type "hostPath"), ...
daemonset.apps/log-sammler created
```

#symptom[
```text
$ kubectl --context talos get ds -n dbg-10
NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
log-sammler   2         0         0       0            0           <none>          40s
```
Two pods desired, zero created. On RKE2 the same line shows `2 2 2`.
]

=== Investigate

Where there is no pod, there is no `describe pod`. The message is attached to the object that tried to create the pod:

#cmd("Mac")[```bash
kubectl --context talos events -n dbg-10 --for daemonset/log-sammler
```][The events of the DaemonSet. For Deployments you look one level deeper, at the ReplicaSet.]

```text
LAST SEEN   TYPE      REASON         OBJECT                  MESSAGE
12s         Warning   FailedCreate   DaemonSet/log-sammler   Error creating: pods "log-sammler-8kq2d" is
forbidden: violates PodSecurity "baseline:latest": hostPath volumes (volume "varlog")
```

#cmd("k9s")[```text
:ds dbg-10⏎        select log-sammler, d = describe
:events⏎           / FailedCreate⏎
```][The warning is at the end of the DaemonSet's describe view. In the event view, you filter by the reason with `/`.]

`kubectl --context talos get ns dbg-10 --show-labels` confirms it: there is no label `pod-security.kubernetes.io/...`, so the Talos default applies.

#ursache[
  The warning during `apply` came from the `warn` mode (Talos: `restricted`) and did not stop the DaemonSet. In `enforce` mode, PSA checks only pods, not their controllers. That is why the DaemonSet was accepted, and only the DaemonSet controller got the rejection against `baseline` when it tried to create each pod. RKE2 without the CIS profile enforces `privileged` and lets the pod through.
]

=== Fix

There are two clean ways: the pod does without `hostPath`, or the namespace gets a deliberate exception. A log collector needs the node, so you take the second one. You set `warn` and `audit` to `baseline` so that the exception stays visible.

#datei("szenarien/10-rbac-psa/fix-hostpath.yaml", ```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dbg-10
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/warn-version: latest
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/audit-version: latest
```)

#cmd("Mac")[```bash
kubectl --context talos apply -f szenarien/10-rbac-psa/fix-hostpath.yaml
```][The DaemonSet controller tries again after a delay. You do not need to restart anything.]

#pruefe[
  `kubectl --context talos get ds -n dbg-10` shows `2 2 2`. Every change to the DaemonSet still brings the warning `would violate PodSecurity "baseline:latest": hostPath volumes ...`. That is intended: the exception keeps reminding you of itself.
]

#falle[
  The same thing hits `kubectl debug` on Talos. The default profile `general` adds the capability `SYS_PTRACE`, and `baseline` rejects the debug container. Always use `--profile=baseline` there, just like the k9s plugin from Chapter 3 does.
]

== restricted: Deployment Yes, Pods No

For the last scenario you set up the namespace again, this time with the strictest level. This is the normal case for application namespaces.

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-10
kubectl --context talos delete ns dbg-10
```][Cleans up the previous scenarios. Remember the ClusterRole from the second scenario, it stays.]

#datei("szenarien/10-rbac-psa/kaputt-restricted.yaml (excerpt)", ```yaml
kind: Namespace
metadata:
  name: dbg-10
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
# ...
      containers:
        - name: web
          image: nginx:1.29-alpine
```, erklaerung: [An ordinary nginx image without a `securityContext`. It runs as root.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/kaputt-restricted.yaml
```][Here RKE2 is just as strict as Talos, because the label on the namespace overrides any cluster-wide default.]

```text
namespace/dbg-10 created
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false
(container "web" must set securityContext.allowPrivilegeEscalation=false), ...
deployment.apps/web created
```

#symptom[
```text
$ kubectl --context rke2 get deploy,rs,pods -n dbg-10
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   0/2     0            0           30s

NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/web-5d7c9b8f6d   2         0         0       30s
```
`created`, and still not a single pod. In pipelines the warning above easily gets lost, and then this picture is all you see.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 describe rs -n dbg-10 -l app=web | tail -4
```][The ReplicaSet creates the pods, so it got the rejection.]

```text
  Warning  FailedCreate  12s (x14 over 52s)  replicaset-controller  Error creating: pods
"web-5d7c9b8f6d-x7k2p" is forbidden: violates PodSecurity "restricted:latest":
allowPrivilegeEscalation != false (container "web" must set securityContext.
allowPrivilegeEscalation=false), unrestricted capabilities (container "web" must set
securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "web"
must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "web" must
set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

The message is a checklist. Each parenthesis names the field that is missing. Before you tighten an existing namespace, `kubectl label --dry-run=server --overwrite ns <name> pod-security.kubernetes.io/enforce=restricted` checks all running pods against the new level without setting the label.

#ursache[
  `enforce` applies only to pods. A Deployment contains a pod template, but it is checked only in the `warn` and `audit` modes. The Deployment is created, so is the ReplicaSet, and only the pods fail. Without a `warn` label (the normal case on RKE2 without CIS), you would not even get the warning during `apply`.
]

=== Fix

Do not lower the level, fix the pod. nginx offers an image that runs without root on port 8080.

#datei("szenarien/10-rbac-psa/fix-restricted.yaml (excerpt)", ```yaml
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: nginxinc/nginx-unprivileged:1.29-alpine
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/fix-restricted.yaml
kubectl --context talos apply -f szenarien/10-rbac-psa/kaputt-restricted.yaml \
  -f szenarien/10-rbac-psa/fix-restricted.yaml
```][On Talos you create the namespace and the fix in one step. This time there is no warning.]

#pruefe[
```text
$ kubectl --context rke2 get pods -n dbg-10
NAME                   READY   STATUS    RESTARTS   AGE
web-6f8b7d5c9b-4tq8z   1/1     Running   0          8s
web-6f8b7d5c9b-n2wlx   1/1     Running   0          8s
```
]

#aufgabe[
  `szenarien/10-rbac-psa/aufgabe-job.yaml` creates a Job that is supposed to read ConfigMaps in `dbg-10`. It fails with `Forbidden`, even though the Role and the RoleBinding are in the right namespace and name the right ServiceAccount. Find the error using only the log and `kubectl auth can-i`.

  Hint: read the part `in API group "..."` in the message and compare it with the `apiGroups` of the Role.
]

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-10
kubectl --context talos delete ns dbg-10
kubectl --context rke2 delete -f szenarien/10-rbac-psa/fix-clusterrole.yaml
```][Cleans up the chapter, including the cluster-wide objects.]

#gelernt(
  [A `Forbidden` message names the identity, verb, resource, API group and scope, exactly what a role has to contain.],
  [`kubectl auth can-i ... --as=system:serviceaccount:<ns>:<name>` answers permission questions without involving the pod. `--list` shows everything.],
  [RoleBindings only work in their namespace. Cluster-wide resources need a ClusterRole and a ClusterRoleBinding.],
  [PSA enforces levels only for pods. Deployments and DaemonSets are accepted, and the rejection shows up as `FailedCreate` on the controller.],
  [RKE2 without CIS enforces `privileged`, Talos enforces `baseline`. Labels on the namespace override both defaults.],
)
