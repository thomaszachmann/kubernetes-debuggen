#import "../lib.typ": *

#kapitel(
  [Failures Caused by Kyverno],
  ziel: [You recognize when Kyverno is behind a rejection or an unexpected change, read its messages, find the responsible policy, get back into the cluster when the webhook is down and test policies in advance without a cluster.],
  zeit: [75 minutes],
  braucht: [Chapters 2, 3 and 10],
)

== What Breaks in This Chapter

Kyverno is an admission webhook. The API server sends it every matching request before it stores it. Kyverno can reject (`ValidatingPolicy`), change (`MutatingPolicy`) or, if it does not answer, bring the cluster to a halt. To users, all three cases at first look like “Kubernetes is acting up”.

#tabelle(
  (auto, 1fr, 1fr),
  ([Scenario], [Symptom], [Where the answer is]),
  [Policy rejects Deployment], [`apply` fails immediately], [`admission webhook "vpol..." denied the request`],
  [Policy rejects only pods], [Deployment `0/1`, no pod], [Event `FailedCreate` on the ReplicaSet],
  [Mutation changes the pod], [`CreateContainerConfigError`], [Live object versus manifest, `kubectl get mpol`],
  [Webhook unreachable], [*Every* change in `dbg-11` fails], [`failed calling webhook`, `failurePolicy`],
  [PolicyException has no effect], [Exception created, pods still rejected], [Warning during `apply`, startup arguments],
)

All policies in this chapter are under `policies/` and apply only in the namespace `dbg-11`. Create each policy at the start of its scenario and delete it again at the end, so that the scenarios do not interfere with each other.

== Installing Kyverno

#datei("werkzeuge/kyverno-values.yaml (excerpt)", ```yaml
admissionController:
  replicas: 1
backgroundController:
  replicas: 1
# ... cleanupController, reportsController likewise
features:
  policyExceptions:
    enabled: false
    namespace: ""
```, erklaerung: [One instance per controller saves memory in the lab. The price: if the admission controller fails, nobody answers webhook requests anymore. PolicyExceptions stay off for now, as the chart's default. You need that in the last scenario.])

#cmd("Mac")[```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
for ctx in rke2 talos; do
  helm --kube-context $ctx upgrade --install kyverno kyverno/kyverno \
    -n kyverno --create-namespace --version 3.9.2 \
    -f werkzeuge/kyverno-values.yaml --wait --timeout 5m
done
```][Chart 3.9.2 ships Kyverno 1.19.2. The loop installs the same version on both clusters.]

#cmd("Mac")[```bash
kubectl --context rke2 get deploy -n kyverno
```][Four Deployments: `kyverno-admission-controller`, `kyverno-background-controller`, `kyverno-cleanup-controller`, `kyverno-reports-controller`, each `1/1`.]

The Kyverno pods meet `restricted`, so there are no PSA warnings on Talos. On both clusters, Kyverno excludes `kube-system` and `kyverno` itself.

#falle[
  Many guides still use `kind: ClusterPolicy` from `kyverno.io/v1`. In Kyverno 1.19 it is deprecated, and `kubectl apply` warns with `kyverno.io/v1 ClusterPolicy is deprecated and will be removed in a future release`. This chapter uses the CEL-based policies from `policies.kyverno.io/v1`, whose messages look different.
]

== Policy Rejects the Deployment

#datei("policies/require-team-label.yaml (excerpt)", ```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: require-team-label
spec:
  validationActions: [Deny]
  matchConstraints:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: In
          values: [dbg-11]
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
  validations:
    - message: Pods brauchen das Label team.
      expression: >-
        object.metadata.?labels.team.orValue('') != ''
```, erklaerung: [The policy checks only pods. But Kyverno automatically generates the same rule for Deployments, StatefulSets, DaemonSets, Jobs and CronJobs. This is called autogen, and it is the default for CEL policies when exactly one rule matches `pods` without an `objectSelector`. The message is German, as in the whole repo: "Pods need the label team."])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f policies/require-team-label.yaml
kubectl --context rke2 apply -f szenarien/11-kyverno/kaputt-label.yaml
```][The Deployment `web` has only the label `app` in its pod template.]

#symptom[
```text
namespace/dbg-11 created
Error from server: error when creating "szenarien/11-kyverno/kaputt-label.yaml": admission webhook
"vpol.validate.kyverno.svc-fail" denied the request: Policy require-team-label failed: Pods
brauchen das Label team.
```
]

=== Investigate

The message already contains everything: the webhook name starts with `vpol` (ValidatingPolicy, `mpol` for MutatingPolicy, just `validate.kyverno.svc` for old ClusterPolicies), and the suffix `-fail` stands for `failurePolicy: Fail`. Then come the name of the policy and its `message` text, word for word.

#cmd("Mac")[```bash
kubectl --context rke2 get vpol
kubectl --context rke2 get vpol require-team-label -o jsonpath='{.status.autogen}{"\n"}'
```][`vpol` is the short form of `validatingpolicies`, and the `READY` column should show `True`. `status.autogen` lists the controllers for which Kyverno generated the rule as well.]

#cmd("k9s")[```text
:vpol⏎             select require-team-label, y = YAML
:polr dbg-11⏎      policy reports in the namespace
```][k9s knows the Kyverno CRDs by their short names. In the YAML view, you search for `message` with `/`.]

#falle[
  Old ClusterPolicies answer with `resource Deployment/dbg-11/web was blocked due to the following policies`, followed by the policy, the rule and `validation error: ... failed at path ...`. If there are several CEL policies with different selectors in the cluster, Kyverno appends a short hash to the webhook name, for example `vpol.validate.kyverno.svc-fail-1a2b3c4d`.
]

#ursache[
  The pod template contains no label `team`. Because of autogen, Kyverno already checks the Deployment and not only the pod. For that, the expression from the policy was rewritten to `object.spec.template.metadata`. That is why `apply` fails immediately and visibly.
]

=== Fix

#datei("szenarien/11-kyverno/fix-label.yaml (excerpt)", ```yaml
  template:
    metadata:
      labels:
        app: web
        team: shop
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/11-kyverno/fix-label.yaml
```][This time you get `deployment.apps/web created`.]

#pruefe[
  `kubectl --context rke2 get pods -n dbg-11 -l app=web` shows one pod in `Running`. Then clean up: `kubectl --context rke2 delete -f policies/require-team-label.yaml`.
]

== Policy Rejects Only the Pods

The more dangerous case is when Kyverno lets the Deployment through and only rejects the pods. Then the developer sees `created`, the pipeline is green, and still nothing runs.

#datei("policies/require-memory-limit.yaml (excerpt)", ```yaml
  matchConstraints:
    objectSelector:
      matchExpressions:
        - key: policy.nyrvex.com/skip
          operator: DoesNotExist
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
  validations:
    - message: Jeder Container braucht ein Memory-Limit.
      expression: >-
        object.spec.containers.all(c,
          c.?resources.?limits.?memory.orValue('') != '')
```, erklaerung: [Someone wanted to build in an opt-out by label and added an `objectSelector`. With an `objectSelector`, Kyverno turns autogen off, because labels on the Deployment and labels on the pod are different things. The message means "Every container needs a memory limit."])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f policies/require-memory-limit.yaml
kubectl --context rke2 apply -f szenarien/11-kyverno/kaputt-limit.yaml
```][The Deployment `api` sets no memory limit.]

#symptom[
```text
$ kubectl --context rke2 get deploy,rs -n dbg-11 -l app=api
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/api   0/1     0            0           25s

NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/api-6c8d9f7b54   1         0         0       25s
```
]

=== Investigate

The same pattern as with PSA in Chapter 10: no pod, so look at the events on the ReplicaSet.

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-11 --for replicaset/api-6c8d9f7b54
```][Insert the name of your ReplicaSet, or use the `Shift-E` plugin on the ReplicaSet in k9s.]

```text
LAST SEEN   TYPE      REASON         OBJECT                      MESSAGE
8s          Warning   FailedCreate   ReplicaSet/api-6c8d9f7b54   Error creating: admission webhook
"vpol.validate.kyverno.svc-fail" denied the request: Policy require-memory-limit failed: Jeder
Container braucht ein Memory-Limit.
```

A policy's status tells you whether it also checks controllers. For `require-memory-limit`, `status.autogen` stays empty:

#cmd("Mac")[```bash
kubectl --context rke2 get vpol require-memory-limit -o jsonpath='{.status.autogen}{"\n"}'
```][Empty or `{}` means: this policy sees only pods. Compare it with `require-team-label` from the first scenario.]

#ursache[
  The policy applies only to pods and, because of the `objectSelector`, has no autogen rules. The Deployment and the ReplicaSet pass Kyverno, and only the pod creation by the ReplicaSet controller is rejected. That is why the message does not end up in your terminal, but as an event on the ReplicaSet. For users, a rejection during `apply` is much friendlier, so autogen should only be missing for a good reason.
]

=== Fix

#datei("szenarien/11-kyverno/fix-limit.yaml (excerpt)", ```yaml
          resources:
            limits:
              memory: 128Mi
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/11-kyverno/fix-limit.yaml
```][New pod template, so a new ReplicaSet. The old one stays around with `0` replicas.]

#pruefe[
  `kubectl --context rke2 get pods -n dbg-11 -l app=api` shows `1/1 Running`. Then: `kubectl --context rke2 delete -f policies/require-memory-limit.yaml`.
]

== Mutation Changes the Pod Unexpectedly

The platform team rolls out a “secure default”: every pod in `dbg-11` gets `runAsNonRoot: true`. Well meant, but the application team knows nothing about it.

#datei("policies/add-run-as-non-root.yaml (excerpt)", ```yaml
apiVersion: policies.kyverno.io/v1
kind: MutatingPolicy
metadata:
  name: add-run-as-non-root
spec:
  # ... matchConstraints as above, CREATE only
  mutations:
    - patchType: ApplyConfiguration
      applyConfiguration:
        expression: >-
          Object{
            spec: Object.spec{
              securityContext: Object.spec.securityContext{
                runAsNonRoot: true
              }
            }
          }
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f policies/add-run-as-non-root.yaml
kubectl --context rke2 apply -f szenarien/11-kyverno/kaputt-mutation.yaml
```][The Deployment `shop` uses the normal image `nginx:1.29-alpine`, which starts as root. The manifest contains no `securityContext`.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-11 -l app=shop
NAME                   READY   STATUS                       RESTARTS   AGE
shop-7b9c6d5f8-2kx9p   0/1     CreateContainerConfigError   0          20s
```
]

=== Investigate

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-11 -l app=shop | tail -3
```][The kubelet message at the end explains the status.]

```text
  Warning  Failed     4s (x3 over 20s)  kubelet  Error: container has runAsNonRoot and image will run as
root (pod: "shop-7b9c6d5f8-2kx9p_dbg-11(5c1e9a7d-...)", container: shop)
```

The team swears it never set `runAsNonRoot`. So you compare the manifest and the live object:

#cmd("Mac")[```bash
grep -c runAsNonRoot szenarien/11-kyverno/kaputt-mutation.yaml
kubectl --context rke2 get deploy shop -n dbg-11 \
  -o jsonpath='{.spec.template.spec.securityContext}{"\n"}'
```][In the manifest: `0` matches. In the cluster: `{"runAsNonRoot":true}`. Something changed the object between `apply` and storage.]

Even the Deployment is changed, not just the pod: autogen also applies to MutatingPolicies. Only mutating webhooks change objects when they are created. `kubectl --context rke2 get mpol` lists the Kyverno mutations, and `kubectl --context rke2 get mutatingwebhookconfigurations` lists all other candidates.

You confirm the suspicion offline with the Kyverno CLI. It shows the object as it would look after the mutation:

#cmd("Mac")[```bash
kyverno apply policies/add-run-as-non-root.yaml \
  --resource szenarien/11-kyverno/kaputt-mutation.yaml \
  --values-file policies/values-dbg-11.yaml
```][Offline, the CLI knows no namespace labels. `values-dbg-11.yaml` tells it that `dbg-11` carries the label `kubernetes.io/metadata.name=dbg-11`.]

```text
policy add-run-as-non-root applied to dbg-11/Deployment/shop:
# ...
    template:
        spec:
            containers:
                - image: nginx:1.29-alpine
                  name: shop
            securityContext:
                runAsNonRoot: true
```

#ursache[
  The MutatingPolicy sets `runAsNonRoot: true` in every new pod template. The image `nginx:1.29-alpine` starts as UID 0. Before the start, the kubelet checks whether the effective UID matches `runAsNonRoot`, and refuses the container with `CreateContainerConfigError`. In the default configuration, Kyverno does not write successful mutations as events, so the change is invisible.
]

=== Fix

The policy makes sense here. The image is what is wrong. nginx offers a variant without root:

#datei("szenarien/11-kyverno/fix-mutation.yaml (excerpt)", ```yaml
        - name: shop
          image: nginxinc/nginx-unprivileged:1.29-alpine
          ports:
            - containerPort: 8080
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/11-kyverno/fix-mutation.yaml
```][The image runs as UID 101 and listens on 8080, because ports below 1024 need root.]

#pruefe[
  The new pod is `Running`. Then: `kubectl --context rke2 delete -f policies/add-run-as-non-root.yaml`.
]

#falle[
  `kubectl diff` does not help here: it sends the manifest through admission as a server-side dry run, the mutation applies there too, and the difference disappears. If you want to see mutations as events, set `config.generateSuccessEvents: true` in the chart and remove `PolicyApplied` from `features.omitEvents.eventTypes`.
]

== Webhook Unreachable

Now Kyverno itself fails. In real life this happens through an OOMKill, a failed node or a NetworkPolicy. In the lab you simulate it with `scale`.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f policies/require-team-label.yaml
kubectl --context rke2 scale deploy kyverno-admission-controller -n kyverno --replicas=0
kubectl --context rke2 apply -f szenarien/11-kyverno/kaputt-webhook.yaml
```][The Deployment `notfall` ("emergency") meets the policy. So it should be created.]

#symptom[
```text
namespace/dbg-11 unchanged
Error from server (InternalError): error when creating "szenarien/11-kyverno/kaputt-webhook.yaml":
Internal error occurred: failed calling webhook "vpol.validate.kyverno.svc-fail": failed to call
webhook: Post "https://kyverno-svc.kyverno.svc:443/vpol/require-team-label?timeout=10s": no
endpoints available for service "kyverno-svc"
```
The same hits every pod that a ReplicaSet in `dbg-11` wants to create. A deleted pod does not come back.
]

=== Investigate

The message names the webhook, the Service and the reason. First check whether anybody is behind the Service at all:

#cmd("Mac")[```bash
kubectl --context rke2 get deploy kyverno-admission-controller -n kyverno
kubectl --context rke2 get endpointslices -n kyverno -l kubernetes.io/service-name=kyverno-svc
```][`READY 0/0` and an EndpointSlice without endpoints. In a real incident you see `CrashLoopBackOff` or `Pending` here, and you continue with Chapters 4 and 6.]

Then the question of why a missing webhook blocks instead of being skipped:

#cmd("Mac")[```bash
kubectl --context rke2 get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.failurePolicy}{"\n"}{end}' | grep vpol
```][Lists every webhook of the configuration with its `failurePolicy`.]

```text
vpol.validate.kyverno.svc-fail    Fail
```

In k9s you find the same under `:validatingwebhookconfigurations`, then `y` for the YAML view and `/failurePolicy`.

#ursache[
  Without an explicit setting, CEL policies have `failurePolicy: Fail`. If the API server cannot reach the webhook, it rejects the request instead of letting it through. With only one replica of the admission controller, a single failed pod is enough for that. All resources that a policy matches are affected. `kube-system` and `kyverno` are excluded, which is why Kyverno itself can start again at all.
]

=== Fix

The order in an emergency:

+ Start the admission controller again and fix the cause of its failure.
+ If it does not come up, delete the webhook configuration. Kyverno creates it again by itself on the next start. Until then, no policies apply.
+ In the long run: two or three replicas, and `failurePolicy: Ignore` for non-critical policies.

#cmd("Mac")[```bash
kubectl --context rke2 scale deploy kyverno-admission-controller -n kyverno --replicas=1
kubectl --context rke2 rollout status deploy kyverno-admission-controller -n kyverno
```][Step 1. The emergency exit from step 2 would be `kubectl --context rke2 delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg`.]

#pruefe[
  `kubectl --context rke2 apply -f szenarien/11-kyverno/kaputt-webhook.yaml` reports `deployment.apps/notfall created`. Then: `kubectl --context rke2 delete -f policies/require-team-label.yaml`.
]

#distro(
  [The API server runs as the static pod `kube-apiserver-rke2-cp`. You see its messages about webhooks with `kubectl --context rke2 logs -n kube-system kube-apiserver-rke2-cp | grep 'failed calling webhook'`.],
  [Here too it is a static pod, `kube-apiserver-talos-cp`, with the same `kubectl logs`. If the API server itself fails, `talosctl -n 172.16.0.170 containers --namespace cri` and `talosctl logs --namespace cri` with the container ID help.],
)

== PolicyException Without Effect

A legacy application still runs without a memory limit. Instead of weakening the policy, it gets a `PolicyException`.

#datei("policies/exceptions/legacy-batch.yaml", ```yaml
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata:
  name: legacy-batch
  namespace: dbg-11
spec:
  policyRefs:
    - name: require-memory-limit
      kind: ValidatingPolicy
  matchConditions:
    - name: nur-legacy-batch
      expression: >-
        object.metadata.?labels.app.orValue('') == 'legacy-batch'
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f policies/require-memory-limit.yaml
kubectl --context rke2 apply -f szenarien/11-kyverno/kaputt-ausnahme.yaml
kubectl --context rke2 apply -f policies/exceptions/legacy-batch.yaml
```][The policy, the Deployment `legacy-batch` without a limit (`Ausnahme` means "exception"), and the exception. Watch the output of the last command.]

#symptom[
```text
Warning: PolicyException resources would not be processed until it is enabled.
policyexception.policies.kyverno.io/legacy-batch created
```
The Deployment stays at `0/1`, and the ReplicaSet shows the same `FailedCreate` message as in the second scenario.
]

=== Investigate

The warning comes from Kyverno itself. The startup arguments of the admission controller show which setting it means:

#cmd("Mac")[```bash
kubectl --context rke2 get deploy kyverno-admission-controller -n kyverno -o yaml \
  | grep -E 'enablePolicyException|exceptionNamespace'
```][The Helm values under `features.policyExceptions` turn into these arguments.]

```text
        - --enablePolicyException=false
```

To list them, you spell out the group: `kubectl get policyexceptions.policies.kyverno.io -n dbg-11`. The old group `kyverno.io` also has a `PolicyException`, and without a group `kubectl` silently picks one of the two.

#ursache[
  In Kyverno, PolicyExceptions are opt-in. Without `--enablePolicyException=true`, the API server accepts the exception, but Kyverno ignores it. In addition, `--exceptionNamespace` defines the namespace from which exceptions apply. This prevents anyone who may write in their own namespace from exempting themselves from policies.
]

=== Fix

#datei("szenarien/11-kyverno/fix-ausnahme-values.yaml (excerpt)", ```yaml
features:
  policyExceptions:
    enabled: true
    namespace: dbg-11
```, erklaerung: [In the lab, the exceptions live directly in `dbg-11`. In production you use a separate namespace that only the platform team may write to.])

#cmd("Mac")[```bash
helm --kube-context rke2 upgrade kyverno kyverno/kyverno -n kyverno --version 3.9.2 \
  -f werkzeuge/kyverno-values.yaml -f szenarien/11-kyverno/fix-ausnahme-values.yaml --wait
```][The second file overrides only the `features.policyExceptions` block. The controllers restart with the new arguments.]

#pruefe[
  After a short while, the ReplicaSet creates the pod, and `kubectl --context rke2 get pods -n dbg-11 -l app=legacy-batch` shows `Running`. The policy report lists the exception as `SKIP`:
```text
$ kubectl --context rke2 get polr -n dbg-11
NAME                                   KIND   NAME                           PASS   FAIL   WARN   ERROR   SKIP   AGE
9b2f4c1e-7a3d-4e8b-b6f0-2d5c8a1e9f37   Pod    legacy-batch-7f6d9c8b5-wq4zr   0      0      0      0       1      40s
```
]

== Test Policies Before They Get in the Way

You could have found almost all failures in this chapter without a cluster. For every policy under `policies/` there are test cases in `policies/tests/kyverno-test.yaml`: resources that must pass, fail or be skipped by an exception, and, for the mutation, the expected result.

#datei("policies/tests/kyverno-test.yaml (excerpt)", ```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: kapitel-11
policies:
  - ../require-team-label.yaml
  - ../require-memory-limit.yaml
  - ../add-run-as-non-root.yaml
exceptions:
  - ../exceptions/legacy-batch.yaml
# ... resources, values
results:
  - isValidatingPolicy: true
    policy: require-team-label
    kind: Deployment
    resources: [web-ohne-team]
    result: fail
  # ... more cases
  - isMutatingPolicy: true
    policy: add-run-as-non-root
    kind: Pod
    resources: [root-web]
    patchedResources: patched/pod-root.yaml
    result: pass
```)

#cmd("Mac")[```bash
kyverno test policies/tests
```][Runs locally with the Kyverno CLI 1.19 (`brew install kyverno`). In the lab, the file was checked with CLI 1.19.1.]

#pruefe[
```text
Test Summary: 13 tests passed and 0 tests failed
```
]

The second scenario also shows up offline: `kyverno apply` with both policies on `kaputt-limit.yaml` reports `pass: 1, fail: 0`. The one `pass` comes from `require-team-label`. `require-memory-limit` does not check the Deployment at all. So a missing `fail` does not mean “all good”, but possibly “not responsible”.

The second safety belt runs in the cluster: introduce new policies with `validationActions: [Audit]`. They then block nothing, but Kyverno checks all existing resources in the background and writes the result to policy reports. `kubectl --context rke2 get polr -A` shows in the `FAIL` column whom a later `Deny` would hit.

#aufgabe[
  Write another test case: a pod with the label `policy.nyrvex.com/skip: "true"` and without a memory limit. Which result do you expect for `require-memory-limit`, and why is this opt-out by label a security problem?

  Hint: the `objectSelector` filters already in the API server. Anyone who may create pods may also set their labels. A PolicyException in a protected namespace is the cleaner way.
]

#cmd("Mac")[```bash
kubectl --context rke2 delete -f policies/require-memory-limit.yaml -f policies/exceptions/legacy-batch.yaml
kubectl --context rke2 delete ns dbg-11
```][Cleans up the chapter. If you want to repeat the scenarios on Talos, use the same commands with `--context talos`.]

#gelernt(
  [Kyverno rejections name the webhook, the policy and the message. `vpol` stands for ValidatingPolicy, `-fail` for `failurePolicy: Fail`.],
  [Autogen decides whether the Deployment is rejected right away or only the pod. Without autogen, the message shows up as `FailedCreate` on the ReplicaSet.],
  [Mutations are invisible by default. Compare the manifest and the live object, and check `kubectl get mpol` and the mutating webhooks.],
  [If the webhook is gone, `failurePolicy: Fail` blocks everything that matches. Emergency exit: start the controller or delete the webhook configuration.],
  [PolicyExceptions only work with `features.policyExceptions.enabled` and a matching namespace.],
  [`kyverno test` checks policies, including exceptions and mutations, without a cluster.],
)
