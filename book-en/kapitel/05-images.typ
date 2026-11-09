#import "../lib.typ": *

#kapitel(
  [Images and Container Start],
  ziel: [You tell the pull errors apart by their message, check images directly on the node, set up a registry mirror on RKE2 and Talos, and find errors that happen between the pull and the start of a container.],
  zeit: [60 minutes],
  braucht: [Chapters 2 and 4],
)

== What Breaks in This Chapter

After scheduling, it is the kubelet's turn. It has containerd pull the image, assembles the container's configuration from environment variables, Secrets and volumes, and starts it. Each of these three steps can fail, and each step has its own status.

#tabelle(
  (auto, auto, 1fr),
  ([Step], [Status in `get pods`], [Scenario]),
  [Pull the image], [`ErrImagePull`, `ImagePullBackOff`], [Typo in the tag, registry unreachable, private repository, rate limit],
  [Build the configuration], [`CreateContainerConfigError`], [ConfigMap missing, key missing in the Secret],
  [Start the process], [`CrashLoopBackOff`, log `exec format error`], [Script without a shebang, wrong architecture],
)

All scenarios run in the namespace `dbg-05`. In this chapter, the scheduler has always placed the pod already. The `NODE` column in `kubectl get pods -o wide` tells you which node you have to look at.

== Three Pull Errors, Three Messages

`ImagePullBackOff` is not an error but a waiting state: the kubelet tried a pull, it failed, and now it waits with a growing interval (up to five minutes) for the next attempt. The cause is in the message of the *first* failure. The manifest creates three broken Deployments at once:

#datei("szenarien/05-images/kaputt-pull.yaml (excerpt)", ```yaml
  name: tippfehler
# ...
        - name: web
          image: nginx:1.29-alpnie
---
  name: unerreichbar
# ...
          image: registry.labor.invalid:5000/web:1.0
---
  name: privat
# ...
          image: docker.io/dbglabor/privat-app:1.0
```, erklaerung: [Two swapped letters in the tag, a registry that does not exist (the domain `.invalid` is reserved for this), and a repository you have no credentials for. The Deployment names mean "typo", "unreachable" and "private".])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/kaputt-pull.yaml
kubectl --context talos apply -f szenarien/05-images/kaputt-pull.yaml
```][Creates the namespace and three Deployments.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-05
NAME                            READY   STATUS             RESTARTS   AGE
privat-6c7d9f8b5-4kq9m          0/1     ImagePullBackOff   0          58s
tippfehler-7b9c5d4f6-p8x2l      0/1     ErrImagePull       0          58s
unerreichbar-5f6d8c7b9-r3n7v    0/1     ImagePullBackOff   0          58s
```
The status switches between `ErrImagePull` (just failed) and `ImagePullBackOff` (waiting). You cannot tell the three cases apart by the status alone.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-05 -l app=tippfehler | tail -n 6
```][The events show the whole sequence of a pull attempt.]

```text
  Normal   Pulling    40s (x3 over 82s)  kubelet  Pulling image "nginx:1.29-alpnie"
  Warning  Failed     39s (x3 over 81s)  kubelet  Failed to pull image "nginx:1.29-alpnie": rpc
  error: code = NotFound desc = failed to pull and unpack image "docker.io/library/nginx:1.29-
  alpnie": failed to resolve reference "docker.io/library/nginx:1.29-alpnie": docker.io/library/
  nginx:1.29-alpnie: not found
  Warning  Failed     39s (x3 over 81s)  kubelet  Error: ErrImagePull
  Normal   BackOff    12s (x4 over 80s)  kubelet  Back-off pulling image "nginx:1.29-alpnie"
  Warning  Failed     12s (x4 over 80s)  kubelet  Error: ImagePullBackOff
```

Only the `Failed to pull image` line matters. Read it from the end: the last link is the actual answer from containerd or the registry. Before it is what containerd was trying to do. Also note that the kubelet expands the short name `nginx` to `docker.io/library/nginx`. For the other two pods, you fetch only this line:

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-05 --types=Warning | grep "Failed to pull"
```][Filters all pull errors in the namespace. On Talos the output looks the same, only the address of the DNS resolver may differ.]

The three messages end like this:

#tabelle(
  (auto, 1fr),
  ([Deployment], [End of the message (shortened)]),
  [`tippfehler`], [`docker.io/library/nginx:1.29-alpnie: not found`],
  [`unerreichbar`], [`dial tcp: lookup registry.labor.invalid ...: no such host`],
  [`privat`], [`pull access denied, repository does not exist or may require authorization: server message: insufficient_scope: authorization failed`],
)

In k9s: `:pods dbg-05⏎`, select the pod, press `d` (events at the bottom) or `Shift-E` (plugin from Chapter 3).

#ursache[
  Three different errors under the same status. `not found` means: the registry knows the repository, but not this tag. `no such host` means: the *node* cannot resolve the name of the registry. containerd on the node does the pull, not the pod, so the node's DNS is what counts, not CoreDNS. `pull access denied` means: the registry refuses access. Docker Hub deliberately does not distinguish between "does not exist" and "you are not allowed to see it".
]

Other endings you should know:

#tabelle(
  (auto, 1fr),
  ([Message ends with], [Likely cause]),
  [`i/o timeout`], [Firewall or proxy between node and registry],
  [`x509: certificate signed by unknown authority`], [Registry with its own CA that the node does not trust],
  [`401 Unauthorized`], [Credentials present, but wrong or expired],
  [`429 Too Many Requests`, `toomanyrequests`], [Docker Hub rate limit, see below],
  [`no match for platform in manifest`], [The image does not exist for the node's architecture],
)

=== Fix

Only a corrected manifest fixes the typo and the wrong registry:

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/fix-pull.yaml
kubectl --context talos apply -f szenarien/05-images/fix-pull.yaml
```][Sets the image `nginx:1.29-alpine` for `tippfehler` and `unerreichbar`.]

For a private repository, the pod needs credentials in a Secret of type `kubernetes.io/dockerconfigjson` in the *same* namespace. You create it with `kubectl -n dbg-05 create secret docker-registry regcred --docker-server=docker.io --docker-username=... --docker-password=...`, ideally with a read-only token, and reference it in the pod:

#datei("szenarien/05-images/fix-pull-privat.yaml (excerpt)", ```yaml
    spec:
      imagePullSecrets:
        - name: regcred
      containers:
        - name: web
          image: docker.io/dbglabor/privat-app:1.0
```, erklaerung: [The repository `dbglabor/privat-app` does not exist, so in the lab this pod stays stuck even with the Secret. Replace the image with a private repository of your own to walk through the process. Alternatively, you attach the Secret to the ServiceAccount: `kubectl -n dbg-05 patch serviceaccount default -p '{"imagePullSecrets":[{"name":"regcred"}]}'`. Then all new pods of this ServiceAccount get it automatically.])

#pruefe[
  `tippfehler` and `unerreichbar` are `Running`. The events show `Successfully pulled image "nginx:1.29-alpine" in ...`. If you do not have a private repository of your own, delete the pod `privat`: `kubectl --context rke2 -n dbg-05 delete deployment privat`.
]

== Looking on the Node

Sometimes you want to know whether a pull works on the node itself, without the kubelet in between: for example, to check credentials, a mirror or a proxy. On RKE2 you do this with `crictl`, on Talos with `talosctl image`. Both talk to the same containerd instance that the kubelet uses.

#cmd("rke2-w1")[```bash
sudo -i
export PATH=$PATH:/var/lib/rancher/rke2/bin
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
crictl pull nginx:1.29-alpnie
crictl pull nginx:1.29-alpine
crictl images | grep nginx
```][The first pull fails with the same message as in the event. The second ends with `Image is up to date for sha256:...`. `crictl images` lists the columns `IMAGE`, `TAG`, `IMAGE ID` and `SIZE`.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.171 image pull docker.io/library/nginx:1.29-alpine
talosctl -n 172.16.0.171 image list | grep nginx
```][`image pull` reports `172.16.0.171: pulled image ...`. `image list` shows the columns `NODE`, `IMAGE`, `DIGEST`, `SIZE` and more. Without further options, `talosctl image` works in the namespace `cri`, that is, with the images of the Kubernetes workloads.]

#distro[
  More detailed pull errors are in the containerd log `/var/lib/rancher/rke2/agent/containerd/containerd.log`.
][
  You read the log of the workload runtime with `talosctl -n 172.16.0.171 logs cri`.
]

== Rate Limit and Registry Mirror

Docker Hub limits anonymous pulls to 100 per six hours per IP address. Behind a NAT, all nodes and all colleagues share this one address. When the limit is reached, pulls from `docker.io` fail with `429 Too Many Requests`, and Docker's message contains `toomanyrequests: You have reached your pull rate limit`. In the lab, you do not provoke this on purpose. But you set up the remedy that also helps against a slow or failed registry: a mirror at the node level.

A mirror is not configured in the pod, but in containerd on every node. The pod still says `nginx:1.29-alpine`, and containerd asks the mirror first. In the lab, that is `mirror.gcr.io`, a public cache by Google for popular images from Docker Hub.

=== RKE2: registries.yaml

#datei("labor/rke2/registries-mirror.yaml (excerpt)", ```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://mirror.gcr.io"
# Credentials for your own registry (do not commit them to the repo):
# configs:
#   "registry.example.com:5000":
#     auth:
#       username: xxxxxx
#       password: xxxxxx
```, erklaerung: [The format is specific to RKE2. RKE2 generates the containerd configuration from it at startup. Credentials go under `configs`, with the hostname of the registry as the key.])

Copy the file with `scp` and your SSH user from Chapter 2 to `/tmp/registries.yaml` on every node and install it there:

#cmd("rke2-w1")[```bash
sudo install -m 600 /tmp/registries.yaml /etc/rancher/rke2/registries.yaml
sudo systemctl restart rke2-agent
sudo cat /var/lib/rancher/rke2/agent/etc/containerd/certs.d/docker.io/hosts.toml
```][RKE2 reads `registries.yaml` only at startup, hence the restart (on `rke2-cp`: `rke2-server`). Running pods survive it. The generated `hosts.toml` must contain an entry for `https://mirror.gcr.io`.]

#falle[
  RKE2 always tries the original registry as a last resort, even when a mirror is configured. So a broken mirror does not stand out right away. Pulls just get slower and count against the limit again. If you want to turn off the fallback, set the option `disable-default-registry-endpoint: true` in `/etc/rancher/rke2/config.yaml`.
]

=== Talos: RegistryMirrorConfig

Talos 1.14 describes mirrors in a separate configuration document. The old way via `machine.registries` in the machine config still works, but it is deprecated.

#datei("labor/talos/patch-registry.yaml (excerpt)", ```yaml
apiVersion: v1alpha1
kind: RegistryMirrorConfig
name: docker.io
endpoints:
  - url: https://mirror.gcr.io
```, erklaerung: [`name` is the registry that is mirrored. Credentials for a mirror go in another document of type `RegistryAuthConfig` with `name`, `username` and `password`, and your own CAs go in `RegistryTLSConfig`. With `skipFallback: true`, Talos no longer asks the original registry at all.])

#cmd("Mac")[```bash
talosctl -n 172.16.0.170,172.16.0.171 patch machineconfig \
  --patch @labor/talos/patch-registry.yaml
talosctl -n 172.16.0.171 ls /etc/cri/conf.d/hosts
```][The patch adds the document on both nodes. From it, Talos writes the containerd configuration under `/etc/cri/conf.d/hosts`, with an entry for `docker.io`. `talosctl patch` reports whether the change was applied without a reboot.]

#pruefe[
  Pulling an image from Docker Hub that is not on the node yet still works: on RKE2 with `crictl pull busybox:1.37`, on Talos with `talosctl -n 172.16.0.171 image pull docker.io/library/busybox:1.37`. The image shows up under its original name `docker.io/library/busybox`, not under the mirror's name. Whether the mirror was really asked is shown by the containerd log on RKE2 and by `talosctl logs cri` on Talos.
]

== CreateContainerConfigError

The image is there, but the kubelet cannot configure the container. If a ConfigMap or Secret referenced in `env` or `envFrom` is missing, the container does not even start.

#datei("szenarien/05-images/kaputt-config.yaml (excerpt)", ```yaml
kind: Secret
metadata:
  name: app-secret
stringData:
  db-password: geheim-nur-im-labor
---
# ... Deployment "app"
          envFrom:
            - configMapRef:
                name: app-config
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-secret
                  key: DB_PASSWORD
```, erklaerung: [Two errors: the ConfigMap `app-config` does not exist, and the Secret has the key `db-password`, not `DB_PASSWORD`.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/kaputt-config.yaml
```][On Talos, this scenario behaves the same way.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-05 -l app=app
NAME                   READY   STATUS                       RESTARTS   AGE
app-6f9d7c8b5d-w2xkq   0/1     CreateContainerConfigError   0          21s
```
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-05 --types=Warning
```][All warnings in the namespace, the newest at the bottom. In k9s: select the pod, press `Shift-E`.]

```text
LAST SEEN   TYPE      REASON    OBJECT                     MESSAGE
3s          Warning   Failed    Pod/app-6f9d7c8b5d-w2xkq   Error: configmap "app-config" not found
```

The kubelet only ever reports the first error it runs into. Create the ConfigMap and see what comes next:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-05 create configmap app-config \
  --from-literal=DB_HOST=db.dbg-05.svc.cluster.local
```][The kubelet tries again on its own. After a few seconds, there is a new event.]

```text
Warning   Failed    Pod/app-6f9d7c8b5d-w2xkq   Error: couldn't find key DB_PASSWORD in Secret
dbg-05/app-secret
```

`kubectl --context rke2 describe secret app-secret -n dbg-05` shows which keys the Secret really has under `Data`, without printing the values: only `db-password`.

#ursache[
  The kubelet resolves environment variables right before the container starts. If the object or the key is missing and the reference is not `optional: true`, it aborts, sets `CreateContainerConfigError` and tries again periodically. At this point the pod is already scheduled and the image is pulled, so at first glance the error looks like an image problem.
]

=== Fix

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/fix-config.yaml
```][Creates the ConfigMap declaratively and references the correct key `db-password`.]

#pruefe[
  The pod is `Running`, and `kubectl --context rke2 logs -n dbg-05 deploy/app` shows `Verbinde mit db.dbg-05.svc.cluster.local` ("Connecting to ...").
]

#falle[
  If the missing ConfigMap is mounted as a *volume* instead of an environment variable, the error looks different: the pod hangs in `ContainerCreating`, and the event is `FailedMount` with `MountVolume.SetUp failed for volume "config" : configmap "app-config" not found`. The same cause, a different status.
]

== exec format error

This error occurs when the kernel cannot execute the file that is supposed to start as a process. The classic case is an image for the wrong CPU architecture, for example built for `arm64` on a Mac with Apple Silicon and started on `amd64` nodes. In the lab, you reproduce it with a second, equally common trigger: a start script without a shebang line.

#datei("szenarien/05-images/kaputt-exec.yaml (excerpt)", ```yaml
kind: ConfigMap
data:
  start.sh: |
    echo "Starte Dienst"
    exec sleep infinity
---
# ... Deployment "skript"
          command: ["/scripts/start.sh"]
          volumeMounts:
            - name: skript
              mountPath: /scripts
      volumes:
        - name: skript
          configMap:
            name: start-skript
            defaultMode: 0755
```, erklaerung: [The script is executable, but the first line `#!/bin/sh` is missing. `skript` means "script", and `Starte Dienst` means "Starting service".])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/kaputt-exec.yaml
kubectl --context talos apply -f szenarien/05-images/kaputt-exec.yaml
```][Creates the ConfigMap and the Deployment `skript`.]

#symptom[
  After a short time, `kubectl --context rke2 get pods -n dbg-05 -l app=skript` shows `CrashLoopBackOff` with a rising number in `RESTARTS`.
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 logs -n dbg-05 deploy/skript --previous
```][`--previous` reads the log of the last terminated container. In k9s: select the pod, press `p`.]

```text
exec /scripts/start.sh: exec format error
```

This line does not come from the script, but from the container runtime (runc) that tried to start the process. You find out in two steps whether the architecture or the shebang is to blame:

#cmd("Mac")[```bash
kubectl --context rke2 get nodes -L kubernetes.io/arch
kubectl --context rke2 get cm start-skript -n dbg-05 -o jsonpath='{.data.start\.sh}' | head -n 1
```][The first line shows the architecture of each node in the `ARCH` column. The second shows the first line of the script: `#!/bin/sh` is missing here.]

#ursache[
  runc starts the container's command directly with the `execve` system call, without a shell. The kernel recognizes executable files by their first bytes: ELF binaries for its own architecture, or scripts with `#!`. It rejects everything else with `ENOEXEC`, and that shows up as `exec format error`. In an interactive shell, the same script would run, because in this case the shell interprets it itself.
]

=== Fix

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/fix-exec.yaml
kubectl --context rke2 -n dbg-05 rollout restart deployment skript
```][The new ConfigMap starts with `#!/bin/sh`. The restart makes sure the pod sees the new version right away. On Talos, run the same commands with `--context talos`.]

#pruefe[
  `kubectl --context rke2 logs -n dbg-05 deploy/skript` shows `Starte Dienst`, and the pod is `Running` with `RESTARTS 0`.
]

#warum[
  With the wrong architecture, the pull often fails already (`no match for platform in manifest`) if the image does not offer the node's architecture at all. If the metadata is right but the binary is not, you get `exec format error`. `docker buildx imagetools inspect nginx:1.29` shows which platforms an image has.
]

#aufgabe[
  Apply `szenarien/05-images/aufgabe-pullpolicy.yaml` with `--context talos`. The Deployment `offline` does not start. Find the cause through the events and get the pod running *without* changing the manifest.

  Hint: the status is `ErrImageNeverPull`, and the message is `Container image "nginx:1.29-alpine-slim" is not present with pull policy of Never`. With `imagePullPolicy: Never`, the kubelet never pulls by itself. Preload the image with `talosctl image pull` on the node where the pod is. The pod starts on the kubelet's next attempt.
]

Clean up on both clusters:

#cmd("Mac")[```bash
kubectl --context rke2 delete namespace dbg-05
kubectl --context talos delete namespace dbg-05
```][The registry mirror stays active. It does no harm and spares the rate limit in the following chapters.]

#gelernt(
  [`ImagePullBackOff` is a waiting state. The cause is in the `Failed to pull image` event, at the end of the message.],
  [`not found`, `no such host`, `pull access denied`, `x509`, `429`: each ending points to a different cause. The node does the pull, not the pod.],
  [`crictl` on RKE2 and `talosctl image` on Talos check pulls directly against containerd, without the kubelet.],
  [Mirrors and registry credentials at the node level: on RKE2 `/etc/rancher/rke2/registries.yaml` plus a restart, on Talos `RegistryMirrorConfig` via `talosctl patch`.],
  [`CreateContainerConfigError` reports missing ConfigMaps, Secrets and keys, always only the first error.],
  [`exec format error` means: the kernel cannot execute the file. Wrong architecture or a missing shebang.],
)
