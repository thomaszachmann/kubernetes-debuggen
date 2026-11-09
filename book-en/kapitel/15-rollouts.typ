#import "../lib.typ": *

#kapitel(
  [Rollouts, Autoscaling and Helm],
  ziel: [You recognize hanging rollouts and roll them back, get an HPA with `<unknown>` to measure, install the metrics-server on Talos for it, free a stuck Helm release, and read why Jobs give up and ConfigMap changes do not arrive.],
  zeit: [75 minutes],
  braucht: [Chapters 2, 3 and 6],
)

== What Breaks in This Chapter

The failures in this chapter do not happen on the first deployment, but with the second version, when scaling and when automating. What they have in common: nothing visibly crashes. The old version keeps running, the HPA does nothing, Helm refuses. If you do not check, you only notice days later.

#tabelle(
  (auto, 1fr, 1fr),
  ([Scenario], [Symptom], [Where the answer is]),
  [Rollout hangs], [`rollout status` ends with `exceeded its progress deadline`], [Condition `Progressing`, events of the new pod],
  [HPA does not measure], [`TARGETS` shows `cpu: <unknown>/50%`], [Events of the HPA, `kubectl top`],
  [Helm release hangs], [`another operation ... is in progress`], [`helm history`, status `pending-upgrade`],
  [Job gives up], [Job `Failed`, several pods `Error`], [Condition and event `BackoffLimitExceeded`],
  [ConfigMap has no effect], [Pod shows the old value], [How the ConfigMap is mounted],
)

All scenarios run in the namespace `dbg-15`. The manifests comply with `restricted`, so on Talos there are no warnings from Pod Security Admission.

== The Rollout Hangs

A Deployment replaces pods step by step. With `maxSurge: 1` and `maxUnavailable: 0`, it first starts a new pod and removes an old one only once the new one is ready. If it never becomes ready, the rollout stops. After `progressDeadlineSeconds`, the Deployment controller declares it failed, but it does not roll anything back.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/web-v1.yaml
kubectl --context rke2 rollout status deploy/web -n dbg-15
```][Version 1 with three replicas. `rollout status` ends with `deployment "web" successfully rolled out`.]

#datei("szenarien/15-rollouts/kaputt-rollout.yaml (excerpt)", ```yaml
  annotations:
    kubernetes.io/change-cause: "v2: httpd auf 8081"
spec:
  progressDeadlineSeconds: 60
# ...
          command: ["httpd", "-f", "-p", "8081", "-h", "/tmp"]
          readinessProbe:
            tcpSocket:
              port: 8080
```, erklaerung: [Version 2 listens on a new port ("httpd auf 8081" means "httpd on 8081"), but the readiness probe still checks the old one. The deadline is short at 60 seconds. The default is 600.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/kaputt-rollout.yaml
kubectl --context rke2 rollout status deploy/web -n dbg-15
```][Starts the rollout to version 2 and watches it.]

#symptom[
```text
Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been
updated...
error: deployment "web" exceeded its progress deadline
```
The application still answers: `kubectl get deploy -n dbg-15` shows `READY 3/3`, `UP-TO-DATE 1`. The three old pods keep running.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 describe deploy web -n dbg-15 \
  | sed -n '/^Conditions/,/^Events/p'
kubectl --context rke2 get rs,pods -n dbg-15 -l app=web
```][The conditions of the Deployment, then the ReplicaSets and pods. The new ReplicaSet has one pod that is `0/1` ready.]

```text
Conditions:
  Type           Status  Reason
  ----           ------  ------
  Available      True    MinimumReplicasAvailable
  Progressing    False   ProgressDeadlineExceeded
```

`Available True` together with `Progressing False` means: the application runs, but the new version does not arrive. The new pod gives the reason:

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-15 --types=Warning
```][Only warnings in the namespace.]

```text
LAST SEEN   TYPE      REASON      OBJECT                    MESSAGE
4s          Warning   Unhealthy   pod/web-6d5f8c9b7-tq4lz   Readiness probe ...
```

The full message is `Readiness probe failed: dial tcp 10.42.1.23:8080: connect: connection refused`. In k9s, `:deploy dbg-15` opens the Deployments, and `z` the ReplicaSets of the selected entry. `Enter` takes you on to the pods, and `d` to the events.

#ursache[
  The new pod listens on 8081, the readiness probe knocks on 8080 and gets `connection refused`. The pod never becomes ready, so the Deployment removes no old pod and starts no further new one. After 60 seconds without progress, the controller sets `Progressing=False` with `ProgressDeadlineExceeded`. That is only a message. The rollout stays stuck in this state.
]

=== Fix

#cmd("Mac")[```bash
kubectl --context rke2 rollout history deploy/web -n dbg-15
kubectl --context rke2 rollout undo deploy/web -n dbg-15
```][`history` lists the revisions with the `change-cause` annotation. `undo` goes back to the previous revision, and with `--to-revision=<n>` to a specific one.]

```text
REVISION  CHANGE-CAUSE
1         v1: httpd auf 8080
2         v2: httpd auf 8081
```

Then you roll out the corrected version, in which probe and port match:

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/fix-rollout.yaml
kubectl --context rke2 rollout status deploy/web -n dbg-15
```][Version 2 with `readinessProbe` on port 8081.]

#pruefe[
  `deployment "web" successfully rolled out`, and `kubectl --context rke2 get deploy web -n dbg-15` shows `3/3` with `UP-TO-DATE 3`. `rollout history` now shows the new `change-cause`.
]

#falle[
  With a broken rollout, `kubectl apply` reports `configured` and ends successfully. Pipelines that only run `apply` notice nothing. A `kubectl rollout status --timeout=...` afterwards returns a non-zero exit code when the deadline is exceeded and makes the pipeline fail.
]

== The HPA Does Not Measure

A HorizontalPodAutoscaler with the target `averageUtilization: 50` calculates like this: current CPU usage divided by the CPU request, averaged over all pods. For that, it needs two things: measurements from the Resource Metrics API (`metrics.k8s.io`, provided by the metrics-server) and a request in every container.

#datei("szenarien/15-rollouts/kaputt-hpa.yaml (excerpt)", ```yaml
      containers:
        - name: rechner
          image: busybox:1.37
          resources:
            limits:
              memory: 32Mi
---
kind: HorizontalPodAutoscaler
spec:
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```, erklaerung: [No CPU request in the container `rechner` ("calculator"). You cannot calculate 50 percent of nothing.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/kaputt-hpa.yaml
kubectl --context talos apply -f szenarien/15-rollouts/kaputt-hpa.yaml
```][The same manifest on both clusters.]

#symptom[
```text
$ kubectl --context rke2 get hpa -n dbg-15
NAME      REFERENCE            TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
rechner   Deployment/rechner   cpu: <unknown>/50%   1         4         1          2m
```
The same picture on both clusters. But the causes are different.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 describe hpa rechner -n dbg-15 | sed -n '/^Conditions/,$p'
kubectl --context talos describe hpa rechner -n dbg-15 | sed -n '/^Events/,$p'
```][Conditions and events of the HPA on both clusters.]

On RKE2, the condition says `ScalingActive False` with the reason `FailedGetResourceMetric`, and the event reads:

```text
failed to get cpu utilization: missing request for cpu in container rechner
of Pod rechner-7b9c6d8f5-l2kxn
```

On Talos it fails one step earlier:

```text
failed to get cpu utilization: unable to get metrics for resource cpu: unable
to fetch metrics from resource metrics API: the server could not find the
requested resource (get pods.metrics.k8s.io)
```

#cmd("Mac")[```bash
kubectl --context talos top pods -n dbg-15
kubectl --context talos get apiservice v1beta1.metrics.k8s.io
```][On Talos, `top` reports `error: Metrics API not available`, and the APIService does not exist (`NotFound`). On RKE2 both return values, because `rke2-metrics-server` runs there.]

In k9s, `:hpa dbg-15` shows the HPAs, and `d` the describe view with the events. If the Metrics API is missing, the CPU and memory columns in the k9s pod view also stay empty.

#ursache[
  On RKE2 the CPU request is missing: the HPA gets measurements but cannot convert them into percent. On Talos the source of measurements is missing as well, because Talos does not ship a metrics-server. In both cases the HPA sets `ScalingActive=False` and does not change the replica count, neither up nor down.
]

=== Fix on Talos: Install the metrics-server

The metrics-server fetches its values over HTTPS from the kubelet of every node. By default, the Talos kubelet signs its serving certificate itself, and the metrics-server would reject it. So the Talos documentation describes three steps: the kubelet requests its certificate from the cluster CA, an approver approves these requests, and then the metrics-server comes in.

#datei("labor/talos/patch-kubelet-serving-certs.yaml (excerpt)", ```yaml
apiVersion: v1alpha1
kind: KubeletConfig
extraArgs:
  rotate-server-certificates: "true"
```, erklaerung: [The kubelet then submits a CertificateSigningRequest with the signer `kubernetes.io/kubelet-serving`.])

#cmd("Mac")[```bash
talosctl -n 172.16.0.170,172.16.0.171 patch mc \
  --patch @labor/talos/patch-kubelet-serving-certs.yaml
kubectl --context talos apply -f https://raw.githubusercontent.com/\
alex1989hu/kubelet-serving-cert-approver/v0.12.1/deploy/standalone-install.yaml
kubectl --context talos get csr
```][The patch on both nodes, then the approver at the pinned version 0.12.1. After a short while, the CSRs with the signer `kubernetes.io/kubelet-serving` show `Approved,Issued`.]

#falle[
  As long as the serving CSRs are `Pending`, the kubelet has no certificate. Then `kubectl logs` and `kubectl exec` on this node also fail with a TLS error. So install the approver right after the patch. Without the patch, on the other hand, the metrics-server reports something like `x509: cannot validate certificate for 172.16.0.171 because it doesn't contain any IP SANs`. The shortcut `--kubelet-insecure-tls` turns off the check. The Talos documentation deliberately takes the secure route.
]

#datei("werkzeuge/metrics-server-values-talos.yaml (excerpt)", ```yaml
replicas: 1
args: []
resources:
  requests:
    cpu: 50m
    memory: 64Mi
```, erklaerung: [No `--kubelet-insecure-tls`. The chart's default arguments query the kubelet through the `InternalIP` and the port from the node status.])

#cmd("Mac")[```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm --kube-context talos upgrade --install metrics-server \
  metrics-server/metrics-server --version 3.14.0 \
  -n kube-system -f werkzeuge/metrics-server-values-talos.yaml --wait
kubectl --context talos top nodes
```][Installs metrics-server 0.9.0 into `kube-system`. After about a minute, `top nodes` returns CPU and memory for both nodes.]

Now the Talos HPA shows the same message as RKE2: `missing request for cpu`. The fix sets the request for both:

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/fix-hpa.yaml
kubectl --context talos apply -f szenarien/15-rollouts/fix-hpa.yaml
```][The container now requests `cpu: 50m`.]

#pruefe[
  After one to two minutes, `kubectl get hpa -n dbg-15` shows `cpu: 0%/50%` or a small percentage on both clusters. `describe hpa` reports `ScalingActive True`.
]

#distro(
  [The metrics-server ships as `rke2-metrics-server` and is managed by the RKE2 Helm controller. You customize it with a `HelmChartConfig` in `/var/lib/rancher/rke2/server/manifests/`.],
  [No metrics-server, no Metrics API. You install it yourself, following the pattern from the Talos documentation with serving certificates from the cluster CA. That also means you have to update it yourself.],
)

== The Helm Release Hangs

Helm stores every revision of a release as a Secret in the namespace. Before an upgrade, it creates the new revision with the status `pending-upgrade`, and at the end it sets `deployed` or `failed`. If Helm is killed hard in between, `pending-upgrade` stays behind. That status is also the lock against parallel upgrades. A typical trigger in practice: a CI runner aborts a job for exceeding its time limit while `helm upgrade --wait` is still waiting.

#datei("szenarien/15-rollouts/haenger.sh (excerpt)", ```bash
helm --kube-context "$CTX" upgrade demo "$CHART" \
  -n dbg-15 --set readinessPort=9999 --wait --timeout 5m &
HELM_PID=$!
sleep 15
kill -9 "$HELM_PID"
```, erklaerung: [The script `haenger.sh` ("hanger"): revision 2 never becomes ready, and `helm` waits. After 15 seconds comes `SIGKILL`. Helm would still react to `Ctrl-C` or `SIGTERM` and mark the release as `failed`, but not to `SIGKILL`.])

#cmd("Mac")[```bash
szenarien/15-rollouts/haenger.sh rke2
helm --kube-context rke2 upgrade demo \
  szenarien/15-rollouts/demo-chart -n dbg-15
```][The script installs revision 1 from the mini chart `demo-chart` and aborts the upgrade to revision 2. Then you try to carry on as usual.]

#symptom[
```text
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```
Yet no other operation is running at all. Every further attempt ends the same way.
]

=== Investigate

#cmd("Mac")[```bash
helm --kube-context rke2 history demo -n dbg-15
kubectl --context rke2 get secrets -n dbg-15 -l owner=helm --show-labels
```][The revisions of the release, then the Secrets in which Helm stores them. The `status` label of each Secret matches the `STATUS` column.]

```text
REVISION  UPDATED                   STATUS           CHART       ... DESCRIPTION
1         Mon Nov  9 22:41:03 2026  deployed         demo-0.1.0  ... Install complete
2         Mon Nov  9 22:41:20 2026  pending-upgrade  demo-0.1.0  ... Preparing upgrade
```

In k9s, `:helm` opens the releases, and `r` shows the history of the selected release. `helm list -n dbg-15` also shows the release, because Helm 4 lists all states by default. With `--pending` you filter specifically.

#ursache[
  The latest revision is `pending-upgrade`. Before every upgrade, Helm checks whether the most recent revision is in a `pending` state, and if so aborts with `another operation ... is in progress`. The process that was supposed to finish the revision was terminated with `SIGKILL` and could not clean anything up.
]

=== Fix

#cmd("Mac")[```bash
helm --kube-context rke2 rollback demo 1 -n dbg-15
helm --kube-context rke2 upgrade demo szenarien/15-rollouts/demo-chart \
  -n dbg-15 --wait
```][The rollback does not check the lock and creates revision 3 as a copy of revision 1. After that, a normal upgrade works again. In the k9s history, you roll back with `r` on the revision you want.]

#pruefe[
  `helm history demo -n dbg-15` ends with a revision in status `deployed`. Revision 3 has the description `Rollback to 1`.
]

If the rollback does not help, for example because the very first installation hangs (`pending-install`), you are left with deleting the Secret of the hanging revision: `kubectl delete secret sh.helm.release.v1.demo.v2 -n dbg-15`. After that, the previous revision applies again. Only do this if you are sure that no Helm process is really running anymore.

#distro(
  [RKE2 installs its bundled charts (`rke2-traefik`, `rke2-coredns` ...) through the built-in Helm controller, visible as the Jobs `helm-install-rke2-...` in `kube-system`. You do not change these releases with `helm upgrade`, but with `HelmChartConfig`.],
  [Talos has no Helm controller. Everything you install with Helm, including the metrics-server and Traefik, you manage yourself with the Helm CLI.],
)

== The Job Gives Up

On failure, a Job starts new pods until `backoffLimit` is reached. The waiting time between attempts grows: 10 seconds, 20, 40 and so on. `activeDeadlineSeconds` also limits the total runtime.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/kaputt-job.yaml
```][The Job `import` expects `/daten/import.csv`, and the file does not exist. `backoffLimit: 2` allows two retries.]

#symptom[
```text
$ kubectl --context rke2 get jobs,pods -n dbg-15 -l app=import
NAME               STATUS   COMPLETIONS   DURATION   AGE
job.batch/import   Failed   0/1           52s        52s

NAME               READY   STATUS   RESTARTS   AGE
pod/import-7xq9d   0/1     Error    0          52s
pod/import-bk2mw   0/1     Error    0          41s
pod/import-zr4pt   0/1     Error    0          20s
```
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 describe job import -n dbg-15 | sed -n '/^Events/,$p'
kubectl --context rke2 logs -n dbg-15 job/import
```][The events of the Job, then the log of one of its pods. `logs job/...` picks a pod by itself.]

```text
  Warning  BackoffLimitExceeded  2s  job-controller  Job has reached the specified
                                                    backoff limit
FEHLER: /daten/import.csv fehlt
```

The last line means "ERROR: /daten/import.csv is missing". In k9s, `:jobs dbg-15` shows the Jobs. `Enter` leads to the pods, `l` to the logs and `p` to the logs of the previous container, if one was restarted.

#ursache[
  Every attempt ends with exit code 1. After three pods (one attempt plus two retries), the Job controller sets the condition `Failed` with the reason `BackoffLimitExceeded` and starts nothing more. If `activeDeadlineSeconds` had expired instead, it would say `DeadlineExceeded` with `Job was active longer than specified deadline`.
]

=== Fix

The pod template of a Job is immutable. An `apply` with a changed command fails with `field is immutable`. You delete the Job and create it again.

#cmd("Mac")[```bash
kubectl --context rke2 delete job import -n dbg-15
kubectl --context rke2 apply -f szenarien/15-rollouts/fix-job.yaml
kubectl --context rke2 wait --for=condition=Complete job/import \
  -n dbg-15 --timeout=60s
```][The corrected Job creates its input file itself. `wait` returns as soon as the Job is done.]

#pruefe[
  `job.batch/import condition met`, and `kubectl get jobs -n dbg-15` shows `Complete` and `1/1`.
]

#falle[
  `ttlSecondsAfterFinished: 3600` deletes the Job one hour after it ends, together with its pods and logs. For CronJobs, `successfulJobsHistoryLimit` and `failedJobsHistoryLimit` clean up as well. Investigate failed Jobs promptly. To test a CronJob on purpose, use `kubectl create job --from=cronjob/<name> test-1`.
]

== The ConfigMap Change Does Not Arrive

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/kaputt-configmap.yaml
kubectl --context rke2 patch configmap begruessung -n dbg-15 \
  --type=merge -p '{"data":{"GRUSS":"Hallo v2"}}'
```][The Deployment `gruss` ("greeting") reads `GRUSS` via `envFrom` from the ConfigMap `begruessung` ("welcome") and prints the value every ten seconds. Then you change the ConfigMap.]

#symptom[
  `kubectl --context rke2 logs -n dbg-15 deploy/gruss --tail 3` still shows only `Hallo v1` minutes later.
]

#ursache[
  The kubelet sets environment variables once, when the container starts. A later change to the ConfigMap never reaches the running process. The kubelet does update ConfigMaps mounted as volumes, with a delay (sync period plus cache, together often one to two minutes), except for `subPath` mounts. Whether the application then rereads the changed file is up to the application.
]

#cmd("Mac")[```bash
kubectl --context rke2 rollout restart deploy/gruss -n dbg-15
```][Restarts the pods, which read the ConfigMap at startup. In k9s, use `r` in the Deployment view.]

#pruefe[
  After the restart, `kubectl --context rke2 logs -n dbg-15 deploy/gruss --tail 1` shows the text `Hallo v2`.
]

In Helm charts, you solve this permanently with an annotation on the pod template that contains a checksum of the ConfigMap, for example `checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}`. If the ConfigMap changes, the template changes, and Kubernetes rolls out again.

== Clean Up

#cmd("Mac")[```bash
helm --kube-context rke2 uninstall demo -n dbg-15
kubectl --context rke2 delete ns dbg-15
kubectl --context talos delete ns dbg-15
```][Removes the Helm release and both namespaces. The metrics-server on Talos stays, because you need it in the remaining exercises and for k9s.]

#aufgabe[
  In a copy of `fix-rollout.yaml`, set the image to `busybox:1.37-gibtesnicht` ("does not exist"), `progressDeadlineSeconds` to `30` and the `change-cause` to `v3: neues Image` ("new image"). Apply it. Which condition does the Deployment have after a minute, what status does the new pod have, and which revision do you restore with `rollout undo --to-revision` so that `v2` with the corrected probe runs?

  Hint: again `Progressing False` with `ProgressDeadlineExceeded`, but this time the new pod is in `ImagePullBackOff` (Chapter 5). `rollout history` shows you which revision has the `change-cause` "Probe korrigiert" ("probe fixed").
]

#gelernt(
  [A hanging rollout shows `Progressing=False` with `ProgressDeadlineExceeded`. Kubernetes does not roll back by itself. You do that with `rollout undo`.],
  [`<unknown>` on an HPA has two common reasons: no Metrics API (Talos without metrics-server) or no request in the container. The HPA's events tell the two apart.],
  [The metrics-server on Talos needs kubelet serving certificates from the cluster CA: `rotate-server-certificates`, an approver for the CSRs, then the chart.],
  [`another operation (install/upgrade/rollback) is in progress` means the latest revision is `pending-*`. `helm history` shows it, and `helm rollback` releases the lock.],
  [Jobs give up after `backoffLimit` with `BackoffLimitExceeded`. Their template is immutable, so delete and recreate them.],
  [ConfigMaps used as environment variables only take effect after a restart: `rollout restart` or a checksum annotation.],
)
