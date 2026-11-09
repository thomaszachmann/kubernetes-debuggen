#import "../lib.typ": *

#kapitel(
  [RBAC und Pod Security],
  ziel: [Du liest `Forbidden`-Meldungen wie ein Protokoll, prüfst Rechte mit `kubectl auth can-i`, findest falsch gebundene Rollen und erkennst, wann Pod Security Admission einen Pod ablehnt, obwohl das Deployment angenommen wurde.],
  zeit: [60 Minuten],
  braucht: [Kapitel 2 und 3],
)

== Was in diesem Kapitel kaputtgeht

Zwei Mechanismen sagen im Cluster „nein“, und beide antworten mit `Forbidden`. RBAC entscheidet, *wer* eine Aktion auf der API ausführen darf. Pod Security Admission (PSA) entscheidet, *welche* Pods überhaupt entstehen dürfen, egal wer sie anlegt. Die Meldungen sehen sich ähnlich, die Fehlersuche ist aber völlig verschieden.

#tabelle(
  (auto, 1fr, 1fr),
  ([Szenario], [Symptom], [Wo die Antwort steht]),
  [RoleBinding im falschen Namespace], [Pod in `CrashLoopBackOff`, Log: `cannot list resource "pods"`], [`kubectl auth can-i --as`, `get rolebindings -A`],
  [Role statt ClusterRole], [Log: `... at the cluster scope`], [`kubectl api-resources --namespaced=false`],
  [hostPath auf Talos], [DaemonSet `0/2`, kein Pod], [Event `FailedCreate` am DaemonSet],
  [Namespace mit `restricted`], [Deployment `0/2`, kein Pod], [Event `FailedCreate` am ReplicaSet],
)

Alle Szenarien laufen im Namespace `dbg-10`. Spiele sie in der Reihenfolge des Kapitels. Die PSA-Szenarien setzen Labels am Namespace, die für alles darin gelten.

== Eine Forbidden-Meldung lesen

Jede RBAC-Ablehnung folgt demselben Satzbau. Wer ihn kennt, muss nicht raten:

```text
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:dbg-10:app"
cannot list resource "pods" in API group "" in the namespace "dbg-10"
```

#tabelle(
  (auto, 1fr),
  ([Teil], [Bedeutung]),
  [`User "system:serviceaccount:dbg-10:app"`], [Die Identität. Bei ServiceAccounts immer `system:serviceaccount:<namespace>:<name>`.],
  [`cannot list`], [Das Verb: `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`.],
  [`resource "pods"`], [Die Ressource im Plural, bei Unterressourcen etwa `pods/log` oder `pods/exec`.],
  [`in API group ""`], [Die API-Gruppe. `""` ist die Kerngruppe (Pods, Services, ConfigMaps), Deployments liegen in `apps`.],
  [`in the namespace "dbg-10"`], [Der Geltungsbereich. Bei cluster-weiten Ressourcen steht hier `at the cluster scope`.],
)

Diese fünf Angaben übersetzt du eins zu eins in eine Regel einer Role. Fehlt eine davon in der Rolle, oder bindet die Rolle die falsche Identität, kommt `Forbidden`.

== RoleBinding im falschen Namespace

Eine Role gilt nur in ihrem Namespace, eine RoleBinding ebenso. Ein häufiger Kopierfehler: Die RoleBinding stammt aus einem anderen Projekt, und ihr `metadata.namespace` wurde nicht angepasst.

#datei("szenarien/10-rbac-psa/kaputt-binding.yaml (Ausschnitt)", ```yaml
kind: RoleBinding
metadata:
  name: pod-reader
  namespace: default        # Fehler: kopiert, Namespace nicht angepasst
subjects:
  - kind: ServiceAccount
    name: app
    namespace: dbg-10
roleRef:
  kind: Role
  name: pod-reader
# ...
      containers:
        - name: kubectl
          image: registry.k8s.io/kubectl:v1.36.6
          args: ["get", "pods", "-n", "dbg-10", "--watch"]
```, erklaerung: [Der Container führt `kubectl get pods --watch` mit dem Token des ServiceAccounts `app` aus. Klappt das, läuft er dauerhaft. Scheitert es, beendet sich `kubectl` mit Exit-Code 1. Der Pod erfüllt `restricted`, damit er dir später nicht mit PSA dazwischenfunkt.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/kaputt-binding.yaml
kubectl --context talos apply -f szenarien/10-rbac-psa/kaputt-binding.yaml
```][Legt Namespace, ServiceAccount, Role, die falsche RoleBinding und das Deployment `pod-lister` an.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-10
NAME                         READY   STATUS             RESTARTS      AGE
pod-lister-7d9f6c8b5-k2x8w   0/1     CrashLoopBackOff   3 (28s ago)   75s
```
Ein CrashLoop wie aus Kapitel 6. Erst das Log zeigt, dass es kein Programmfehler ist.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 logs -n dbg-10 deploy/pod-lister
```][Bei einem Neustart-Zyklus kann der Container gerade weg sein. Dann hilft `--previous`.]

```text
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:dbg-10:app"
cannot list resource "pods" in API group "" in the namespace "dbg-10"
```

Jetzt fragst du den API-Server selbst, ob diese Identität das darf. `--as` lässt dich als jemand anderes auftreten, ohne dessen Token zu kennen. Dein Admin-Konto darf das, normale Benutzer nicht.

#cmd("Mac")[```bash
kubectl --context rke2 auth can-i list pods -n dbg-10 \
  --as=system:serviceaccount:dbg-10:app
```][Antwortet mit `yes` oder `no`. Das ist dieselbe Prüfung, die der API-Server bei echten Anfragen macht.]

```text
no
```

Was darf der ServiceAccount überhaupt? `--list` zählt alle Regeln auf, die für ihn in diesem Namespace greifen:

#cmd("Mac")[```bash
kubectl --context rke2 auth can-i --list -n dbg-10 \
  --as=system:serviceaccount:dbg-10:app
```][Hier stehen nur die Grundrechte, die jeder authentifizierte Benutzer hat (`selfsubjectaccessreviews`, `/api/*` und Ähnliches), aber keine Pods.]

Die Role existiert aber. Also suchst du die Bindung, und zwar in allen Namespaces:

#cmd("Mac")[```bash
kubectl --context rke2 get rolebindings -A -o wide | grep -E 'NAMESPACE|pod-reader'
```][`-o wide` zeigt Rolle und Subjekte. So siehst du, wo die Bindung wirklich liegt.]

```text
NAMESPACE   NAME         ROLE              AGE   USERS   GROUPS   SERVICEACCOUNTS
default     pod-reader   Role/pod-reader   3m                     dbg-10/app
```

Die Bindung liegt in `default` und verweist auf eine Role `pod-reader` in `default`. Die gibt es dort nicht. Der API-Server prüft das beim Anlegen nicht, eine RoleBinding auf eine fehlende Rolle ist erlaubt und wirkungslos.

#cmd("k9s")[```text
:sa dbg-10⏎        app auswählen, Enter = wirksame Regeln
:rolebindings⏎     0 = alle Namespaces, d = describe
```][In der ServiceAccount-Ansicht zeigt `Enter` die Regeln, die über Bindungen auf den Account wirken. Bleibt die Liste leer, greift keine Bindung. `u` zeigt, welche Pods den Account benutzen.]

#ursache[
  Role und RoleBinding sind namespaced, und eine RoleBinding verweist immer auf eine Role im *eigenen* Namespace. Die Bindung in `default` sucht dort eine Role `pod-reader`, findet keine und vergibt deshalb nichts. Der ServiceAccount in `dbg-10` bleibt ohne Rechte.
]

=== Beheben

#datei("szenarien/10-rbac-psa/fix-binding.yaml (Ausschnitt)", ```yaml
kind: RoleBinding
metadata:
  name: pod-reader
  namespace: dbg-10
```)

#cmd("Mac")[```bash
kubectl --context rke2 delete rolebinding pod-reader -n default
kubectl --context rke2 apply -f szenarien/10-rbac-psa/fix-binding.yaml
kubectl --context rke2 rollout restart deploy/pod-lister -n dbg-10
```][Löscht die verirrte Bindung und legt die richtige an. RBAC wird bei jeder Anfrage neu geprüft, der Neustart verkürzt nur das Warten auf das Ende des Backoffs. Auf Talos dieselben Befehle mit `--context talos`.]

#pruefe[
`kubectl --context rke2 auth can-i list pods -n dbg-10 --as=system:serviceaccount:dbg-10:app` antwortet `yes`. Der Pod läuft, und sein Log zeigt die Pod-Liste:
```text
NAME                         READY   STATUS    RESTARTS   AGE
pod-lister-6b8d7f9c4-q7tlm   1/1     Running   0          5s
```
]

== Role statt ClusterRole

Manche Ressourcen gehören keinem Namespace: Nodes, PersistentVolumes, Namespaces selbst, StorageClasses, ClusterRoles. Eine Role kann darauf keine Rechte vergeben. Der API-Server nimmt eine solche Role trotzdem an, denn er prüft Regeln nicht auf Sinn.

#datei("szenarien/10-rbac-psa/kaputt-clusterrole.yaml (Ausschnitt)", ```yaml
kind: Role
metadata:
  name: node-reader
  namespace: dbg-10
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
```, erklaerung: [Dazu ein ServiceAccount `node-reader`, eine passende RoleBinding in `dbg-10` und ein Deployment, das `kubectl get nodes --watch` ausführt.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/kaputt-clusterrole.yaml
```][Diesmal ist die Bindung im richtigen Namespace.]

#symptom[
  Der Pod `node-lister` geht in `CrashLoopBackOff`. Das Log:
```text
Error from server (Forbidden): nodes is forbidden: User "system:serviceaccount:dbg-10:node-reader"
cannot list resource "nodes" in API group "" at the cluster scope
```
]

=== Untersuchen

Der entscheidende Teil ist `at the cluster scope`. Die Anfrage hat keinen Namespace, also können nur cluster-weite Bindungen helfen. Ob eine Ressource namespaced ist, verrät `api-resources`:

#cmd("Mac")[```bash
kubectl --context rke2 api-resources --namespaced=false | grep -E 'NAME|^nodes'
```][Listet nur cluster-weite Ressourcen. Mit `--namespaced=true` bekommst du die Gegenliste.]

```text
NAME    SHORTNAMES   APIVERSION   NAMESPACED   KIND
nodes   no           v1           false        Node
```

`kubectl auth can-i list nodes -n dbg-10 --as=system:serviceaccount:dbg-10:node-reader` antwortet `no`, obwohl die Role genau dieses Recht nennt. Ein `-n` ändert nichts, Nodes kennen keinen Namespace.

#ursache[
  RBAC wertet eine Role nur für Anfragen *innerhalb* ihres Namespace aus. `list nodes` ist eine Anfrage ohne Namespace, dafür zählen ausschließlich ClusterRoleBindings. Auch eine RoleBinding, die auf eine ClusterRole zeigt, hilft nicht: Sie vergibt deren Rechte nur innerhalb des Namespace der Bindung.
]

=== Beheben

#datei("szenarien/10-rbac-psa/fix-clusterrole.yaml (Ausschnitt)", ```yaml
kind: ClusterRole
metadata:
  name: dbg-10-node-reader
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
---
kind: ClusterRoleBinding
metadata:
  name: dbg-10-node-reader
subjects:
  - kind: ServiceAccount
    name: node-reader
    namespace: dbg-10
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/fix-clusterrole.yaml
kubectl --context rke2 rollout restart deploy/node-lister -n dbg-10
```][Vergibt das Leserecht auf Nodes cluster-weit, aber nur an diesen einen ServiceAccount.]

#pruefe[
  `auth can-i list nodes --as=system:serviceaccount:dbg-10:node-reader` antwortet `yes`, und `kubectl --context rke2 logs -n dbg-10 deploy/node-lister` zeigt `rke2-cp` und `rke2-w1`.
]

#falle[
  ClusterRole und ClusterRoleBinding gehören keinem Namespace, `kubectl delete ns dbg-10` entfernt sie nicht. Vergessene ClusterRoleBindings sind ein Klassiker bei Audits: Legt jemand später einen ServiceAccount mit gleichem Namen an, erbt er die Rechte.
]

== Pod Security: Was die Distributionen vorgeben

PSA prüft Pods gegen eine von drei Stufen: `privileged` (alles erlaubt), `baseline` (keine bekannten Ausbrüche wie `privileged`, `hostPath`, Host-Namespaces) und `restricted` (zusätzlich kein root, alle Capabilities weg, Seccomp). Pro Namespace legen Labels die Stufe für drei Modi fest: `enforce` lehnt ab, `warn` gibt `kubectl` eine Warnung zurück, `audit` schreibt ins Audit-Log. Fehlt ein Label, gilt die cluster-weite Vorgabe des API-Servers. Und genau die unterscheidet sich im Labor:

#distro(
  [Ohne `profile` in `/etc/rancher/rke2/config.yaml` schreibt RKE2 nach `/etc/rancher/rke2/rke2-pss.yaml` nur `enforce: privileged`. Es gibt keine Vorgabe für `warn` und `audit`, also auch keine Warnungen. Mit `profile: cis` wird daraus `restricted` für alle drei Modi, ausgenommen sind `kube-system`, `compliance-operator-system` und `tigera-operator`. Eine eigene Datei setzt du mit `pod-security-admission-config-file`.],
  [Talos setzt in der Machine-Config unter `cluster.apiServer.admissionControl` cluster-weit `enforce: baseline`, `audit: restricted` und `warn: restricted`. Ausgenommen ist nur `kube-system`. Deshalb siehst du auf Talos bei vielen Manifesten Warnungen `would violate PodSecurity "restricted:latest"`, die nichts blockieren. Ändern kannst du die Vorgabe mit einem Machine-Config-Patch.],
)

Dasselbe Manifest kann also auf RKE2 laufen und auf Talos scheitern. Prüfe die Vorgabe deines Clusters, bevor du ein Problem anderswo suchst:

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 get machineconfig -o yaml | grep -A 14 'name: PodSecurity'
```][Zeigt den PSA-Block aus der aktiven Machine-Config des Control-Plane-Knotens. Auf RKE2 liest du stattdessen auf `rke2-cp` die Datei `/etc/rancher/rke2/rke2-pss.yaml`.]

== hostPath: läuft auf RKE2, nicht auf Talos

Ein kleiner Log-Sammler soll auf jedem Knoten `/var/log` lesen. Typischer Kandidat für ein DaemonSet mit `hostPath`.

#datei("szenarien/10-rbac-psa/kaputt-hostpath.yaml (Ausschnitt)", ```yaml
kind: DaemonSet
metadata:
  name: log-sammler
  namespace: dbg-10
# ...
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/kaputt-hostpath.yaml
kubectl --context talos apply -f szenarien/10-rbac-psa/kaputt-hostpath.yaml
```][Auf RKE2 kommt keine Rückfrage. Auf Talos gibt `kubectl` eine Warnung aus.]

```text
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false
(container "sammler" must set securityContext.allowPrivilegeEscalation=false), ...
restricted volume types (volume "varlog" uses restricted volume type "hostPath"), ...
daemonset.apps/log-sammler created
```

#symptom[
```text
$ kubectl --context talos get ds -n dbg-10
NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
log-sammler   2         0         0       0            0           <none>          40s
```
Zwei Pods gewünscht, null angelegt. Auf RKE2 steht in derselben Zeile `2 2 2`.
]

=== Untersuchen

Wo kein Pod ist, gibt es kein `describe pod`. Die Meldung hängt am Objekt, das den Pod anlegen wollte:

#cmd("Mac")[```bash
kubectl --context talos events -n dbg-10 --for daemonset/log-sammler
```][Die Events des DaemonSets. Bei Deployments schaust du eine Ebene tiefer, beim ReplicaSet.]

```text
LAST SEEN   TYPE      REASON         OBJECT                  MESSAGE
12s         Warning   FailedCreate   DaemonSet/log-sammler   Error creating: pods "log-sammler-8kq2d" is
forbidden: violates PodSecurity "baseline:latest": hostPath volumes (volume "varlog")
```

#cmd("k9s")[```text
:ds dbg-10⏎        log-sammler auswählen, d = describe
:events⏎           / FailedCreate⏎
```][Die Warnung steht am Ende der Describe-Ansicht des DaemonSets. In der Event-Ansicht filterst du mit `/` nach dem Reason.]

`kubectl --context talos get ns dbg-10 --show-labels` bestätigt: kein Label `pod-security.kubernetes.io/...`, also gilt die Talos-Vorgabe.

#ursache[
  Die Warnung beim `apply` kam aus dem Modus `warn` (Talos: `restricted`) und hat das DaemonSet nicht aufgehalten. PSA prüft im Modus `enforce` nur Pods, nicht ihre Controller. Deshalb wurde das DaemonSet angenommen, und erst der DaemonSet-Controller bekam beim Anlegen jedes Pods die Ablehnung gegen `baseline`. RKE2 ohne CIS-Profil erzwingt `privileged` und lässt den Pod durch.
]

=== Beheben

Zwei saubere Wege: Der Pod verzichtet auf `hostPath`, oder der Namespace bekommt bewusst eine Ausnahme. Ein Log-Sammler braucht den Knoten, also das Zweite. Dabei setzt du `warn` und `audit` auf `baseline`, damit die Ausnahme sichtbar bleibt.

#datei("szenarien/10-rbac-psa/fix-hostpath.yaml", ```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dbg-10
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/warn-version: latest
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/audit-version: latest
```)

#cmd("Mac")[```bash
kubectl --context talos apply -f szenarien/10-rbac-psa/fix-hostpath.yaml
```][Der DaemonSet-Controller versucht es nach einer Wartezeit erneut, du musst nichts neu starten.]

#pruefe[
  `kubectl --context talos get ds -n dbg-10` zeigt `2 2 2`. Jede Änderung am DaemonSet bringt weiterhin die Warnung `would violate PodSecurity "baseline:latest": hostPath volumes ...`. Das ist gewollt: Die Ausnahme erinnert an sich selbst.
]

#falle[
  Dasselbe trifft `kubectl debug` auf Talos. Das Standardprofil `general` fügt die Capability `SYS_PTRACE` hinzu, und `baseline` lehnt den Debug-Container ab. Nutze dort immer `--profile=baseline`, wie es auch das k9s-Plugin aus Kapitel 3 tut.
]

== restricted: Deployment ja, Pods nein

Für das letzte Szenario setzt du den Namespace neu auf, diesmal mit der strengsten Stufe. Das ist der Normalfall für Anwendungs-Namespaces.

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-10
kubectl --context talos delete ns dbg-10
```][Räumt die bisherigen Szenarien ab. Denk an die ClusterRole aus dem zweiten Szenario, sie bleibt stehen.]

#datei("szenarien/10-rbac-psa/kaputt-restricted.yaml (Ausschnitt)", ```yaml
kind: Namespace
metadata:
  name: dbg-10
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
# ...
      containers:
        - name: web
          image: nginx:1.29-alpine
```, erklaerung: [Ein gewöhnliches nginx-Image ohne `securityContext`. Es läuft als root.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/kaputt-restricted.yaml
```][Hier zeigt sich RKE2 genauso streng wie Talos, denn das Label am Namespace schlägt jede cluster-weite Vorgabe.]

```text
namespace/dbg-10 created
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false
(container "web" must set securityContext.allowPrivilegeEscalation=false), ...
deployment.apps/web created
```

#symptom[
```text
$ kubectl --context rke2 get deploy,rs,pods -n dbg-10
NAME                  READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web   0/2     0            0           30s

NAME                             DESIRED   CURRENT   READY   AGE
replicaset.apps/web-5d7c9b8f6d   2         0         0       30s
```
`created` und trotzdem kein einziger Pod. In Pipelines geht die Warnung oben gern unter, dann ist dieses Bild alles, was du siehst.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 describe rs -n dbg-10 -l app=web | tail -4
```][Das ReplicaSet legt die Pods an, also hat es die Ablehnung bekommen.]

```text
  Warning  FailedCreate  12s (x14 over 52s)  replicaset-controller  Error creating: pods
"web-5d7c9b8f6d-x7k2p" is forbidden: violates PodSecurity "restricted:latest":
allowPrivilegeEscalation != false (container "web" must set securityContext.
allowPrivilegeEscalation=false), unrestricted capabilities (container "web" must set
securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "web"
must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "web" must
set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Die Meldung ist eine Checkliste. Jede Klammer nennt das Feld, das fehlt. Bevor du einen bestehenden Namespace verschärfst, prüft `kubectl label --dry-run=server --overwrite ns <name> pod-security.kubernetes.io/enforce=restricted` alle laufenden Pods gegen die neue Stufe, ohne das Label zu setzen.

#ursache[
  `enforce` gilt nur für Pods. Ein Deployment enthält zwar eine Pod-Vorlage, wird aber nur im Modus `warn` und `audit` geprüft. Das Deployment entsteht, das ReplicaSet ebenfalls, und erst die Pods scheitern. Ohne `warn`-Label (auf RKE2 ohne CIS der Normalfall) gäbe es beim `apply` nicht einmal die Warnung.
]

=== Beheben

Nicht die Stufe senken, sondern den Pod reparieren. nginx bietet ein Image, das ohne root auf Port 8080 läuft.

#datei("szenarien/10-rbac-psa/fix-restricted.yaml (Ausschnitt)", ```yaml
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: nginxinc/nginx-unprivileged:1.29-alpine
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/10-rbac-psa/fix-restricted.yaml
kubectl --context talos apply -f szenarien/10-rbac-psa/kaputt-restricted.yaml \
  -f szenarien/10-rbac-psa/fix-restricted.yaml
```][Auf Talos legst du Namespace und Fix in einem Schritt an. Diesmal kommt keine Warnung mehr.]

#pruefe[
```text
$ kubectl --context rke2 get pods -n dbg-10
NAME                   READY   STATUS    RESTARTS   AGE
web-6f8b7d5c9b-4tq8z   1/1     Running   0          8s
web-6f8b7d5c9b-n2wlx   1/1     Running   0          8s
```
]

#aufgabe[
  `szenarien/10-rbac-psa/aufgabe-job.yaml` legt einen Job an, der ConfigMaps in `dbg-10` lesen soll. Er scheitert mit `Forbidden`, obwohl Role und RoleBinding im richtigen Namespace liegen und den richtigen ServiceAccount nennen. Finde den Fehler nur mit dem Log und `kubectl auth can-i`.

  Hinweis: Lies in der Meldung den Teil `in API group "..."` und vergleiche ihn mit `apiGroups` der Role.
]

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-10
kubectl --context talos delete ns dbg-10
kubectl --context rke2 delete -f szenarien/10-rbac-psa/fix-clusterrole.yaml
```][Räumt das Kapitel auf, einschließlich der cluster-weiten Objekte.]

#gelernt(
  [Eine `Forbidden`-Meldung nennt Identität, Verb, Ressource, API-Gruppe und Geltungsbereich, genau das, was eine Rolle enthalten muss.],
  [`kubectl auth can-i ... --as=system:serviceaccount:<ns>:<name>` beantwortet Rechtefragen, ohne den Pod zu bemühen. `--list` zeigt alles.],
  [RoleBindings wirken nur in ihrem Namespace. Cluster-weite Ressourcen brauchen ClusterRole und ClusterRoleBinding.],
  [PSA erzwingt Stufen nur für Pods. Deployments und DaemonSets werden angenommen, die Ablehnung steht als `FailedCreate` am Controller.],
  [RKE2 ohne CIS erzwingt `privileged`, Talos `baseline`. Labels am Namespace schlagen beide Vorgaben.],
)
