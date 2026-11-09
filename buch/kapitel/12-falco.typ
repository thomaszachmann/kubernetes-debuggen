#import "../lib.typ": *

#kapitel(
  [Falco: Alarme und Störungen],
  ziel: [Du bringst Falco auf beiden Clustern zum Laufen, führst einen Alarm auf Pod und Container zurück, stellst einen Fehlalarm gezielt ab und erkennst, wenn Falco keine Kubernetes-Metadaten mehr liefert.],
  zeit: [60 Minuten],
  braucht: [Kapitel 2, 3 und 10],
)

== Was in diesem Kapitel kaputtgeht

Falco beobachtet per eBPF die Systemaufrufe auf jedem Knoten und vergleicht sie mit Regeln. Es blockiert nichts, es meldet nur. Fehler mit Falco sind deshalb selten Ausfälle der Anwendung, sondern Fragen an den Betrieb: Warum startet Falco nicht? Woher kommt dieser Alarm? Warum meldet es jede Nacht denselben Job? Und warum steht im Alarm kein Pod-Name?

#tabelle(
  (auto, 1fr, 1fr),
  ([Szenario], [Symptom], [Wo die Antwort steht]),
  [Falco startet nicht auf Talos], [DaemonSet `0/2`], [`FailedCreate` am DaemonSet, PSA `baseline`],
  [Alarm nach `kubectl exec`], [`Terminal shell in container`], [`output_fields`, `hostname`, Container-ID],
  [Fehlalarm durch Job], [Alle zehn Minuten derselbe Alarm], [Regel, Bedingung, `exceptions`],
  [Keine Kubernetes-Metadaten], [`k8s_pod=<NA>` in jedem Alarm], [Socket-Liste und Mounts des Charts],
)

Die Workloads laufen im Namespace `dbg-12`, Falco selbst im Namespace `falco`.

== Falco installieren

Für RKE2 und Talos gibt es je eine Werte-Datei. Sie unterscheiden sich nur in einer Zeile, und genau diese Zeile ist Thema des letzten Szenarios.

#datei("werkzeuge/falco-values-rke2.yaml (Ausschnitt)", ```yaml
tty: true
driver:
  kind: modern_ebpf
falco:
  json_output: true
  json_include_output_property: true
  append_output:
    - suggested_output: true
    - match:
        source: syscall
      extra_output: "k8s_ns=%k8s.ns.name k8s_pod=%k8s.pod.name"
collectors:
  containerEngine:
    engines:
      docker:
        enabled: false
      # ... podman, containerd ebenso aus
      cri:
        enabled: true
        sockets: ["/run/k3s/containerd/containerd.sock"]
```, erklaerung: [`modern_ebpf` braucht kein Kernel-Modul, das ist auf Talos auch gar nicht ladbar. `suggested_output` hängt Container-ID und -Name an jede Meldung, der zweite Eintrag Namespace und Pod. Die Metadaten holt sich das Plugin `container` über die CRI-Schnittstelle von containerd. In `werkzeuge/falco-values-talos.yaml` steht dort `/run/containerd/containerd.sock`.])

#cmd("Mac")[```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm --kube-context rke2 upgrade --install falco falcosecurity/falco \
  -n falco --create-namespace --version 9.2.2 \
  -f werkzeuge/falco-values-rke2.yaml --wait --timeout 5m
```][Chart 9.2.2 bringt Falco 0.45.2 mit. Auf RKE2 läuft das ohne Zwischenfall durch.]

#cmd("Mac")[```bash
kubectl --context rke2 logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=20
```][Mit `-l` liest `kubectl` aus allen Falco-Pods, je Knoten einer. Bei Selektoren zeigt `kubectl` standardmäßig nur zehn Zeilen pro Pod, daher `--tail`.]

```text
Mon Nov  9 14:02:11 2026: Falco version: 0.45.2 (x86_64)
Mon Nov  9 14:02:11 2026: Loading rules from:
Mon Nov  9 14:02:11 2026:    /etc/falco/falco_rules.yaml | schema validation: ok
Mon Nov  9 14:02:12 2026: Opening 'syscall' source with modern BPF probe.
```

Wichtig sind `schema validation: ok` für jede Regeldatei und die Zeile mit `modern BPF probe`. Fehlt sie, kam der Treiber nicht hoch.

== Falco startet nicht auf Talos

Dieselbe Installation auf Talos, aber ohne `--wait`, damit du zusiehst:

#cmd("Mac")[```bash
helm --kube-context talos upgrade --install falco falcosecurity/falco \
  -n falco --create-namespace --version 9.2.2 \
  -f werkzeuge/falco-values-talos.yaml
```][`--create-namespace` legt `falco` ohne Labels an. Helm meldet `STATUS: deployed`, denn ohne `--wait` prüft es nur, ob die Objekte angelegt wurden.]

#symptom[
```text
$ kubectl --context talos get ds -n falco
NAME    DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
falco   2         0         0       0            0           <none>          1m
```
]

=== Untersuchen

Kein Pod, also Events am DaemonSet. Das Muster kennst du aus Kapitel 10:

#cmd("Mac")[```bash
kubectl --context talos events -n falco --for daemonset/falco
```][Oder in k9s: `:ds falco⏎`, dann `d` und ganz nach unten.]

```text
LAST SEEN   TYPE      REASON         OBJECT            MESSAGE
5s          Warning   FailedCreate   DaemonSet/falco   Error creating: pods "falco-7xk2p" is forbidden:
violates PodSecurity "baseline:latest": hostPath volumes (volumes "container-engine-socket-0",
"boot-fs", "lib-modules", "usr-fs", "etc-fs", "sys-fs", "proc-fs"), privileged (container "falco"
must not set securityContext.privileged=true)
```

#ursache[
  Talos erzwingt cluster-weit `baseline`. Falco braucht einen privilegierten Container, um den eBPF-Treiber zu laden, und `hostPath`-Mounts für `/proc`, `/etc` und den containerd-Socket. Beides verbietet `baseline`. Das DaemonSet selbst wird angenommen, denn `enforce` gilt nur für Pods.
]

=== Beheben

#datei("szenarien/12-falco/namespace-falco.yaml", ```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: falco
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: latest
```)

#cmd("Mac")[```bash
kubectl --context talos apply -f szenarien/12-falco/namespace-falco.yaml
kubectl --context talos rollout status ds/falco -n falco --timeout=5m
```][`kubectl apply` warnt, dass der von Helm angelegte Namespace die Annotation `kubectl.kubernetes.io/last-applied-configuration` nicht hat, und ergänzt sie. Das ist harmlos. Bei einer Neuinstallation legst du den Namespace vor Helm an.]

#pruefe[
  `kubectl --context talos get ds -n falco` zeigt `2 2 2`, und das Log enthält `Opening 'syscall' source with modern BPF probe.`
]

#distro(
  [RKE2 ohne CIS-Profil erzwingt `privileged`, Falco startet sofort. Mit `profile: cis` gilt `restricted`, dann brauchst du dasselbe Label wie auf Talos.],
  [Statt des Namespace-Labels kannst du `falco` auch in der Machine-Config unter `cluster.apiServer.admissionControl` bei `exemptions.namespaces` eintragen. Das Label ist sichtbarer und braucht keinen Patch der Knoten. `driver.kind: kmod` funktioniert auf Talos nicht, Kernel-Module lassen sich dort nicht nachladen.],
)

== Alarm nach `kubectl exec`

Ein Kollege öffnet eine Shell in einem Pod. Falco schlägt an. Deine Aufgabe ist, aus dem Alarm herauszulesen, wo das passiert ist.

#datei("szenarien/12-falco/kaputt-shell.yaml (Ausschnitt)", ```yaml
      containers:
        - name: web
          image: busybox:1.37
          command: ["sh", "-c", "while true; do sleep 3600; done"]
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/12-falco/kaputt-shell.yaml
kubectl --context rke2 exec -it -n dbg-12 deploy/web -- sh -c 'id; exit'
```][`-it` gibt der Shell ein Terminal. Genau darauf achtet die Regel `Terminal shell in container`.]

#symptom[
  In den Falco-Logs erscheint eine JSON-Zeile. Den Text unter `output` kürzt dieser Auszug:
```text
{"hostname":"rke2-w1","output":"14:21:37.482915063: Notice A shell was spawned in a container
with an attached terminal | evt_type=execve user=root user_uid=0 user_loginuid=-1 process=sh
proc_exepath=/bin/sh ... command=sh -c id; exit terminal=34816 ... container_id=8f2c41d9a7b3
container_name=web k8s_ns=dbg-12 k8s_pod=web-5b9d8c7f6-tx4lp","priority":"Notice",
"rule":"Terminal shell in container","source":"syscall", ...}
```
]

=== Untersuchen

Bei vielen Meldungen hilft `jq`. Die Felder unter `output_fields` tragen die Namen der Falco-Felder:

#cmd("Mac")[```bash
kubectl --context rke2 logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=500 \
  | jq -cR 'fromjson? | select(.rule=="Terminal shell in container")
      | {hostname, priority,
         ns: .output_fields["k8s.ns.name"], pod: .output_fields["k8s.pod.name"],
         id: .output_fields["container.id"], cmd: .output_fields["proc.cmdline"],
         user: .output_fields["user.name"]}'
```][`fromjson?` überspringt die Textzeilen vom Start. Übrig bleibt pro Alarm eine kompakte Zeile.]

```text
{"hostname":"rke2-w1","priority":"Notice","ns":"dbg-12","pod":"web-5b9d8c7f6-tx4lp",
 "id":"8f2c41d9a7b3","cmd":"sh -c id; exit","user":"root"}
```

#tabelle(
  (auto, 1fr),
  ([Feld], [Was es dir sagt]),
  [`hostname`], [Der Knoten, auf dem Falco den Aufruf gesehen hat. Im Chart ist das der Knotenname.],
  [`k8s.ns.name`, `k8s.pod.name`], [Namespace und Pod. Beide kommen über die Container-Runtime, nicht von der Kubernetes-API.],
  [`container.id`], [Die ersten zwölf Zeichen der Container-ID. Falco liest sie direkt aus den cgroups, sie ist auch ohne Runtime-Zugriff da.],
  [`proc.cmdline`], [Die ausgeführte Befehlszeile.],
  [`user.name`, `user.loginuid`], [Benutzer *im* Container. `-1` heißt: kein Login, typisch für `kubectl exec`.],
)

Die Container-ID ist der sichere Anker, falls Pod-Namen fehlen oder der Pod längst weg ist:

#cmd("Mac")[```bash
kubectl --context rke2 get pods -A \
  -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,ID:.status.containerStatuses[*].containerID \
  | grep 8f2c41d9a7b3
```][`containerID` hat die Form `containerd://8f2c41d9a7b3...`, der Präfix aus Falco reicht für `grep`.]

#cmd("rke2-w1")[```bash
crictl ps -a | grep 8f2c41d9a7b3
```][Auf dem Knoten aus `hostname`, nach den Exporten aus Kapitel 2 (`CRI_CONFIG_FILE`). Für Talos: `talosctl -n 172.16.0.171 containers --namespace cri | grep 8f2c41d9a7b3`.]

#cmd("k9s")[```text
:ds falco⏎      Enter, Pod auf dem richtigen Knoten wählen, l = Logs
/Terminal⏎      Logs auf die Regel filtern
```][In der Log-Ansicht von k9s filtert `/` die Zeilen. Für die Auswertung über mehrere Pods ist `kubectl` mit `jq` bequemer.]

#ursache[
  Kein Fehler im eigentlichen Sinn: Die Regel `Terminal shell in container` meldet jeden Prozess einer Shell mit Terminal, der als Einstiegspunkt in einen Container kommt. `kubectl exec -it` erfüllt genau das. *Wer* den Befehl abgesetzt hat, sieht Falco nicht. Dafür brauchst du das Audit-Log des API-Servers, abgeglichen über Zeit, Namespace und Pod.
]

#pruefe[
  Du kannst zu jedem Alarm Knoten, Namespace, Pod und Container nennen. Ein `kubectl exec` *ohne* `-it`, etwa `kubectl exec -n dbg-12 deploy/web -- id`, löst diese Regel nicht aus.
]

== Fehlalarm durch einen legitimen Job

Ein Aufräum-Job löscht alle zehn Minuten fertige Pods. Dazu spricht er mit `kubectl` die Kubernetes-API an.

#datei("szenarien/12-falco/kaputt-cronjob.yaml (Ausschnitt)", ```yaml
kind: CronJob
metadata:
  name: aufraeumer
  namespace: dbg-12
spec:
  schedule: "*/10 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: aufraeumer
          containers:
            - name: kubectl
              image: registry.k8s.io/kubectl:v1.36.6
              args: ["delete", "pods", "-n", "dbg-12", "--field-selector=status.phase==Succeeded"]
```, erklaerung: [In der Datei steht `args` als Liste über mehrere Zeilen. Role und RoleBinding geben dem ServiceAccount genau `get`, `list` und `delete` auf Pods.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/12-falco/kaputt-cronjob.yaml
kubectl --context rke2 create job -n dbg-12 --from=cronjob/aufraeumer aufraeumer-jetzt
```][Der zweite Befehl startet den Job sofort, statt auf die nächste volle zehnte Minute zu warten.]

#symptom[
```text
14:40:02.118204551: Notice Unexpected connection to K8s API Server from container |
connection=10.42.1.23:51734->10.43.0.1:443 lport=51734 rport=443 fd_type=ipv4 fd_proto=tcp
evt_type=connect user=root ... process=kubectl ... command=kubectl delete pods -n dbg-12
--field-selector=status.phase==Succeeded ... container_name=kubectl k8s_ns=dbg-12
k8s_pod=aufraeumer-jetzt-q8w2n
```
Ab jetzt sechsmal pro Stunde. Wer so etwas eine Woche lang sieht, liest Falco-Alarme nicht mehr.
]

=== Untersuchen

Welche Bedingung hat angeschlagen? Die Regel steht in den Standardregeln des Pods:

#cmd("Mac")[```bash
kubectl --context rke2 exec -n falco ds/falco -c falco -- \
  grep -A 12 'rule: Contact K8S API Server From Container' /etc/falco/falco_rules.yaml
```][Zeigt die Regel, wie sie geladen wurde. Die Regeldateien installiert der Init-Container `falcoctl-artifact-install`.]

```text
- rule: Contact K8S API Server From Container
  desc: > ...
  condition: >
    evt.type=connect
    and (fd.typechar=4 or fd.typechar=6)
    and container
    and k8s_api_server
    and not k8s_containers
    and not user_known_contact_k8s_api_server_activities
```

`k8s_api_server` prüft, ob das Ziel `kubernetes.default.svc.cluster.local` ist. `k8s_containers` ist eine feste Liste bekannter Images, unser Job steht nicht darin.

#ursache[
  Die Regel ist bewusst laut: Ein Container, der die API anspricht, kann ein Angreifer mit gestohlenem Token sein. Unser Job tut das aber legitim und regelmäßig. Ohne Ausnahme erzeugt er Rauschen, das echte Treffer derselben Regel verdeckt.
]

=== Beheben

Nicht die Regel abschalten, sondern eine enge Ausnahme ergänzen: dieser Namespace, dieses Image, dieser Prozess.

#datei("szenarien/12-falco/fix-ausnahme-values.yaml", ```yaml
customRules:
  dbg-ausnahmen.yaml: |-
    - rule: Contact K8S API Server From Container
      exceptions:
        - name: dbg12_aufraeumer
          fields: [k8s.ns.name, container.image.repository, proc.name]
          comps: [=, =, =]
          values:
            - [dbg-12, registry.k8s.io/kubectl, kubectl]
      override:
        exceptions: append
```, erklaerung: [`override: exceptions: append` hängt die Ausnahme an die bestehende Regel an, ohne Bedingung oder Ausgabe anzufassen. Jede Zeile unter `values` ist ein Tupel, passend zu `fields` und `comps`. Das Chart legt `customRules` nach `/etc/falco/rules.d`, das Falco nach den Standardregeln lädt. Das alte `append: true` ist veraltet.])

#cmd("Mac")[```bash
helm --kube-context rke2 upgrade falco falcosecurity/falco -n falco --version 9.2.2 \
  -f werkzeuge/falco-values-rke2.yaml -f szenarien/12-falco/fix-ausnahme-values.yaml --wait
```][Die Falco-Pods starten mit der zusätzlichen Regeldatei neu. Lass bei künftigen Upgrades die zweite Datei nicht weg, sonst ist die Ausnahme wieder verschwunden.]

#pruefe[
  Im Start-Log steht `/etc/falco/rules.d/dbg-ausnahmen.yaml | schema validation: ok`. Ein neuer Lauf mit `kubectl --context rke2 create job -n dbg-12 --from=cronjob/aufraeumer aufraeumer-2` bleibt still. Die Regel selbst lebt noch: `kubectl --context rke2 run apitest -n dbg-12 --image=busybox:1.37 --restart=Never -- wget -T 2 -q -O /dev/null https://kubernetes.default.svc` löst sie weiter aus.
]

#falle[
  Fehlt in einer neuen Ausnahme `fields` oder `values`, verweigert Falco das Laden der Regeln. Der Pod startet dann nicht, im Log steht `Rule exception must have fields property with a list of fields`. Prüfe nach jeder Regeländerung das Start-Log. Für einfache Fälle gibt es einen zweiten Weg: das leere Makro `user_known_contact_k8s_api_server_activities` mit `override: condition: replace` füllen.
]

== Keine Kubernetes-Metadaten

Jemand „vereinheitlicht“ die Falco-Werte für beide Cluster und setzt den Socket auf den Standardpfad. Auf Talos stimmt der, auf RKE2 nicht.

#datei("szenarien/12-falco/kaputt-values-sockets.yaml", ```yaml
collectors:
  containerEngine:
    engines:
      cri:
        enabled: true
        sockets: ["/run/containerd/containerd.sock"]
```)

#cmd("Mac")[```bash
helm --kube-context rke2 upgrade falco falcosecurity/falco -n falco --version 9.2.2 \
  -f werkzeuge/falco-values-rke2.yaml -f szenarien/12-falco/kaputt-values-sockets.yaml --wait
kubectl --context rke2 exec -it -n dbg-12 deploy/web -- sh -c 'exit'
```][Die Werte werden in der Reihenfolge der `-f` zusammengeführt, die letzte Datei gewinnt. Danach löst du den Shell-Alarm erneut aus.]

#symptom[
```text
14:58:10.903311277: Notice A shell was spawned in a container with an attached terminal | ...
container_id=3c7e90b1f2a4 container_name=<NA> k8s_ns=<NA> k8s_pod=<NA>
```
Falco läuft, alle Pods sind `Running`, die Alarme kommen. Nur der Pod fehlt, und eine Ausnahme mit `k8s.ns.name` wie im letzten Szenario greift nicht mehr.
]

=== Untersuchen

`container_id` ist gefüllt, sie stammt aus dem Kernel. Alles, was von der Runtime kommt, fehlt. Also fragst du: Welchen Socket fragt Falco, und gibt es den auf dem Knoten?

#cmd("Mac")[```bash
kubectl --context rke2 get ds falco -n falco -o yaml \
  | yq '.spec.template.spec.volumes[] | select(.hostPath) | .hostPath.path'
```][Das Chart mountet genau die Verzeichnisse der konfigurierten Sockets unter `/host` in den Container.]

```text
/run/containerd
/boot
/lib/modules
/usr
/etc
/sys/kernel
/proc
```

#cmd("rke2-w1")[```bash
grep runtime-endpoint /var/lib/rancher/rke2/agent/etc/crictl.yaml
ls -l /run/containerd/ /run/k3s/containerd/containerd.sock
```][Die crictl-Konfiguration von RKE2 nennt den echten Socket. `/run/containerd/` ist leer oder fehlt.]

```text
runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
/run/containerd/:
total 0
srw-rw---- 1 root root 0 Nov  9 08:11 /run/k3s/containerd/containerd.sock
```

#ursache[
  RKE2 bringt ein eigenes containerd mit, dessen Socket unter `/run/k3s/containerd/` liegt. Das Plugin `container` fragt nur den konfigurierten Pfad und erreicht dort keine Runtime. Ohne Runtime-Antwort bleiben alle Container- und Pod-Felder leer, Falco zeigt `<NA>`. Der Kernel liefert weiter Systemaufrufe und die Container-ID aus den cgroups, deshalb wirkt alles gesund.
]

=== Beheben

#cmd("Mac")[```bash
helm --kube-context rke2 upgrade falco falcosecurity/falco -n falco --version 9.2.2 \
  -f werkzeuge/falco-values-rke2.yaml -f szenarien/12-falco/fix-ausnahme-values.yaml --wait
```][Ohne die kaputte Datei gilt wieder `/run/k3s/containerd/containerd.sock` aus der RKE2-Werte-Datei. Die Ausnahme bleibt erhalten.]

#pruefe[
  Ein neues `kubectl exec -it` erzeugt wieder `container_name=web k8s_ns=dbg-12 k8s_pod=web-...`. Im DaemonSet steht `/run/k3s/containerd` unter den `hostPath`-Volumes.
]

#distro(
  [Socket der Kubelet-Runtime: `/run/k3s/containerd/containerd.sock`. Nachlesen in `/var/lib/rancher/rke2/agent/etc/crictl.yaml`. Die Standardwerte des Charts enthalten diesen Pfad bereits. Der Fehler entsteht erst, wenn jemand die Liste überschreibt.],
  [Talos betreibt zwei containerd-Instanzen: eine für Systemdienste unter `/system/run/containerd/` und eine für die Kubelet-Pods unter `/run/containerd/containerd.sock`. Falco braucht die zweite. Prüfen kannst du sie mit `talosctl -n 172.16.0.171 containers --namespace cri`.],
)

#warum[
  Falco schreibt im Labor auf die Standardausgabe. In Produktion schickst du Alarme an ein zentrales System, etwa mit Falcosidekick, das im Chart als Option enthalten ist. Für die Fehlersuche ändert das nichts: Die Felder sind dieselben, und fehlende Metadaten fallen dort genauso auf, nur später.
]

#aufgabe[
  Öffne auf Talos eine Shell im Pod `web` (Szenario aus diesem Kapitel, `--context talos`). Lies aus dem Alarm Knoten, Pod und Container-ID ab und finde den Container mit `talosctl ... containers --namespace cri`. Welcher der beiden Talos-Knoten war es?

  Hinweis: `hostname` im JSON ist der Knotenname, `talosctl -n` braucht die IP. Die Zuordnung zeigt `kubectl --context talos get nodes -o wide`.
]

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-12
kubectl --context talos delete ns dbg-12
```][Räumt die Workloads auf. Falco kann installiert bleiben. Entfernen würdest du es mit `helm --kube-context rke2 uninstall falco -n falco`.]

#gelernt(
  [Falco braucht `privileged` und `hostPath`. Auf Talos (Vorgabe `baseline`) gehört der Namespace `falco` deshalb auf `privileged`, sonst bleibt das DaemonSet bei `0`.],
  [`hostname`, `k8s.ns.name`, `k8s.pod.name` und `container.id` führen jeden Alarm auf Knoten, Pod und Container zurück. Den auslösenden Benutzer kennt nur das Audit-Log.],
  [Fehlalarme stellst du mit einer engen Ausnahme ab: `exceptions` mit `override: exceptions: append` in `customRules`.],
  [`<NA>` bei Pod und Namespace heißt: Falco erreicht die Container-Runtime nicht. Auf RKE2 liegt der Socket unter `/run/k3s/containerd/`.],
)
