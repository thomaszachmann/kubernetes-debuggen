#import "../lib.typ": *

#kapitel(
  [Pods bleiben Pending],
  ziel: [Du liest die Meldungen des Schedulers, erkennst, ob ein Pod an Ressourcen, Labels, Taints, Volumes oder einer Quota scheitert, und behebst jeden dieser Fehler auf RKE2 und Talos.],
  zeit: [60 Minuten],
  braucht: [Kapitel 2 und 3],
)

== Was in diesem Kapitel kaputtgeht

Ein Pod in `Pending` hat noch keinen Knoten. Kein Container läuft, es gibt keine Logs, `kubectl logs` bleibt leer. Die Antwort steht fast immer an einer von zwei Stellen: in den Events des Pods, geschrieben vom Scheduler, oder, wenn es den Pod gar nicht gibt, in den Events des ReplicaSets.

#tabelle(
  (auto, 1fr, 1fr),
  ([Szenario], [Symptom], [Wo die Antwort steht]),
  [Zu große Requests], [Pod `Pending`, Event `FailedScheduling`], [`Insufficient cpu` im Pod-Event],
  [nodeSelector und Taint], [Pod `Pending`], [`didn't match Pod's node affinity/selector`, `had untolerated taint(s)`],
  [PVC ohne StorageClass], [Pod und PVC `Pending`], [`unbound immediate PersistentVolumeClaims`, Events der PVC],
  [ResourceQuota], [Deployment `0/2`, *kein* Pod], [Event `FailedCreate` am ReplicaSet],
)

Alle Szenarien laufen im Namespace `dbg-04`, den jede `kaputt-*.yaml` selbst anlegt. Die Quota aus dem letzten Szenario gilt für den ganzen Namespace, spiele sie deshalb zuletzt. Auf Talos meldet `kubectl apply` bei diesen Manifesten `Warning: would violate PodSecurity "restricted:latest": ...`. Talos erzwingt cluster-weit nur `baseline` und warnt bei `restricted`. Die Warnung blockiert nichts, mehr dazu in Kapitel 10.

== Der Scheduler erklärt sich selbst

Findet der Scheduler keinen Knoten, schreibt er ein Event mit dem Reason `FailedScheduling`. Der Text folgt immer dem Muster `0/2 nodes are available: <Gründe je Knoten>. preemption: <Ergebnis>`. Der erste Teil zählt für jeden Grund, an wie vielen Knoten er zutraf. `2 Insufficient cpu` heißt: beide Knoten haben zu wenig freie CPU. Stehen mehrere Gründe da, ergeben die Zahlen zusammen die Knotenzahl, denn der Scheduler meldet je Knoten den ersten Filter, der scheitert. Der zweite Teil sagt, ob der Scheduler andere Pods verdrängen könnte, um Platz zu schaffen. `Preemption is not helpful for scheduling` bedeutet: Verdrängen löst dieses Problem nicht, etwa weil ein Label fehlt. Dann musst du selbst etwas ändern.

== Zu große Requests

Requests sind Reservierungen. Der Scheduler rechnet nicht mit der tatsächlichen Last eines Knotens, sondern mit der Summe der Requests aller Pods darauf. Ein Pod, der mehr anfordert, als ein Knoten zuteilen kann, findet nie einen Platz, auch wenn der Cluster gerade nichts tut.

#datei("szenarien/04-pending/kaputt-ressourcen.yaml (Ausschnitt)", ```yaml
      containers:
        - name: app
          image: busybox:1.37
          command: ["sleep", "infinity"]
          resources:
            requests:
              cpu: "6"
              memory: 256Mi
```, erklaerung: [Sechs CPU-Kerne als Request. Der größte Knoten im Labor hat vier.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/kaputt-ressourcen.yaml
kubectl --context talos apply -f szenarien/04-pending/kaputt-ressourcen.yaml
```][Legt Namespace und Deployment `gross` auf beiden Clustern an.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-04 -o wide
NAME                     READY   STATUS    RESTARTS   AGE   IP       NODE     NOMINATED NODE   READINESS GATES
gross-6d4b9c7f8d-q2xkp   0/1     Pending   0          48s   <none>   <none>   <none>           <none>
```
Kein Knoten, keine IP, keine Neustarts. Der Pod wartet, und das bleibt so.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-04 -l app=gross
```][`describe` mit Label-Selektor erspart dir das Abtippen des Pod-Namens. Wichtig ist der Block `Events` ganz unten.]

```text
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  51s   default-scheduler  0/2 nodes are available: 2 Insufficient cpu.
  preemption: 0/2 nodes are available: 2 No preemption victims found for incoming pod.
```

Beide Knoten haben zu wenig CPU, und auch das Verdrängen anderer Pods würde nicht helfen. Was ein Knoten vergeben kann (`Allocatable`) und was davon schon vergeben ist, zeigt `describe node`:

#cmd("Mac")[```bash
kubectl --context rke2 describe node rke2-cp | grep -A 8 "Allocated resources"
```][Die Spalte `Requests` ist entscheidend, nicht `Limits`. Limits dürfen in Summe über 100 Prozent liegen, Requests nicht. Den Block `Allocatable` weiter oben in derselben Ausgabe siehst du ohne `grep`.]

```text
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests     Limits
  --------           --------     ------
  cpu                1150m (28%)  200m (5%)
  memory             1004Mi (12%) 662Mi (8%)
  ephemeral-storage  0 (0%)       0 (0%)
```

In k9s kommst du auf demselben Weg zum Ziel, nur schneller zwischen den Ansichten:

#cmd("k9s")[```text
:pods dbg-04⏎   Pod wählen, d   (describe, Events unten)
                oder Shift-E    (Plugin: kubectl events --for)
:nodes⏎         Knoten wählen, d
```][Mit `Esc` geht es zurück zur Liste, mit `/` filterst du die Describe-Ansicht nach `FailedScheduling`. `Shift-E` ist das Plugin aus Kapitel 3.]

#ursache[
  Der Pod fordert 6 CPU an, kein Knoten kann mehr als 4 zuteilen. Der Scheduler prüft für jeden Knoten, ob `allocatable` minus Summe der bestehenden Requests für den neuen Request reicht. Das ist reine Buchhaltung: Ob die CPU gerade ausgelastet ist, spielt keine Rolle. Ein Request größer als jeder einzelne Knoten bleibt deshalb für immer `Pending`.
]

=== Beheben

Realistische Requests orientieren sich am gemessenen Verbrauch. Im Labor reicht ein Viertel Kern: `fix-ressourcen.yaml` setzt `requests.cpu: 250m`, sonst ist alles gleich.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/fix-ressourcen.yaml
kubectl --context talos apply -f szenarien/04-pending/fix-ressourcen.yaml
```][Das Deployment erzeugt ein neues ReplicaSet, der alte Pending-Pod verschwindet.]

#pruefe[
```text
$ kubectl --context rke2 get pods -n dbg-04 -l app=gross
NAME                     READY   STATUS    RESTARTS   AGE
gross-7f5c8b9d64-mz7wd   1/1     Running   0          9s
```
Im Event-Verlauf (`kubectl --context rke2 events -n dbg-04 --for pod/<name>`) steht jetzt `Successfully assigned dbg-04/... to rke2-cp` oder `to rke2-w1`.
]

#warum[
  Gefährlicher ist der Teil-Erfolg: Drei Replikas zu je 1500m passen im Labor nur zweimal, der dritte Pod bleibt `Pending`, und das Deployment zeigt ein halb gesundes `2/3`.
]

== nodeSelector und Taint

Ein `nodeSelector` ist eine harte Bedingung: Der Pod darf nur auf Knoten, die alle genannten Labels tragen. Ein Taint ist das Gegenstück: Der Knoten weist Pods ab, die ihn nicht ausdrücklich tolerieren. Typisch sind Knoten für Spezialaufgaben, Knoten in Wartung und Control-Plane-Knoten. Im Labor machst du `rke2-w1` und `talos-w1` zu einem Batch-Knoten mit Label *und* Taint.

#cmd("Mac")[```bash
kubectl --context rke2 label node rke2-w1 dbg-pool=batch
kubectl --context rke2 taint node rke2-w1 dbg-pool=batch:NoSchedule
kubectl --context talos label node talos-w1 dbg-pool=batch
kubectl --context talos taint node talos-w1 dbg-pool=batch:NoSchedule
```][`NoSchedule` verhindert nur neue Pods. Was schon auf dem Knoten läuft, bleibt. `NoExecute` würde auch laufende Pods ohne Toleration vertreiben.]

#datei("szenarien/04-pending/kaputt-taint.yaml (Ausschnitt)", ```yaml
    spec:
      nodeSelector:
        dbg-pool: batch
      containers:
        - name: app
          image: busybox:1.37
```, erklaerung: [Der Pod will auf den Batch-Knoten, hat aber keine Toleration.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/kaputt-taint.yaml
kubectl --context talos apply -f szenarien/04-pending/kaputt-taint.yaml
```][Legt das Deployment `batch` an.]

#symptom[
  Der Pod `batch-...` steht auf `Pending`, obwohl es einen Knoten mit dem passenden Label gibt.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-04 -l app=batch | tail -n 4
```][Die letzten Zeilen von `describe` sind die Events.]

```text
  Warning  FailedScheduling  20s   default-scheduler  0/2 nodes are available: 1 node(s) didn't
  match Pod's node affinity/selector, 1 node(s) had untolerated taint(s). preemption: 0/2 nodes
  are available: 2 Preemption is not helpful for scheduling.
```

Zwei Gründe, und ihre Zahlen ergeben zusammen die zwei Knoten: `rke2-cp` scheitert am Selektor, `rke2-w1` am Taint. Hätte gar kein Knoten das Label, stünde dort `2 node(s) didn't match Pod's node affinity/selector`. Der Filter `NodeAffinity` prüft `nodeSelector` und `requiredDuringScheduling...` gemeinsam, daher der Doppelname. Welches Label und welcher Taint gemeint ist, verrät die Meldung nicht. Ältere Versionen nannten den Taint noch, Kubernetes 1.36 nicht mehr. Du vergleichst selbst:

#cmd("Mac")[```bash
kubectl --context rke2 get nodes \
  -o custom-columns=NAME:.metadata.name,POOL:.metadata.labels.dbg-pool,TAINTS:.spec.taints
```][Zeigt Label und Taints je Knoten. `<none>` heißt: nicht vorhanden. Was der Pod verlangt und toleriert, steht in `describe pod` unter `Node-Selectors` und `Tolerations`.]

```text
NAME      POOL    TAINTS
rke2-cp   <none>  <none>
rke2-w1   batch   [map[effect:NoSchedule key:dbg-pool value:batch]]
```

Der Pod hat nur die beiden Tolerations `node.kubernetes.io/not-ready` und `unreachable` für 300 Sekunden, die jeder Pod automatisch bekommt. `dbg-pool` ist nicht darunter. In k9s siehst du die Taints mit `:nodes⏎`, Knoten auswählen, `y` für das YAML, dort unter `spec.taints`.

#ursache[
  Der Selektor schickt den Pod auf genau einen Knoten, und dieser Knoten weist ihn per Taint ab. Selektor und Toleration lösen verschiedene Fragen: Der Selektor sagt, wohin der Pod *will*, die Toleration sagt, wohin er *darf*. Ein Spezialknoten braucht beides, sonst landen entweder fremde Pods darauf oder die eigenen nicht.
]

=== Beheben

`fix-taint.yaml` ergänzt das Pod-Template um die passende Toleration:

```yaml
      tolerations:
        - {key: dbg-pool, operator: Equal, value: batch, effect: NoSchedule}
```

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/fix-taint.yaml
kubectl --context talos apply -f szenarien/04-pending/fix-taint.yaml
```][Das neue ReplicaSet erzeugt einen Pod mit Toleration.]

#pruefe[
  `kubectl --context rke2 get pods -n dbg-04 -l app=batch -o wide` zeigt `Running` auf `rke2-w1`, auf Talos entsprechend `talos-w1`.
]

Entferne danach Taint und Label, sonst landen künftige Pods nicht mehr auf dem Worker:

#cmd("Mac")[```bash
kubectl --context rke2 taint node rke2-w1 dbg-pool=batch:NoSchedule-
kubectl --context rke2 label node rke2-w1 dbg-pool-
kubectl --context talos taint node talos-w1 dbg-pool=batch:NoSchedule-
kubectl --context talos label node talos-w1 dbg-pool-
```][Das angehängte Minus entfernt Taint bzw. Label.]

#distro[
  Der RKE2-Server nimmt im Labor Workloads an und hat keinen Taint. Wer Server-Knoten frei halten will, setzt in `/etc/rancher/rke2/config.yaml` zum Beispiel `node-taint: ["CriticalAddonsOnly=true:NoExecute"]`. Dauerhafte Labels gehören dort unter `node-label:`.
][
  Ohne `cluster.allowSchedulingOnControlPlanes: true` trägt `talos-cp` den Taint `node-role.kubernetes.io/control-plane:NoSchedule`. In einem Cluster mit nur einem Worker landet dann jeder Pod dort, und ist der Worker voll oder weg, bleibt alles `Pending` mit `had untolerated taint(s)`. Im Labor ist das Scheduling auf der Control Plane erlaubt. Dauerhafte Labels gehören in `machine.nodeLabels`.
]

== PVC ohne StorageClass

Ein Pod mit einem PersistentVolumeClaim kann erst starten, wenn der Claim an ein Volume gebunden ist oder gebunden werden kann. Im Labor gibt es auf beiden Clustern die StorageClass `local-path`, aber sie ist bewusst *nicht* Standard. Eine PVC ohne `storageClassName` bekommt deshalb keine Klasse, und niemand legt ein Volume an.

#datei("szenarien/04-pending/kaputt-pvc.yaml (Ausschnitt)", ```yaml
kind: PersistentVolumeClaim
metadata:
  name: daten
  namespace: dbg-04
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
# ... Deployment "datenbank" bindet die PVC unter /daten ein
```, erklaerung: [Kein `storageClassName`. Das sieht man in vielen Helm-Charts, die sich auf eine Default-StorageClass verlassen.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/kaputt-pvc.yaml
kubectl --context talos apply -f szenarien/04-pending/kaputt-pvc.yaml
```][Legt PVC `daten` und Deployment `datenbank` an.]

#symptom[
```text
$ kubectl --context rke2 get pvc -n dbg-04
NAME    STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
daten   Pending                                                     <unset>                 31s
```
Die PVC ist `Pending`, die Spalte `STORAGECLASS` ist leer. Der Pod `datenbank-...` ist ebenfalls `Pending`.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-04 -l app=datenbank | tail -n 3
kubectl --context rke2 describe pvc -n dbg-04 daten | tail -n 4
```][Erst der Pod, dann die PVC. Die eigentliche Erklärung steht bei der PVC.]

```text
  Warning  FailedScheduling  40s   default-scheduler  0/2 nodes are available: pod has unbound
  immediate PersistentVolumeClaims. preemption: 0/2 nodes are available: 2 Preemption is not
  helpful for scheduling.

  Type    Reason         Age              From                         Message
  ----    ------         ----             ----                         -------
  Normal  FailedBinding  5s (x4 over 40s) persistentvolume-controller  no persistent volumes
  available for this claim and no storage class is set
```

Beachte die Form der Scheduler-Meldung: keine Zählung je Knoten, sondern ein einziger Satz. Das Volume-Binding scheitert schon vor der Prüfung der einzelnen Knoten. Und die PVC-Meldung ist vom Typ `Normal`, nicht `Warning`. Wer mit `--types=Warning` filtert, übersieht sie.

`kubectl --context rke2 get storageclass` zeigt `local-path` ohne den Zusatz `(default)` hinter dem Namen. In k9s: `:pvc dbg-04⏎`, PVC auswählen, `d`. Die Spalte `STORAGECLASS` ist schon in der Liste leer.

#ursache[
  Ohne `storageClassName` und ohne Default-StorageClass gibt es niemanden, der ein Volume bereitstellt. Der PV-Controller sucht ein vorhandenes, passendes PersistentVolume ohne Klasse, findet keines und wartet. Der Scheduler wiederum setzt keinen Pod mit ungebundener PVC im Modus `Immediate` auf einen Knoten. Beide warten aufeinander, für immer.
]

=== Beheben

Die PVC nennt die Klasse ausdrücklich. Die Spezifikation einer bestehenden PVC lässt sich nur eingeschränkt ändern, deshalb löschst du Deployment und PVC und legst beide neu an:

#datei("szenarien/04-pending/fix-pvc.yaml (Ausschnitt)", ```yaml
spec:
  storageClassName: local-path
  accessModes: ["ReadWriteOnce"]
```)

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-04 delete deployment datenbank
kubectl --context rke2 -n dbg-04 delete pvc daten
kubectl --context rke2 apply -f szenarien/04-pending/fix-pvc.yaml
```][Auf Talos dieselben drei Befehle mit `--context talos`. Die PVC zuerst zu löschen hilft nicht: Solange ein Pod sie verwendet, hält der Finalizer `kubernetes.io/pvc-protection` sie in `Terminating`.]

#pruefe[
```text
$ kubectl --context rke2 get pvc -n dbg-04
NAME    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   ...
daten   Bound    pvc-3c1e6a0b-8f5d-4c47-9b1e-2d7a4f0c9e18   1Gi        RWO            local-path     ...
```
Direkt nach dem Anlegen steht die PVC kurz auf `Pending` mit dem Event `WaitForFirstConsumer`: `local-path` legt das Volume erst an, wenn der Pod einen Knoten hat. Das ist kein Fehler.
]

#falle[
  Alternativ machst du `local-path` per Annotation `storageclass.kubernetes.io/is-default-class: "true"` zur Standardklasse. Seit Kubernetes 1.28 bekommen dann auch bestehende PVCs ohne Klasse nachträglich diese Klasse. Im Labor bleibt sie absichtlich ohne Default.
]

#distro[
  RKE2 bringt keine StorageClass mit. `local-path` aus Kapitel 2 legt die Daten auf dem Knoten unter `/opt/local-path-provisioner` ab.
][
  Talos bringt ebenfalls keine StorageClass mit. `local-path` schreibt unter `/var/mnt/local-path-provisioner`, und der Helper-Pod läuft im Namespace `local-path-storage`, der deshalb `enforce=privileged` trägt. Fehlt das Label, scheitert der Helper-Pod, und die PVC bleibt trotz Klasse `Pending`. Diesen Fall behandelt Kapitel 9.
]

== ResourceQuota: Der Pod, den es nicht gibt

Die ersten drei Szenarien hatten einen Pod in `Pending`. Dieses hat gar keinen Pod. Eine ResourceQuota begrenzt, was ein Namespace insgesamt anfordern darf. Sobald sie CPU oder Speicher begrenzt, muss außerdem *jeder* Container Requests und Limits für diese Ressourcen angeben. Die Quota-Admission prüft das beim Anlegen des Pods im API-Server, und wer es nicht erfüllt, wird abgelehnt.

Lösche vorher mit `kubectl --context rke2 -n dbg-04 delete deployment --all` (und ebenso auf Talos) die Deployments der anderen Szenarien, damit die Zahlen unten übersichtlich bleiben.

#datei("szenarien/04-pending/kaputt-quota.yaml (Ausschnitt)", ```yaml
kind: ResourceQuota
metadata:
  name: dbg-quota
  namespace: dbg-04
spec:
  hard:
    pods: "10"
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
---
# ... Deployment "web" mit nginx:1.29, 2 Replikas, ohne resources
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/kaputt-quota.yaml
kubectl --context talos apply -f szenarien/04-pending/kaputt-quota.yaml
```][`apply` meldet `deployment.apps/web created`. Kein Fehler, keine Warnung.]

#symptom[
```text
$ kubectl --context rke2 get deploy,pods -n dbg-04 -l app=web
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   0/2     0            0           25s
```
Das Deployment existiert, aber es gibt keinen einzigen Pod, auch keinen in `Pending`.
]

=== Untersuchen

Die Kette lautet Deployment → ReplicaSet → Pod. Fehlt das letzte Glied, liegt der Fehler beim vorletzten:

#cmd("Mac")[```bash
kubectl --context rke2 get rs -n dbg-04 -l app=web
kubectl --context rke2 describe rs -n dbg-04 -l app=web | tail -n 4
```][Das ReplicaSet will zwei Pods (`DESIRED`), hat aber keinen (`CURRENT`). In seinen Events steht, warum.]

```text
NAME             DESIRED   CURRENT   READY   AGE
web-5d8c6b7f9c   2         0         0       31s

  Warning  FailedCreate  12s (x5 over 31s)  replicaset-controller  Error creating: pods
  "web-5d8c6b7f9c-x8k2p" is forbidden: failed quota: dbg-quota: must specify limits.cpu for: web;
  limits.memory for: web; requests.cpu for: web; requests.memory for: web
```

Auch das Deployment kennt das Problem: `kubectl describe deploy` zeigt unter `Conditions` die Zeile `ReplicaFailure True FailedCreate`. In k9s ist der schnellste Weg `:deploy dbg-04⏎`, dann `Enter` auf `web`. Das führt zum ReplicaSet, dort `d` für die Events. Den Füllstand der Quota zeigt `:quota dbg-04⏎` mit `d`, oder auf der Kommandozeile `kubectl --context rke2 describe quota -n dbg-04`.

#ursache[
  Die Quota begrenzt `requests.cpu`, `requests.memory`, `limits.cpu` und `limits.memory`. Damit verlangt die Admission von jedem Container in `dbg-04` genau diese vier Angaben. Der nginx-Container hat keine, also lehnt der API-Server jeden Pod ab. Das ReplicaSet versucht es mit wachsenden Abständen immer wieder und protokolliert jeden Versuch als `FailedCreate`. Weil kein Pod entsteht, gibt es auch kein Pod-Event, und `kubectl get pods` bleibt leer.
]

=== Beheben

#datei("szenarien/04-pending/fix-quota.yaml (Ausschnitt)", ```yaml
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 128Mi
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/04-pending/fix-quota.yaml
kubectl --context talos apply -f szenarien/04-pending/fix-quota.yaml
```][Neues Pod-Template, neues ReplicaSet. Das alte wird auf null skaliert.]

#pruefe[
```text
$ kubectl --context rke2 describe quota -n dbg-04
Name:            dbg-quota
Namespace:       dbg-04
Resource         Used   Hard
--------         ----   ----
limits.cpu       500m   2
limits.memory    256Mi  2Gi
pods             2      10
requests.cpu     200m   1
requests.memory  128Mi  1Gi
```
Zwei Pods laufen, und die Quota zählt genau deren Requests und Limits.
]

Ist die Quota ausgeschöpft, lautet die Meldung `exceeded quota: dbg-quota, requested: ..., used: ..., limited: ...`. Der Ort bleibt derselbe, die Events am ReplicaSet. Dort landen auch Ablehnungen durch Pod Security (Kapitel 10) und Webhooks wie Kyverno (Kapitel 11).

#aufgabe[
  Wende `szenarien/04-pending/aufgabe-limitrange.yaml` auf einen der beiden Cluster an. Das Deployment `rechner` erreicht nie `1/1`. Finde heraus, warum, ohne die Datei vorher zu lesen, und behebe es mit einer eigenen Änderung.

  Hinweis: Auch hier gibt es keinen Pod. Die Events am ReplicaSet nennen eine LimitRange, deren `max` kleiner ist als das Limit des Containers. Senke `limits.cpu` auf höchstens `500m`. Requests brauchst du nicht zu ergänzen: Gibt ein Container nur Limits an, setzt Kubernetes die Requests auf denselben Wert, und damit ist auch die Quota zufrieden.
]

Zum Schluss räumst du auf. Damit verschwinden Quota, LimitRange, PVC und alle Deployments:

#cmd("Mac")[```bash
kubectl --context rke2 delete namespace dbg-04
kubectl --context talos delete namespace dbg-04
```][Das local-path-Volume wird wegen `RECLAIMPOLICY Delete` mit gelöscht.]

#gelernt(
  [`Pending` heißt: kein Knoten. Logs gibt es keine, die Antwort steht in den Events des Pods (`describe`, `kubectl events --for`).],
  [Die Scheduler-Meldung zählt Gründe je Knoten. Mehrere Gründe ergeben zusammen die Knotenzahl, „Preemption is not helpful“ heißt: Du musst selbst etwas ändern.],
  [Requests sind Reservierungen gegen `allocatable`, nicht gegen die tatsächliche Last.],
  [Selektor sagt, wohin ein Pod will, Toleration, wohin er darf. Welches Label fehlt und welcher Taint stört, zeigst du mit `custom-columns` an den Knoten.],
  [Beide Labor-Distributionen haben keine Default-StorageClass. PVCs brauchen dort `storageClassName`.],
  [Fehlt der Pod ganz, liegt die Antwort am ReplicaSet (`FailedCreate`): Quota, LimitRange, Pod Security oder Webhook.],
)
