#import "../lib.typ": *

#kapitel(
  [k9s as a Cockpit],
  ziel: [You move through both clusters in k9s without a mouse, filter, read logs including the previous run, open shells and port forwards and start a debug container with a single keystroke. You also know when `kubectl` is the better choice.],
  zeit: [45 minutes],
  braucht: [Chapter 2],
)

== Why a Second Tool

`kubectl` shows you a state at one point in time. For troubleshooting that is often not enough. You want to watch a pod restart or a rollout progress, and jump quickly between pod, logs, events and deployment while you do. That is exactly what k9s is built for: a terminal UI that refreshes every two seconds and puts every view a few keys away.

k9s talks to the same API as `kubectl` and uses the same kubeconfig. So it sees nothing that `kubectl` could not see, and it may do nothing your user is not allowed to do. Its only advantage is speed. That is why this book shows both paths in every scenario: `kubectl` for commands you want to document and repeat, k9s for a quick round through the cluster.

To have something to look at, first create a few practice objects:

#datei("szenarien/03-k9s/demo.yaml (excerpt)", ```yaml
kind: Deployment
metadata:
  name: web
  namespace: dbg-03
spec:
  replicas: 2
  # ... busybox httpd on port 8080, plus Service web (80 -> 8080)
---
kind: Deployment
metadata:
  name: wackel
  namespace: dbg-03
# ...
          command:
            - sh
            - -c
            - |
              echo "start"
              sleep 15
              echo "FEHLER: Cache voll, gebe auf" >&2
              exit 3
```, erklaerung: [
  `web` is a small web server with two replicas and a service. `wackel` (German for wobbly) crashes after 15 seconds with exit code 3 and ends up in `CrashLoopBackOff` after a few rounds. Its message means "ERROR: cache full, giving up". Both run without root so that Talos does not print warnings.
])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/03-k9s/demo.yaml
```][Creates the namespace `dbg-03`, both deployments and the service.]

== Starting and Finding Your Way

#cmd("Mac")[```bash
k9s --context rke2 -n dbg-03
```][Starts k9s in the context `rke2` and directly in the namespace `dbg-03`. Without `-n`, k9s opens the namespace you last used in this context. `-A` starts in all namespaces, `-c deploy` with a view other than pods.]

The screen has three areas. At the top left are the context, cluster, user and the versions of k9s and Kubernetes, and next to them the keys that apply in the current view. The middle shows the table, with a title above it listing the resource, namespace and number of objects. At the bottom, the *crumbs* show how you got here.

#falle[
  Before every action that changes something, look at the context at the top left. If you work with k9s in two terminals, one per cluster, it is easy to delete in the wrong one. One aid: k9s can load its own skin per context, for example red for the lab you are breaking right now.
]

You only need a few keys. `?` shows all keys of the current view. That is the most reliable source, because the key bindings depend on the resource and the version.

#tabelle(
  (auto, 1fr),
  ([Key], [Effect]),
  [`:`], [Command line: open a resource, for example `:deploy⏎`, `:svc⏎`, `:events⏎`],
  [`/`], [Filter the current table],
  [`Esc`], [Cancel the filter or command line, go back one view],
  [`Enter`], [Open an object: a pod shows its containers, a deployment shows its pods],
  [`?`], [Help for the current view],
  [`Ctrl-a`], [All resources and their aliases],
  [`-`], [Back to the previous command, like `cd -`],
  [`:q⏎` or `Ctrl-c`], [Quit k9s],
)

== Resources, Namespaces and Filters

After `:`, k9s accepts any name that `kubectl` also understands: singular, plural and short name. `:po`, `:pod` and `:pods` open the same view. CRDs work too, as soon as they are in the cluster, for example `:policyreports` in chapter 11.

#cmd("k9s")[```text
:deploy dbg-03⏎
:pods kube-system⏎
:pods app=web⏎
:pods /wackel⏎
```][Open a resource with a namespace, show pods by a label selector and filter the list right when you open it.]

There are three ways to switch the namespace. `0` shows all namespaces. The digits `1` to `9` jump to recently used namespaces, which k9s shows at the top in the key list. And `:ns⏎` lists all namespaces, where `u` makes the selected one the active one.

The `/` filter is the tool you will use most:

#tabelle(
  (auto, 1fr),
  ([Input], [Effect]),
  [`/web⏎`], [Only rows that contain `web`. Regular expressions are allowed, for example `web|wackel`.],
  [`/!Running⏎`], [Inverted: all rows that do *not* contain `Running`],
  [`/-l app=web⏎`], [Filter by labels],
  [`/-f wkl⏎`], [Fuzzy search],
  [`Ctrl-z`], [Show only objects with faults, a second `Ctrl-z` switches back],
)

#cmd("k9s")[```text
:pods⏎
0
/!Running|Completed⏎
```][All pods in all namespaces that are neither running nor completed. A good first round when you do not know what is broken in a cluster.]

You sort with capital letters: `Shift-s` by status, `Shift-a` by age, `Shift-n` by name. `Ctrl-w` shows additional columns, for pods for example IP and node. That corresponds to `kubectl get -o wide`.

== A Pod in Detail

In the pod view, select a pod of `wackel`. All of the following keys act on the selected row:

#tabelle(
  (auto, 1fr, auto),
  ([Key], [Effect], [kubectl equivalent]),
  [`d`], [Describe], [`describe pod`],
  [`y`], [YAML of the object including `status`], [`get -o yaml`],
  [`e`], [Edit in the editor], [`edit`],
  [`l`], [Logs], [`logs -f`],
  [`p`], [Logs of the previous run], [`logs --previous`],
  [`s`], [Shell in the container], [`exec -it ... -- sh`],
  [`a`], [Attach to the container], [`attach`],
  [`o`], [Jump to the pod's node], [`get node`],
  [`Shift-j`], [Jump to the owner, for example the ReplicaSet], [—],
  [`Shift-f`], [Set up a port forward], [`port-forward`],
  [`Ctrl-d`], [Delete, with confirmation], [`delete`],
  [`Ctrl-k`], [Delete immediately, *without* confirmation], [`delete --now`],
)

#cmd("k9s")[```text
:pods dbg-03⏎
/wackel⏎
d
```][Describe of the crashing pod. You scroll with the arrow keys, and `Esc` takes you back to the list.]

#pruefe[
  Under `Last State` it says `Terminated`, `Reason: Error`, `Exit Code: 3`. At the very bottom the event `BackOff` repeats with `Back-off restarting failed container wackel`.
]

`Enter` on a pod opens the container view. There, `l`, `p` and `s` apply to exactly one container. You need this for pods with sidecars or init containers. In the pod view, k9s otherwise picks the first container or asks you.

#falle[
  `s` starts `bash` if the image has one, otherwise `sh`. If the image has no shell at all, as with distroless images, this fails with an error message from `exec`. Then only a debug container helps. The plugin on `Shift-d`, described further down, is there for exactly that.
]

== Reading Logs

#cmd("k9s")[```text
:pods dbg-03⏎
/wackel⏎
p
```][Shows the log of the previous run. It contains the last line before the crash: `FEHLER: Cache voll, gebe auf`.]

The log view has keys of its own. They differ from the table, for example `w` here means line wrap and not namespace switch:

#tabelle(
  (auto, 1fr),
  ([Key], [Effect]),
  [`0`], [Follow from now on (tail)],
  [`1`], [From the beginning (head)],
  [`2` to `6`], [Time window: 1, 5, 15, 30 minutes, 1 hour],
  [`s`], [Autoscroll on or off],
  [`w`], [Wrap long lines],
  [`t`], [Show timestamps],
  [`f`], [Full screen],
  [`/`], [Filter the log lines],
  [`Ctrl-s`], [Save the log to a file],
)

Timestamps are almost always helpful when debugging. They show whether a failure just happened or has been going on for hours. If you always want to see them, set `showTime: true` under `k9s.logger` in the k9s `config.yaml`. There you also set how many lines k9s loads when it opens the log with `tail`, and line wrapping with `textWrap`.

== Events, XRay and Pulses

#cmd("k9s")[```text
:events dbg-03⏎
```][Events of the namespace as a table that keeps updating. `Ctrl-z` shows only warnings and errors.]

Two views exist only in k9s. *XRay* shows objects as a tree: deployment, below it the ReplicaSet, below that the pods with their containers, ConfigMaps, Secrets and the ServiceAccount. A red element in the tree takes you straight to the cause. This helps especially when a deployment was accepted but no pods get created.

#cmd("k9s")[```text
:xray deploy dbg-03⏎
```][Tree of all deployments in `dbg-03`. Allowed are, among others, `po`, `svc`, `dp`, `rs`, `sts` and `ds`.]

*Pulses* (`:pulses⏎`) shows small trend charts for nodes, namespaces, services, events, pods, deployments, StatefulSets, DaemonSets, jobs, PVCs and other objects, each with the number of healthy and faulty ones, plus CPU and memory if a metrics-server is running. It is not a tool for a single cause, but a good way to see whether a rollout is making waves right now.

Older guides mention `:popeye` for checking the whole cluster. k9s 0.51 no longer includes this view. If you want to use Popeye, run it as a separate program.

== Port Forward

#cmd("k9s")[```text
:svc dbg-03⏎
/web⏎
Shift-f
```][Opens the dialog for a port forward to the service `web`. Enter `8080` under `Local Port` and confirm with `OK`.]

#cmd("Mac")[```bash
curl -s localhost:8080
```][A second terminal queries the web server through the port forward.]

#pruefe[
  The answer is `hallo aus web-…` ("hello from web-…") with the name of one of the two pods. The `f` key in the service or pod view shows all active port forwards, and so does `:pf⏎`. There you end one with `Ctrl-d`. Port forwards only live as long as k9s does.
]

== Contexts and Read-Only

`:ctx⏎` lists all contexts from your kubeconfig, and `Enter` switches. `:ctx talos⏎` is faster. k9s remembers the namespace and view separately for each context.

For this book I still recommend two terminals with one k9s each: `k9s --context rke2` and `k9s --context talos`. Then you see both clusters side by side and never have to think about where you are.

If you only want to look around in someone else's cluster or a production cluster, start k9s read-only:

#cmd("Mac")[```bash
k9s --context talos --readonly
```][Turns off all actions that change something: edit, delete, kill, shell, attach and all plugins marked as `dangerous`. To make it permanent, set `readOnly: true` in `config.yaml`, and `--write` lifts it again for a single start.]

#warum[
  Read-only does not protect against curiosity, it protects against typos. `Ctrl-k` deletes without asking. In a cluster where you are only looking for failures, there is no reason to take that risk.
]

== This Book's Plugins

Plugins bind your own commands to a key. k9s replaces variables like `$NAME`, `$NAMESPACE`, `$CONTEXT` and, in the container view, `$POD` with the values of the selected row. You copied the file `k9s/plugins.yaml` to `~/Library/Application Support/k9s/` in chapter 2. It defines three plugins:

#tabelle(
  (auto, auto, 1fr),
  ([Key], [View], [Effect]),
  [`Shift-d`], [Pods], [Plugin `netshoot`: starts `nicolaka/netshoot:v0.15` as an ephemeral container in the selected pod. Shares the pod's network.],
  [`Shift-d`], [Containers], [Plugin `netshoot-target`: as above, but also with `--target` on the selected container. Sees its processes.],
  [`Shift-e`], [Pods, deployments, ReplicaSets, StatefulSets, DaemonSets, jobs, services, PVCs], [Plugin `events`: `kubectl events --for` exactly this object, in chronological order, in `less`. Quit with `q`.],
)

#datei("k9s/plugins.yaml (excerpt)", ```yaml
plugins:
  netshoot:
    shortCut: Shift-D
    description: netshoot debug
    scopes:
      - pods
    dangerous: true
    confirm: true
    background: false
    command: kubectl
    args:
      - debug
      - -it
      - --context
      - $CONTEXT
      - -n
      - $NAMESPACE
      - $NAME
      - --image=nicolaka/netshoot:v0.15
      - --profile=baseline
  # ... netshoot-target (containers) and events
```, erklaerung: [
  `scopes` defines the views in which the key applies. `confirm: true` shows the finished command before it starts and asks for confirmation. `dangerous: true` hides the plugin in read-only mode, because an ephemeral container changes the pod permanently. `--profile=baseline` is needed because Talos otherwise rejects the debug container (chapter 1). `background: false` hands the terminal over to `kubectl` until you leave the shell with `exit`.
])

The keys are chosen so that they do not collide with any k9s 0.51 binding. That matters: if a plugin uses a key that k9s already uses in that view, k9s does not load the plugin, shows `Plugins load failed!` at the top right and writes the reason (`duplicate plugin key`) to the log. Only with `override: true` does the plugin replace the built-in function. If a plugin is missing, use `?` to check whether the key appears, and look in the log file whose path `k9s info` shows.

#cmd("k9s")[```text
:pods dbg-03⏎
/web⏎
Shift-d
```][Select one of the `web` pods and press `Shift-d`. Confirm the command shown. After a few seconds you land in a netshoot shell.]

#cmd("Pod")[```bash
ss -ltn
curl -s localhost:8080
exit
```][`ss` shows the web server listening on port 8080 in the *other* container. Both share the pod's network, which is why `curl` reaches it through `localhost`. With `exit` you return to k9s.]

#pruefe[
  `ss -ltn` lists a line with `*:8080` in the state `LISTEN`, and `curl` returns `hallo aus web-…`. A `describe` of the pod (`d`) then shows a section `Ephemeral Containers` with the debug container in the state `Terminated`. Ephemeral containers cannot be removed. They only go away with the pod.
]

Finally, try `Shift-e` on the deployment `wackel` in the `:deploy⏎` view. You see the events of the deployment itself, meaning the scaling of the ReplicaSet, not those of the pods. On the pod, the same key shows the `BackOff` events. This separation is intentional and helps you in chapters 10 and 11, when pods are not even created.

== Where kubectl Is Better

k9s does not replace `kubectl`. For some tasks the command line is clearly superior:

- *Documenting and sharing.* A command with its output can be copied into a ticket and repeated by others. A sequence of keystrokes cannot.
- *Scripts and loops.* Anything you repeat across several clusters or namespaces belongs in `kubectl` with `-o jsonpath` or `-o json`.
- *Questions to the API.* `kubectl explain`, `kubectl auth can-i --as`, `kubectl get --raw '/readyz?verbose'` and `kubectl debug --copy-to` have no counterpart in k9s.
- *State after a restart.* Like `--previous`, `p` shows exactly one previous run. Combinations like `--previous --all-containers --since=10m` only work with `kubectl`.
- *Short events.* k9s refreshes in two-second intervals. A pod that exists for only one second can disappear in between. `kubectl get pods -w` and events show every change.

And k9s only sees what your user is allowed to see. If a view stays empty even though `kubectl` with admin rights shows objects, the cause is RBAC, not k9s.

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-03
```][Cleans up. In k9s you would do this with `:ns⏎`, selecting the namespace and pressing `Ctrl-d`.]

#aufgabe[
  Apply `szenarien/03-k9s/demo.yaml` to `talos` and work only in `k9s --context talos`. Find out which node the `wackel` pod runs on (`o`), how often it has restarted already, and read the last log line before the crash. Then start `Shift-d` on a `web` pod and use `dig web.dbg-03.svc.cluster.local` to check whether the service name resolves. Hint: without `--profile=baseline` in the plugin, Talos would reject the debug container with `violates PodSecurity "baseline:latest"`. Delete the namespace afterwards.
]

#gelernt(
  [k9s uses the same API and kubeconfig as `kubectl`. Its advantage is speed, not extra knowledge.],
  [`:` opens resources, `/` filters (also `/!`, `/-l`), `0` shows all namespaces, `Ctrl-z` only faults, `?` the keys of the view.],
  [`d`, `y`, `l` and `p` cover most investigations. `p` corresponds to `kubectl logs --previous`.],
  [`--readonly` turns off actions that change something and dangerous plugins.],
  [This book's plugins: `Shift-d` starts netshoot in the pod or, with `--target`, in the container, and `Shift-e` shows the events of an object.],
  [For documentation, scripts and API questions like `auth can-i`, `kubectl` is the better choice.],
)
