#import "../lib.typ": *

#kapitel(
  [The Method],
  ziel: [You assign every symptom to a layer of the cluster, know the basic `kubectl` tools for each layer and read pod status, container state and exit code correctly. A small example shows the process from start to finish.],
  zeit: [45 minutes],
  braucht: [Basic Kubernetes knowledge; for the example, the lab from Chapter 2],
)

== Guessing or Narrowing Down

When you face a pod in `CrashLoopBackOff` for the first time, it is tempting to just try things: rebuild the image, delete the pod, reapply the deployment. Sometimes that even helps. But you have not understood anything, and next time you start from scratch again.

This book works differently. Every failure goes through the same five steps:

#tabelle(
  (auto, 1fr),
  ([Step], [What you do]),
  [Reproduce], [Trigger the failure on purpose. If you cannot trigger it, you cannot reliably declare it fixed either.],
  [Investigate], [Commands in a fixed order, from the outside in. You collect facts, not guesses.],
  [Understand], [Name the cause in two or three sentences, including the mechanism behind it.],
  [Fix], [The smallest change that removes the cause. Not the symptom.],
  [Verify], [Show that it works again, using the same signal where you saw the failure.],
)

The most important step is the second one. Good troubleshooters are not faster at guessing. They ask better questions in a better order. Every question cuts the space of possible causes in half. After three or four questions, usually only one is left.

#warum[
  While you search, jot down what you checked and what came out of it. It sounds tedious, but it keeps you from running the same command three times. And if you hand the case over to a colleague, half the analysis is already done.
]

== The Map

A Kubernetes cluster consists of layers that build on each other. Almost every symptom belongs to one of them. If you know the layer, you also know the first commands.

#tabelle(
  (auto, 1fr, 1fr, auto),
  ([Layer], [Typical symptom], [First question], [Chapter]),
  [Scheduling], [Pod stays `Pending`], [Why does the scheduler not find a node?], [4],
  [Image and runtime], [`ImagePullBackOff`, `CreateContainerConfigError`], [Can the node pull the image and create the container?], [5],
  [Workload], [`CrashLoopBackOff`, `OOMKilled`, not ready], [What does the process itself say, and how does it end?], [6],
  [Network], [Timeout, `connection refused`, DNS error], [Does the packet arrive, and does anyone answer?], [7, 8],
  [Storage], [PVC `Pending`, `Permission denied`], [Is there a volume, and may the process write to it?], [9],
  [Policy and admission], [`Forbidden`, `denied the request`], [Who rejected it: RBAC, Pod Security or a webhook?], [10, 11],
  [Runtime], [Falco alert, process behaves unexpectedly], [Is this an attack or a legitimate workflow?], [12],
  [Node], [`NotReady`, evictions, `Unknown`], [Is the kubelet alive, and does the node have enough resources?], [13],
  [Control plane], [`kubectl` hangs, changes do not arrive], [Are the API server, etcd and webhooks healthy?], [14],
  [Rollout], [Deployment stuck, HPA shows `<unknown>`], [Is the controller waiting for something that never happens?], [15],
)

The layers have a direction. A failure further down often shows up further up. A node with a full disk leads to evictions, which you first see as pods that disappeared. A hanging webhook in the control plane makes every `kubectl apply` fail, even though your manifests are fine. So you start at the top with the symptom, but you are ready to go one layer deeper as soon as the facts point there.

=== From the Outside In

The investigation follows a fixed order. It is chosen so that every step is cheap and prepares the next one:

+ `kubectl get`: What is the state, and since when?
+ `kubectl describe`: What does Kubernetes know about this object, and which events are attached to it?
+ `kubectl events`: What happened around it, including objects you have not looked at yet?
+ `kubectl logs`: What does the process say, including the previous run?
+ `kubectl debug`: What does it look like from the inside, in the network and file system of the pod?
+ Node: kubelet, containerd, kernel. On RKE2 via SSH, on Talos with `talosctl`.
+ Control plane: API server, etcd, webhooks.

Most failures are explained after step 4. You rarely need steps 6 and 7, but when you do, you need them urgently. That is why you practice them in chapters 13 and 14 on a healthy cluster, before things get serious.

== Phase, State and Reason

The `STATUS` column of `kubectl get pods` is a summary that `kubectl` builds from several fields. If you read it as a single field, you draw the wrong conclusions. There are three levels behind it:

#tabelle(
  (auto, auto, 1fr),
  ([Level], [Field], [Values]),
  [Pod phase], [`status.phase`], [`Pending`, `Running`, `Succeeded`, `Failed`, `Unknown`. Only these five.],
  [Container state], [`status.containerStatuses[].state`], [Exactly one of `waiting`, `running`, `terminated`],
  [Reason], [`state.waiting.reason`, `state.terminated.reason`], [`ContainerCreating`, `ImagePullBackOff`, `CrashLoopBackOff`, `CreateContainerConfigError`, `Completed`, `Error`, `OOMKilled` and others],
)

A pod in `CrashLoopBackOff` has the phase `Running`. That surprises many people. The phase only says that the pod is assigned to a node and at least one container has started or is restarting right now. The container itself is in `waiting` with the reason `CrashLoopBackOff`, and `kubectl` shows that reason in the `STATUS` column. `Terminating` is not a phase either. `kubectl` shows it as soon as the pod has a `deletionTimestamp`.

For the cause, `lastState` often matters more than the current state. It tells you how the previous run of the container ended:

#cmd("Mac")[```bash
kubectl --context rke2 get pod <pod> -n dbg-01 \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
```][Shows reason, exit code, start and end time of the last terminated run. `describe` shows the same under `Last State`, but here you get it in machine-readable form, for example for a script.]

== Exit Codes

When a process in the container ends, the runtime reports its exit code to the kubelet. If the process was killed by a signal, the code is 128 plus the signal number, following the Unix convention. You should know these seven codes by heart:

#tabelle(
  (auto, auto, 1fr),
  ([Code], [Meaning], [Typical cause]),
  [`0`], [Exited normally], [Correct for a job. For a deployment it is a failure: the main process must not end, otherwise Kubernetes restarts it.],
  [`1`], [General error], [The application aborted on its own. The answer is almost always in the log, often in the previous one.],
  [`126`], [Not executable], [File found, but no execute permission, or a script without a matching interpreter.],
  [`127`], [Command not found], [Typo in the `command`, program missing from the image. The shell in the container reports `not found`.],
  [`137`], [SIGKILL (128 + 9)], [With reason `OOMKilled`: memory limit exceeded. Without it: killed hard, for example because the process did not react to SIGTERM after a failed liveness probe.],
  [`139`], [SIGSEGV (128 + 11)], [Segmentation fault, usually a bug in native code, for example in a C library the application uses.],
  [`143`], [SIGTERM (128 + 15)], [Shut down in an orderly way, for example during a rollout or by `kubectl delete`. Rarely a failure.],
)

#falle[
  A container whose program cannot even be started, for example because the path in `command` does not exist and there is no shell in between, does not end with 127. containerd then reports the reason `StartError` with exit code `128` and a message like `executable file not found in $PATH`. Only when a shell looks up the command, as with `sh -c`, do you get the 127.
]

== The Basic Tools

All commands in this section work the same against both clusters. The examples show `--context rke2`. For Talos you only swap the context.

=== get

#cmd("Mac")[```bash
kubectl --context rke2 get pods -n dbg-01 -o wide
```][`-o wide` adds the pod IP and the node. This shows you right away whether all broken pods are on the same node. If they are, the cause is more likely the node than the application.]

In the output, watch `READY` (how many containers are ready), `RESTARTS` (with the time of the last restart) and `AGE`. A pod with 40 restarts in two hours has a different problem than one that crashed for the first time five minutes ago. With `-w` you watch changes live, with `-o yaml` you see the complete object including `status`.

=== describe

#cmd("Mac")[```bash
kubectl --context rke2 describe pod <pod> -n dbg-01
```][Summarizes the spec, the status of all containers, the conditions and the events of the pod. Read from bottom to top: first the events, then `State` and `Last State` of the containers.]

`describe` only shows events that are attached directly to this object. If, for example, Pod Security rejects a pod, the pod is never created. The event is then attached to the ReplicaSet, and a `describe` on the pod is impossible because it does not exist. That is why the next command always belongs in the routine.

=== events

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-01
kubectl --context rke2 events -n dbg-01 --for pod/<pod>
kubectl --context rke2 events -A --types=Warning
```][`kubectl events` lists events sorted by time, newest at the bottom. `--for` filters on one object, `--types=Warning` hides the normal messages. `-A` searches all namespaces.]

The older `kubectl get events` does not sort by time. If you still need it, for example for a particular output format, add `--sort-by=.lastTimestamp`.

#falle[
  Events are short-lived. By default the API server deletes them after one hour. A failure from last night has no events left this morning. Then all you have is `status`, the logs and, if you have one, a central logging system.
]

=== logs

#cmd("Mac")[```bash
kubectl --context rke2 logs <pod> -n dbg-01
kubectl --context rke2 logs <pod> -n dbg-01 --previous
kubectl --context rke2 logs <pod> -n dbg-01 -c <container>
kubectl --context rke2 logs <pod> -n dbg-01 --all-containers --since=10m
kubectl --context rke2 logs deploy/app -n dbg-01 --tail=50
```][The first command shows the log of the running container. If the container keeps restarting, that log is often empty or only shows the beginning. The cause is then in the previous run: `--previous`. With several containers you pick one with `-c` or use `--all-containers`. `deploy/app` picks one pod of the deployment.]

The kubelet keeps exactly one log from the previous run. If the pod is deleted and recreated, for example by a rollout, that one is gone too. This applies to `kubectl` and k9s alike.

=== debug

Many images contain no shell and no tools. `kubectl exec` does not help then. `kubectl debug` attaches an additional container with your tool image:

#cmd("Mac")[```bash
kubectl --context rke2 debug -it <pod> -n dbg-01 \
  --image=nicolaka/netshoot:v0.15 --profile=baseline --target=app
```][Starts an ephemeral container with netshoot in the running pod. It shares the pod's network. With `--target` it also sees the processes of the container `app`, for example with `ps`.]

#tabelle(
  (auto, 1fr),
  ([Variant], [What for]),
  [`kubectl debug <pod> --image=...`], [Ephemeral container in the running pod. Shares the network and, with `--target`, the processes too.],
  [`kubectl debug <pod> --copy-to=<new> ...`], [Copy of the pod, optionally with a different image (`--set-image`) or a different command. Useful when the original pod crashes immediately.],
  [`kubectl debug node/<node> ...`], [Pod with host namespaces on a node, the node's file system is under `/host`.],
)

#falle[
  Without `--profile`, `kubectl debug` uses the `general` profile. It adds the capability `SYS_PTRACE` to the debug container. Pod Security at the `baseline` level does not allow this capability, and Talos enforces `baseline` in every namespace except `kube-system`. There the API server rejects the debug container. With `--profile=baseline` it works on both clusters. `kubectl debug node/`, on the other hand, needs host namespaces and fails on Talos in a normal namespace. Chapter 13 shows how to deal with that.
]

=== explain, auth can-i and the API Server

Three commands round out the toolkit. You need them less often, but they answer questions that otherwise take a long time:

#cmd("Mac")[```bash
kubectl --context rke2 explain pod.spec.containers.startupProbe
```][Shows the documentation of a field straight from the API server's schema, matching the cluster's version. Faster than any web search, and it applies to exactly this cluster, CRDs included.]

#cmd("Mac")[```bash
kubectl --context rke2 auth can-i list pods -n dbg-01 \
  --as=system:serviceaccount:dbg-01:default
```][Asks whether a specific user or ServiceAccount may perform an action. The answer is `yes` or `no`. With `--list` you see all permissions. More on this in chapter 10.]

#cmd("Mac")[```bash
kubectl --context rke2 get --raw '/readyz?verbose'
```][Asks the API server for its internal checks. Every line starts with `[+]` (OK) or `[-]` (failed), and at the end it says `readyz check passed`. If etcd or an informer is stuck here, no amount of searching in your pods will help.]

== An Example from Start to Finish

A small case shows the process. An application expects an environment variable `DB_HOST`. If it is missing, the application aborts with a message. The lab from chapter 2 has to be running for this. Read the example now anyway, and replay it as soon as the clusters are up.

#datei("szenarien/01-methode/kaputt.yaml (excerpt)", ```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: dbg-01
spec:
  # ...
      containers:
        - name: app
          image: busybox:1.37
          command:
            - sh
            - -c
            - |
              if [ -z "$DB_HOST" ]; then
                echo "FEHLER: DB_HOST ist nicht gesetzt" >&2
                exit 1
              fi
              echo "verbinde mit $DB_HOST"
              sleep 3600
```, erklaerung: [
  The file first creates the namespace `dbg-01`. Pod and container run without root and without capabilities. That way the pod meets the `restricted` level, and Talos does not print warnings when you apply it. The messages are German, as in the whole repo: `FEHLER: DB_HOST ist nicht gesetzt` means "ERROR: DB_HOST is not set", and `verbinde mit` means "connecting to".
])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/01-methode/kaputt.yaml
```][Creates the namespace and the deployment.]

#symptom[
  ```text
  NAME                   READY   STATUS             RESTARTS      AGE
  app-6b8f9c7d54-x7kqp   0/1     CrashLoopBackOff   3 (21s ago)   88s
  ```
  The pod is never ready, the restarts go up, and the intervals between them get longer.
]

The status `CrashLoopBackOff` only says that the container ends repeatedly and the kubelet is waiting before the next start. Why it ends is written somewhere else. First question: how did the last run end?

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-01 -l app=app
```][`-l` selects the pod by its label, so you do not have to type the name.]

```text
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
...
Events:
  Type     Reason   Age                From     Message
  ----     ------   ----               ----     -------
  Warning  BackOff  12s (x6 over 85s)  kubelet  Back-off restarting failed container app in pod ...
```

Exit code `1`, reason `Error`, no `OOMKilled`. The image was pulled, the container started. That rules out scheduling, image and runtime. The process itself gave up. Next question: what did it say?

#cmd("Mac")[```bash
kubectl --context rke2 logs -n dbg-01 deploy/app --previous
```][The log of the previous run that crashed.]

```text
FEHLER: DB_HOST ist nicht gesetzt
```

#ursache[
  The application checks at startup whether `DB_HOST` is set and otherwise exits with exit code 1. The deployment does not set the variable. Because a deployment has `restartPolicy: Always`, the kubelet starts the container again and again and stretches the pause between attempts up to five minutes.
]

The fix is the missing variable, not a restart of the pod. The file `fix.yaml` contains the same deployment with an `env` block:

#datei("szenarien/01-methode/fix.yaml (excerpt)", ```yaml
          env:
            - name: DB_HOST
              value: db.dbg-01.svc.cluster.local
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/01-methode/fix.yaml
kubectl --context rke2 rollout status deploy/app -n dbg-01
```][The change to the pod template triggers a rollout. `rollout status` waits until the new pod is ready.]

#pruefe[
  - `rollout status` reports `deployment "app" successfully rolled out`.
  - `get pods -n dbg-01` shows a new pod: `1/1`, `Running`, `0` restarts.
  - `logs -n dbg-01 deploy/app` prints `verbinde mit db.dbg-01.svc.cluster.local`.
]

On Talos the example runs the same way. Repeat it with `--context talos` if you like. Then clean up:

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-01
kubectl --context talos delete ns dbg-01 --ignore-not-found
```][Deletes the namespace together with the deployment and pods.]

The investigation took three commands. Each one answered a question and ruled out a layer. That is exactly how all scenarios in this book work, except that the questions get harder.

#aufgabe[
  In a copy of `kaputt.yaml`, change the command so that the line `slep 3600` runs instead of `exit 1`, and apply it. Which exit code do you expect before you look? Check your guess with `describe` and `logs --previous`. Hint: the shell reports `sh: slep: not found` and ends with 127. Delete the namespace again afterwards.
]

#gelernt(
  [Every failure goes through five steps: reproduce, investigate, understand, fix, verify.],
  [The map assigns a symptom to a layer: scheduling, image and runtime, workload, network, storage, policy, node, control plane.],
  [The investigation goes from the outside in: `get`, `describe`, `events`, `logs`, `debug`, then node and control plane.],
  [`STATUS` is a summary. Pod phase, container state and reason are three different levels, and `lastState` explains the previous run.],
  [Exit codes above 128 mean a signal. 137 with `OOMKilled` is the memory limit, 137 without it is a hard kill.],
  [On Talos, `kubectl debug` needs `--profile=baseline`, because the default profile adds a capability that Pod Security `baseline` forbids.],
)
