#import "../lib.typ": *

#kapitel(
  [The Lab],
  ziel: [Four empty VMs become two clusters: RKE2 on Ubuntu and Talos Linux. Your Mac controls them through the contexts `rke2` and `talos`, both have a StorageClass `local-path`, and k9s is set up with this book's plugins.],
  zeit: [120 minutes],
  braucht: [Four VMs (two with Ubuntu 24.04 and SSH, two empty), a Mac with Homebrew, the cloned repo],
)

== What You Build

Every failure in this book runs on two clusters. Both use the same Kubernetes version but differ in how they are operated: RKE2 is a package on an ordinary Linux that you log in to via SSH. Talos is an operating system of its own, without a shell and without SSH, that you control only through an API. These differences are exactly what makes debugging interesting.

#tabelle(
  (auto, auto, auto, auto, 1fr),
  ([Node], [IP], [Context], [System], [Role]),
  [`rke2-cp`], [`172.16.0.160`], [`rke2`], [Ubuntu 24.04], [Server: control plane, etcd, also runs workloads],
  [`rke2-w1`], [`172.16.0.161`], [`rke2`], [Ubuntu 24.04], [Agent],
  [`talos-cp`], [`172.16.0.170`], [`talos`], [Talos v1.14.5], [Control plane, scheduling allowed],
  [`talos-w1`], [`172.16.0.171`], [`talos`], [Talos v1.14.5], [Worker],
)

The control plane nodes need 4 CPUs, 8 GB RAM and 60 GB disk, the other two 2 CPUs, 4 GB and 40 GB. Give every VM a fixed IP or a DHCP reservation. The addresses end up in configurations and certificates and must not change later. If you have different addresses, replace them in the files under `labor/` (German for lab) and in the commands.

Both clusters run Kubernetes 1.36.6. What they bring along differs a lot:

#tabelle(
  (auto, 1fr, 1fr),
  ([], [RKE2 v1.36.6+rke2r1], [Talos v1.14.5]),
  [CNI], [Canal (Flannel plus Calico for NetworkPolicies)], [Flannel, does *not* enforce NetworkPolicies],
  [Ingress], [Traefik (`rke2-traefik`)], [none],
  [metrics-server], [yes], [no],
  [StorageClass], [none], [none],
  [Pod Security], [no default], [cluster-wide `enforce: baseline`, `warn` and `audit` at `restricted`],
  [Node access], [SSH, `journalctl`, `crictl`], [only `talosctl` over port 50000],
)

Later chapters add the missing pieces when they are needed. Only the StorageClass is created here.

#warum[
  Take a snapshot of all four VMs as soon as you finish this chapter. You will damage the clusters on purpose in the coming chapters. Most of the time you fix the failure yourself afterwards, but if an experiment goes wrong, the snapshot gets you back to the starting point in a minute.
]

== Tools on the Mac

#cmd("Mac")[```bash
brew install kubernetes-cli helm siderolabs/tap/talosctl derailed/k9s/k9s
```][Installs `kubectl`, `helm`, `talosctl` and k9s. Homebrew installs the latest version of each. The book describes kubectl 1.36, talosctl 1.14.5, helm 4 and k9s 0.51.0.]

#cmd("Mac")[```bash
kubectl version --client
talosctl version --client
k9s version
```][Shows the installed versions.]

#falle[
  `talosctl` should match the Talos version of the nodes. A much newer `talosctl` uses `gen config` to create configurations for its own Talos version and puts in the matching installer image. If your version is not 1.14, download the binary for v1.14.5 from the project's release page on GitHub.
]

#cmd("Mac")[```bash
git clone https://github.com/thomaszachmann/kubernetes-debuggen.git
cd kubernetes-debuggen
```][All paths in the book are relative to this directory. You run commands labeled *Mac* here.]

== RKE2: The Configuration

At startup RKE2 reads the file `/etc/rancher/rke2/config.yaml`. Every key corresponds to an option of the command `rke2 server` or `rke2 agent`. The files for both nodes are in the repo:

#datei("labor/rke2/config-cp.yaml", ```yaml
node-name: rke2-cp
node-ip: 172.16.0.160
token: TOKEN-HIER-EINSETZEN
tls-san:
  - 172.16.0.160
  - rke2-cp
write-kubeconfig-mode: "0600"
cni: canal
ingress-controller: traefik
```, erklaerung: [
  `token` is the shared secret the agent uses to identify itself to the server. The placeholder `TOKEN-HIER-EINSETZEN` means "insert token here". `tls-san` adds the IP and name to the API server's certificate, otherwise `kubectl` on the Mac rejects the connection with an `x509` error. `write-kubeconfig-mode` makes the admin kubeconfig readable only by root. `cni` and `ingress-controller` match the defaults of RKE2 1.36. They are listed anyway so the file shows what the lab works with.
])

#datei("labor/rke2/config-w1.yaml", ```yaml
server: https://172.16.0.160:9345
node-name: rke2-w1
node-ip: 172.16.0.161
token: TOKEN-HIER-EINSETZEN
```, erklaerung: [
  The agent registers with the server through the supervisor port 9345, not through the API port 6443. Over this connection it gets its certificates and the address of the API server.
])

The repo is public, so there is no real token in it. You create one now and insert it while copying:

#cmd("Mac")[```bash
RKE2_TOKEN=$(openssl rand -hex 32)
sed "s/TOKEN-HIER-EINSETZEN/$RKE2_TOKEN/" labor/rke2/config-cp.yaml \
  | ssh <user>@172.16.0.160 'umask 077; cat > ~/rke2-config.yaml'
sed "s/TOKEN-HIER-EINSETZEN/$RKE2_TOKEN/" labor/rke2/config-w1.yaml \
  | ssh <user>@172.16.0.161 'umask 077; cat > ~/rke2-config.yaml'
```][Creates a random token and puts each node's configuration into the home directory, readable only by your user. Replace `<user>` with your SSH user. You do not need the token again later. The server also stores it under `/var/lib/rancher/rke2/server/node-token`.]

== RKE2: The Server

#cmd("Mac")[```bash
ssh <user>@172.16.0.160
```][Opens the session on the server. All steps labeled *rke2-cp* run here.]

#cmd("rke2-cp")[```bash
sudo hostnamectl set-hostname rke2-cp
sudo install -D -m 600 -o root -g root \
  ~/rke2-config.yaml /etc/rancher/rke2/config.yaml
rm ~/rke2-config.yaml
```][Sets the hostname to match the `node-name` and puts the configuration in place. It has to be there *before* RKE2 starts for the first time. `-D` creates the directory.]

#cmd("rke2-cp")[```bash
curl -sfL https://get.rke2.io | \
  sudo INSTALL_RKE2_VERSION=v1.36.6+rke2r1 sh -
sudo systemctl enable --now rke2-server.service
```][The script installs exactly the version used in this book. Without `INSTALL_RKE2_VERSION` you would get the latest version from the `stable` channel. The first start takes a few minutes because RKE2 pulls the control plane images.]

#cmd("rke2-cp")[```bash
sudo journalctl -u rke2-server -f
```][Follows the service log. Stop with `Ctrl-C`. Errors in `config.yaml` show up right at the beginning.]

For work directly on the node, later chapters always need the same environment. RKE2 puts `kubectl`, `crictl` and `ctr` in a directory of its own and writes its kubeconfig to a location of its own:

#cmd("rke2-cp")[```bash
sudo -i
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
kubectl get pods -n kube-system
```][Switches to root and sets the three variables. Without `CRI_CONFIG_FILE`, `crictl` does not find the containerd socket. Whenever later chapters work on an RKE2 node, they assume exactly these four lines.]

#pruefe[
  In `kube-system` you see `etcd-rke2-cp`, `kube-apiserver-rke2-cp` and the other static pods of the control plane, plus `rke2-canal`, `rke2-coredns`, `rke2-metrics-server` and `rke2-traefik`. Several `helm-install-rke2-…` pods are `Completed`. That is correct: they installed the bundled charts and are done.
]

The admin kubeconfig belongs to root. For the Mac you create a copy that your user is allowed to fetch:

#cmd("rke2-cp")[```bash
install -m 600 -o <user> /etc/rancher/rke2/rke2.yaml /tmp/rke2.yaml
exit
exit
```][Still runs as root from the `sudo -i` session. The first `exit` ends the root shell, the second ends the SSH session.]

== RKE2: The Agent

#cmd("Mac")[```bash
ssh <user>@172.16.0.161
```][Opens the session on the agent.]

#cmd("rke2-w1")[```bash
sudo hostnamectl set-hostname rke2-w1
sudo install -D -m 600 -o root -g root \
  ~/rke2-config.yaml /etc/rancher/rke2/config.yaml
rm ~/rke2-config.yaml
curl -sfL https://get.rke2.io | \
  sudo INSTALL_RKE2_VERSION=v1.36.6+rke2r1 INSTALL_RKE2_TYPE=agent sh -
sudo systemctl enable --now rke2-agent.service
```][Same as on the server, but with `INSTALL_RKE2_TYPE=agent`. The service is now called `rke2-agent`, and you read its log with `sudo journalctl -u rke2-agent -f`.]

#falle[
  If the agent hangs and the log keeps reporting connection errors to `172.16.0.160:9345`, a firewall is usually blocking it. On Ubuntu Server `ufw` is inactive by default, and `sudo ufw status` shows it. If it is active, RKE2 needs at least TCP 6443 and 9345 to the server, TCP 10250 between all nodes, and for Canal UDP 8472 (VXLAN) and TCP 9099. Keep port 22 open, or you lock yourself out.
]

== The RKE2 Kubeconfig

The file from the server points to `127.0.0.1` and calls the cluster, user and context `default`. You change both before it goes into your `~/.kube/config`.

#cmd("Mac")[```bash
mkdir -p ~/.kube
[ -f ~/.kube/config ] && cp -p ~/.kube/config ~/.kube/config.bak
scp <user>@172.16.0.160:/tmp/rke2.yaml ~/.kube/rke2.raw
ssh <user>@172.16.0.160 'rm /tmp/rke2.yaml'
```][Backs up an existing kubeconfig, fetches the file from the server and deletes the copy there. It contains full admin rights.]

#cmd("Mac")[```bash
sed -e 's/127\.0\.0\.1/172.16.0.160/' -e 's/: default$/: rke2/' \
  ~/.kube/rke2.raw > ~/.kube/rke2.yaml
KUBECONFIG=~/.kube/config:~/.kube/rke2.yaml \
  kubectl config view --flatten > ~/.kube/config.neu
chmod 600 ~/.kube/config.neu
mv ~/.kube/config.neu ~/.kube/config
rm ~/.kube/rke2.raw ~/.kube/rke2.yaml
```][`sed` puts in the IP and renames everything to `rke2`. `kubectl` merges several files listed in `KUBECONFIG`, and `--flatten` writes the certificates directly into the output. If a context `rke2` already exists, remove it first with `kubectl config delete-context rke2`, otherwise the old entry wins.]

#cmd("Mac")[```bash
kubectl --context rke2 get nodes
```][First access from the Mac.]

#pruefe[
  Two nodes, `rke2-cp` and `rke2-w1`, both `Ready`, version `v1.36.6+rke2r1`. If `rke2-w1` is missing, check the agent's log.
]

== Talos: Booting

You do not install Talos as a package. You boot it from an ISO. Get the ISO from the Image Factory at `factory.talos.dev`: version v1.14.5, platform bare metal, architecture amd64. You do not need any extensions for the lab. If your hypervisor runs a guest agent, for example Proxmox with `qemu-guest-agent`, you can add the matching extension.

Boot both Talos VMs from this ISO. The console shows the Talos dashboard with the IP address. The node is now in *maintenance mode*: it runs in RAM, has no configuration yet and is waiting for one. In this state the maintenance API accepts configurations without authentication. That is by design, which is why the lab belongs on a network only you can reach.

#cmd("Mac")[```bash
talosctl get disks --insecure --nodes 172.16.0.170
talosctl get disks --insecure --nodes 172.16.0.171
```][Lists the disks of the nodes. `--insecure` talks to the maintenance API. Note the name of the system disk, for example `sda` or `vda`.]

Then remove the ISO from the virtual drives. The node keeps running because Talos lives entirely in RAM. This way Talos cannot accidentally boot from the ISO again after the installation.

== Talos: The Patches

A Talos configuration is a long YAML document that `talosctl gen config` creates. You do not edit it by hand. Instead you describe your changes in small patches. There are three in the repo:

#datei("labor/talos/patch-cp.yaml", ```yaml
machine:
  install:
    disk: /dev/sda
cluster:
  allowSchedulingOnControlPlanes: true
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: talos-cp
auto: off
```, erklaerung: [
  `machine.install.disk` is the disk Talos installs itself on. If `get disks` showed a different name, adjust it here and in `patch-w1.yaml`. `allowSchedulingOnControlPlanes` removes the taint Talos uses to keep normal pods off the control plane. The second document sets the hostname. `auto: off` turns off the automatically generated name like `talos-2ld-dvw`.
])

#datei("labor/talos/patch-w1.yaml", ```yaml
machine:
  install:
    disk: /dev/sda
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: talos-w1
auto: off
```)

#datei("labor/talos/patch-local-path.yaml", ```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: local-path-provisioner
volumeType: directory
```, erklaerung: [
  A *user volume* of type `directory` creates the directory `/var/mnt/local-path-provisioner` on the `EPHEMERAL` partition and passes it through into the kubelet's container. That is where the local-path-provisioner stores the volumes later. A dedicated directory is necessary because the default directory `/opt/local-path-provisioner` is read-only on Talos and the kubelet does not see every path under `/var`.
])

== Talos: Generating the Configuration

#cmd("Mac")[```bash
talosctl gen secrets -o labor/talos/secrets.yaml
```][Creates the certificate authorities and keys of the cluster. With this file you can regenerate the configuration at any time without the certificates changing. Like all generated files, it is listed in `.gitignore`.]

#cmd("Mac")[```bash
talosctl gen config talos https://172.16.0.170:6443 \
  --with-secrets labor/talos/secrets.yaml \
  --kubernetes-version 1.36.6 \
  --config-patch @labor/talos/patch-local-path.yaml \
  --config-patch-control-plane @labor/talos/patch-cp.yaml \
  --config-patch-worker @labor/talos/patch-w1.yaml \
  --output labor/talos/
```][`talos` is the name of the cluster, the URL is the API server's endpoint. `--config-patch` applies to all nodes, the other two only to the control plane or the worker. Without `--kubernetes-version`, `talosctl` uses its own default, which does not necessarily match the RKE2 cluster.]

#cmd("Mac")[```bash
talosctl validate --config labor/talos/controlplane.yaml --mode metal
talosctl validate --config labor/talos/worker.yaml --mode metal
```][Checks both files before they go to a node.]

#pruefe[
  The directory `labor/talos/` now contains `controlplane.yaml`, `worker.yaml` and `talosconfig`. `validate` reports `is valid for metal mode` for both files.
]

== Talos: Applying and Bootstrapping

#cmd("Mac")[```bash
talosctl apply-config --insecure --nodes 172.16.0.170 \
  --file labor/talos/controlplane.yaml
talosctl apply-config --insecure --nodes 172.16.0.171 \
  --file labor/talos/worker.yaml
```][Sends each node its configuration. Talos installs itself to disk and reboots. From now on the node is only reachable with the certificates from `talosconfig`, and `--insecure` no longer works.]

#cmd("Mac")[```bash
export TALOSCONFIG=$PWD/labor/talos/talosconfig
talosctl config endpoint 172.16.0.170
echo "export TALOSCONFIG=$PWD/labor/talos/talosconfig" >> ~/.zshrc
```][`TALOSCONFIG` tells `talosctl` where the certificates and context are. The endpoint is the node `talosctl` sends all requests through. The last line adds the variable to your shell permanently. All later chapters assume it.]

#cmd("Mac")[```bash
talosctl --nodes 172.16.0.170 bootstrap
```][Starts etcd on the control plane. You run this command exactly *once* and only on one node. If the node is still waiting for the reboot, repeat it after a minute.]

#cmd("Mac")[```bash
talosctl --nodes 172.16.0.170 health
```][Checks etcd, the kubelet, the control plane and whether all nodes have joined the cluster. The command waits up to 20 minutes and reports every step.]

#falle[
  If you run `bootstrap` a second time on another control plane node, you create a second, independent etcd cluster. The lab has only one control plane node, so the risk is small. In real clusters with three nodes this is a common mistake.
]

#cmd("Mac")[```bash
talosctl --nodes 172.16.0.170 kubeconfig --force-context-name talos
kubectl --context talos get nodes
```][Downloads the admin kubeconfig and merges it into `~/.kube/config`. Without `--force-context-name` the context would be called `admin@talos`.]

#pruefe[
  Two nodes, `talos-cp` and `talos-w1`, both `Ready`, version `v1.36.6`. `kubectl config get-contexts` shows `rke2` and `talos` side by side.
]

#distro([
  You manage the node like any Linux. The configuration is a file under `/etc/rancher/rke2/`, and changes take effect after `systemctl restart rke2-server`. You read logs with `journalctl`.
], [
  The node has no shell. The entire configuration is the machine config, which you change with `talosctl patch machineconfig`. You read logs with `talosctl logs kubelet` or `talosctl dmesg`, always with `--nodes`.
])

== Storage: local-path-provisioner

Neither cluster has a StorageClass yet. A PVC would stay `Pending` forever. Rancher's local-path-provisioner creates a directory for each PVC on the node where the pod runs. For a lab that is exactly right: no network storage, no extra disks.

The StorageClass is called `local-path` on both clusters. It is deliberately *not* made the default StorageClass. A PVC has to request it explicitly with `storageClassName: local-path`. A PVC without it stays `Pending`, and chapters 4 and 9 investigate exactly that failure.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f \
  https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
```][Installs version v0.0.37 in the namespace `local-path-storage`. On Ubuntu the default directory `/opt/local-path-provisioner` is writable, so no adjustment is needed.]

Talos needs two changes to the same manifest. A kustomization in the repo applies them:

#datei("werkzeuge/local-path-talos/kustomization.yaml (excerpt)", ```yaml
resources:
  - https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
patches:
  - patch: |-
      kind: ConfigMap
      # ... local-path-config: "paths": ["/var/mnt/local-path-provisioner"]
  - patch: |-
      apiVersion: v1
      kind: Namespace
      metadata:
        name: local-path-storage
        labels:
          pod-security.kubernetes.io/enforce: privileged
```, erklaerung: [
  The first patch sends the volumes into the user volume from `patch-local-path.yaml`. The second allows privileged pods in the namespace. For every volume the provisioner starts a short-lived helper pod with `hostPath`, and Pod Security `baseline` on Talos would reject it.
])

#cmd("Mac")[```bash
kubectl --context talos apply -k werkzeuge/local-path-talos/
```][`-k` builds the kustomization and applies the result. `kubectl` downloads the manifest directly from GitHub in the process.]

#cmd("Mac")[```bash
kubectl --context rke2 get storageclass
kubectl --context talos get storageclass
```][Shows the StorageClasses of both clusters.]

#pruefe[
  Exactly one StorageClass on each cluster:

  ```text
  NAME         PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
  local-path   rancher.io/local-path   Delete          WaitForFirstConsumer
  ```
  The output also has the columns `ALLOWVOLUMEEXPANSION` and `AGE`. What matters is the name: there is *no* `(default)` after it.
]

A small test shows whether a volume is really created: a PVC and a pod that writes a file into it.

#cmd("Mac")[```bash
for c in rke2 talos; do
  kubectl --context $c apply -f labor/pvc-test.yaml
  kubectl --context $c wait pod/schreiber -n dbg-02 \
    --for=condition=Ready --timeout=120s
  kubectl --context $c get pvc,pod -n dbg-02 -o wide
done
```][Creates the namespace `dbg-02`, the PVC `daten` and the pod `schreiber` (German for data and writer) on both clusters and waits until the pod is running. Because of `WaitForFirstConsumer`, the volume is only created once the pod is assigned to a node.]

#pruefe[
  The PVC is `Bound`, the pod is `Running`, and `logs -n dbg-02 schreiber` shows the date and time. On Talos you can also see the volume on the node. Take the node's IP from the `NODE` column:

  ```text
  talosctl --nodes 172.16.0.171 ls /var/mnt/local-path-provisioner
  ```
]

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-02
kubectl --context talos delete ns dbg-02
```][Cleans up. Because of `reclaimPolicy: Delete`, the provisioner also deletes the directories on the nodes.]

== Setting Up k9s

You already installed k9s. What is missing are this book's plugins. k9s looks for them in its configuration directory, and on macOS that is not under `~/.config`:

#cmd("Mac")[```bash
k9s info
```][Shows where k9s expects its configuration, plugins, skins and logs.]

#pruefe[
  The `Plugins` line names `~/Library/Application Support/k9s/plugins.yaml`, spelled out with your home directory. On Linux it says `~/.config/k9s/plugins.yaml`.
]

#cmd("Mac")[```bash
mkdir -p "$HOME/Library/Application Support/k9s"
cp k9s/plugins.yaml "$HOME/Library/Application Support/k9s/plugins.yaml"
```][Copies the plugins into place. If you already have a `plugins.yaml` there, merge the two files by hand instead of overwriting it. Chapter 3 shows what the plugins do.]

== Wrap-Up: Both Clusters at a Glance

#cmd("Mac")[```bash
kubectl --context rke2 get nodes -o wide
kubectl --context talos get nodes -o wide
```][The end of the chapter. These two commands are also where every investigation starts when you do not know what state the lab is in.]

#pruefe[
  Four nodes, all `Ready`. For RKE2, `VERSION` shows `v1.36.6+rke2r1` and `OS-IMAGE` Ubuntu 24.04, for Talos `v1.36.6` and `Talos (v1.14.5)`. The `INTERNAL-IP` matches the table at the beginning of the chapter. Now is the right moment for the snapshots.
]

#aufgabe[
  Compare what runs in `kube-system` on the two clusters: `kubectl --context rke2 get pods -n kube-system` and the same for `talos`. Which pod is responsible for DNS on which cluster, and what is it called? Which one for the pod network? Hint: on RKE2 the bundled components carry the prefix `rke2-`, on Talos they are simply called `coredns` and `kube-flannel`. Chapter 7 needs exactly these names.
]

#gelernt(
  [RKE2 reads `/etc/rancher/rke2/config.yaml`. Server and agent share a token, and the agent registers through port 9345.],
  [Talos is controlled through a machine config that `talosctl gen config` creates from secrets and small patches. `bootstrap` runs exactly once.],
  [The contexts are called `rke2` and `talos`, and `TALOSCONFIG` points to `labor/talos/talosconfig`.],
  [Both clusters have the StorageClass `local-path`, but no default StorageClass. On Talos the volumes are stored under `/var/mnt/local-path-provisioner`, and the provisioner's namespace needs Pod Security `privileged`.],
  [On macOS, k9s expects its plugins under `~/Library/Application Support/k9s/`. `k9s info` shows the exact path.],
)
