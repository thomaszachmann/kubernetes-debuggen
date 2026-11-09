#import "../lib.typ": *

#kapitel(
  [Pods Stay Pending],
  ziel: [You read the scheduler's messages, recognize whether a pod fails because of resources, labels, taints, volumes or a quota, and you fix each of these errors on RKE2 and Talos.],
  zeit: [60 minutes],
  braucht: [Chapters 2 and 3],
)

== What Breaks in This Chapter

A pod in `Pending` does not have a node yet. No container runs, there are no logs, and `kubectl logs` stays empty. The answer is almost always in one of two places: in the pod's events, written by the scheduler, or, if the pod does not exist at all, in the events of the ReplicaSet.

#tabelle(
  (auto, 1fr, 1fr),
  ([Scenario], [Symptom], [Where the answer is]),
  [Requests too large], [Pod `Pending`, event `FailedScheduling`], [`Insufficient cpu` in the pod event],
  [nodeSelector and taint], [Pod `Pending`], [`didn't match Pod's node affinity/selector`, `had untolerated taint(s)`],
  [PVC without StorageClass], [Pod and PVC `Pending`], [`unbound immediate PersistentVolumeClaims`, events of the PVC],
  [ResourceQuota], [Deployment `0/2`, *no* pod], [Event `FailedCreate` on the ReplicaSet],
)

All scenarios run in the namespace `dbg-04`, which every `kaputt-*.yaml` creates itself (`kaputt` means "broken"). The quota from the last scenario applies to the whole namespace, so apply it last. On Talos, `kubectl apply` reports `Warning: would violate PodSecurity "restricted:latest": ...` for these manifests. Talos enforces only `baseline` cluster-wide and warns about `restricted`. The warning blocks nothing. There is more on this in Chapter 10.

== The Scheduler Explains Itself

If the scheduler finds no node, it writes an event with the reason `FailedScheduling`. The text always follows the pattern `0/2 nodes are available: <reasons per node>. preemption: <result>`. The first part counts, for each reason, on how many nodes it applied. `2 Insufficient cpu` means: both nodes have too little free CPU. If there are several reasons, the numbers add up to the number of nodes, because the scheduler reports the first filter that fails for each node. The second part says whether the scheduler could evict other pods to make room. `Preemption is not helpful for scheduling` means: evicting does not solve this problem, for example because a label is missing. Then you have to change something yourself.

== Requests Too Large

Requests are reservations. The scheduler does not calculate with the actual load of a node, but with the sum of the requests of all pods on it. A pod that asks for more than a node can allocate never finds a place, even if the cluster is doing nothing at the moment.

#datei("szenarien/04-pending/kaputt-ressourcen.yaml (excerpt)", ```yaml
      containers:
        - name: app
          image: busybox:1.37
          command: ["sleep", "infinity"]
          resources:
            requests:
              cpu: "6"
              memory: 256Mi
```, erklaerung: [Six CPU cores as a request. The largest node in the lab has four.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/kaputt-ressourcen.yaml
kubectl --context talos apply -f szenarien/04-pending/kaputt-ressourcen.yaml
```][Creates the namespace and the Deployment `gross` ("big") on both clusters.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-04 -o wide
NAME                     READY   STATUS    RESTARTS   AGE   IP       NODE     NOMINATED NODE   READINESS GATES
gross-6d4b9c7f8d-q2xkp   0/1     Pending   0          48s   <none>   <none>   <none>           <none>
```
No node, no IP, no restarts. The pod waits, and it stays that way.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-04 -l app=gross
```][`describe` with a label selector saves you from typing the pod name. The important part is the `Events` block at the very bottom.]

```text
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  51s   default-scheduler  0/2 nodes are available: 2 Insufficient cpu.
  preemption: 0/2 nodes are available: 2 No preemption victims found for incoming pod.
```

Both nodes have too little CPU, and evicting other pods would not help either. `describe node` shows what a node can hand out (`Allocatable`) and how much of it is already taken:

#cmd("Mac")[```bash
kubectl --context rke2 describe node rke2-cp | grep -A 8 "Allocated resources"
```][The `Requests` column is what counts, not `Limits`. Limits may add up to more than 100 percent, requests may not. You see the `Allocatable` block further up in the same output without `grep`.]

```text
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests     Limits
  --------           --------     ------
  cpu                1150m (28%)  200m (5%)
  memory             1004Mi (12%) 662Mi (8%)
  ephemeral-storage  0 (0%)       0 (0%)
```

In k9s you reach the same goal the same way, only faster between the views:

#cmd("k9s")[```text
:pods dbg-04⏎   select pod, d   (describe, events at the bottom)
                or Shift-E      (plugin: kubectl events --for)
:nodes⏎         select node, d
```][`Esc` takes you back to the list, and `/` filters the describe view for `FailedScheduling`. `Shift-E` is the plugin from Chapter 3.]

#ursache[
  The pod requests 6 CPUs, and no node can allocate more than 4. For every node, the scheduler checks whether `allocatable` minus the sum of the existing requests is enough for the new request. This is pure bookkeeping: whether the CPU is busy right now does not matter. A request larger than any single node therefore stays `Pending` forever.
]

=== Fix

Realistic requests are based on measured usage. In the lab, a quarter of a core is enough: `fix-ressourcen.yaml` sets `requests.cpu: 250m`, everything else is the same.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/fix-ressourcen.yaml
kubectl --context talos apply -f szenarien/04-pending/fix-ressourcen.yaml
```][The Deployment creates a new ReplicaSet, and the old pending pod disappears.]

#pruefe[
```text
$ kubectl --context rke2 get pods -n dbg-04 -l app=gross
NAME                     READY   STATUS    RESTARTS   AGE
gross-7f5c8b9d64-mz7wd   1/1     Running   0          9s
```
The event history (`kubectl --context rke2 events -n dbg-04 --for pod/<name>`) now shows `Successfully assigned dbg-04/... to rke2-cp` or `to rke2-w1`.
]

#warum[
  Partial success is more dangerous: three replicas of 1500m each fit only twice in the lab. The third pod stays `Pending`, and the Deployment shows a half-healthy `2/3`.
]

== nodeSelector and Taint

A `nodeSelector` is a hard condition: the pod may only go to nodes that carry all the listed labels. A taint is the counterpart: the node rejects pods that do not explicitly tolerate it. Typical examples are nodes for special tasks, nodes in maintenance and control plane nodes. In the lab, you turn `rke2-w1` and `talos-w1` into a batch node with a label *and* a taint.

#cmd("Mac")[```bash
kubectl --context rke2 label node rke2-w1 dbg-pool=batch
kubectl --context rke2 taint node rke2-w1 dbg-pool=batch:NoSchedule
kubectl --context talos label node talos-w1 dbg-pool=batch
kubectl --context talos taint node talos-w1 dbg-pool=batch:NoSchedule
```][`NoSchedule` only prevents new pods. What is already running on the node stays. `NoExecute` would also evict running pods without a toleration.]

#datei("szenarien/04-pending/kaputt-taint.yaml (excerpt)", ```yaml
    spec:
      nodeSelector:
        dbg-pool: batch
      containers:
        - name: app
          image: busybox:1.37
```, erklaerung: [The pod wants to go to the batch node, but it has no toleration.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/kaputt-taint.yaml
kubectl --context talos apply -f szenarien/04-pending/kaputt-taint.yaml
```][Creates the Deployment `batch`.]

#symptom[
  The pod `batch-...` is `Pending`, even though there is a node with the matching label.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-04 -l app=batch | tail -n 4
```][The last lines of `describe` are the events.]

```text
  Warning  FailedScheduling  20s   default-scheduler  0/2 nodes are available: 1 node(s) didn't
  match Pod's node affinity/selector, 1 node(s) had untolerated taint(s). preemption: 0/2 nodes
  are available: 2 Preemption is not helpful for scheduling.
```

Two reasons, and their numbers add up to the two nodes: `rke2-cp` fails on the selector, `rke2-w1` on the taint. If no node had the label at all, it would say `2 node(s) didn't match Pod's node affinity/selector`. The `NodeAffinity` filter checks `nodeSelector` and `requiredDuringScheduling...` together, hence the double name. The message does not tell you which label and which taint it means. Older versions still named the taint, Kubernetes 1.36 no longer does. You compare yourself:

#cmd("Mac")[```bash
kubectl --context rke2 get nodes \
  -o custom-columns=NAME:.metadata.name,POOL:.metadata.labels.dbg-pool,TAINTS:.spec.taints
```][Shows the label and the taints for each node. `<none>` means: not present. What the pod requires and tolerates is in `describe pod` under `Node-Selectors` and `Tolerations`.]

```text
NAME      POOL    TAINTS
rke2-cp   <none>  <none>
rke2-w1   batch   [map[effect:NoSchedule key:dbg-pool value:batch]]
```

The pod only has the two tolerations `node.kubernetes.io/not-ready` and `unreachable` for 300 seconds, which every pod gets automatically. `dbg-pool` is not among them. In k9s you see the taints with `:nodes⏎`, select the node, press `y` for the YAML, and look under `spec.taints`.

#ursache[
  The selector sends the pod to exactly one node, and that node rejects it with a taint. Selector and toleration answer different questions: the selector says where the pod *wants* to go, the toleration says where it *may* go. A special node needs both. Otherwise either foreign pods end up on it, or your own pods do not.
]

=== Fix

`fix-taint.yaml` adds the matching toleration to the pod template:

```yaml
      tolerations:
        - {key: dbg-pool, operator: Equal, value: batch, effect: NoSchedule}
```

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/fix-taint.yaml
kubectl --context talos apply -f szenarien/04-pending/fix-taint.yaml
```][The new ReplicaSet creates a pod with the toleration.]

#pruefe[
  `kubectl --context rke2 get pods -n dbg-04 -l app=batch -o wide` shows `Running` on `rke2-w1`, and on Talos on `talos-w1`.
]

Remove the taint and the label afterward. Otherwise future pods will no longer land on the worker:

#cmd("Mac")[```bash
kubectl --context rke2 taint node rke2-w1 dbg-pool=batch:NoSchedule-
kubectl --context rke2 label node rke2-w1 dbg-pool-
kubectl --context talos taint node talos-w1 dbg-pool=batch:NoSchedule-
kubectl --context talos label node talos-w1 dbg-pool-
```][The trailing minus removes the taint or the label.]

#distro[
  In the lab, the RKE2 server accepts workloads and has no taint. If you want to keep server nodes free, set for example `node-taint: ["CriticalAddonsOnly=true:NoExecute"]` in `/etc/rancher/rke2/config.yaml`. Permanent labels go there under `node-label:`.
][
  Without `cluster.allowSchedulingOnControlPlanes: true`, `talos-cp` carries the taint `node-role.kubernetes.io/control-plane:NoSchedule`. In a cluster with only one worker, every pod then lands there, and if the worker is full or gone, everything stays `Pending` with `had untolerated taint(s)`. In the lab, scheduling on the control plane is allowed. Permanent labels go in `machine.nodeLabels`.
]

== PVC Without StorageClass

A pod with a PersistentVolumeClaim can only start when the claim is bound to a volume or can be bound. In the lab, both clusters have the StorageClass `local-path`, but on purpose it is *not* the default. A PVC without `storageClassName` therefore gets no class, and nobody creates a volume.

#datei("szenarien/04-pending/kaputt-pvc.yaml (excerpt)", ```yaml
kind: PersistentVolumeClaim
metadata:
  name: daten
  namespace: dbg-04
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
# ... Deployment "datenbank" mounts the PVC at /daten
```, erklaerung: [No `storageClassName`. You see this in many Helm charts that rely on a default StorageClass.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/kaputt-pvc.yaml
kubectl --context talos apply -f szenarien/04-pending/kaputt-pvc.yaml
```][Creates the PVC `daten` ("data") and the Deployment `datenbank` ("database").]

#symptom[
```text
$ kubectl --context rke2 get pvc -n dbg-04
NAME    STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
daten   Pending                                                     <unset>                 31s
```
The PVC is `Pending`, and the `STORAGECLASS` column is empty. The pod `datenbank-...` is `Pending` too.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-04 -l app=datenbank | tail -n 3
kubectl --context rke2 describe pvc -n dbg-04 daten | tail -n 4
```][First the pod, then the PVC. The real explanation is on the PVC.]

```text
  Warning  FailedScheduling  40s   default-scheduler  0/2 nodes are available: pod has unbound
  immediate PersistentVolumeClaims. preemption: 0/2 nodes are available: 2 Preemption is not
  helpful for scheduling.

  Type    Reason         Age              From                         Message
  ----    ------         ----             ----                         -------
  Normal  FailedBinding  5s (x4 over 40s) persistentvolume-controller  no persistent volumes
  available for this claim and no storage class is set
```

Notice the shape of the scheduler message: no count per node, just a single sentence. Volume binding fails before the individual nodes are even checked. And the PVC message is of type `Normal`, not `Warning`. If you filter with `--types=Warning`, you miss it.

`kubectl --context rke2 get storageclass` shows `local-path` without the `(default)` suffix after the name. In k9s: `:pvc dbg-04⏎`, select the PVC, press `d`. The `STORAGECLASS` column is already empty in the list.

#ursache[
  Without `storageClassName` and without a default StorageClass, there is nobody to provision a volume. The PV controller looks for an existing, matching PersistentVolume without a class, finds none and waits. The scheduler, in turn, does not place a pod with an unbound PVC in `Immediate` mode on a node. Both wait for each other, forever.
]

=== Fix

The PVC names the class explicitly. You can only change the spec of an existing PVC in limited ways, so you delete the Deployment and the PVC and create both again:

#datei("szenarien/04-pending/fix-pvc.yaml (excerpt)", ```yaml
spec:
  storageClassName: local-path
  accessModes: ["ReadWriteOnce"]
```)

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-04 delete deployment datenbank
kubectl --context rke2 -n dbg-04 delete pvc daten
kubectl --context rke2 apply -f szenarien/04-pending/fix-pvc.yaml
```][On Talos, run the same three commands with `--context talos`. Deleting the PVC first does not help: as long as a pod uses it, the finalizer `kubernetes.io/pvc-protection` keeps it in `Terminating`.]

#pruefe[
```text
$ kubectl --context rke2 get pvc -n dbg-04
NAME    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   ...
daten   Bound    pvc-3c1e6a0b-8f5d-4c47-9b1e-2d7a4f0c9e18   1Gi        RWO            local-path     ...
```
Right after it is created, the PVC is briefly `Pending` with the event `WaitForFirstConsumer`: `local-path` only creates the volume once the pod has a node. That is not an error.
]

#falle[
  Alternatively, you make `local-path` the default class with the annotation `storageclass.kubernetes.io/is-default-class: "true"`. Since Kubernetes 1.28, existing PVCs without a class then get this class retroactively as well. In the lab, it deliberately stays without a default.
]

#distro[
  RKE2 does not ship a StorageClass. `local-path` from Chapter 2 stores the data on the node under `/opt/local-path-provisioner`.
][
  Talos does not ship a StorageClass either. `local-path` writes under `/var/mnt/local-path-provisioner`, and the helper pod runs in the namespace `local-path-storage`, which is why that namespace carries `enforce=privileged`. If the label is missing, the helper pod fails, and the PVC stays `Pending` despite the class. Chapter 9 covers this case.
]

== ResourceQuota: The Pod That Does Not Exist

The first three scenarios had a pod in `Pending`. This one has no pod at all. A ResourceQuota limits what a namespace may request in total. As soon as it limits CPU or memory, *every* container must also specify requests and limits for these resources. Quota admission checks this in the API server when the pod is created, and anything that does not comply is rejected.

Before you start, delete the Deployments of the other scenarios with `kubectl --context rke2 -n dbg-04 delete deployment --all` (and the same on Talos), so the numbers below stay easy to read.

#datei("szenarien/04-pending/kaputt-quota.yaml (excerpt)", ```yaml
kind: ResourceQuota
metadata:
  name: dbg-quota
  namespace: dbg-04
spec:
  hard:
    pods: "10"
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
---
# ... Deployment "web" with nginx:1.29, 2 replicas, no resources
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/kaputt-quota.yaml
kubectl --context talos apply -f szenarien/04-pending/kaputt-quota.yaml
```][`apply` reports `deployment.apps/web created`. No error, no warning.]

#symptom[
```text
$ kubectl --context rke2 get deploy,pods -n dbg-04 -l app=web
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   0/2     0            0           25s
```
The Deployment exists, but there is not a single pod, not even one in `Pending`.
]

=== Investigate

The chain is Deployment → ReplicaSet → Pod. If the last link is missing, the error is in the second-to-last:

#cmd("Mac")[```bash
kubectl --context rke2 get rs -n dbg-04 -l app=web
kubectl --context rke2 describe rs -n dbg-04 -l app=web | tail -n 4
```][The ReplicaSet wants two pods (`DESIRED`) but has none (`CURRENT`). Its events say why.]

```text
NAME             DESIRED   CURRENT   READY   AGE
web-5d8c6b7f9c   2         0         0       31s

  Warning  FailedCreate  12s (x5 over 31s)  replicaset-controller  Error creating: pods
  "web-5d8c6b7f9c-x8k2p" is forbidden: failed quota: dbg-quota: must specify limits.cpu for: web;
  limits.memory for: web; requests.cpu for: web; requests.memory for: web
```

The Deployment knows about the problem too: `kubectl describe deploy` shows the line `ReplicaFailure True FailedCreate` under `Conditions`. In k9s, the fastest way is `:deploy dbg-04⏎`, then `Enter` on `web`. That takes you to the ReplicaSet, where `d` shows the events. `:quota dbg-04⏎` with `d` shows how full the quota is, or on the command line `kubectl --context rke2 describe quota -n dbg-04`.

#ursache[
  The quota limits `requests.cpu`, `requests.memory`, `limits.cpu` and `limits.memory`. So admission requires exactly these four values from every container in `dbg-04`. The nginx container has none, so the API server rejects every pod. The ReplicaSet keeps trying with growing intervals and logs every attempt as `FailedCreate`. Because no pod is created, there is no pod event either, and `kubectl get pods` stays empty.
]

=== Fix

#datei("szenarien/04-pending/fix-quota.yaml (excerpt)", ```yaml
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 128Mi
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/fix-quota.yaml
kubectl --context talos apply -f szenarien/04-pending/fix-quota.yaml
```][New pod template, new ReplicaSet. The old one is scaled to zero.]

#pruefe[
```text
$ kubectl --context rke2 describe quota -n dbg-04
Name:            dbg-quota
Namespace:       dbg-04
Resource         Used   Hard
--------         ----   ----
limits.cpu       500m   2
limits.memory    256Mi  2Gi
pods             2      10
requests.cpu     200m   1
requests.memory  128Mi  1Gi
```
Two pods are running, and the quota counts exactly their requests and limits.
]

If the quota is used up, the message is `exceeded quota: dbg-quota, requested: ..., used: ..., limited: ...`. The place stays the same: the events on the ReplicaSet. Rejections by Pod Security (Chapter 10) and by webhooks like Kyverno (Chapter 11) end up there too.

#aufgabe[
  Apply `szenarien/04-pending/aufgabe-limitrange.yaml` to one of the two clusters. The Deployment `rechner` ("calculator") never reaches `1/1`. Find out why without reading the file first, and fix it with your own change.

  Hint: there is no pod here either. The events on the ReplicaSet name a LimitRange whose `max` is smaller than the container's limit. Lower `limits.cpu` to at most `500m`. You do not need to add requests: if a container specifies only limits, Kubernetes sets the requests to the same value, and that also satisfies the quota.
]

Finally, you clean up. This removes the quota, the LimitRange, the PVC and all Deployments:

#cmd("Mac")[```bash
kubectl --context rke2 delete namespace dbg-04
kubectl --context talos delete namespace dbg-04
```][The local-path volume is deleted along with it because of `RECLAIMPOLICY Delete`.]

#gelernt(
  [`Pending` means: no node. There are no logs. The answer is in the pod's events (`describe`, `kubectl events --for`).],
  [The scheduler message counts reasons per node. Several reasons add up to the number of nodes. "Preemption is not helpful" means: you have to change something yourself.],
  [Requests are reservations against `allocatable`, not against the actual load.],
  [The selector says where a pod wants to go, the toleration says where it may go. You show which label is missing and which taint is in the way with `custom-columns` on the nodes.],
  [Neither lab distribution has a default StorageClass. PVCs there need `storageClassName`.],
  [If the pod is missing entirely, the answer is on the ReplicaSet (`FailedCreate`): quota, LimitRange, Pod Security or webhook.],
)
