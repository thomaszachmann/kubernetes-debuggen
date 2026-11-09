#import "../lib.typ": *

#kapitel(
  [Storage],
  ziel: [You read the events of PVC, PV and provisioner, see why a volume is not created or not mounted, and find a volume's data on the node, on RKE2 via SSH and on Talos with `talosctl`.],
  zeit: [75 minutes],
  braucht: [Chapter 2 (StorageClass `local-path`) and Chapter 4],
)

== What Breaks in This Chapter

Both lab clusters use the local-path-provisioner from Chapter 2. For every PersistentVolumeClaim, it creates a directory on exactly one node and a matching PersistentVolume of type `hostPath` that is bound to this node. That is simple and fast, but it has quirks that look different in production with network storage. This chapter covers both.

#tabelle(
  (auto, 1fr, auto),
  ([Scenario], [Symptom], [Where you see it]),
  [Wrong StorageClass name], [PVC and pod `Pending`], [Events on the PVC],
  [Provisioner without `privileged` (Talos)], [PVC `Pending`, `ProvisioningFailed`], [Events on the PVC],
  [RWO volume, two nodes], [Second replica `Pending`], [Events on the pod],
  [Wrong permissions in the volume], [`Permission denied`, CrashLoopBackOff], [Pod logs],
  [emptyDir overflows], [Pod is evicted, a new one starts], [Status and events],
)

The order of the investigation is always the same: pod, then PVC, then PV, then provisioner, then node. `kubectl get pod,pvc,pv` shows the first three stops, the provisioner log in `local-path-storage` shows the fourth.

#warum[
  The StorageClass `local-path` uses `volumeBindingMode: WaitForFirstConsumer`. So a new PVC stays `Pending` until a pod uses it, and the event says `waiting for first consumer to be created before binding`. That is not an error. Only when the scheduler has picked a node for the pod does the provisioner create the volume, on exactly that node. So a `Pending` PVC is only suspicious when a pod is already waiting for it.
]

== The PVC Cannot Find Its StorageClass

#datei("szenarien/09-storage/kaputt-klasse.yaml (excerpt)", ```yaml
kind: PersistentVolumeClaim
metadata:
  name: daten
  namespace: dbg-09
spec:
  storageClassName: local-paht    # ERROR: typo
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```, erklaerung: [The file also creates the namespace `dbg-09` and a pod `app` that mounts the PVC at `/data`.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/09-storage/kaputt-klasse.yaml
kubectl --context rke2 -n dbg-09 get pod,pvc
```][Creates the PVC and the pod and shows both.]

#symptom[
  ```text
  NAME      READY   STATUS    RESTARTS   AGE
  pod/app   0/1     Pending   0          35s

  NAME                          STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
  persistentvolumeclaim/daten   Pending                                      local-paht     35s
  ```
]

Both are stuck. The pod is waiting for the PVC, so the search starts at the PVC:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-09 describe pvc daten | tail -n 4
kubectl --context rke2 get storageclass
```][The last lines of `describe` are the events. Then the list of all StorageClasses.]

```text
  Type     Reason              Age               From                         Message
  ----     ------              ----              ----                         -------
  Warning  ProvisioningFailed  4s (x4 over 49s)  persistentvolume-controller  storageclass.storage.k8s.io "local-paht" not found
NAME         PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
local-path   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  3d
```

The pod has the event `0/2 nodes are available: pod has unbound immediate PersistentVolumeClaims.` The scheduler treats a PVC with an unknown class like one with immediate binding that just has not been bound yet. In k9s you find the same events with `:pvc dbg-09⏎` and `d` on the PVC.

#ursache[
  The PersistentVolume controller looks for the StorageClass `local-paht` to find the right provisioner. It does not exist, so no volume is ever created, and the PVC stays `Pending`. If `storageClassName` is missing entirely, you end up in a similar dead end: neither lab cluster has a default StorageClass, so the PVC waits for a matching, manually created PV (Chapter 4).
]

The obvious fix is a `kubectl edit`. The API rejects it:

```text
error: persistentvolumeclaims "daten" is invalid: spec: Forbidden: spec is immutable after
creation except resources.requests and volumeAttributesClassName for bound claims
```

The spec of a PVC cannot be changed after it is created. So you delete the pod and the PVC and create both again. In the lab you lose no data, because there never was a volume.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-09 delete pod app
kubectl --context rke2 -n dbg-09 delete pvc daten
kubectl --context rke2 apply -f szenarien/09-storage/fix-klasse.yaml
kubectl --context rke2 -n dbg-09 get pvc daten
```][Delete the pod first, otherwise the finalizer `kubernetes.io/pvc-protection` holds on to the PVC. `fix-klasse.yaml` contains the PVC and the pod, this time with `storageClassName: local-path`.]

#pruefe[
  ```text
  NAME    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
  daten   Bound    pvc-3f1c2a9e-8b7d-4e21-9c55-1d0a6b2e7f43   1Gi        RWO            local-path     12s
  ```
  `kubectl --context rke2 -n dbg-09 events --for pvc/daten` shows the sequence: `WaitForFirstConsumer`, `ExternalProvisioning`, `Provisioning` and `ProvisioningSucceeded` from the provisioner `rancher.io/local-path`.
]

== Talos: The Helper Pod Is Not Allowed to Start

The local-path-provisioner does not create the directory itself. Instead, it briefly starts a helper pod in the namespace `local-path-storage` that mounts the node's directory via `hostPath`. That is exactly what the Pod Security Standard `baseline` forbids, and Talos enforces it cluster-wide. That is why you labeled the namespace with `pod-security.kubernetes.io/enforce=privileged` in Chapter 2. This scenario shows what happens without that label.

#cmd("Mac")[```bash
kubectl --context talos label namespace local-path-storage pod-security.kubernetes.io/enforce-
kubectl --context talos apply -f szenarien/09-storage/pvc-test.yaml
```][The minus at the end removes the label. After that, the Talos default `baseline` applies again. `pvc-test.yaml` only contains a PVC `probe` and a pod that uses it.]

#symptom[
  The pod and the PVC stay `Pending`. This time the StorageClass exists, and the `WaitForFirstConsumer` event is long over, because the pod has been assigned a node.
]

#cmd("Mac")[```bash
kubectl --context talos -n dbg-09 events --for pvc/probe
```][The events of the PVC, sorted by time.]

```text
LAST SEEN   TYPE      REASON                 OBJECT                        MESSAGE
40s         Normal    WaitForFirstConsumer   PersistentVolumeClaim/probe   waiting for first consumer to be created before binding
38s         Normal    Provisioning           PersistentVolumeClaim/probe   External provisioner is provisioning volume for claim "dbg-09/probe"
38s         Warning   ProvisioningFailed     PersistentVolumeClaim/probe   failed to provision volume with StorageClass "local-path": failed to create volume pvc-8e2d...: pods "helper-pod-create-pvc-8e2d..." is forbidden: violates PodSecurity "baseline:latest": hostPath volumes (volume "data")
```

The message names everything: the helper pod, the standard `baseline` and the forbidden field. The provisioner retries with increasing delays. You see every attempt in the provisioner log:

#cmd("Mac")[```bash
kubectl --context talos -n local-path-storage logs deploy/local-path-provisioner --tail=20
```][In k9s: `:pods local-path-storage⏎`, highlight the pod, `l`. The line `create the helper pod helper-pod-create-pvc-... into local-path-storage` comes right before the error message.]

#ursache[
  Pod Security Admission checks every pod against the namespace's standard when the pod is created. The helper pod needs a `hostPath` volume to create a directory on the node, and `baseline` forbids `hostPath` completely. The API rejects the pod, and the provisioner cannot create the volume. The application itself is not affected: its pod only mounts a PVC, not a `hostPath`, so it may run in a `baseline` namespace.
]

#cmd("Mac")[```bash
kubectl --context talos label namespace local-path-storage \
  pod-security.kubernetes.io/enforce=privileged
kubectl --context talos -n dbg-09 get pvc probe -w
```][Sets the label again. The provisioner's next attempt succeeds, and `-w` shows the change to `Bound`. Stop it with `Ctrl-C`.]

#pruefe[
  The PVC is `Bound`, the pod is `Running`. The node now has the directory that the provisioner created:
  ```text
  $ talosctl -n 172.16.0.171 ls /var/mnt/local-path-provisioner
  NODE           NAME
  172.16.0.171   .
  172.16.0.171   pvc-8e2d4b1a-77c3-4f0e-a9d2-5b6c0e1f3a88_dbg-09_probe
  ```
  If the pod runs on `talos-cp`, ask `-n 172.16.0.170` instead. `kubectl get pod probe -o wide` tells you the node.
]

#distro(
  [RKE2 without the CIS profile does not enforce any Pod Security Standard. The helper pod starts even without the label. With `profile: cis`, however, `restricted` applies cluster-wide, and you need an exemption for `local-path-storage` (Chapter 10). The volumes live under `/opt/local-path-provisioner`, the provisioner's default path.],
  [Talos enforces `baseline` in all namespaces except `kube-system`. The provisioner's namespace needs `enforce=privileged`. The volumes live in the user volume `local-path-provisioner` under `/var/mnt/local-path-provisioner` on the EPHEMERAL partition. `talosctl -n 172.16.0.171 get volumestatus u-local-path-provisioner` shows its state.],
)

== Two Replicas, One Volume, Two Nodes

#datei("szenarien/09-storage/kaputt-rwo.yaml (excerpt)", ```yaml
kind: Deployment
metadata:
  name: cache
spec:
  replicas: 2
  template:
    spec:
      affinity:
        podAntiAffinity:         # each replica on a different node
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  app: cache
      # ...
      volumes:
        - name: daten
          persistentVolumeClaim:
            claimName: cache     # ERROR: both replicas share one RWO volume
```, erklaerung: [The PVC `cache` has `accessModes: [ReadWriteOnce]`. The anti-affinity is meant to spread the replicas across both nodes, so that losing one node does not take out both.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/09-storage/kaputt-rwo.yaml
kubectl --context rke2 -n dbg-09 get pods -l app=cache -o wide
```][`-o wide` shows which node each pod landed on.]

#symptom[
  ```text
  NAME                     READY   STATUS    RESTARTS   AGE   IP           NODE      ...
  cache-6f8d7b9c5d-hx2lp   1/1     Running   0          40s   10.42.1.41   rke2-w1   ...
  cache-6f8d7b9c5d-q9m4z   0/1     Pending   0          40s   <none>       <none>    ...
  ```
]

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-09 describe pod cache-6f8d7b9c5d-q9m4z | grep -A3 Events
```][The events of the waiting pod. In k9s: `:pods dbg-09⏎`, highlight the pending pod, `d`.]

```text
  Warning  FailedScheduling  25s  default-scheduler  0/2 nodes are available: 1 node(s) didn't match
  PersistentVolume's node affinity, 1 node(s) didn't match pod anti-affinity rules. preemption: 0/2
  nodes are available: 2 Preemption is not helpful for scheduling.
```

Read the message node by node: `rke2-w1` is ruled out because a replica already runs there (anti-affinity). `rke2-cp` is ruled out because the PV only exists on `rke2-w1`. The node affinity of the PV confirms this: `kubectl --context rke2 get pv -o yaml` shows the node `rke2-w1` under `spec.nodeAffinity`.

#ursache[
  A local-path volume is a directory on exactly one node. That is why the PV carries a node affinity, and every pod that uses it has to run on that node. The anti-affinity demands the opposite. Both at once is impossible. By the way, `ReadWriteOnce` means “writable by one *node*”, not “by one pod”. Without the anti-affinity, both replicas would run on `rke2-w1` and share the directory, which would be just as wrong for most applications.
]

#warum[
  With network storage such as Longhorn, Ceph RBD or cloud disks, the same error looks different. The scheduler places the second replica on the other node, but the volume is already attached to the first node. The pod stays in `ContainerCreating`, and the event says `Multi-Attach error for volume "pvc-..." Volume is already used by pod(s) ...`. The cause and the fix are the same. If you want to guarantee that really only one pod writes, use `ReadWriteOncePod`.
]

The fix: every replica gets its own volume. That is exactly what a StatefulSet with `volumeClaimTemplates` is for.

#datei("szenarien/09-storage/fix-rwo.yaml (excerpt)", ```yaml
kind: StatefulSet
metadata:
  name: cache
spec:
  serviceName: cache
  replicas: 2
  # ... same anti-affinity and same container
  volumeClaimTemplates:
    - metadata:
        name: daten
      spec:
        storageClassName: local-path
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
```, erklaerung: [The StatefulSet creates the PVCs `daten-cache-0` and `daten-cache-1`. Each one is only created when its pod has a node, and thanks to `WaitForFirstConsumer` it ends up on that node. The file also contains the headless Service that `serviceName` requires.])

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-09 delete deploy cache
kubectl --context rke2 -n dbg-09 delete pvc cache
kubectl --context rke2 apply -f szenarien/09-storage/fix-rwo.yaml
kubectl --context rke2 -n dbg-09 get pods,pvc -l app=cache -o wide
```][Removes the old Deployment and the old PVC and creates the StatefulSet. The StatefulSet controller copies the selector's `matchLabels` onto every PVC it creates from `volumeClaimTemplates`. That is why `-l app=cache` finds the pods and the PVCs at once.]

#pruefe[
  `cache-0` and `cache-1` run on different nodes, and `kubectl get pvc -n dbg-09` shows `daten-cache-0` and `daten-cache-1` as `Bound`. The PVCs stay when you delete the StatefulSet. That way the data even survives a `delete sts`.
]

== Permission Denied on the Volume

#datei("szenarien/09-storage/kaputt-rechte.yaml (excerpt)", ```yaml
      initContainers:
        - name: vorbereiten       # runs as root and creates the directory
          image: busybox:1.37
          command: ["sh", "-c", "mkdir -p /data/notizen"]
      containers:
        - name: app
          image: busybox:1.37
          command: ["sh", "-c", "date >> /data/notizen/log.txt && sleep infinity"]
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
```, erklaerung: [A typical pattern after hardening: the application no longer runs as root, but an older init container still does.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/09-storage/kaputt-rechte.yaml
kubectl --context rke2 -n dbg-09 get pods -l app=notizen
kubectl --context rke2 -n dbg-09 logs deploy/notizen -c app --previous
```][`--previous` shows the output of the last crashed container. In k9s: highlight the pod, `l`, then `p` for the previous logs.]

#symptom[
  ```text
  NAME                       READY   STATUS             RESTARTS      AGE
  notizen-7c8f9d6b5f-l4wqk   0/1     CrashLoopBackOff   3 (25s ago)   80s
  sh: can't create /data/notizen/log.txt: Permission denied
  ```
]

Who owns the directory? A look at the node tells you. The PV says where the volume lives:

#cmd("Mac")[```bash
PV=$(kubectl --context rke2 -n dbg-09 get pvc notizen -o jsonpath='{.spec.volumeName}')
kubectl --context rke2 get pv "$PV" -o jsonpath='{.spec.hostPath.path}{"\n"}'
kubectl --context rke2 -n dbg-09 get pod -l app=notizen -o wide
```][The path of the directory on the node, and the node itself.]

#cmd("rke2-w1")[```bash
sudo ls -ln /opt/local-path-provisioner/pvc-5a0e..._dbg-09_notizen/
```][On RKE2 you look directly via SSH. `-n` shows numeric UIDs.]

```text
drwxr-xr-x 2 0 0 4096 Nov  9 20:31 notizen
```

On Talos you ask the same with `talosctl -n 172.16.0.171 ls -l /var/mnt/local-path-provisioner/pvc-..._dbg-09_notizen`. The `UID` and `GID` columns also show `0`.

#ursache[
  The provisioner creates the root directory of the volume with permissions `0777`, so anyone may write there. But the init container created the subdirectory `notizen` as root with `0755`. The application runs as UID 1000 and may not create anything in it. So the error is not in Kubernetes but in the file permissions on the volume.
]

The reflex would be `fsGroup: 1000` in the pod's `securityContext`. For many volume types, the kubelet then changes the group of all files when it mounts the volume. Not here:

#falle[
  By default, local-path creates PVs of type `hostPath`, and the kubelet does not apply `fsGroup` to `hostPath`. The pod starts with `fsGroup`, but the permissions on the volume stay the same, and so does the error. This costs a lot of time if you do not know it. With most CSI drivers, on the other hand, `fsGroup` works.
]

The reliable fix: whoever creates the directory hands it over to the application's user.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/09-storage/fix-rechte.yaml
kubectl --context rke2 -n dbg-09 rollout status deploy/notizen
```][The init container now runs `mkdir -p /data/notizen && chown -R 1000:1000 /data/notizen`. It still runs as root. That is fine for a one-off step, but it violates the `restricted` standard (Chapter 10).]

#pruefe[
  The pod is `1/1 Running`, and `kubectl --context rke2 -n dbg-09 exec deploy/notizen -c app -- cat /data/notizen/log.txt` shows a timestamp. `ls -ln` on the node now shows `1000 1000` for `notizen`.
]

== When Space Runs Out

Not all storage is a PVC. An `emptyDir` lives on the node's disk under `/var/lib/kubelet/pods/`, and the kubelet monitors its size. If a pod exceeds its limit, the kubelet removes it: the pod is *evicted*.

#datei("szenarien/09-storage/kaputt-platte.yaml (excerpt)", ```yaml
      containers:
        - name: export
          image: busybox:1.37
          command: ["sh", "-c", "dd if=/dev/zero of=/cache/export.tmp bs=1M count=80 && sleep infinity"]
          volumeMounts:
            - name: cache
              mountPath: /cache
      volumes:
        - name: cache
          emptyDir:
            sizeLimit: 50Mi        # ERROR: smaller than the intermediate data
```)

#cmd("Mac")[```bash
kubectl --context talos apply -f szenarien/09-storage/kaputt-platte.yaml
kubectl --context talos -n dbg-09 get pods -l app=export -w
```][This time on Talos. The behavior is the same on both clusters. After a few seconds, the first pod is evicted, and the Deployment starts a new one.]

#symptom[
  After a short time, the running pod disappears, a new one starts, and the old ones stay with `0/1`. Depending on the timing, their status is `Error`, `ContainerStatusUnknown` or `Evicted`. `RESTARTS` is 0 everywhere, because this is not a restart but a new pod.
]

#cmd("Mac")[```bash
kubectl --context talos -n dbg-09 get pods -l app=export \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason,MESSAGE:.status.message
```][`status.reason` and `status.message` explain every eviction. In k9s: `:events dbg-09⏎`, where you see the reason `Evicted`.]

```text
NAME                      PHASE     REASON    MESSAGE
export-6d5c8f7b9d-9kq2x   Failed    Evicted   Usage of EmptyDir volume "cache" exceeds the limit "50Mi".
export-6d5c8f7b9d-x7wlm   Running   <none>    <none>
```

#ursache[
  `sizeLimit` does not limit an `emptyDir` the way a file system would. The process can keep writing, and `dd` reports no error. But the kubelet measures the usage regularly, and as soon as it is above the limit, it ends the pod. The Deployment replaces it, the new pod writes the same 80 MiB, and the cycle starts over.
]

#cmd("Mac")[```bash
kubectl --context talos apply -f szenarien/09-storage/fix-platte.yaml
kubectl --context talos -n dbg-09 delete pod --field-selector=status.phase=Failed
```][Raises `sizeLimit` to 200 MiB and sets a request and limit for `ephemeral-storage`, so that the scheduler plans for the space. The second command removes the evicted pods, which would otherwise stay around as leftovers.]

#pruefe[
  One pod `1/1 Running` that is still running after several minutes. `kubectl describe pod` shows the entry `ephemeral-storage: 200Mi` under `Requests`.
]

If not a single pod but the whole node runs low, the kubelet sets the condition `DiskPressure`, adds the taint `node.kubernetes.io/disk-pressure` to the node and evicts pods by priority. Chapter 13 shows how to investigate that. For storage, one lesson remains: local-path volumes live on the same disk as images, logs and `emptyDir`.

#distro(
  [Volumes under `/opt/local-path-provisioner` on the root partition. Check via SSH with `df -h /opt /var/lib/kubelet` and `sudo du -sh /opt/local-path-provisioner/*`. A full volume fills up Ubuntu's system disk.],
  [Volumes under `/var/mnt/local-path-provisioner` on the EPHEMERAL partition, together with images and kubelet data. Check with `talosctl -n 172.16.0.171 mounts` (usage per mount) and `talosctl -n 172.16.0.171 usage /var/mnt/local-path-provisioner`.],
)

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-09
kubectl --context talos delete ns dbg-09
```][Cleans up both clusters. Because `local-path` has `reclaimPolicy: Delete`, the provisioner deletes the PVs and the directories on the nodes together with the PVCs. To do that, it starts helper pods again, `helper-pod-delete-...`.]

#aufgabe[
  On RKE2, create the PVC from `fix-klasse.yaml` without a pod. Wait a minute. What status does the PVC have, and which event do you see? Then create a pod that uses the PVC with `nodeSelector: kubernetes.io/hostname: rke2-cp`. On which node does the volume live afterwards?

  Hint: without a pod, the PVC stays `Pending` with `WaitForFirstConsumer`, which is correct. As soon as the pod is scheduled on `rke2-cp`, the provisioner creates the directory there. The node affinity in the PV shows `rke2-cp`. Every later pod with this PVC also has to run on `rke2-cp`.
]

#gelernt(
  [For storage problems, follow the order pod, PVC, PV, provisioner, node. The events on the PVC are almost always the fastest way to the cause.],
  [`WaitForFirstConsumer` is not an error. The spec of a PVC is immutable, so a wrong StorageClass means creating it again.],
  [On Talos, the local-path-provisioner needs a namespace with PSA `privileged`, otherwise the API rejects its helper pods (`hostPath volumes`).],
  [local-path volumes are bound to one node. `ReadWriteOnce` applies per node. Several replicas with their own data need a StatefulSet with `volumeClaimTemplates`.],
  [`fsGroup` has no effect on `hostPath` PVs. You set the permissions in the volume when you create it, for example in the init container. An `emptyDir` above its `sizeLimit` leads to eviction, not to a write error.],
)
