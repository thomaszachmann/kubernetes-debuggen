#import "../lib.typ": *

#kapitel(
  [Appendix],
  ziel: [Error messages, commands and keys to look up quickly when things are on fire.],
)

#show table: set par(justify: false)

== Cheat Sheet: From the Message to the First Command

The left column is what you see. The middle one names the most common cause, not the only one. The right one tells you where to look first.

#tabelle(
  (1.15fr, 1fr, 0.8fr, auto),
  ([Message or status], [Most common cause], [First look], [Ch.]),
  [`Pending`, `Insufficient cpu`], [Requests larger than the free capacity on every node], [`describe pod`, events], [4],
  [`didn't match Pod's node affinity/selector`], [Label missing on the node or typo in the selector], [`get nodes --show-labels`], [4],
  [`had untolerated taint(s)`], [Taint without a matching toleration], [`describe node`, `Taints:`], [4],
  [`unbound immediate PersistentVolumeClaims`], [PVC without a StorageClass or with a wrong name], [`describe pvc`], [4, 9],
  [Deployment without pods, `FailedCreate`], [ResourceQuota, LimitRange or Pod Security rejects], [Events on the ReplicaSet], [4, 10],
  [`ImagePullBackOff`, `not found`], [Typo in the tag or repository], [`describe pod`, events], [5],
  [`ImagePullBackOff`, `pull access denied`], [Private repository without `imagePullSecrets`], [Secret in the same namespace], [5],
  [`toomanyrequests`], [Docker Hub rate limit], [Registry mirror on the node], [5],
  [`CreateContainerConfigError`], [Secret, ConfigMap or key missing], [`describe pod`], [5],
  [`exec format error`], [Script without a shebang or wrong architecture], [Check image and entrypoint], [5],
  [`CrashLoopBackOff`, exit 127], [Command not found in the container], [`logs --previous`], [6],
  [`CrashLoopBackOff`, exit 1], [Application exits with an error], [`logs --previous`], [6],
  [`OOMKilled`, exit 137], [Memory limit too small or memory leak], [`lastState`, limits], [6],
  [Restarts, `failed liveness probe`], [Probe too strict, startup takes longer], [Events, `startupProbe`], [6],
  [`Running`, but `0/1` ready], [Readiness probe fails], [Events, EndpointSlice], [6, 7],
  [`Read-only file system`], [`readOnlyRootFilesystem` without a writable volume], [`securityContext`], [6],
  [Service without endpoints], [Selector does not match the pod labels], [`get endpointslices`], [7],
  [`connection refused`], [Wrong `targetPort` or the process listens elsewhere], [`kubectl debug`, `ss -ltn`], [7],
  [`NXDOMAIN`, DNS timeout], [Wrong name or namespace, or egress on port 53 blocked], [`nslookup` from a pod], [7],
  [NetworkPolicy has no effect], [CNI does not enforce policies (Flannel on Talos)], [Check the CNI], [7],
  [HTTP 404 from the ingress], [Wrong `ingressClassName`, host or Service port], [Controller logs], [8],
  [HTTP 503 from the ingress], [No ready pod behind the Service], [Endpoints, readiness], [8],
  [`TRAEFIK DEFAULT CERT`], [TLS Secret malformed or not found], [`describe secret`, Traefik log], [8],
  [`Permission denied` on a volume], [The process UID may not write], [`ls -ln` in the pod], [9],
  [`Multi-Attach`, pod on another node stuck], [RWO volume, replicas on several nodes], [`get pods -o wide`], [9],
  [`Forbidden`, `cannot list resource`], [RBAC: binding missing, wrong namespace or Role instead of ClusterRole], [`auth can-i --as`], [10],
  [`violates PodSecurity`], [Pod Security Admission of the namespace], [Namespace labels], [10],
  [`admission webhook ... denied the request`], [A Kyverno policy applies], [Policy name from the message], [11],
  [`failed calling webhook`], [Webhook backend unreachable, `failurePolicy: Fail`], [`get validatingwebhookconfigurations`], [11, 14],
  [Falco alert], [A process does something a rule considers suspicious], [Alert fields, pod, container ID], [12],
  [Node `NotReady`], [Kubelet not running or cannot reach the API server], [Kubelet log on the node], [13],
  [Pod `Terminating`, `Unknown`], [Node down, eviction after 300 s], [`get nodes`, tolerations], [13],
  [`Evicted`], [Node or pod exceeded a limit for memory or disk], [`status.message`], [13],
  [Drain hangs], [PodDisruptionBudget allows no disruption], [`get pdb`], [13],
  [`x509: certificate has expired`], [Client certificate in the kubeconfig expired], [Decode the certificate], [14],
  [Namespace stays `Terminating`], [Unreachable APIService or finalizer], [`get apiservice`, conditions], [14],
  [`ProgressDeadlineExceeded`], [New pods never become ready], [`rollout status`, new pods], [15],
  [HPA shows `<unknown>`], [metrics-server missing or pods without CPU requests], [`top pods`, `describe hpa`], [15],
  [`another operation ... is in progress`], [Interrupted Helm release in a `pending-*` state], [`helm history`], [15],
  [`BackoffLimitExceeded`], [Job pods fail more often than allowed], [Logs of the job pods], [15],
)

== RKE2 and Talos: Same Question, Two Commands

On RKE2, the commands run on the node, after `sudo -i` and the exports from chapter 2. On Talos, they run on the Mac, with `-n` and the node's IP.

#tabelle(
  (0.8fr, 1fr, 1fr),
  ([Question], [RKE2 (on the node)], [Talos (on the Mac)]),
  [Is the node service running?], [`systemctl status rke2-server` or `rke2-agent`], [`talosctl -n <IP> services`],
  [Log of the node service], [`journalctl -u rke2-server`], [`talosctl -n <IP> logs kubelet`],
  [Kubelet log], [`/var/lib/rancher/rke2/agent/logs/kubelet.log`], [`talosctl -n <IP> logs kubelet`],
  [Kernel messages, OOM killer], [`journalctl -k`], [`talosctl -n <IP> dmesg`],
  [Containers on the node], [`crictl ps -a`], [`talosctl -n <IP> containers --namespace cri`],
  [Log of a container], [`crictl logs <id>`], [`talosctl -n <IP> logs --namespace cri <id>`],
  [Check or pull an image], [`crictl images`, `crictl pull`], [`talosctl -n <IP> image list`, `image pull`],
  [Live overview], [`top`, `df -h`], [`talosctl -n <IP> dashboard`],
  [Configuration], [`/etc/rancher/rke2/config.yaml`], [`talosctl -n <IP> get machineconfig -o yaml`],
  [Change the configuration], [Edit the file, restart the service], [`talosctl -n <IP> patch mc --patch @file`],
  [Registry mirror], [`/etc/rancher/rke2/registries.yaml`], [`RegistryMirrorConfig` document],
  [etcd health], [`etcdctl` in the etcd pod], [`talosctl -n <IP> etcd status`, `etcd members`],
  [etcd snapshot], [`rke2 etcd-snapshot save`], [`talosctl -n <IP> etcd snapshot <file>`],
  [Check certificates], [`rke2 certificate check`], [`talosctl config info`, `get kubernetesdynamiccerts`],
  [Collect everything], [Logs and `crictl` output by hand], [`talosctl -n <IP> support --no-encryption`],
)

== k9s: The Most Important Keys

#tabelle(
  (auto, 1fr),
  ([Key], [Effect]),
  [`:pods`, `:deploy`, `:events`], [Switch the resource view, with a namespace after it: `:pods dbg-04`],
  [`:ctx`], [Switch context],
  [`0`], [Show all namespaces],
  [`/text`, `/!text`, `/-l app=web`], [Filter, inverse filter, filter by label],
  [`d`, `y`, `e`], [Describe, YAML, edit],
  [`l`, `p`], [Logs, logs of the previous run],
  [`s`], [Shell in the container],
  [`Enter`], [Open a pod's container view],
  [`o`, `Shift-j`], [Jump to the node, jump to the owner],
  [`Shift-f`], [Set up a port forward],
  [`Ctrl-w`], [Show more columns],
  [`Ctrl-d`, `Ctrl-k`], [Delete with confirmation, delete immediately],
  [`:xray deploy`, `:pulses`], [Dependency tree, cluster overview],
  [`Shift-D`], [Plugin from chapter 3: netshoot debug container on the pod],
  [`Shift-E`], [Plugin from chapter 3: events of the selected resource],
  [`Esc`, `?`], [Back, help with all keys of the current view],
)

Start k9s with `--readonly` when you only want to look and not change anything.

== Versions

All details apply to the state of this book, November 9, 2026.

#tabelle(
  (1fr, auto),
  ([Component], [Version]),
  [RKE2], [`v1.36.6+rke2r1`],
  [Talos Linux and `talosctl`], [`v1.14.5`],
  [Kubernetes on both clusters], [`1.36.6`],
  [k9s], [`v0.51.0`],
  [Kyverno (chart `kyverno/kyverno`)], [`v1.19.2` (chart `3.9.2`)],
  [Falco (chart `falcosecurity/falco`)], [`0.45.2` (chart `9.2.2`)],
  [Traefik for Talos (chart `traefik/traefik`)], [`v3.7.17` (chart `42.3.1`)],
  [metrics-server for Talos (chart `metrics-server/metrics-server`)], [chart `3.14.0`],
  [local-path-provisioner], [`v0.0.37`],
  [netshoot], [`nicolaka/netshoot:v0.15`],
)

== The Repo at a Glance

The repo is shared with the German edition, so folder and file names are German: `labor` is the lab, `werkzeuge` the tools, `szenarien` the scenarios, `kaputt` means broken.

```
kubernetes-debuggen/
├── buch/            source of the German edition (Typst), book-en/ this one
├── labor/
│   ├── rke2/        config-cp.yaml, config-w1.yaml, registries-mirror.yaml
│   └── talos/       patch-cp.yaml, patch-w1.yaml, patch-local-path.yaml,
│                    patch-registry.yaml and the patches from ch. 13 and 14
├── k9s/             plugins.yaml                                  (ch. 2, 3)
├── werkzeuge/       Helm values for Kyverno, Falco, Traefik, metrics-server,
│                    local-path for Talos
├── policies/        Kyverno policies with tests under tests/      (ch. 11)
└── szenarien/       one folder per chapter, with kaputt-*.yaml and fix-*.yaml
```

Every `kaputt-*.yaml` file creates its own namespace `dbg-<chapter>`. That makes cleanup always the same: `kubectl --context <cluster> delete namespace dbg-<chapter>`.

== Official Documentation

- Kubernetes, debugging: #link("https://kubernetes.io/docs/tasks/debug/")[kubernetes.io/docs/tasks/debug]
- RKE2: #link("https://docs.rke2.io")[docs.rke2.io]
- Talos Linux 1.14: #link("https://docs.siderolabs.com/talos/v1.14")[docs.siderolabs.com/talos/v1.14]
- k9s: #link("https://k9scli.io")[k9scli.io]
- Kyverno: #link("https://kyverno.io/docs")[kyverno.io/docs]
- Falco: #link("https://falco.org/docs")[falco.org/docs]
- Traefik: #link("https://doc.traefik.io/traefik")[doc.traefik.io/traefik]

#gelernt(
  [Troubleshooting is a method, not a talent: symptom, layer, cause, fix, verification.],
  [Most answers are in the events, in `describe` and in the logs of the previous run.],
  [On RKE2 you SSH into the node, on Talos you ask the API with `talosctl`.],
  [Policies, admission and runtime security are failure sources of their own. Read the message to the end, it almost always names the culprit.],
)
