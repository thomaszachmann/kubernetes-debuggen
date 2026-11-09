#import "../lib.typ": *

#kapitel(
  [Fehler durch Kyverno],
  ziel: [Du erkennst, wann Kyverno hinter einer Ablehnung oder einer unerwarteten Änderung steckt, liest seine Meldungen, findest die verantwortliche Policy, kommst bei einem ausgefallenen Webhook wieder in den Cluster und testest Policies vorab ohne Cluster.],
  zeit: [75 Minuten],
  braucht: [Kapitel 2, 3 und 10],
)

== Was in diesem Kapitel kaputtgeht

Kyverno ist ein Admission-Webhook. Der API-Server schickt ihm jede passende Anfrage, bevor er sie speichert. Kyverno kann ablehnen (`ValidatingPolicy`), ändern (`MutatingPolicy`) oder, wenn es nicht antwortet, den Cluster lahmlegen. Alle drei Fälle sehen für Anwender zunächst aus wie „Kubernetes spinnt“.

#tabelle(
  (auto, 1fr, 1fr),
  ([Szenario], [Symptom], [Wo die Antwort steht]),
  [Policy lehnt Deployment ab], [`apply` scheitert sofort], [`admission webhook "vpol..." denied the request`],
  [Policy lehnt nur Pods ab], [Deployment `0/1`, kein Pod], [Event `FailedCreate` am ReplicaSet],
  [Mutation ändert den Pod], [`CreateContainerConfigError`], [Live-Objekt gegen Manifest, `kubectl get mpol`],
  [Webhook nicht erreichbar], [*Jede* Änderung in `dbg-11` scheitert], [`failed calling webhook`, `failurePolicy`],
  [PolicyException wirkungslos], [Ausnahme angelegt, Pods trotzdem abgelehnt], [Warnung beim `apply`, Startparameter],
)

Alle Policies dieses Kapitels liegen unter `policies/` und wirken nur im Namespace `dbg-11`. Lege jede Policy zu Beginn ihres Szenarios an und lösche sie am Ende wieder, damit sich die Szenarien nicht gegenseitig stören.

== Kyverno installieren

#datei("werkzeuge/kyverno-values.yaml (Ausschnitt)", ```yaml
admissionController:
  replicas: 1
backgroundController:
  replicas: 1
# ... cleanupController, reportsController ebenso
features:
  policyExceptions:
    enabled: false
    namespace: ""
```, erklaerung: [Je Controller eine Instanz spart im Labor Speicher. Der Preis: Fällt der Admission-Controller aus, antwortet niemand mehr auf Webhook-Anfragen. PolicyExceptions bleiben vorerst aus, wie im Chart vorgegeben. Das brauchst du im letzten Szenario.])

#cmd("Mac")[```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
for ctx in rke2 talos; do
  helm --kube-context $ctx upgrade --install kyverno kyverno/kyverno \
    -n kyverno --create-namespace --version 3.9.2 \
    -f werkzeuge/kyverno-values.yaml --wait --timeout 5m
done
```][Chart 3.9.2 bringt Kyverno 1.19.2 mit. Die Schleife installiert auf beiden Clustern dieselbe Version.]

#cmd("Mac")[```bash
kubectl --context rke2 get deploy -n kyverno
```][Vier Deployments: `kyverno-admission-controller`, `kyverno-background-controller`, `kyverno-cleanup-controller`, `kyverno-reports-controller`, jeweils `1/1`.]

Die Kyverno-Pods erfüllen `restricted`, auf Talos gibt es also keine PSA-Warnungen. Von Kyverno ausgenommen sind auf beiden Clustern `kube-system` und `kyverno` selbst.

#falle[
  Viele Anleitungen nutzen noch `kind: ClusterPolicy` aus `kyverno.io/v1`. In Kyverno 1.19 ist das veraltet, `kubectl apply` warnt mit `kyverno.io/v1 ClusterPolicy is deprecated and will be removed in a future release`. Dieses Kapitel nutzt die CEL-basierten Policies aus `policies.kyverno.io/v1`, deren Meldungen anders aussehen.
]

== Policy lehnt das Deployment ab

#datei("policies/require-team-label.yaml (Ausschnitt)", ```yaml
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
```, erklaerung: [Die Policy prüft nur Pods. Kyverno erzeugt daraus aber automatisch dieselbe Regel für Deployments, StatefulSets, DaemonSets, Jobs und CronJobs. Das heißt Autogen und ist für CEL-Policies der Standard, wenn genau eine Regel auf `pods` ohne `objectSelector` passt.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f policies/require-team-label.yaml
kubectl --context rke2 apply -f szenarien/11-kyverno/kaputt-label.yaml
```][Das Deployment `web` hat im Pod-Template nur das Label `app`.]

#symptom[
```text
namespace/dbg-11 created
Error from server: error when creating "szenarien/11-kyverno/kaputt-label.yaml": admission webhook
"vpol.validate.kyverno.svc-fail" denied the request: Policy require-team-label failed: Pods
brauchen das Label team.
```
]

=== Untersuchen

Die Meldung trägt bereits alles: Der Webhook-Name beginnt mit `vpol` (ValidatingPolicy, bei MutatingPolicy `mpol`, bei alten ClusterPolicies nur `validate.kyverno.svc`), die Endung `-fail` steht für `failurePolicy: Fail`. Danach folgen der Name der Policy und wörtlich ihr `message`-Text.

#cmd("Mac")[```bash
kubectl --context rke2 get vpol
kubectl --context rke2 get vpol require-team-label -o jsonpath='{.status.autogen}{"\n"}'
```][`vpol` ist die Kurzform von `validatingpolicies`, die Spalte `READY` sollte `True` zeigen. Unter `status.autogen` steht, für welche Controller Kyverno die Regel mitgeneriert hat.]

#cmd("k9s")[```text
:vpol⏎             require-team-label auswählen, y = YAML
:polr dbg-11⏎      Policy Reports im Namespace
```][k9s kennt die Kyverno-CRDs über ihre Kurznamen. In der YAML-Ansicht suchst du mit `/` nach `message`.]

#falle[
  Alte ClusterPolicies antworten mit `resource Deployment/dbg-11/web was blocked due to the following policies`, darunter Policy, Regel und `validation error: ... failed at path ...`. Liegen mehrere CEL-Policies mit unterschiedlichen Selektoren im Cluster, hängt Kyverno an den Webhook-Namen einen kurzen Hash, etwa `vpol.validate.kyverno.svc-fail-1a2b3c4d`.
]

#ursache[
  Das Pod-Template enthält kein Label `team`. Durch Autogen prüft Kyverno schon das Deployment und nicht erst den Pod. Der Ausdruck aus der Policy wurde dafür auf `object.spec.template.metadata` umgeschrieben. Deshalb scheitert `apply` sofort und sichtbar.
]

=== Beheben

#datei("szenarien/11-kyverno/fix-label.yaml (Ausschnitt)", ```yaml
  template:
    metadata:
      labels:
        app: web
        team: shop
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/11-kyverno/fix-label.yaml
```][Diesmal kommt `deployment.apps/web created`.]

#pruefe[
  `kubectl --context rke2 get pods -n dbg-11 -l app=web` zeigt einen Pod in `Running`. Danach aufräumen: `kubectl --context rke2 delete -f policies/require-team-label.yaml`.
]

== Policy lehnt nur die Pods ab

Gefährlicher ist der Fall, in dem Kyverno das Deployment durchlässt und erst die Pods ablehnt. Dann sieht der Entwickler `created`, die Pipeline ist grün, und trotzdem läuft nichts.

#datei("policies/require-memory-limit.yaml (Ausschnitt)", ```yaml
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
```, erklaerung: [Jemand wollte einen Ausstieg per Label einbauen und hat einen `objectSelector` ergänzt. Mit einem `objectSelector` schaltet Kyverno Autogen ab, denn Labels am Deployment und am Pod sind verschiedene Dinge.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f policies/require-memory-limit.yaml
kubectl --context rke2 apply -f szenarien/11-kyverno/kaputt-limit.yaml
```][Das Deployment `api` setzt kein Memory-Limit.]

#symptom[
```text
$ kubectl --context rke2 get deploy,rs -n dbg-11 -l app=api
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/api   0/1     0            0           25s

NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/api-6c8d9f7b54   1         0         0       25s
```
]

=== Untersuchen

Dasselbe Muster wie bei PSA in Kapitel 10: kein Pod, also Events am ReplicaSet.

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-11 --for replicaset/api-6c8d9f7b54
```][Setze den Namen deines ReplicaSets ein, oder nutze in k9s das Plugin `Shift-E` auf dem ReplicaSet.]

```text
LAST SEEN   TYPE      REASON         OBJECT                      MESSAGE
8s          Warning   FailedCreate   ReplicaSet/api-6c8d9f7b54   Error creating: admission webhook
"vpol.validate.kyverno.svc-fail" denied the request: Policy require-memory-limit failed: Jeder
Container braucht ein Memory-Limit.
```

Ob eine Policy auch Controller prüft, verrät ihr Status. Bei `require-memory-limit` bleibt `status.autogen` leer:

#cmd("Mac")[```bash
kubectl --context rke2 get vpol require-memory-limit -o jsonpath='{.status.autogen}{"\n"}'
```][Leer oder `{}` heißt: Diese Policy sieht nur Pods. Vergleiche mit `require-team-label` aus dem ersten Szenario.]

#ursache[
  Die Policy gilt nur für Pods und hat wegen des `objectSelector` keine Autogen-Regeln. Das Deployment und das ReplicaSet passieren Kyverno, erst die Pod-Erstellung durch den ReplicaSet-Controller wird abgelehnt. Die Meldung landet deshalb nicht bei dir im Terminal, sondern als Event am ReplicaSet. Für Anwender ist eine Ablehnung schon beim `apply` viel freundlicher, Autogen sollte deshalb nur aus gutem Grund fehlen.
]

=== Beheben

#datei("szenarien/11-kyverno/fix-limit.yaml (Ausschnitt)", ```yaml
          resources:
            limits:
              memory: 128Mi
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/11-kyverno/fix-limit.yaml
```][Neues Pod-Template, also neues ReplicaSet. Das alte bleibt mit `0` Replikas stehen.]

#pruefe[
  `kubectl --context rke2 get pods -n dbg-11 -l app=api` zeigt `1/1 Running`. Danach: `kubectl --context rke2 delete -f policies/require-memory-limit.yaml`.
]

== Mutation ändert den Pod unerwartet

Das Plattform-Team rollt eine „sichere Voreinstellung“ aus: Jeder Pod in `dbg-11` bekommt `runAsNonRoot: true`. Gut gemeint, nur weiß das Anwendungsteam nichts davon.

#datei("policies/add-run-as-non-root.yaml (Ausschnitt)", ```yaml
apiVersion: policies.kyverno.io/v1
kind: MutatingPolicy
metadata:
  name: add-run-as-non-root
spec:
  # ... matchConstraints wie oben, nur CREATE
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
```][Das Deployment `shop` nutzt das normale Image `nginx:1.29-alpine`, das als root startet. Im Manifest steht kein `securityContext`.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-11 -l app=shop
NAME                   READY   STATUS                       RESTARTS   AGE
shop-7b9c6d5f8-2kx9p   0/1     CreateContainerConfigError   0          20s
```
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-11 -l app=shop | tail -3
```][Die Kubelet-Meldung am Ende erklärt den Status.]

```text
  Warning  Failed     4s (x3 over 20s)  kubelet  Error: container has runAsNonRoot and image will run as
root (pod: "shop-7b9c6d5f8-2kx9p_dbg-11(5c1e9a7d-...)", container: shop)
```

Das Team schwört, nie `runAsNonRoot` gesetzt zu haben. Also vergleichst du Manifest und Live-Objekt:

#cmd("Mac")[```bash
grep -c runAsNonRoot szenarien/11-kyverno/kaputt-mutation.yaml
kubectl --context rke2 get deploy shop -n dbg-11 \
  -o jsonpath='{.spec.template.spec.securityContext}{"\n"}'
```][Im Manifest: `0` Treffer. Im Cluster: `{"runAsNonRoot":true}`. Zwischen `apply` und Speichern hat jemand das Objekt verändert.]

Sogar das Deployment ist verändert, nicht nur der Pod: Autogen gilt auch für MutatingPolicies. Objekte beim Anlegen verändern nur Mutating-Webhooks. `kubectl --context rke2 get mpol` listet die Kyverno-Mutationen, `kubectl --context rke2 get mutatingwebhookconfigurations` alle anderen Kandidaten.

Den Verdacht bestätigst du offline mit der Kyverno-CLI. Sie zeigt das Objekt so, wie es nach der Mutation aussähe:

#cmd("Mac")[```bash
kyverno apply policies/add-run-as-non-root.yaml \
  --resource szenarien/11-kyverno/kaputt-mutation.yaml \
  --values-file policies/values-dbg-11.yaml
```][Offline kennt die CLI keine Namespace-Labels. `values-dbg-11.yaml` sagt ihr, dass `dbg-11` das Label `kubernetes.io/metadata.name=dbg-11` trägt.]

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
  Die MutatingPolicy setzt `runAsNonRoot: true` in jede neue Pod-Vorlage. Das Image `nginx:1.29-alpine` startet als UID 0. Das Kubelet prüft vor dem Start, ob die effektive UID zu `runAsNonRoot` passt, und verweigert den Container mit `CreateContainerConfigError`. Kyverno schreibt erfolgreiche Mutationen in der Standardkonfiguration nicht als Event, der Eingriff ist deshalb unsichtbar.
]

=== Beheben

Die Policy ist hier sinnvoll, falsch ist das Image. nginx bietet eine Variante ohne root:

#datei("szenarien/11-kyverno/fix-mutation.yaml (Ausschnitt)", ```yaml
        - name: shop
          image: nginxinc/nginx-unprivileged:1.29-alpine
          ports:
            - containerPort: 8080
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/11-kyverno/fix-mutation.yaml
```][Das Image läuft als UID 101 und lauscht auf 8080, weil Ports unter 1024 root brauchen.]

#pruefe[
  Der neue Pod ist `Running`. Danach: `kubectl --context rke2 delete -f policies/add-run-as-non-root.yaml`.
]

#falle[
  `kubectl diff` hilft hier nicht: Es schickt das Manifest als Server-Side-Dry-Run durch die Admission, die Mutation greift auch dort, und der Unterschied verschwindet. Willst du Mutationen als Event sehen, setze im Chart `config.generateSuccessEvents: true` und entferne `PolicyApplied` aus `features.omitEvents.eventTypes`.
]

== Webhook nicht erreichbar

Jetzt fällt Kyverno selbst aus. Im echten Leben durch einen OOMKill, einen ausgefallenen Knoten oder eine NetworkPolicy. Im Labor simulierst du das mit `scale`.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f policies/require-team-label.yaml
kubectl --context rke2 scale deploy kyverno-admission-controller -n kyverno --replicas=0
kubectl --context rke2 apply -f szenarien/11-kyverno/kaputt-webhook.yaml
```][Das Deployment `notfall` erfüllt die Policy. Es dürfte also angelegt werden.]

#symptom[
```text
namespace/dbg-11 unchanged
Error from server (InternalError): error when creating "szenarien/11-kyverno/kaputt-webhook.yaml":
Internal error occurred: failed calling webhook "vpol.validate.kyverno.svc-fail": failed to call
webhook: Post "https://kyverno-svc.kyverno.svc:443/vpol/require-team-label?timeout=10s": no
endpoints available for service "kyverno-svc"
```
Dasselbe trifft jeden Pod, den ein ReplicaSet in `dbg-11` neu anlegen will. Ein gelöschter Pod kommt nicht wieder.
]

=== Untersuchen

Die Meldung nennt Webhook, Service und Grund. Prüfe zuerst, ob hinter dem Service überhaupt jemand steht:

#cmd("Mac")[```bash
kubectl --context rke2 get deploy kyverno-admission-controller -n kyverno
kubectl --context rke2 get endpointslices -n kyverno -l kubernetes.io/service-name=kyverno-svc
```][`READY 0/0` und eine EndpointSlice ohne Endpunkte. Im Ernstfall siehst du hier `CrashLoopBackOff` oder `Pending`, dann geht es mit den Kapiteln 4 und 6 weiter.]

Dann die Frage, warum ein fehlender Webhook blockiert, statt übersprungen zu werden:

#cmd("Mac")[```bash
kubectl --context rke2 get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{range .webhooks[*]}{.name}{"\t"}{.failurePolicy}{"\n"}{end}' | grep vpol
```][Listet jeden Webhook der Konfiguration mit seiner `failurePolicy`.]

```text
vpol.validate.kyverno.svc-fail    Fail
```

In k9s findest du dasselbe unter `:validatingwebhookconfigurations`, dann `y` für die YAML-Ansicht und `/failurePolicy`.

#ursache[
  CEL-Policies haben ohne Angabe `failurePolicy: Fail`. Kann der API-Server den Webhook nicht erreichen, lehnt er die Anfrage ab, statt sie durchzulassen. Mit nur einer Replika des Admission-Controllers reicht dafür ein einziger ausgefallener Pod. Betroffen sind alle Ressourcen, auf die eine Policy passt. `kube-system` und `kyverno` sind ausgenommen, deshalb kann Kyverno selbst überhaupt wieder starten.
]

=== Beheben

Die Reihenfolge im Notfall:

+ Den Admission-Controller wieder starten und die Ursache seines Ausfalls beheben.
+ Kommt er nicht hoch, die Webhook-Konfiguration löschen. Kyverno legt sie beim nächsten Start selbst wieder an. Bis dahin gelten keine Policies.
+ Langfristig: zwei oder drei Replikas und für unkritische Policies `failurePolicy: Ignore`.

#cmd("Mac")[```bash
kubectl --context rke2 scale deploy kyverno-admission-controller -n kyverno --replicas=1
kubectl --context rke2 rollout status deploy kyverno-admission-controller -n kyverno
```][Schritt 1. Der Notausgang aus Schritt 2 wäre `kubectl --context rke2 delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg`.]

#pruefe[
  `kubectl --context rke2 apply -f szenarien/11-kyverno/kaputt-webhook.yaml` meldet `deployment.apps/notfall created`. Danach: `kubectl --context rke2 delete -f policies/require-team-label.yaml`.
]

#distro(
  [Der API-Server läuft als Static Pod `kube-apiserver-rke2-cp`. Seine Meldungen zu Webhooks siehst du mit `kubectl --context rke2 logs -n kube-system kube-apiserver-rke2-cp | grep 'failed calling webhook'`.],
  [Auch hier ein Static Pod, `kube-apiserver-talos-cp`, mit demselben `kubectl logs`. Fällt der API-Server selbst aus, hilft `talosctl -n 172.16.0.170 containers --namespace cri` und `talosctl logs --namespace cri` mit der Container-ID.],
)

== PolicyException ohne Wirkung

Eine Altanwendung läuft noch ohne Memory-Limit. Statt die Policy aufzuweichen, bekommt sie eine `PolicyException`.

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
```][Policy, Deployment `legacy-batch` ohne Limit, Ausnahme. Achte auf die Ausgabe des letzten Befehls.]

#symptom[
```text
Warning: PolicyException resources would not be processed until it is enabled.
policyexception.policies.kyverno.io/legacy-batch created
```
Das Deployment bleibt bei `0/1`, am ReplicaSet steht dieselbe `FailedCreate`-Meldung wie im zweiten Szenario.
]

=== Untersuchen

Die Warnung kommt von Kyverno selbst. Welche Einstellung gemeint ist, zeigen die Startparameter des Admission-Controllers:

#cmd("Mac")[```bash
kubectl --context rke2 get deploy kyverno-admission-controller -n kyverno -o yaml \
  | grep -E 'enablePolicyException|exceptionNamespace'
```][Die Helm-Werte unter `features.policyExceptions` werden zu diesen Argumenten.]

```text
        - --enablePolicyException=false
```

Zum Auflisten schreibst du die Gruppe aus, `kubectl get policyexceptions.policies.kyverno.io -n dbg-11`. Auch die alte Gruppe `kyverno.io` kennt eine `PolicyException`, und ohne Gruppe wählt `kubectl` still eine der beiden.

#ursache[
  PolicyExceptions sind in Kyverno ein Opt-in. Ohne `--enablePolicyException=true` nimmt der API-Server die Ausnahme zwar an, Kyverno beachtet sie aber nicht. Zusätzlich legt `--exceptionNamespace` fest, aus welchem Namespace Ausnahmen gelten. Das verhindert, dass jeder, der in seinem Namespace schreiben darf, sich selbst von Policies befreit.
]

=== Beheben

#datei("szenarien/11-kyverno/fix-ausnahme-values.yaml (Ausschnitt)", ```yaml
features:
  policyExceptions:
    enabled: true
    namespace: dbg-11
```, erklaerung: [Im Labor liegen die Ausnahmen direkt in `dbg-11`. In Produktion nimmst du einen eigenen Namespace, in den nur das Plattform-Team schreiben darf.])

#cmd("Mac")[```bash
helm --kube-context rke2 upgrade kyverno kyverno/kyverno -n kyverno --version 3.9.2 \
  -f werkzeuge/kyverno-values.yaml -f szenarien/11-kyverno/fix-ausnahme-values.yaml --wait
```][Die zweite Datei überschreibt nur den Block `features.policyExceptions`. Die Controller starten mit den neuen Argumenten neu.]

#pruefe[
  Nach kurzer Zeit legt das ReplicaSet den Pod an, `kubectl --context rke2 get pods -n dbg-11 -l app=legacy-batch` zeigt `Running`. Im Policy Report steht die Ausnahme als `SKIP`:
```text
$ kubectl --context rke2 get polr -n dbg-11
NAME                                   KIND   NAME                           PASS   FAIL   WARN   ERROR   SKIP   AGE
9b2f4c1e-7a3d-4e8b-b6f0-2d5c8a1e9f37   Pod    legacy-batch-7f6d9c8b5-wq4zr   0      0      0      0       1      40s
```
]

== Policies testen, bevor sie stören

Fast alle Fehler dieses Kapitels hättest du ohne Cluster finden können. Zu jeder Policy unter `policies/` gibt es Testfälle in `policies/tests/kyverno-test.yaml`: Ressourcen, die bestehen, scheitern oder per Ausnahme übersprungen werden müssen, und für die Mutation das erwartete Ergebnis.

#datei("policies/tests/kyverno-test.yaml (Ausschnitt)", ```yaml
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
  # ... weitere Fälle
  - isMutatingPolicy: true
    policy: add-run-as-non-root
    kind: Pod
    resources: [root-web]
    patchedResources: patched/pod-root.yaml
    result: pass
```)

#cmd("Mac")[```bash
kyverno test policies/tests
```][Lokal mit der Kyverno-CLI 1.19 (`brew install kyverno`). Im Labor wurde die Datei mit der CLI 1.19.1 geprüft.]

#pruefe[
```text
Test Summary: 13 tests passed and 0 tests failed
```
]

Auch das zweite Szenario zeigt sich offline: `kyverno apply` mit beiden Policies auf `kaputt-limit.yaml` meldet `pass: 1, fail: 0`. Das eine `pass` kommt von `require-team-label`, das Deployment prüft `require-memory-limit` gar nicht. Ein fehlendes `fail` heißt also nicht „in Ordnung“, sondern womöglich „nicht zuständig“.

Der zweite Sicherheitsgurt läuft im Cluster: Führe neue Policies mit `validationActions: [Audit]` ein. Sie blockieren dann nichts, Kyverno prüft aber im Hintergrund alle bestehenden Ressourcen und schreibt das Ergebnis in Policy Reports. `kubectl --context rke2 get polr -A` zeigt in der Spalte `FAIL`, wen ein späteres `Deny` treffen würde.

#aufgabe[
  Schreibe einen weiteren Testfall: einen Pod mit dem Label `policy.nyrvex.com/skip: "true"` und ohne Memory-Limit. Welches Ergebnis erwartest du für `require-memory-limit`, und warum ist dieser Ausstieg per Label ein Sicherheitsproblem?

  Hinweis: Der `objectSelector` filtert schon im API-Server. Jeder, der Pods anlegen darf, darf auch ihre Labels setzen. Eine PolicyException in einem geschützten Namespace ist der sauberere Weg.
]

#cmd("Mac")[```bash
kubectl --context rke2 delete -f policies/require-memory-limit.yaml -f policies/exceptions/legacy-batch.yaml
kubectl --context rke2 delete ns dbg-11
```][Räumt das Kapitel auf. Willst du die Szenarien auf Talos wiederholen, nimm dieselben Befehle mit `--context talos`.]

#gelernt(
  [Kyverno-Ablehnungen nennen Webhook, Policy und Meldung. `vpol` steht für ValidatingPolicy, `-fail` für `failurePolicy: Fail`.],
  [Autogen entscheidet, ob schon das Deployment oder erst der Pod abgelehnt wird. Ohne Autogen steht die Meldung als `FailedCreate` am ReplicaSet.],
  [Mutationen sind standardmäßig unsichtbar. Vergleiche Manifest und Live-Objekt und prüfe `kubectl get mpol` und die Mutating-Webhooks.],
  [Ist der Webhook weg, blockiert `failurePolicy: Fail` alles Passende. Notausgang: Controller starten oder Webhook-Konfiguration löschen.],
  [PolicyExceptions wirken nur mit `features.policyExceptions.enabled` und passendem Namespace.],
  [`kyverno test` prüft Policies samt Ausnahmen und Mutationen ohne Cluster.],
)
