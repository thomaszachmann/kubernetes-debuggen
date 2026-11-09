#import "../lib.typ": *
#set heading(numbering: none)

#heading(level: 1, numbering: none, outlined: false)[Contents]

#{
  show outline.entry.where(level: 1): it => {
    v(0.55em, weak: true)
    strong(it)
  }
  outline(title: none, depth: 2, indent: 1.2em)
}

#pagebreak(to: "odd")
#heading(level: 1, numbering: none)[How to Use This Book]

A Kubernetes cluster rarely admits what is wrong with it. It shows you `Pending`, `CrashLoopBackOff` or a terse `Forbidden` and leaves the rest to you. If you have ever stared at a pod for an hour that simply would not start, you know the feeling. Most of the time the answer was sitting in an event that nobody read.

This book turns troubleshooting into a routine. You build two small clusters and break them on purpose, again and again and in many ways. For every failure you see how it shows up, how you investigate it with `kubectl` and k9s, what the actual cause is and how you fix it. After a few chapters you will notice that the questions repeat. That is exactly the goal.

== Why Two Distributions

Kubernetes is the same everywhere, the platform underneath is not. Troubleshooting often does not end at the pod but on the node: at the kubelet, at containerd, at etcd or at a setting that comes with the distribution. That is why you work with two very different representatives:

#tabelle(
  (auto, 1fr, 1fr),
  ([], [RKE2], [Talos Linux]),
  [Operating system], [Ubuntu 24.04, RKE2 as a systemd service], [Talos, an immutable Linux just for Kubernetes],
  [Node access], [SSH, `journalctl`, `crictl`], [no shell, only the API with `talosctl`],
  [Configuration], [`/etc/rancher/rke2/config.yaml`], [machine config, applied with `talosctl`],
  [Network], [Canal, enforces NetworkPolicies], [Flannel, ignores NetworkPolicies],
  [Bundled], [Traefik, metrics-server, CoreDNS], [CoreDNS, otherwise deliberately little],
)

RKE2 feels like a classic Linux server. On Talos many familiar moves do not work because there is no shell. Where troubleshooting differs, a box shows both paths side by side:

#distro(
  [This is how you proceed on RKE2, usually via SSH on the node.],
  [This is the path through `talosctl`, without a shell on the node.],
)

== First, Clone the Repo

Every file this book refers to lives in a public repository: #link("https://github.com/thomaszachmann/kubernetes-debuggen")[github.com/thomaszachmann/kubernetes-debuggen]. Each failure scenario has its own folder under `szenarien/` with one file that creates the failure and one that fixes it. The repo is shared with the German edition, so its file and folder names are German: `szenarien` means scenarios, `kaputt.yaml` means broken, and `fix.yaml` is the fix.

#cmd("Mac")[```bash
git clone https://github.com/thomaszachmann/kubernetes-debuggen.git
cd kubernetes-debuggen
```][Downloads the repo and switches to its root directory. All commands labeled *Mac* run from here. Paths like `szenarien/04-pending/` are always relative to this folder.]

== Where You Run a Command

Every command carries a colored label:

#tabelle(
  (auto, 1fr),
  ([Label], [Meaning]),
  [#etikett(akzent, "Mac")], [Your terminal on the laptop, in the root directory of the repo. From here you control both clusters with `kubectl --context rke2` or `--context talos`, and the Talos nodes with `talosctl`.],
  [#etikett(probe, "k9s")], [Keystrokes in k9s. `⏎` stands for the Enter key.],
  [#etikett(warn, "rke2-cp")], [An SSH session on the RKE2 server `rke2-cp` (`172.16.0.160`).],
  [#etikett(warn, "rke2-w1")], [An SSH session on the RKE2 agent `rke2-w1` (`172.16.0.161`).],
  [#etikett(lila, "Pod")], [A shell in a container, opened with `kubectl exec` or `kubectl debug`.],
)

There is no separate label for Talos. You never log in to a Talos node, `talosctl` always runs on the Mac.

#warum[
  With two clusters, the most common mistake is the wrong context. That is why every command names `--context rke2` or `--context talos` explicitly. This book never uses the active default context of `kubectl`. Make this a habit in your daily work too: a fix in the wrong cluster is worse than no fix at all.
]

== The Boxes

#symptom[What you see when the failure occurs. Every investigation starts here.]
#ursache[What is really behind it, and why Kubernetes behaves this way.]
#pruefe[The expected result. If your output differs, do not move on. Clear up the difference first.]
#warum[The background that helps you with the next, similar problem.]
#falle[What typically goes wrong and how you recognize it.]
#aufgabe[This is your turn. Think it through yourself first before you look things up.]

== How a Scenario Works

From chapter 4 on, every scenario follows the same pattern. You apply a file that contains a failure. Then you see the symptom, investigate it step by step and find the cause. Only then do you fix the failure and check the result. Do not read the cause ahead of time. You learn while searching, not while reading the solution.

Every scenario runs in its own namespace, for example `dbg-04` for chapter 4. Whatever you break there stays there. At the end of a chapter you clean up with a single command:

#cmd("Mac")[```bash
kubectl --context rke2 delete namespace dbg-04
kubectl --context talos delete namespace dbg-04
```][Deletes the namespace and every object in it, on both clusters.]

The chapters build on each other loosely. Read chapters 1 to 3 in order. After that you can jump around, for example straight to Kyverno in chapter 11 if that is what you are dealing with right now.

== What Was Tested and What Was Not

A book full of commands is only as good as its testing. So here is an honest account of how far that testing went.

*Tested on November 9, 2026:*
- All versions come from the official release pages and Helm repositories: RKE2, Talos, k9s, Kyverno, Falco, Traefik, metrics-server and local-path-provisioner.
- All Kubernetes manifests in the repo were checked with `kubeconform` against Kubernetes 1.36.
- All Kyverno policies pass `kyverno test` with Kyverno CLI 1.19.1 against the test resources in the repo.
- All Helm values were rendered with `helm template` against the chart versions given, and the shell scripts pass `shellcheck`.
- The Talos patches were merged into a complete configuration and checked with `talosctl validate`, though with `talosctl` 1.12. Commands that only Talos 1.14 knows were looked up in the 1.14.5 documentation and source code.
- Error messages from Kubernetes, Kyverno, Traefik and Helm were read in the source code of the versions given. Commands, flags and paths for RKE2, k9s and `kubectl` come from the official documentation and the CLIs themselves.

*Not tested:*
- The book was *not* run through on real clusters. All output in the boxes and code blocks are examples that follow the format of the real tools. Pod names, times and IDs will look different on your machine.
- The wording of error messages can change slightly between versions. The core, meaning the keyword such as `Insufficient cpu` or `violates PodSecurity`, usually stays the same.

So expect something to differ at some point. For this book that is a gift: it is a real failure, and you are holding the right tool to find it.

== What You Need

- Four VMs with fixed IP addresses on the same network:

#tabelle(
  (auto, auto, auto, 1fr),
  ([Role], [Hostname], [IP], [Size]),
  [RKE2 server], [`rke2-cp`], [`172.16.0.160`], [4 CPUs, 8 GB RAM, 60 GB disk, Ubuntu 24.04],
  [RKE2 agent], [`rke2-w1`], [`172.16.0.161`], [2 CPUs, 4 GB RAM, 40 GB disk, Ubuntu 24.04],
  [Talos control plane], [`talos-cp`], [`172.16.0.170`], [4 CPUs, 8 GB RAM, 60 GB disk, Talos ISO],
  [Talos worker], [`talos-w1`], [`172.16.0.171`], [2 CPUs, 4 GB RAM, 40 GB disk, Talos ISO],
)

- On the laptop: `kubectl`, `talosctl`, `helm`, `k9s`, `jq`, `curl`, `openssl` and `git`. For chapter 11 also the Kyverno CLI.
- SSH access to the two Ubuntu VMs with a user who can run `sudo`.
- Basic Kubernetes knowledge: you know what pods, deployments, services and namespaces are. The book explains everything else.

#hinweis("Different IP addresses?", akzent, akzent-hell)[
  The four addresses appear in the configurations under `labor/` and in many commands. If yours are different, replace them everywhere before you start chapter 2. A `grep -rn "172.16.0.1[67]" .` shows you every occurrence.
]
