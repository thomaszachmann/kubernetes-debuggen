#import "../lib.typ": *

#kapitel(
  [Nodes],
  ziel: [You recognize when a failure is not in the pod but in the node, investigate the kubelet and the container runtime via SSH on RKE2 and via `talosctl` on Talos, and understand why pods hang for minutes after a node failure.],
  zeit: [75 minutes],
  braucht: [Chapters 2 and 3],
)

== What Breaks in This Chapter

So far the cause was always in a manifest. In this chapter it sits one layer deeper: in the kubelet, which starts and monitors the pods on every node and reports to the API server. If it fails, the cluster only hears silence. And Kubernetes interprets silence cautiously, with deadlines you need to know.

#tabelle(
  (auto, 1fr, 1fr),
  ([Scenario], [Symptom], [Where the answer is]),
  [Kubelet not running], [Node `NotReady`], [`describe node`, then the kubelet log on the node],
  [Node failure], [Pods hang in `Terminating`, replacement only after 5 minutes], [Taints of the node, tolerations of the pod],
  [Local storage full], [Pods `Error`, reason `Evicted`, new pods keep coming], [`.status.message` of the pod, events],
  [Drain hangs], [`kubectl drain` retries endlessly], [`kubectl get pdb`, column `ALLOWED DISRUPTIONS`],
)

All scenarios run in the namespace `dbg-13`. It has the label `pod-security.kubernetes.io/enforce: privileged`. Only the debug pod from the eviction scenario on Talos needs this. The applications themselves comply with `restricted`.

== The Toolbox for Nodes

On an RKE2 node, you log in via SSH and work with the familiar Linux tools. On Talos there is no shell. Every question to the node goes out as an API call through `talosctl`. The table compares the commands you need in this chapter.

#tabelle(
  (auto, 1fr, 1fr),
  ([Question], [RKE2 (on the node, as root)], [Talos (on the Mac)]),
  [Is the kubelet running?], [`systemctl status rke2-agent` (server: `rke2-server`)], [`talosctl -n <IP> service kubelet`],
  [Kubelet log], [`/var/lib/rancher/rke2/agent/logs/kubelet.log`], [`talosctl -n <IP> logs kubelet`],
  [Service log], [`journalctl -u rke2-agent`], [`talosctl -n <IP> services`, `logs <dienst>`],
  [Kernel messages], [`dmesg -T`], [`talosctl -n <IP> dmesg`],
  [Containers on the node], [`crictl ps -a`, `crictl logs <id>`], [`talosctl -n <IP> containers --namespace cri`],
  [Live overview], [`top`, `df -h`], [`talosctl -n <IP> dashboard`],
  [Everything for support], [Collect `journalctl` and logs by hand], [`talosctl -n <IP> support`],
)

For RKE2, the environment from Chapter 2 applies: `sudo -i`, then set `KUBECONFIG`, `PATH` and `CRI_CONFIG_FILE`. Without `CRI_CONFIG_FILE`, `crictl` does not find the RKE2 containerd socket.

#falle[
  Since Talos 1.14, the switch for Kubernetes containers in `talosctl containers` and `talosctl logs` is `--namespace cri`. The older `-k` still works but is marked as deprecated. Also, starting with 1.14, `talosctl support` encrypts the archive by default for the Sidero Labs support team. For your own analysis, you need `--no-encryption` or your own recipients via `--encryption-recipients`.
]

== Node Becomes NotReady

The kubelet checks in with the API server regularly: through a Lease object in the namespace `kube-node-lease` and through the status of the Node object. If these check-ins stop, the node lifecycle controller in the controller manager waits for a grace period, the `node-monitor-grace-period`. In Kubernetes 1.36 it is 50 seconds by default (it used to be 40). After that, it sets all conditions of the node to `Unknown`.

On RKE2, you halt the kubelet by stopping the agent. On Talos that is not so easy, so you build a failure that happens often in practice: a typo in the kubelet arguments.

#datei("labor/talos/patch-kubelet-tippfehler.yaml", ```yaml
apiVersion: v1alpha1
kind: KubeletConfig
extraArgs:
  max-pod: "150"
```, erklaerung: [`tippfehler` means "typo": `max-pods` was intended. Since Talos 1.14, the kubelet configuration lives in its own document `KubeletConfig`. The old field `machine.kubelet` is deprecated.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/web.yaml
kubectl --context talos apply -f szenarien/13-nodes/web.yaml
ssh <user>@172.16.0.161
```][Creates the test application `web` on both clusters and opens a session on `rke2-w1`.]

#cmd("rke2-w1")[```bash
sudo systemctl stop rke2-agent
```][Stops the RKE2 agent and with it the kubelet. The pods' containers usually keep running, but nobody reports them anymore.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.171 patch mc --patch @labor/talos/patch-kubelet-tippfehler.yaml
```][Talos applies the change without rebooting the node and restarts the kubelet with the new argument.]

#symptom[
```text
$ kubectl --context rke2 get nodes
NAME      STATUS     ROLES                       AGE   VERSION
rke2-cp   Ready      control-plane,etcd,master   9d    v1.36.6+rke2r1
rke2-w1   NotReady   <none>                      9d    v1.36.6+rke2r1
```
After about a minute, `rke2-w1` is `NotReady`, and so is `talos-w1` in the cluster `talos`. The pods on it still show `Running`.
]

=== Investigate

Your first look goes to the Node object. It tells you since when and why the node is no longer ready.

#cmd("Mac")[```bash
kubectl --context rke2 describe node rke2-w1 | sed -n '/^Taints/,/^Addresses/p'
```][Shows taints and conditions. The rest of the output (capacity, pods, events) is secondary here.]

```text
Taints:             node.kubernetes.io/unreachable:NoExecute
                    node.kubernetes.io/unreachable:NoSchedule
Unschedulable:      false
...
Conditions:
Type            Status   ... Reason              Message
----            ------   ... ------              -------
MemoryPressure  Unknown  ... NodeStatusUnknown   Kubelet stopped posting node status.
DiskPressure    Unknown  ... NodeStatusUnknown   Kubelet stopped posting node status.
PIDPressure     Unknown  ... NodeStatusUnknown   Kubelet stopped posting node status.
Ready           Unknown  ... NodeStatusUnknown   Kubelet stopped posting node status.
```

`Unknown` means the controller does not know, because the kubelet is silent. If it says `False` with a message from the kubelet instead, the kubelet is running and reports a problem itself, such as a missing CNI. This distinction saves a lot of time. The taint `unreachable` goes with the status `Unknown`. With `False`, the controller sets `node.kubernetes.io/not-ready`.

In k9s you see the same thing in the node view:

#cmd("k9s")[```text
:nodes⏎            Knoten auswählen, d = describe
```][Select the node (`Knoten auswählen`), then `d` for describe. The `STATUS` column shows `NotReady`. In the describe view, `/` and `Conditions` take you to the right place quickly.]

Because the kubelet does not answer, `kubectl` does not help here. `kubectl debug node/rke2-w1` fails too: the debug pod would have to be started by exactly the kubelet that is down. You have to go to the node.

#cmd("rke2-w1")[```bash
systemctl status rke2-agent --no-pager
journalctl -u rke2-agent --since "15 min ago" --no-pager | tail -n 20
tail -n 20 /var/lib/rancher/rke2/agent/logs/kubelet.log
```][The state of the service, its latest messages and the end of the kubelet log. `inactive (dead)` with a `Stopped` entry in the journal means someone halted the service. A crash would look different, with an exit code and restart attempts.]

#ursache[
  On `rke2-w1` the kubelet is not running, because the service `rke2-agent` was stopped. Without a kubelet, nobody renews the node's Lease. After 50 seconds, the node lifecycle controller sets the conditions to `Unknown` and adds the taint `node.kubernetes.io/unreachable`. New pods no longer land on the node, and the old ones stay where they are for now.
]

=== The Same on Talos

On Talos you do not ask `systemd`, but the Talos service manager. The kubelet is a service of its own there, just like `etcd`, `containerd` or `apid`.

#cmd("Mac")[```bash
talosctl -n 172.16.0.171 services
talosctl -n 172.16.0.171 service kubelet
talosctl -n 172.16.0.171 logs kubelet --tail 20
```][A list of all services with state and health, then the kubelet details with its latest events, and finally its log.]

In the service status, starts and failures alternate: Talos keeps restarting the kubelet. The log gives the reason, roughly:

```text
Error: failed to parse kubelet flag: unknown flag: --max-pod
```

#ursache[
  The kubelet aborts while parsing its arguments, because it does not know `--max-pod`. Talos passes `extraArgs` through unchecked. It only rejects arguments it manages itself, such as `kubeconfig` or `container-runtime-endpoint`. The same happens with flags that a new Kubernetes version has removed. After an upgrade, that is a typical cause of `NotReady`.
]

=== Fix

#cmd("rke2-w1")[```bash
sudo systemctl start rke2-agent
```][Starts the agent again. The kubelet checks in within a few seconds.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.171 edit mc
```][Opens the machine config in the editor. In the document `KubeletConfig`, delete the line `max-pod: "150"` (and `extraArgs:` if it becomes empty), save and close. Talos applies the change immediately.]

#pruefe[
  `kubectl --context rke2 get nodes` and `kubectl --context talos get nodes` show `Ready` for both again. The taint `unreachable` is gone, and `talosctl -n 172.16.0.171 service kubelet` reports `STATE Running` and `HEALTH OK`.
]

#distro(
  [The kubelet, containerd and the supervisor run as child processes of `rke2-agent` (on the server: `rke2-server`). Logs are files under `/var/lib/rancher/rke2/agent/logs/` and in the journal. You set kubelet arguments with `kubelet-arg` in `/etc/rancher/rke2/config.yaml`, then restart the service.],
  [The kubelet is a Talos service, not a process you can touch. Status and log come only through `talosctl service` and `talosctl logs`. Arguments live in the document `KubeletConfig`. If even the Talos API is gone, only the VM console with the dashboard remains.],
)

== Pods Hang After a Node Failure

A `NotReady` node does not lose its pods right away. When a pod is created, the admission plugin `DefaultTolerationSeconds` gives it two tolerations: it tolerates the taints `not-ready` and `unreachable` for 300 seconds. Only after that does the taint eviction controller remove it. This time you leave the node down long enough.

#cmd("Mac")[```bash
kubectl --context rke2 get pod -n dbg-13 -l app=web \
  -o jsonpath='{.items[0].spec.tolerations}' | jq
```][Shows the tolerations of a `web` pod. The manifest contains not a single one. Both come from the API server.]

Two entries, for `node.kubernetes.io/not-ready` and `node.kubernetes.io/unreachable`, both with `"effect": "NoExecute"` and `"tolerationSeconds": 300`.

#cmd("rke2-w1")[```bash
sudo systemctl stop rke2-agent
```][The same failure as before. This time you wait six minutes before you continue.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-13 -o wide
NAME                   READY   STATUS        RESTARTS   AGE   IP           NODE
web-7c9d8f6b5d-4kq2m   1/1     Running       0          31m   10.42.0.37   rke2-cp
web-7c9d8f6b5d-r8vtn   1/1     Terminating   0          31m   10.42.1.12   rke2-w1
web-7c9d8f6b5d-x7lpd   1/1     Running       0          47s   10.42.0.41   rke2-cp
```
For five minutes, the pod on `rke2-w1` appeared healthy and `Running`. Now it hangs in `Terminating`, and only now is there a replacement on `rke2-cp`.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-13 --for pod/web-7c9d8f6b5d-r8vtn
```][The events of the hanging pod. Take the name from your own output.]

```text
LAST SEEN   TYPE     REASON                 OBJECT                     MESSAGE
5m10s       Normal   TaintManagerEviction   pod/web-7c9d8f6b5d-r8vtn   Marking ...
```

The full message is `Marking for deletion Pod dbg-13/web-7c9d8f6b5d-r8vtn`. The controller has marked the pod for deletion. It is only deleted once the kubelet confirms that the containers are gone. But that kubelet is not running. So the pod stays in `Terminating` until the node comes back or someone removes the Node object.

#cmd("k9s")[```text
:pods dbg-13⏎      Spalte NODE beachten, Pod wählen, d = describe
:nodes⏎            rke2-w1 wählen, d = describe, Taints prüfen
```][Watch the `NODE` column, select the pod and press `d`. Then select `rke2-w1` in the node view, press `d` and check the taints. In the pod list, the replacement pod with its small `AGE` stands out immediately.]

#ursache[
  The node was unreachable, so the controller set the taint `node.kubernetes.io/unreachable:NoExecute`. The pods tolerate it for 300 seconds. After that, the controller marks them for deletion. Only the kubelet of the failed node can confirm that, so they hang in `Terminating`. The replacement is created anyway, because the ReplicaSet controller no longer counts pods that have a `deletionTimestamp`.
]

#warum[
  The waiting time is intentional. Kubernetes cannot tell a dead node from a network problem. Maybe the containers are still running and writing to a database. With a StatefulSet, a premature replacement would create two pods with the same identity. That is why no replacement appears there even after 300 seconds, as long as the old pod has not really been deleted.
]

=== Fix

The immediate fix is to bring the node back. As soon as the kubelet runs again, it terminates the marked pods and confirms the deletion.

#cmd("rke2-w1")[```bash
sudo systemctl start rke2-agent
```][The hanging pod disappears after a few seconds.]

If the node is lost for good, you delete the Node object with `kubectl --context rke2 delete node rke2-w1`. Then the garbage collector removes the pods that were bound to the node that no longer exists. For stateless applications, you can also set the deadline yourself:

#datei("szenarien/13-nodes/fix-toleranz.yaml (excerpt)", ```yaml
      tolerations:
        - key: node.kubernetes.io/unreachable
          operator: Exists
          effect: NoExecute
          tolerationSeconds: 30
        # ... the same for node.kubernetes.io/not-ready
```, erklaerung: [If the toleration is already in the manifest, the API server does not add its own.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/fix-toleranz.yaml
```][Rolls out `web` again with the shorter tolerations.]

#pruefe[
  If you repeat the failure, the node shows `NotReady` after about 50 seconds, and 30 seconds later the replacement pod is on `rke2-cp`. Start the agent again afterwards.
]

#distro(
  [`systemctl stop rke2-agent` simulates a hard failure well: the kubelet is gone, the containers keep running. Only `rke2-killall.sh` would stop them too.],
  [`talosctl shutdown` and `talosctl reboot` cordon and drain the node first. The pods then move cleanly, and the scenario does not occur. Only `--force` skips cordon and drain. To simulate a real failure, hard power off the VM in the hypervisor.],
)


== Pods Get Evicted

The kubelet protects its node. If memory runs low, the disk fills up (inodes included) or the process IDs run out, it sets the conditions `MemoryPressure`, `DiskPressure` or `PIDPressure` and throws pods out. This throwing out is called eviction. But it also kicks in without any node shortage, when a pod exceeds its own limit for local storage (`ephemeral-storage`). That is the scenario here, because you do not really want to provoke a full disk in the lab.

#datei("szenarien/13-nodes/kaputt-evicted.yaml (excerpt)", ```yaml
          command:
            - sh
            - -c
            - dd if=/dev/zero of=/daten/block bs=1M count=200 && sleep 3600
          resources:
            limits:
              ephemeral-storage: 100Mi
          volumeMounts:
            - name: daten
              mountPath: /daten
      volumes:
        - name: daten
          emptyDir: {}
```, erklaerung: [200 MiB into an `emptyDir` (`daten` means "data"), with 100 MiB allowed. An `emptyDir` without its own medium lives on the node's disk and counts toward the pod's local storage.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/kaputt-evicted.yaml
```][Creates the Deployment `fueller` ("filler"). It behaves the same on Talos.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-13 -l app=fueller
NAME                       READY   STATUS              RESTARTS   AGE
fueller-6f8b7d9c4b-2xjzq   0/1     Error               0          2m4s
fueller-6f8b7d9c4b-9tqwe   0/1     Error               0          71s
fueller-6f8b7d9c4b-mz5rk   1/1     Running             0          9s
```
A new pod every few seconds, and the old ones stay behind with `Error`. Depending on the timing, you also see `ContainerStatusUnknown`.
]

=== Investigate

The `STATUS` column shows the state of the container. The reason the pod was terminated is one level higher, in the pod status.

#cmd("Mac")[```bash
kubectl --context rke2 get pods -n dbg-13 -l app=fueller \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason
kubectl --context rke2 get pod -n dbg-13 <pod> -o jsonpath='{.status.message}{"\n"}'
```][The phase and reason of every pod, then the message of one of the pods with `Error`.]

```text
NAME                       PHASE     REASON
fueller-6f8b7d9c4b-2xjzq   Failed    Evicted
fueller-6f8b7d9c4b-9tqwe   Failed    Evicted
fueller-6f8b7d9c4b-mz5rk   Running   <none>

Pod ephemeral local storage usage exceeds the total limit of containers 100Mi.
```

The same message appears as an event with the reason `Evicted` on the pod. In k9s, open one of the pods with `d`. At the top of the describe view you see `Status: Failed`, `Reason: Evicted` and the message.

With a real node shortage, the message looks different, for example `The node was low on resource: ephemeral-storage.`, and the node shows `DiskPressure=True` with the taint `node.kubernetes.io/disk-pressure`. You can read the thresholds at which the kubelet steps in directly from its running configuration through the API server:

#cmd("Mac")[```bash
kubectl --context rke2 get --raw /api/v1/nodes/rke2-w1/proxy/configz \
  | jq .kubeletconfig.evictionHard
```][The `configz` endpoint returns the active kubelet configuration. This works the same on both distributions.]

```text
{
  "imagefs.available": "15%",
  "imagefs.inodesFree": "5%",
  "memory.available": "100Mi",
  "nodefs.available": "10%",
  "nodefs.inodesFree": "5%"
}
```

These are the Kubernetes defaults. If free space drops below 10 percent, the kubelet starts cleaning up: first unused images and dead containers, then pods. To see how full the disk really is on RKE2, run `df -h /var/lib` on the node. Without SSH, a debug pod works too:

#cmd("Mac")[```bash
kubectl --context rke2 debug node/rke2-w1 -n dbg-13 -it \
  --image=busybox:1.37 --profile=sysadmin -- df -h /host/var/lib
```][Starts a privileged pod in the host network of `rke2-w1`. The node's file system is under `/host`. The pod is named `node-debugger-rke2-w1-` plus a random suffix and stays behind as `Completed` afterwards. Delete it with `kubectl delete pod` or in k9s with `Ctrl-d`.]

#ursache[
  With its `emptyDir`, the container uses more local storage than `limits.ephemeral-storage` allows. The kubelet checks this on every pass of its eviction manager and terminates the pod immediately, without a grace period. An evicted pod does not restart: it stays behind in phase `Failed`, and the Deployment replaces it with a new one that does the same thing.
]

=== Fix

The fix sets the limit to the real need and also limits the volume directly. With `sizeLimit` on the `emptyDir`, the message on overflow is `Usage of EmptyDir volume "daten" exceeds the limit "250Mi".`. That tells you right away which volume is to blame.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/fix-evicted.yaml
kubectl --context rke2 delete pods -n dbg-13 --field-selector=status.phase=Failed
```][A new limit of 300 MiB and `sizeLimit: 250Mi` on the volume. The second line removes the evicted pods left behind. Otherwise Kubernetes only deletes them once the pod garbage collector reaches a very high threshold.]

#pruefe[
  A single `fueller` pod stays `Running`, `RESTARTS` stays at 0, and no new pods appear.
]

#distro(
  [`kubectl debug node/...` works out of the box, and with `chroot /host` you even get the node's tools. On the node itself, `df -h` and `crictl stats` show the usage.],
  [`kubectl debug node/...` needs a namespace with `enforce: privileged`, otherwise the cluster-wide PSA `baseline` rejects the pod. In newly created 1.14 clusters, pods also run in their own sandbox (`workloadIsolation`) and do not see everything on the host. It is better to go directly through the Talos API: `talosctl mounts` shows the usage, and `talosctl debug <image>` opens a debug shell, without any kubelet.],
)

== Drain Hangs on a PodDisruptionBudget

Before maintenance, you empty a node with `kubectl drain`. The command cordons the node and then evicts every pod through the Eviction API. Before it does, this API asks all PodDisruptionBudgets whether the pod may go. A PDB that is too strict always says no.

#datei("szenarien/13-nodes/kaputt-pdb.yaml (excerpt)", ```yaml
kind: Deployment
metadata:
  name: api
spec:
  replicas: 2
# ...
---
kind: PodDisruptionBudget
metadata:
  name: api
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: api
```, erklaerung: [Two replicas, and the PDB demands that both are always available. That looks like maximum safety and forbids every voluntary disruption.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/kaputt-pdb.yaml
kubectl --context rke2 drain rke2-w1 --ignore-daemonsets \
  --delete-emptydir-data --timeout=90s
```][`--ignore-daemonsets` is necessary because DaemonSet pods like `rke2-canal` run on every node. `--delete-emptydir-data` allows evicting pods with an `emptyDir`, such as `fueller`. The timeout makes sure the command gives up at some point.]

#symptom[
```text
node/rke2-w1 cordoned
evicting pod dbg-13/api-5b8f9c7d6-hx2lw
error when evicting pods/"api-5b8f9c7d6-hx2lw" -n "dbg-13" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.
evicting pod dbg-13/api-5b8f9c7d6-hx2lw
error when evicting pods/"api-5b8f9c7d6-hx2lw" -n "dbg-13" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.
...
```
The same attempt every five seconds, until `global timeout reached` appears after 90 seconds. If both `api` pods happen to be on `rke2-cp`, the drain goes through. In that case, check with `kubectl get pods -o wide` and drain the node that has an `api` pod.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 get pdb -n dbg-13
```][The `ALLOWED DISRUPTIONS` column is the only one that matters.]

```text
NAME   MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
api    2               N/A               0                     3m
```

Zero allowed disruptions. That does not change as long as both pods are running. In k9s, you reach the list with `:pdb` and the nodes with `:nodes`. There, `rke2-w1` now shows `Ready,SchedulingDisabled`.

#ursache[
  `minAvailable: 2` with two replicas allows zero evictions. So the Eviction API answers with HTTP 429 (`Too Many Requests`), and `kubectl drain` keeps retrying endlessly. A PDB only protects against voluntary disruptions. It does not help against a node failure, and if it is too strict, it blocks maintenance.
]

=== Fix

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/fix-pdb.yaml
kubectl --context rke2 drain rke2-w1 --ignore-daemonsets --delete-emptydir-data
kubectl --context rke2 uncordon rke2-w1
```][The new PDB allows one disruption with `maxUnavailable: 1`. The drain goes through, and afterwards you release the node again with `uncordon`. In k9s, cordon, uncordon and drain are `c`, `u` and `r` in the node view.]

#pruefe[
  `kubectl --context rke2 get pdb -n dbg-13` shows `ALLOWED DISRUPTIONS 1`, and the drain ended with `node/rke2-w1 drained`. After `uncordon`, the node is back to `Ready` without `SchedulingDisabled`.
]

#falle[
  An aborted drain leaves the node cordoned. New pods then never land on it, and no error shows up anywhere. After every drain, even a failed one, take a look at `kubectl get nodes`.
]

#distro(
  [You drain nodes yourself before every maintenance, for example before an RKE2 upgrade. That is exactly where the PDB kicks in.],
  [`talosctl reboot`, `shutdown` and `upgrade` cordon and drain the node themselves, also through the Eviction API. So a PDB that is too strict delays these commands as well. Check the PDBs before a Talos upgrade.],
)

== Clean Up

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-13
kubectl --context talos delete ns dbg-13
```][Deletes all objects of this chapter. First check that both workers are `Ready` and none is still cordoned.]

#aufgabe[
  A colleague reports: "Since yesterday, no new pod starts on `talos-w1`, but the node is `Ready`." Reproduce this with `kubectl --context talos cordon talos-w1`, then create the Deployment `web` with four replicas. Find the cause using only `kubectl get nodes`, `describe node` and the pods' events. Which line in `describe node` gives it away, and which taint goes with it?

  Hint: look for `Unschedulable: true` and the taint `node.kubernetes.io/unschedulable:NoSchedule`. With `uncordon`, the problem is gone.
]

#gelernt(
  [`Unknown` in the conditions means the kubelet is silent. `False` means the kubelet is running and reports a problem itself.],
  [On RKE2 you investigate the kubelet with `systemctl`, `journalctl` and `kubelet.log`. On Talos you use `talosctl services`, `service kubelet` and `logs kubelet`.],
  [After 50 seconds without a check-in, a node becomes `NotReady`. After another 300 seconds, its pods are marked for deletion and hang in `Terminating` until the kubelet is back.],
  [Evicted pods have phase `Failed` and reason `Evicted`. The message names the resource and the limit.],
  [A PDB with `minAvailable` equal to the replica count blocks every drain. `ALLOWED DISRUPTIONS` shows it at a glance.],
)
