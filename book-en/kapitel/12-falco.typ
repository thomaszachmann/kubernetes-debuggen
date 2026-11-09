#import "../lib.typ": *

#kapitel(
  [Falco: Alerts and Disruptions],
  ziel: [You get Falco running on both clusters, trace an alert back to the pod and container, silence a false positive in a targeted way and recognize when Falco stops delivering Kubernetes metadata.],
  zeit: [60 minutes],
  braucht: [Chapters 2, 3 and 10],
)

== What Breaks in This Chapter

Falco uses eBPF to watch the system calls on every node and compares them with rules. It blocks nothing, it only reports. That is why failures with Falco are rarely application outages. They are questions for operations: Why does Falco not start? Where does this alert come from? Why does it report the same Job every night? And why is there no pod name in the alert?

#tabelle(
  (auto, 1fr, 1fr),
  ([Scenario], [Symptom], [Where the answer is]),
  [Falco does not start on Talos], [DaemonSet `0/2`], [`FailedCreate` on the DaemonSet, PSA `baseline`],
  [Alert after `kubectl exec`], [`Terminal shell in container`], [`output_fields`, `hostname`, container ID],
  [False positive from a Job], [The same alert every ten minutes], [Rule, condition, `exceptions`],
  [No Kubernetes metadata], [`k8s_pod=<NA>` in every alert], [Socket list and mounts of the chart],
)

The workloads run in the namespace `dbg-12`, Falco itself in the namespace `falco`.

== Installing Falco

There is one values file each for RKE2 and Talos. They differ in only one line, and exactly this line is the topic of the last scenario.

#datei("werkzeuge/falco-values-rke2.yaml (excerpt)", ```yaml
tty: true
driver:
  kind: modern_ebpf
falco:
  json_output: true
  json_include_output_property: true
  append_output:
    - suggested_output: true
    - match:
        source: syscall
      extra_output: "k8s_ns=%k8s.ns.name k8s_pod=%k8s.pod.name"
collectors:
  containerEngine:
    engines:
      docker:
        enabled: false
      # ... podman, containerd likewise off
      cri:
        enabled: true
        sockets: ["/run/k3s/containerd/containerd.sock"]
```, erklaerung: [`modern_ebpf` needs no kernel module, which could not be loaded on Talos anyway. `suggested_output` appends the container ID and name to every message, and the second entry adds the namespace and pod. The `container` plugin gets the metadata through containerd's CRI interface. In `werkzeuge/falco-values-talos.yaml` that line says `/run/containerd/containerd.sock`.])

#cmd("Mac")[```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm --kube-context rke2 upgrade --install falco falcosecurity/falco \
  -n falco --create-namespace --version 9.2.2 \
  -f werkzeuge/falco-values-rke2.yaml --wait --timeout 5m
```][Chart 9.2.2 ships Falco 0.45.2. On RKE2 this runs through without incident.]

#cmd("Mac")[```bash
kubectl --context rke2 logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=20
```][With `-l`, `kubectl` reads from all Falco pods, one per node. With selectors, `kubectl` shows only ten lines per pod by default, hence `--tail`.]

```text
Mon Nov  9 14:02:11 2026: Falco version: 0.45.2 (x86_64)
Mon Nov  9 14:02:11 2026: Loading rules from:
Mon Nov  9 14:02:11 2026:    /etc/falco/falco_rules.yaml | schema validation: ok
Mon Nov  9 14:02:12 2026: Opening 'syscall' source with modern BPF probe.
```

What matters is `schema validation: ok` for every rules file and the line with `modern BPF probe`. If it is missing, the driver did not come up.

== Falco Does Not Start on Talos

The same installation on Talos, but without `--wait`, so that you can watch:

#cmd("Mac")[```bash
helm --kube-context talos upgrade --install falco falcosecurity/falco \
  -n falco --create-namespace --version 9.2.2 \
  -f werkzeuge/falco-values-talos.yaml
```][`--create-namespace` creates `falco` without labels. Helm reports `STATUS: deployed`, because without `--wait` it only checks whether the objects were created.]

#symptom[
```text
$ kubectl --context talos get ds -n falco
NAME    DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
falco   2         0         0       0            0           <none>          1m
```
]

=== Investigate

No pod, so look at the events on the DaemonSet. You know the pattern from Chapter 10:

#cmd("Mac")[```bash
kubectl --context talos events -n falco --for daemonset/falco
```][Or in k9s: `:ds falco⏎`, then `d` and all the way down.]

```text
LAST SEEN   TYPE      REASON         OBJECT            MESSAGE
5s          Warning   FailedCreate   DaemonSet/falco   Error creating: pods "falco-7xk2p" is forbidden:
violates PodSecurity "baseline:latest": hostPath volumes (volumes "container-engine-socket-0",
"boot-fs", "lib-modules", "usr-fs", "etc-fs", "sys-fs", "proc-fs"), privileged (container "falco"
must not set securityContext.privileged=true)
```

#ursache[
  Talos enforces `baseline` cluster-wide. Falco needs a privileged container to load the eBPF driver, and `hostPath` mounts for `/proc`, `/etc` and the containerd socket. `baseline` forbids both. The DaemonSet itself is accepted, because `enforce` applies only to pods.
]

=== Fix

#datei("szenarien/12-falco/namespace-falco.yaml", ```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
```)

#cmd("Mac")[```bash
kubectl --context talos apply -f szenarien/12-falco/namespace-falco.yaml
kubectl --context talos rollout status ds/falco -n falco --timeout=5m
```][`kubectl apply` warns that the namespace created by Helm is missing the annotation `kubectl.kubernetes.io/last-applied-configuration`, and adds it. That is harmless. For a fresh installation, you create the namespace before running Helm.]

#pruefe[
  `kubectl --context talos get ds -n falco` shows `2 2 2`, and the log contains `Opening 'syscall' source with modern BPF probe.`
]

#distro(
  [RKE2 without the CIS profile enforces `privileged`, so Falco starts right away. With `profile: cis`, `restricted` applies, and you need the same label as on Talos.],
  [Instead of the namespace label, you can also add `falco` to `exemptions.namespaces` in the machine config under `cluster.apiServer.admissionControl`. The label is more visible and does not need a patch of the nodes. `driver.kind: kmod` does not work on Talos, because you cannot load kernel modules there afterwards.],
)

== Alert After `kubectl exec`

A colleague opens a shell in a pod. Falco fires. Your job is to read from the alert where this happened.

#datei("szenarien/12-falco/kaputt-shell.yaml (excerpt)", ```yaml
      containers:
        - name: web
          image: busybox:1.37
          command: ["sh", "-c", "while true; do sleep 3600; done"]
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/12-falco/kaputt-shell.yaml
kubectl --context rke2 exec -it -n dbg-12 deploy/web -- sh -c 'id; exit'
```][`-it` gives the shell a terminal. That is exactly what the rule `Terminal shell in container` looks for.]

#symptom[
  A JSON line appears in the Falco logs. This excerpt shortens the text under `output`:
```text
{"hostname":"rke2-w1","output":"14:21:37.482915063: Notice A shell was spawned in a container
with an attached terminal | evt_type=execve user=root user_uid=0 user_loginuid=-1 process=sh
proc_exepath=/bin/sh ... command=sh -c id; exit terminal=34816 ... container_id=8f2c41d9a7b3
container_name=web k8s_ns=dbg-12 k8s_pod=web-5b9d8c7f6-tx4lp","priority":"Notice",
"rule":"Terminal shell in container","source":"syscall", ...}
```
]

=== Investigate

With many messages, `jq` helps. The fields under `output_fields` carry the names of the Falco fields:

#cmd("Mac")[```bash
kubectl --context rke2 logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=500 \
  | jq -cR 'fromjson? | select(.rule=="Terminal shell in container")
      | {hostname, priority,
         ns: .output_fields["k8s.ns.name"], pod: .output_fields["k8s.pod.name"],
         id: .output_fields["container.id"], cmd: .output_fields["proc.cmdline"],
         user: .output_fields["user.name"]}'
```][`fromjson?` skips the text lines from the startup. What remains is one compact line per alert.]

```text
{"hostname":"rke2-w1","priority":"Notice","ns":"dbg-12","pod":"web-5b9d8c7f6-tx4lp",
 "id":"8f2c41d9a7b3","cmd":"sh -c id; exit","user":"root"}
```

#tabelle(
  (auto, 1fr),
  ([Field], [What it tells you]),
  [`hostname`], [The node on which Falco saw the call. In the chart, this is the node name.],
  [`k8s.ns.name`, `k8s.pod.name`], [Namespace and pod. Both come through the container runtime, not from the Kubernetes API.],
  [`container.id`], [The first twelve characters of the container ID. Falco reads it directly from the cgroups, so it is there even without runtime access.],
  [`proc.cmdline`], [The command line that was run.],
  [`user.name`, `user.loginuid`], [The user *inside* the container. `-1` means: no login, typical for `kubectl exec`.],
)

The container ID is the reliable anchor if pod names are missing or the pod is long gone:

#cmd("Mac")[```bash
kubectl --context rke2 get pods -A \
  -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,ID:.status.containerStatuses[*].containerID \
  | grep 8f2c41d9a7b3
```][`containerID` has the form `containerd://8f2c41d9a7b3...`. The prefix from Falco is enough for `grep`.]

#cmd("rke2-w1")[```bash
crictl ps -a | grep 8f2c41d9a7b3
```][On the node from `hostname`, after the exports from Chapter 2 (`CRI_CONFIG_FILE`). For Talos: `talosctl -n 172.16.0.171 containers --namespace cri | grep 8f2c41d9a7b3`.]

#cmd("k9s")[```text
:ds falco⏎      Enter, select pod on the right node, l = logs
/Terminal⏎      filter logs by the rule
```][In the k9s log view, `/` filters the lines. For analysis across several pods, `kubectl` with `jq` is more convenient.]

#ursache[
  Not a failure in the strict sense: the rule `Terminal shell in container` reports every shell process with a terminal that enters a container as an entry point. `kubectl exec -it` does exactly that. Falco does not see *who* issued the command. For that you need the API server's audit log, matched by time, namespace and pod.
]

#pruefe[
  For every alert you can name the node, namespace, pod and container. A `kubectl exec` *without* `-it`, for example `kubectl exec -n dbg-12 deploy/web -- id`, does not trigger this rule.
]

== False Positive From a Legitimate Job

A cleanup Job deletes finished pods every ten minutes. For that it talks to the Kubernetes API with `kubectl`. The name `aufraeumer` means "cleaner".

#datei("szenarien/12-falco/kaputt-cronjob.yaml (excerpt)", ```yaml
kind: CronJob
metadata:
  name: aufraeumer
  namespace: dbg-12
spec:
  schedule: "*/10 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: aufraeumer
          containers:
            - name: kubectl
              image: registry.k8s.io/kubectl:v1.36.6
              args: ["delete", "pods", "-n", "dbg-12", "--field-selector=status.phase==Succeeded"]
```, erklaerung: [In the file, `args` is a list over several lines. Role and RoleBinding give the ServiceAccount exactly `get`, `list` and `delete` on pods.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/12-falco/kaputt-cronjob.yaml
kubectl --context rke2 create job -n dbg-12 --from=cronjob/aufraeumer aufraeumer-jetzt
```][The second command starts the Job right away (`jetzt` means "now") instead of waiting for the next full tenth minute.]

#symptom[
```text
14:40:02.118204551: Notice Unexpected connection to K8s API Server from container |
connection=10.42.1.23:51734->10.43.0.1:443 lport=51734 rport=443 fd_type=ipv4 fd_proto=tcp
evt_type=connect user=root ... process=kubectl ... command=kubectl delete pods -n dbg-12
--field-selector=status.phase==Succeeded ... container_name=kubectl k8s_ns=dbg-12
k8s_pod=aufraeumer-jetzt-q8w2n
```
From now on six times per hour. Anyone who sees this for a week stops reading Falco alerts.
]

=== Investigate

Which condition fired? The rule is in the default rules inside the pod:

#cmd("Mac")[```bash
kubectl --context rke2 exec -n falco ds/falco -c falco -- \
  grep -A 12 'rule: Contact K8S API Server From Container' /etc/falco/falco_rules.yaml
```][Shows the rule as it was loaded. The init container `falcoctl-artifact-install` installs the rules files.]

```text
- rule: Contact K8S API Server From Container
  desc: > ...
  condition: >
    evt.type=connect
    and (fd.typechar=4 or fd.typechar=6)
    and container
    and k8s_api_server
    and not k8s_containers
    and not user_known_contact_k8s_api_server_activities
```

`k8s_api_server` checks whether the target is `kubernetes.default.svc.cluster.local`. `k8s_containers` is a fixed list of known images, and our Job is not on it.

#ursache[
  The rule is loud on purpose: a container that talks to the API could be an attacker with a stolen token. But our Job does this legitimately and regularly. Without an exception it produces noise that hides real hits of the same rule.
]

=== Fix

Do not turn off the rule. Add a narrow exception instead: this namespace, this image, this process.

#datei("szenarien/12-falco/fix-ausnahme-values.yaml", ```yaml
customRules:
  dbg-ausnahmen.yaml: |-
    - rule: Contact K8S API Server From Container
      exceptions:
        - name: dbg12_aufraeumer
          fields: [k8s.ns.name, container.image.repository, proc.name]
          comps: [=, =, =]
          values:
            - [dbg-12, registry.k8s.io/kubectl, kubectl]
      override:
        exceptions: append
```, erklaerung: [`override: exceptions: append` appends the exception to the existing rule without touching its condition or output. Each line under `values` is a tuple that matches `fields` and `comps`. The chart puts `customRules` into `/etc/falco/rules.d`, which Falco loads after the default rules. The old `append: true` is deprecated.])

#cmd("Mac")[```bash
helm --kube-context rke2 upgrade falco falcosecurity/falco -n falco --version 9.2.2 \
  -f werkzeuge/falco-values-rke2.yaml -f szenarien/12-falco/fix-ausnahme-values.yaml --wait
```][The Falco pods restart with the additional rules file. Do not leave out the second file in future upgrades, or the exception is gone again.]

#pruefe[
  The startup log contains `/etc/falco/rules.d/dbg-ausnahmen.yaml | schema validation: ok`. A new run with `kubectl --context rke2 create job -n dbg-12 --from=cronjob/aufraeumer aufraeumer-2` stays quiet. The rule itself is still alive: `kubectl --context rke2 run apitest -n dbg-12 --image=busybox:1.37 --restart=Never -- wget -T 2 -q -O /dev/null https://kubernetes.default.svc` still triggers it.
]

#falle[
  If a new exception is missing `fields` or `values`, Falco refuses to load the rules. The pod then does not start, and the log says `Rule exception must have fields property with a list of fields`. Check the startup log after every rule change. For simple cases there is a second way: fill the empty macro `user_known_contact_k8s_api_server_activities` with `override: condition: replace`.
]

== No Kubernetes Metadata

Someone “unifies” the Falco values for both clusters and sets the socket to the default path. On Talos it is correct, on RKE2 it is not.

#datei("szenarien/12-falco/kaputt-values-sockets.yaml", ```yaml
collectors:
  containerEngine:
    engines:
      cri:
        enabled: true
        sockets: ["/run/containerd/containerd.sock"]
```)

#cmd("Mac")[```bash
helm --kube-context rke2 upgrade falco falcosecurity/falco -n falco --version 9.2.2 \
  -f werkzeuge/falco-values-rke2.yaml -f szenarien/12-falco/kaputt-values-sockets.yaml --wait
kubectl --context rke2 exec -it -n dbg-12 deploy/web -- sh -c 'exit'
```][The values are merged in the order of the `-f` flags, and the last file wins. Then you trigger the shell alert again.]

#symptom[
```text
14:58:10.903311277: Notice A shell was spawned in a container with an attached terminal | ...
container_id=3c7e90b1f2a4 container_name=<NA> k8s_ns=<NA> k8s_pod=<NA>
```
Falco runs, all pods are `Running`, the alerts arrive. Only the pod is missing, and an exception with `k8s.ns.name` like the one in the last scenario no longer applies.
]

=== Investigate

`container_id` is filled, because it comes from the kernel. Everything that comes from the runtime is missing. So you ask: which socket does Falco query, and does it exist on the node?

#cmd("Mac")[```bash
kubectl --context rke2 get ds falco -n falco -o yaml \
  | yq '.spec.template.spec.volumes[] | select(.hostPath) | .hostPath.path'
```][The chart mounts exactly the directories of the configured sockets under `/host` in the container.]

```text
/run/containerd
/boot
/lib/modules
/usr
/etc
/sys/kernel
/proc
```

#cmd("rke2-w1")[```bash
grep runtime-endpoint /var/lib/rancher/rke2/agent/etc/crictl.yaml
ls -l /run/containerd/ /run/k3s/containerd/containerd.sock
```][The crictl configuration of RKE2 names the real socket. `/run/containerd/` is empty or missing.]

```text
runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
/run/containerd/:
total 0
srw-rw---- 1 root root 0 Nov  9 08:11 /run/k3s/containerd/containerd.sock
```

#ursache[
  RKE2 ships its own containerd, whose socket is under `/run/k3s/containerd/`. The `container` plugin queries only the configured path and reaches no runtime there. Without an answer from the runtime, all container and pod fields stay empty, and Falco shows `<NA>`. The kernel still delivers system calls and the container ID from the cgroups, which is why everything looks healthy.
]

=== Fix

#cmd("Mac")[```bash
helm --kube-context rke2 upgrade falco falcosecurity/falco -n falco --version 9.2.2 \
  -f werkzeuge/falco-values-rke2.yaml -f szenarien/12-falco/fix-ausnahme-values.yaml --wait
```][Without the broken file, `/run/k3s/containerd/containerd.sock` from the RKE2 values file applies again. The exception stays in place.]

#pruefe[
  A new `kubectl exec -it` again produces `container_name=web k8s_ns=dbg-12 k8s_pod=web-...`. The DaemonSet lists `/run/k3s/containerd` among the `hostPath` volumes.
]

#distro(
  [Socket of the kubelet runtime: `/run/k3s/containerd/containerd.sock`. You can look it up in `/var/lib/rancher/rke2/agent/etc/crictl.yaml`. The chart's default values already contain this path. The failure only happens when someone overrides the list.],
  [Talos runs two containerd instances: one for system services under `/system/run/containerd/` and one for the kubelet pods under `/run/containerd/containerd.sock`. Falco needs the second one. You can check it with `talosctl -n 172.16.0.171 containers --namespace cri`.],
)

#warum[
  In the lab, Falco writes to standard output. In production you send alerts to a central system, for example with Falcosidekick, which is included in the chart as an option. For troubleshooting this changes nothing: the fields are the same, and missing metadata stands out there just as much, only later.
]

#aufgabe[
  On Talos, open a shell in the pod `web` (scenario from this chapter, `--context talos`). Read the node, pod and container ID from the alert, and find the container with `talosctl ... containers --namespace cri`. Which of the two Talos nodes was it?

  Hint: `hostname` in the JSON is the node name, but `talosctl -n` needs the IP. `kubectl --context talos get nodes -o wide` shows the mapping.
]

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-12
kubectl --context talos delete ns dbg-12
```][Cleans up the workloads. Falco can stay installed. You would remove it with `helm --kube-context rke2 uninstall falco -n falco`.]

#gelernt(
  [Falco needs `privileged` and `hostPath`. On Talos (default `baseline`), the namespace `falco` therefore has to be set to `privileged`, or the DaemonSet stays at `0`.],
  [`hostname`, `k8s.ns.name`, `k8s.pod.name` and `container.id` trace every alert back to the node, pod and container. Only the audit log knows the user who triggered it.],
  [You silence false positives with a narrow exception: `exceptions` with `override: exceptions: append` in `customRules`.],
  [`<NA>` for pod and namespace means: Falco cannot reach the container runtime. On RKE2 the socket is under `/run/k3s/containerd/`.],
)
