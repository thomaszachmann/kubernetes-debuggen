#import "../lib.typ": *

#kapitel(
  [Crashes and Restarts],
  ziel: [You read exit codes and the log of the previous container, recognize OOMKilled and probe failures, and investigate containers without a shell using `kubectl debug`.],
  zeit: [75 minutes],
  braucht: [Chapters 1, 3 and 5],
)

== What Breaks in This Chapter

Now the container runs, but not for long or not correctly. The two most important tools for this are the `Last State` block in `kubectl describe pod` and the log of the *previous* container. After a restart, `kubectl logs` shows only the new container. The error message of the old one is in `kubectl logs --previous`.

#tabelle(
  (auto, auto, 1fr),
  ([Scenario], [Symptom], [First clue]),
  [Wrong command, app error], [`CrashLoopBackOff`], [Exit code 127 or 1, `logs --previous`],
  [Memory limit], [`OOMKilled`, then `CrashLoopBackOff`], [Exit code 137, reason `OOMKilled`],
  [Liveness too strict, readiness wrong], [Restarts, or `0/1` without restarts], [Events `Unhealthy`],
  [`readOnlyRootFilesystem`], [`CrashLoopBackOff`], [`Read-only file system` in the log],
  [Distroless image], [`exec` fails, no shell], [`kubectl debug`],
)

All scenarios run in the namespace `dbg-06`. You need the exit codes from Chapter 1 all the time here: 1 is an application error, 126 and 127 mean "not executable" and "not found" in a shell, and 137 is 128 + 9, that is, `SIGKILL`.

== CrashLoopBackOff: Command and Application

Like `ImagePullBackOff`, `CrashLoopBackOff` is a waiting state. The container has exited, the kubelet restarts it and doubles the waiting time after every crash, from 10 seconds up to at most 5 minutes. The cause is not in the status, but in the exit code and the log.

#datei("szenarien/06-crash/kaputt-crash.yaml (excerpt)", ```yaml
  name: tippfehler
# ...
          command: ["sh", "-c", "serv -p 8080 -h /www"]
---
  name: appfehler
# ...
          command:
            - sh
            - -c
            - |
              echo "Konfiguration wird geladen"
              if [ -z "$DATABASE_URL" ]; then
                echo "FEHLER: DATABASE_URL ist nicht gesetzt" >&2
                exit 1
              fi
              exec sleep infinity
```, erklaerung: [`tippfehler` ("typo") is supposed to start `httpd`, but it says `serv`. `appfehler` ("app error") aborts because an environment variable is missing, like many real applications do at startup. Its messages mean "Loading configuration" and "ERROR: DATABASE_URL is not set".])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/kaputt-crash.yaml
kubectl --context talos apply -f szenarien/06-crash/kaputt-crash.yaml
```][Creates the namespace and two Deployments.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-06
NAME                          READY   STATUS             RESTARTS      AGE
appfehler-5c8d7b6f4-n4w8k     0/1     CrashLoopBackOff   3 (25s ago)   71s
tippfehler-6b9f8c7d5-k2v7x    0/1     CrashLoopBackOff   3 (28s ago)   71s
```
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-06 -l app=tippfehler | grep -A 9 "State:"
```][The excerpt around `State` and `Last State` shows how the last container ended.]

```text
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    127
      Started:      Mon, 09 Nov 2026 10:12:41 +0100
      Finished:     Mon, 09 Nov 2026 10:12:41 +0100
    Ready:          False
    Restart Count:  3
```

Started and Finished in the same second, exit code 127: the shell did not find a command. The log confirms it:

#cmd("Mac")[```bash
kubectl --context rke2 logs -n dbg-06 deploy/tippfehler --previous
kubectl --context rke2 logs -n dbg-06 deploy/appfehler --previous
```][`--previous` reads the previous, crashed container. Without the option, depending on the timing, you catch a container that just started and has an empty log.]

```text
sh: serv: not found
Konfiguration wird geladen
FEHLER: DATABASE_URL ist nicht gesetzt
```

`appfehler` ends with exit code 1, and the application wrote the message itself. In k9s the path is shorter: `:pods dbg-06⏎`, select the pod, `p` opens the logs of the previous container (`l` those of the current one), and `d` shows `Last State`.

#ursache[
  `tippfehler`: the shell does not find `serv` and exits with 127. `appfehler`: the application checks its configuration and exits with 1. In both cases the container is done, and because the `restartPolicy` of a Deployment is always `Always`, the kubelet restarts it. If this repeats, it waits longer and longer: `CrashLoopBackOff`.
]

=== Fix

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/fix-crash.yaml
kubectl --context talos apply -f szenarien/06-crash/fix-crash.yaml
```][`tippfehler` now starts `httpd`, and `appfehler` gets `DATABASE_URL` as an environment variable.]

#pruefe[
  Both pods are `Running` with `RESTARTS 0`, because the Deployment created new pods.
]

#falle[
  If the wrong command is directly in `command` instead of after `sh -c`, that is `command: ["serv"]`, there is no shell that could report 127. Then the runtime cannot start the process at all. `Last State` shows `Reason: StartError` with exit code 128, and the message contains `exec: "serv": executable file not found in $PATH`. In this case, there is no log.
]

== OOMKilled

A memory limit is a hard boundary. If a container exceeds it, the kernel terminates it with `SIGKILL`. There is no warning, no log line from the application and no orderly shutdown.

#datei("szenarien/06-crash/kaputt-oom.yaml (excerpt)", ```yaml
        - name: app
          image: polinux/stress:1.0.4
          command: ["/usr/local/bin/stress"]
          args: ["--vm", "1", "--vm-bytes", "200M", "--vm-hang", "0"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 128Mi
```, erklaerung: [`stress` allocates 200 MB and holds it. The limit allows 128 MiB.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/kaputt-oom.yaml
kubectl --context talos apply -f szenarien/06-crash/kaputt-oom.yaml
```][Creates the Deployment `speicher` ("memory").]

#symptom[
  `kubectl --context rke2 get pods -n dbg-06 -l app=speicher` briefly shows `OOMKilled` in the `STATUS` column, then `CrashLoopBackOff`. If you only look now and then, you only see the latter.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 get pod -n dbg-06 -l app=speicher \
  -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated}' | jq .
```][Reads the last terminated state directly from the status. Without `jq`, you get the same information on one line.]

```text
{
  "containerID": "containerd://9f2c4e1b7a...",
  "exitCode": 137,
  "finishedAt": "2026-11-09T09:31:07Z",
  "reason": "OOMKilled",
  "startedAt": "2026-11-09T09:31:06Z"
}
```

`reason: OOMKilled` and exit code 137 are unambiguous. The log hardly helps here: `logs --previous` shows only `stress: info: [1] dispatching hogs: 0 cpu, 0 io, 1 vm, 0 hdd`, then nothing more. The node's kernel provides the proof:

#distro[
  On the pod's node (the `NODE` column in `get pods -o wide`), via SSH:
  ```bash
  sudo journalctl -k --since "10 min ago" \
    | grep -i "out of memory"
  ```
][
  Without SSH, from the Mac:
  ```bash
  talosctl -n 172.16.0.171 dmesg \
    | grep -i "out of memory"
  ```
]

Both return a line like `Memory cgroup out of memory: Killed process 23817 (stress) total-vm:208712kB, anon-rss:130816kB, ...`.

#ursache[
  The memory limit is enforced as a cgroup boundary in the kernel. If the container exceeds it, the kernel's OOM killer picks a process in this cgroup and terminates it with `SIGKILL` (signal 9, hence 128 + 9 = 137). The kubelet learns about it through the runtime and sets the reason `OOMKilled`. Requests do not help: they are only bookkeeping for the scheduler.
]

=== Fix

Either the application really needs more memory, and you raise the limit. Or it uses too much, and then it is an application bug, for example a leak or a cache that is too large. In the lab, it gets more:

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/fix-oom.yaml
kubectl --context talos apply -f szenarien/06-crash/fix-oom.yaml
```][Sets the memory request and limit to `256Mi`.]

#pruefe[
  The pod stays `Running`. On RKE2, `kubectl --context rke2 top pod -n dbg-06 -l app=speicher` shows about 200 MiB. On Talos the metrics-server is still missing (Chapter 15), so `kubectl top` only reports `error: Metrics API not available` there.
]

#falle[
  `OOMKilled` affects a container that exceeds its *own* limit. If the *node* runs short, the kubelet evicts whole pods. They then show `Failed` with the reason `Evicted` (Chapter 13).
]

== Probes: Too Strict and Aimed Wrong

Probes are the questions the kubelet asks a container regularly. The liveness probe asks "are you still alive?" and restarts the container after repeated no's. The readiness probe asks "can you accept requests?" and takes the pod out of the Service on a no. Setting either of them wrong produces two completely different symptoms.

#datei("szenarien/06-crash/kaputt-probes.yaml (excerpt)", ```yaml
  name: langsam
# ...
              echo "Lade Daten (dauert 40 Sekunden) ..."
              sleep 40
              # ... then httpd on port 8080
          livenessProbe:
            httpGet: {path: /healthz, port: 8080}
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
---
  name: nieready
# ... httpd on port 8080, serves only /healthz
          readinessProbe:
            httpGet: {path: /ready, port: 8080}
# ... plus a Service "nieready"
```, erklaerung: [`langsam` ("slow") needs 40 seconds until its first sign of life ("Lade Daten" means "Loading data, takes 40 seconds"), but the liveness probe gives it only about 20. `nieready` ("never ready") probes a path that does not exist.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/kaputt-probes.yaml
kubectl --context talos apply -f szenarien/06-crash/kaputt-probes.yaml
```][Two Deployments and a Service.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-06 -l 'app in (langsam,nieready)'
NAME                        READY   STATUS    RESTARTS      AGE
langsam-7d6c9b8f5-x4q2m     1/1     Running   3 (12s ago)   2m5s
nieready-5f7b8d9c6-j6t3p    0/1     Running   0             2m5s
```
`langsam` runs, but keeps restarting. `nieready` runs without restarts, but never becomes ready.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-06 | grep -E "Unhealthy|Killing"
```][Probe failures have the reason `Unhealthy` (type `Warning`). The restart is reported by an event of type `Normal` with the reason `Killing`, which is why there is no `--types=Warning` filter here.]

```text
Warning   Unhealthy   Pod/langsam-7d6c9b8f5-x4q2m    Liveness probe failed: Get
"http://10.42.1.23:8080/healthz": dial tcp 10.42.1.23:8080: connect: connection refused
Warning   Unhealthy   Pod/nieready-5f7b8d9c6-j6t3p   Readiness probe failed: HTTP probe failed
with statuscode: 404
Normal    Killing     Pod/langsam-7d6c9b8f5-x4q2m    Container app failed liveness probe, will be
restarted
```

For `langsam`, it is worth looking at `Last State` and the previous log as well: exit code 137, and the last line is `Lade Daten (dauert 40 Sekunden) ...`. The container was terminated in the middle of loading. Exit code 137 happens because the shell ignores the kubelet's `SIGTERM`, and `SIGKILL` follows after the grace period. For `nieready`, what matters is what the Service sees:

#cmd("Mac")[```bash
kubectl --context rke2 get endpointslices -n dbg-06 -l kubernetes.io/service-name=nieready \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
```][Lists every address of the EndpointSlice with its state.]

```text
10.42.1.24 ready=false
```

In k9s, `d` on the pod shows the probe configuration under `Liveness` and `Readiness`, including `delay`, `period` and `#failure`.

#ursache[
  `langsam`: the liveness probe starts after 10 seconds and gives up after three failures 5 seconds apart, so after about 20 seconds. The application needs 40. So the kubelet kills it every time before it reaches the goal, a cycle with no way out. `nieready`: the readiness probe asks for `/ready`, and httpd returns 404. The pod stays in the EndpointSlice, but with `ready=false`, and the Service sends no traffic to it. Readiness never restarts anything, so there is no crash here, only silence.
]

=== Fix

For slow starts, there is the startup probe. As long as it has not succeeded, the kubelet suspends liveness and readiness. After that, the strict liveness probe takes over as usual.

#datei("szenarien/06-crash/fix-probes.yaml (excerpt)", ```yaml
          startupProbe:
            httpGet: {path: /healthz, port: 8080}
            periodSeconds: 5
            failureThreshold: 24
          livenessProbe:
            httpGet: {path: /healthz, port: 8080}
            periodSeconds: 5
            failureThreshold: 3
# ... for nieready:
          readinessProbe:
            httpGet: {path: /healthz, port: 8080}
```, erklaerung: [The startup probe gives the container up to 24 × 5 = 120 seconds. The liveness probe's `initialDelaySeconds` is dropped.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/fix-probes.yaml
kubectl --context talos apply -f szenarien/06-crash/fix-probes.yaml
```][Both Deployments roll out again.]

#pruefe[
  After a little more than 40 seconds, `get pods` shows both with `1/1 Running` and `RESTARTS 0`. The EndpointSlice reports `ready=true`, and `kubectl --context rke2 run test -n dbg-06 --rm -it --image=busybox:1.37 --restart=Never -- wget -qO- nieready/healthz` answers with `ok`.
]

== readOnlyRootFilesystem

A read-only root file system is a common hardening measure, even though Pod Security `restricted` does not require it. But many images write at startup to places the developer never consciously chose.

#datei("szenarien/06-crash/kaputt-readonly.yaml (excerpt)", ```yaml
        - name: web
          image: nginx:1.29
          securityContext:
            readOnlyRootFilesystem: true
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/kaputt-readonly.yaml
```][It behaves the same on Talos.]

#symptom[
  After a few seconds, `webro` is in `CrashLoopBackOff`, and `Last State` shows exit code 1.
]

#cmd("Mac")[```bash
kubectl --context rke2 logs -n dbg-06 deploy/webro --previous
```][The log of the crashed container.]

```text
/docker-entrypoint.sh: Launching /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
10-listen-on-ipv6-by-default.sh: info: can not modify /etc/nginx/conf.d/default.conf (read-only file system?)
...
2026/11/09 09:44:12 [emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
```

The `info` line is harmless. Only `[emerg]` stops nginx.

#ursache[
  With `readOnlyRootFilesystem: true`, the image's file system is mounted read-only. At startup, nginx needs writable directories for temporary files (`/var/cache/nginx`) and for the PID file (under `/run`). Error code 30 is `EROFS`, "Read-only file system". Volumes stay writable even with a read-only root.
]

#datei("szenarien/06-crash/fix-readonly.yaml (excerpt)", ```yaml
          volumeMounts:
            - name: cache
              mountPath: /var/cache/nginx
            - name: run
              mountPath: /run
      volumes:
        - name: cache
          emptyDir: {}
        - name: run
          emptyDir:
            medium: Memory
            sizeLimit: 16Mi
```, erklaerung: [Two `emptyDir` volumes exactly at the places where nginx writes. Everything else stays protected.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/fix-readonly.yaml
```][The same on Talos.]

#pruefe[
  `webro` is `Running`, and the log ends with `Configuration complete; ready for start up` and the startup messages of the worker processes. `kubectl --context rke2 exec -n dbg-06 deploy/webro -- touch /test` still fails with `Read-only file system`, as intended.
]

== Distroless: Debugging Without a Shell

Distroless images contain only the application: no shell, no `ls`. `kubectl exec ... -- sh` ends with a message that contains `exec: "sh": executable file not found in $PATH`. CoreDNS serves as the example, because its official image is distroless.

#datei("szenarien/06-crash/kaputt-distroless.yaml (excerpt)", ```yaml
kind: ConfigMap
data:
  corefile: |
    .:1053 {
        whoami
        health :8080
        log
    }
---
# ... Deployment "dns-test"
          image: registry.k8s.io/coredns/coredns:v1.14.7
          args: ["-conf", "/etc/coredns/Corefile"]
          volumeMounts:
            - name: config
              mountPath: /etc/coredns
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/kaputt-distroless.yaml
kubectl --context rke2 logs -n dbg-06 deploy/dns-test --previous
```][The same on Talos. The pod crashes immediately.]

```text
open /etc/coredns/Corefile: no such file or directory
```

#symptom[
  `dns-test` is in `CrashLoopBackOff`, exit code 1. The file is supposedly missing, even though the ConfigMap is mounted. You cannot look with `exec`: there is no shell, and the container barely runs.
]

=== Investigating with an Ephemeral Container

`kubectl debug` adds an extra container with an image of your choice to the pod. It shares the pod's network, but it only gets volumes via `--custom`:

#datei("szenarien/06-crash/debug-custom.yaml (excerpt)", ```yaml
securityContext:
  runAsUser: 65532
  runAsGroup: 65532
volumeMounts:
  - name: config
    mountPath: /etc/coredns
```, erklaerung: [Not a complete manifest, only the fields that `kubectl debug` applies to the debug container. User 65532 is the user `nonroot` of the CoreDNS image.])

#cmd("Mac")[```bash
POD=$(kubectl --context rke2 get pod -n dbg-06 -l app=dns-test -o name)
kubectl --context rke2 debug -it -n dbg-06 $POD --image=busybox:1.37 \
  --profile=baseline --custom=szenarien/06-crash/debug-custom.yaml -- sh
```][Starts busybox as an ephemeral container in the broken pod and opens a shell. `--profile=baseline` is required on Talos, see below.]

#cmd("Pod")[```bash
ls -l /etc/coredns
lrwxrwxrwx    1 root     root            15 Nov  9 10:31 corefile -> ..data/corefile
```][In the debug container, shown here with its output. You leave it with `exit`, and it stays in the pod spec in a terminated state.]

There it is: `corefile` in lowercase. Before you change the ConfigMap, you test the theory on a copy of the pod with a changed command:

#cmd("Mac")[```bash
kubectl --context rke2 debug -n dbg-06 $POD --copy-to=dns-test-kopie --profile=baseline \
  --container=coredns -- /coredns -conf /etc/coredns/corefile
kubectl --context rke2 logs -n dbg-06 dns-test-kopie -c coredns
```][`--copy-to` creates a new pod (here `dns-test-kopie`, "copy") that matches the original, but without labels, so without the Service and the Deployment. `--container` with a command replaces that container's start command. The log begins with `.:1053` and `CoreDNS-1.14.7`: with the right file name, it runs.]

#ursache[
  When a ConfigMap is mounted, its key becomes the file name, case-sensitive. The ConfigMap provides `corefile`, and CoreDNS looks for `Corefile`. Without a shell in the image, you bring the tool for looking around yourself with `kubectl debug`.
]

=== Fix and Verify

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-06 delete pod dns-test-kopie
kubectl --context rke2 apply -f szenarien/06-crash/fix-distroless.yaml
kubectl --context rke2 -n dbg-06 rollout restart deployment dns-test
```][Delete the copy, apply the ConfigMap with the key `Corefile`, and restart the pods so they see the changed ConfigMap right away.]

Now the container runs, and you can attach to its process namespace with `--target`:

#cmd("Mac")[```bash
POD=$(kubectl --context rke2 get pod -n dbg-06 -l app=dns-test -o name)
kubectl --context rke2 debug -it -n dbg-06 $POD --image=busybox:1.37 --target=coredns \
  --profile=baseline --custom=szenarien/06-crash/debug-custom.yaml -- sh
```][`--target=coredns` shares the processes of this container with the debug container.]

#cmd("Pod")[```bash
ps
ls /proc/1/root/etc/coredns/
```][PID 1 is now CoreDNS. Through `/proc/1/root` you see its file system, because the debug container runs as the same user 65532.]

#pruefe[
```text
PID   USER     TIME  COMMAND
    1 65532     0:00 /coredns -conf /etc/coredns/Corefile
   14 65532     0:00 sh
   21 65532     0:00 ps
Corefile
```
`kubectl get pods -n dbg-06 -l app=dns-test` shows `1/1 Running`.
]

#distro[
  Without the CIS profile, RKE2 does not enforce a Pod Security Standard. The default profile `general` of `kubectl debug` works. It adds the capability `SYS_PTRACE`, which lets a debug container running as root look into other processes too.
][
  Talos enforces `baseline` cluster-wide. With the profile `general`, the API server rejects the debug container: `violates PodSecurity "baseline:latest": non-default capabilities (container "debugger-..." must not include "SYS_PTRACE" in securityContext.capabilities.add)`. Hence `--profile=baseline`, and for `/proc/1/root` the same user as the target process. The k9s plugin `Shift-D` from Chapter 3 also uses `baseline`.
]

#aufgabe[
  Apply `szenarien/06-crash/aufgabe-probe.yaml`. The pod `waechter` ("guard") is running, and the application answers on port 8080, yet `RESTARTS` keeps rising. Find the cause and fix it with `kubectl edit` (in k9s: `e`).

  Hint: the `Unhealthy` events say `dial tcp ...:80: connect: connection refused`. The liveness probe checks port 80 via `tcpSocket`, but httpd listens on 8080.
]

Clean up:

#cmd("Mac")[```bash
kubectl --context rke2 delete namespace dbg-06
kubectl --context talos delete namespace dbg-06
```][Ephemeral containers cannot be removed individually. They only disappear with their pod.]

#gelernt(
  [`CrashLoopBackOff` is a waiting state. The cause: the exit code in `Last State` and the log from `kubectl logs --previous` (k9s: `p`).],
  [127 means command not found (in a shell). `StartError` with 128 means: the runtime could not start the process. 1 is an application error.],
  [`OOMKilled` with 137 is the kernel stepping in at the cgroup boundary. Proof: `dmesg` or `journalctl -k`.],
  [Liveness restarts, readiness takes the pod out of the Service. Slow starts belong in a startup probe.],
  [`readOnlyRootFilesystem` needs `emptyDir` volumes at the places where the application writes.],
  [Without a shell: `kubectl debug` with an ephemeral container, `--target`, `--custom` and `--copy-to`. On Talos, always with `--profile=baseline`.],
)
