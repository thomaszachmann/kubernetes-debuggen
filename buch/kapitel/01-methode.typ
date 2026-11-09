#import "../lib.typ": *

#kapitel(
  [Die Methode],
  ziel: [Du ordnest jedes Symptom einer Schicht des Clusters zu, kennst die Grundwerkzeuge von `kubectl` für jede Schicht und liest Pod-Status, Container-State und Exit-Code richtig. Ein kleines Beispiel zeigt den Ablauf von Anfang bis Ende.],
  zeit: [45 Minuten],
  braucht: [Kubernetes-Grundwissen; für das Beispiel das Labor aus Kapitel 2],
)

== Raten oder eingrenzen

Wer zum ersten Mal vor einem Pod in `CrashLoopBackOff` steht, probiert gern aus: Image neu bauen, Pod löschen, Deployment neu anwenden. Manchmal hilft das sogar. Verstanden hast du danach nichts, und beim nächsten Mal fängst du wieder von vorn an.

Dieses Buch arbeitet anders. Jeder Fehler durchläuft dieselben fünf Schritte:

#tabelle(
  (auto, 1fr),
  ([Schritt], [Was du tust]),
  [Reproduzieren], [Den Fehler gezielt auslösen. Was du nicht auslösen kannst, kannst du auch nicht sicher als behoben erklären.],
  [Untersuchen], [Befehle in fester Reihenfolge, von außen nach innen. Du sammelst Fakten, keine Vermutungen.],
  [Verstehen], [Die Ursache in zwei, drei Sätzen benennen, mit dem Mechanismus dahinter.],
  [Beheben], [Die kleinste Änderung, die die Ursache beseitigt. Nicht das Symptom.],
  [Prüfen], [Zeigen, dass es wieder läuft, und zwar am selben Signal, an dem du den Fehler gesehen hast.],
)

Der wichtigste Schritt ist der zweite. Gute Fehlersucher sind nicht schneller im Raten, sie stellen bessere Fragen in besserer Reihenfolge. Jede Frage halbiert den Raum der möglichen Ursachen. Nach drei, vier Fragen bleibt meist nur noch eine übrig.

#warum[
  Schreib dir während der Suche kurz auf, was du geprüft hast und was dabei herauskam. Das klingt umständlich, verhindert aber, dass du denselben Befehl dreimal ausführst. Und wenn du den Fall an Kollegen übergibst, liegt die halbe Analyse schon vor.
]

== Die Landkarte

Ein Kubernetes-Cluster besteht aus Schichten, die aufeinander aufbauen. Fast jedes Symptom lässt sich einer davon zuordnen. Wer die Schicht kennt, kennt auch die ersten Befehle.

#tabelle(
  (auto, 1fr, 1fr, auto),
  ([Schicht], [Typisches Symptom], [Erste Frage], [Kapitel]),
  [Scheduling], [Pod bleibt `Pending`], [Warum findet der Scheduler keinen Knoten?], [4],
  [Image und Runtime], [`ImagePullBackOff`, `CreateContainerConfigError`], [Kann der Knoten das Image holen und den Container anlegen?], [5],
  [Workload], [`CrashLoopBackOff`, `OOMKilled`, nicht ready], [Was sagt der Prozess selbst, und womit endet er?], [6],
  [Netzwerk], [Timeout, `connection refused`, DNS-Fehler], [Kommt das Paket an, und antwortet jemand?], [7, 8],
  [Storage], [PVC `Pending`, `Permission denied`], [Gibt es ein Volume, und darf der Prozess hineinschreiben?], [9],
  [Policy und Admission], [`Forbidden`, `denied the request`], [Wer hat abgelehnt: RBAC, Pod Security oder ein Webhook?], [10, 11],
  [Laufzeit], [Falco-Alarm, Prozess verhält sich unerwartet], [Ist das ein Angriff oder ein legitimer Ablauf?], [12],
  [Knoten], [`NotReady`, Evictions, `Unknown`], [Lebt das kubelet, und hat der Knoten genug Ressourcen?], [13],
  [Control Plane], [`kubectl` hängt, Änderungen kommen nicht an], [Sind API-Server, etcd und Webhooks gesund?], [14],
  [Rollout], [Deployment hängt, HPA zeigt `<unknown>`], [Wartet der Controller auf etwas, das nie eintritt?], [15],
)

Die Schichten haben eine Richtung. Ein Fehler weiter unten zeigt sich oft weiter oben. Ein Knoten mit voller Platte führt zu Evictions, die du zuerst als verschwundene Pods siehst. Ein hängender Webhook in der Control Plane lässt jedes `kubectl apply` scheitern, obwohl deine Manifeste fehlerfrei sind. Du beginnst deshalb oben beim Symptom, gehst aber bereitwillig eine Schicht tiefer, sobald die Fakten dorthin zeigen.

=== Von außen nach innen

Für die Untersuchung gilt eine feste Reihenfolge. Sie ist so gewählt, dass jeder Schritt billig ist und den nächsten vorbereitet:

+ `kubectl get`: Wie ist der Zustand, und seit wann?
+ `kubectl describe`: Was weiß Kubernetes über dieses Objekt, welche Events hängen daran?
+ `kubectl events`: Was ist drumherum passiert, auch an Objekten, die du noch nicht im Blick hattest?
+ `kubectl logs`: Was sagt der Prozess, auch der vorherige Lauf?
+ `kubectl debug`: Wie sieht es von innen aus, im Netzwerk und im Dateisystem des Pods?
+ Knoten: kubelet, containerd, Kernel. Auf RKE2 per SSH, auf Talos mit `talosctl`.
+ Control Plane: API-Server, etcd, Webhooks.

Die meisten Fehler sind nach Schritt 4 erklärt. Die Schritte 6 und 7 brauchst du selten, aber wenn, dann dringend. Deshalb übst du sie in den Kapiteln 13 und 14 an einem gesunden Cluster, bevor es ernst wird.

== Phase, State und Reason

Die Spalte `STATUS` von `kubectl get pods` ist eine Zusammenfassung, die `kubectl` aus mehreren Feldern baut. Wer sie liest, als wäre sie ein einziges Feld, zieht falsche Schlüsse. Dahinter stehen drei Ebenen:

#tabelle(
  (auto, auto, 1fr),
  ([Ebene], [Feld], [Werte]),
  [Pod-Phase], [`status.phase`], [`Pending`, `Running`, `Succeeded`, `Failed`, `Unknown`. Nur diese fünf.],
  [Container-State], [`status.containerStatuses[].state`], [Genau einer von `waiting`, `running`, `terminated`],
  [Reason], [`state.waiting.reason`, `state.terminated.reason`], [`ContainerCreating`, `ImagePullBackOff`, `CrashLoopBackOff`, `CreateContainerConfigError`, `Completed`, `Error`, `OOMKilled` und weitere],
)

Ein Pod in `CrashLoopBackOff` hat die Phase `Running`. Das überrascht viele. Die Phase sagt nur, dass der Pod einem Knoten zugewiesen ist und mindestens ein Container gestartet wurde oder gerade neu startet. Der Container selbst steht in `waiting` mit dem Reason `CrashLoopBackOff`, und `kubectl` zeigt diesen Reason in der Spalte `STATUS`. Auch `Terminating` ist keine Phase. `kubectl` zeigt es an, sobald der Pod einen `deletionTimestamp` hat.

Für die Ursache wichtiger als der aktuelle State ist oft `lastState`. Dort steht, wie der vorige Lauf des Containers endete:

#cmd("Mac")[```bash
kubectl --context rke2 get pod <pod> -n dbg-01 \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
```][Zeigt Reason, Exit-Code, Start- und Endzeit des letzten beendeten Laufs. `describe` zeigt dasselbe unter `Last State`, aber hier bekommst du es maschinenlesbar, etwa für ein Skript.]

== Exit-Codes

Endet ein Prozess im Container, meldet die Runtime seinen Exit-Code an das kubelet. Wurde der Prozess durch ein Signal beendet, lautet der Code nach Unix-Konvention 128 plus Signalnummer. Diese sieben Codes solltest du auswendig kennen:

#tabelle(
  (auto, auto, 1fr),
  ([Code], [Bedeutung], [Typische Ursache]),
  [`0`], [Regulär beendet], [Bei einem Job richtig. Bei einem Deployment ein Fehler: Der Hauptprozess darf nicht enden, sonst startet Kubernetes ihn neu.],
  [`1`], [Allgemeiner Fehler], [Die Anwendung hat selbst abgebrochen. Die Antwort steht fast immer im Log, oft im vorherigen.],
  [`126`], [Nicht ausführbar], [Datei gefunden, aber keine Ausführungsrechte, oder ein Skript ohne passenden Interpreter.],
  [`127`], [Befehl nicht gefunden], [Tippfehler im `command`, Programm fehlt im Image. Die Shell im Container meldet `not found`.],
  [`137`], [SIGKILL (128 + 9)], [Mit Reason `OOMKilled`: Speicherlimit überschritten. Ohne: hart beendet, etwa weil der Prozess nach einer gescheiterten Liveness-Probe nicht auf SIGTERM reagierte.],
  [`139`], [SIGSEGV (128 + 11)], [Speicherzugriffsfehler, meist ein Fehler in nativem Code, etwa in einer C-Bibliothek der Anwendung.],
  [`143`], [SIGTERM (128 + 15)], [Geordnet beendet, zum Beispiel beim Rollout oder durch `kubectl delete`. Selten ein Fehler.],
)

#falle[
  Ein Container, dessen Programm gar nicht erst gestartet werden kann, etwa weil der Pfad im `command` nicht existiert und keine Shell dazwischen sitzt, endet nicht mit 127. containerd meldet dann den Reason `StartError` mit Exit-Code `128` und einer Meldung wie `executable file not found in $PATH`. Erst wenn eine Shell den Befehl sucht, wie bei `sh -c`, bekommst du die 127.
]

== Die Grundwerkzeuge

Alle Befehle in diesem Abschnitt laufen gegen beide Cluster gleich. Die Beispiele zeigen `--context rke2`. Für Talos tauschst du nur den Kontext.

=== get

#cmd("Mac")[```bash
kubectl --context rke2 get pods -n dbg-01 -o wide
```][`-o wide` ergänzt Pod-IP und Knoten. Damit siehst du sofort, ob alle kaputten Pods auf demselben Knoten liegen. Dann liegt die Ursache eher am Knoten als an der Anwendung.]

Achte in der Ausgabe auf `READY` (wie viele Container sind bereit), `RESTARTS` (mit Zeitpunkt des letzten Neustarts) und `AGE`. Ein Pod mit 40 Neustarts in zwei Stunden hat ein anderes Problem als einer, der vor fünf Minuten zum ersten Mal abgestürzt ist. Mit `-w` beobachtest du Änderungen live, mit `-o yaml` siehst du das vollständige Objekt samt `status`.

=== describe

#cmd("Mac")[```bash
kubectl --context rke2 describe pod <pod> -n dbg-01
```][Fasst Spezifikation, Status aller Container, Conditions und die Events des Pods zusammen. Lies von unten nach oben: zuerst die Events, dann `State` und `Last State` der Container.]

`describe` zeigt nur Events, die direkt an diesem Objekt hängen. Lehnt etwa Pod Security einen Pod ab, entsteht der Pod nie. Das Event hängt dann am ReplicaSet, und ein `describe` auf den Pod ist unmöglich, weil es ihn nicht gibt. Darum gehört der nächste Befehl immer dazu.

=== events

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-01
kubectl --context rke2 events -n dbg-01 --for pod/<pod>
kubectl --context rke2 events -A --types=Warning
```][`kubectl events` listet Events zeitlich sortiert, das neueste unten. `--for` filtert auf ein Objekt, `--types=Warning` blendet die normalen Meldungen aus. `-A` sucht in allen Namespaces.]

Das ältere `kubectl get events` sortiert nicht nach Zeit. Brauchst du es trotzdem, etwa für ein bestimmtes Ausgabeformat, ergänze `--sort-by=.lastTimestamp`.

#falle[
  Events sind kurzlebig. Der API-Server löscht sie standardmäßig nach einer Stunde. Ein Fehler von gestern Abend hat heute Morgen keine Events mehr. Dann bleiben dir nur `status`, Logs und, falls vorhanden, ein zentrales Log-System.
]

=== logs

#cmd("Mac")[```bash
kubectl --context rke2 logs <pod> -n dbg-01
kubectl --context rke2 logs <pod> -n dbg-01 --previous
kubectl --context rke2 logs <pod> -n dbg-01 -c <container>
kubectl --context rke2 logs <pod> -n dbg-01 --all-containers --since=10m
kubectl --context rke2 logs deploy/app -n dbg-01 --tail=50
```][Der erste Befehl zeigt das Log des laufenden Containers. Startet der Container ständig neu, ist das oft leer oder zeigt nur den Anfang. Die Ursache steht dann im vorherigen Lauf: `--previous`. Bei mehreren Containern wählst du mit `-c` einen aus oder nimmst `--all-containers`. `deploy/app` sucht sich einen Pod des Deployments heraus.]

Das kubelet hält vom vorherigen Lauf genau einen Stand vor. Wird der Pod gelöscht und neu erstellt, etwa durch einen Rollout, ist auch dieser weg. Das gilt für `kubectl` und k9s gleichermaßen.

=== debug

Viele Images enthalten keine Shell und keine Werkzeuge. `kubectl exec` hilft dann nicht. `kubectl debug` hängt einen zusätzlichen Container mit deinem Werkzeug-Image an:

#cmd("Mac")[```bash
kubectl --context rke2 debug -it <pod> -n dbg-01 \
  --image=nicolaka/netshoot:v0.15 --profile=baseline --target=app
```][Startet einen Ephemeral Container mit netshoot im laufenden Pod. Er teilt das Netzwerk des Pods. Mit `--target` sieht er auch die Prozesse des Containers `app`, etwa mit `ps`.]

#tabelle(
  (auto, 1fr),
  ([Variante], [Wofür]),
  [`kubectl debug <pod> --image=...`], [Ephemeral Container im laufenden Pod. Netzwerk und mit `--target` auch Prozesse teilen.],
  [`kubectl debug <pod> --copy-to=<neu> ...`], [Kopie des Pods, optional mit anderem Image (`--set-image`) oder anderem Befehl. Gut, wenn der Original-Pod sofort abstürzt.],
  [`kubectl debug node/<knoten> ...`], [Pod mit Host-Namespaces auf einem Knoten, das Dateisystem des Knotens liegt unter `/host`.],
)

#falle[
  Ohne `--profile` nimmt `kubectl debug` das Profil `general`. Es fügt dem Debug-Container die Capability `SYS_PTRACE` hinzu. Pod Security im Level `baseline` erlaubt diese Capability nicht, und Talos erzwingt `baseline` in jedem Namespace außer `kube-system`. Dort lehnt der API-Server den Debug-Container ab. Mit `--profile=baseline` klappt es auf beiden Clustern. `kubectl debug node/` braucht dagegen Host-Namespaces und scheitert auf Talos in einem normalen Namespace. Kapitel 13 zeigt, wie du damit umgehst.
]

=== explain, auth can-i und der API-Server

Drei Befehle ergänzen das Werkzeug. Du brauchst sie seltener, aber sie beantworten Fragen, die sonst lange dauern:

#cmd("Mac")[```bash
kubectl --context rke2 explain pod.spec.containers.startupProbe
```][Zeigt die Dokumentation eines Felds direkt aus dem Schema des API-Servers, passend zur Version des Clusters. Schneller als jede Suche, und es gilt genau für diesen Cluster, auch für CRDs.]

#cmd("Mac")[```bash
kubectl --context rke2 auth can-i list pods -n dbg-01 \
  --as=system:serviceaccount:dbg-01:default
```][Fragt, ob ein bestimmter Benutzer oder ServiceAccount eine Aktion ausführen darf. Die Antwort ist `yes` oder `no`. Mit `--list` siehst du alle Rechte. Mehr dazu in Kapitel 10.]

#cmd("Mac")[```bash
kubectl --context rke2 get --raw '/readyz?verbose'
```][Fragt den API-Server nach seinen internen Prüfungen. Jede Zeile beginnt mit `[+]` (in Ordnung) oder `[-]` (fehlgeschlagen), am Ende steht `readyz check passed`. Wenn hier etcd oder ein Informer hängt, hilft keine Suche in deinen Pods.]

== Ein Beispiel von Anfang bis Ende

Ein kleiner Fall zeigt den Ablauf. Eine Anwendung erwartet eine Umgebungsvariable `DB_HOST`. Fehlt sie, bricht sie mit einer Meldung ab. Das Labor aus Kapitel 2 muss dafür laufen. Lies das Beispiel jetzt trotzdem, und spiel es nach, sobald die Cluster stehen.

#datei("szenarien/01-methode/kaputt.yaml (Ausschnitt)", ```yaml
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
  Die Datei legt zuerst den Namespace `dbg-01` an. Pod und Container laufen ohne Root und ohne Capabilities. So entspricht der Pod dem Level `restricted`, und Talos gibt beim Anwenden keine Warnungen aus.
])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/01-methode/kaputt.yaml
```][Legt Namespace und Deployment an.]

#symptom[
  ```text
  NAME                   READY   STATUS             RESTARTS      AGE
  app-6b8f9c7d54-x7kqp   0/1     CrashLoopBackOff   3 (21s ago)   88s
  ```
  Der Pod ist nie bereit, die Neustarts steigen, und die Abstände dazwischen werden länger.
]

Der Status `CrashLoopBackOff` sagt nur, dass der Container wiederholt endet und das kubelet mit dem nächsten Start wartet. Warum er endet, steht woanders. Erste Frage: Wie endete der letzte Lauf?

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-01 -l app=app
```][`-l` wählt den Pod über sein Label, du musst den Namen nicht abtippen.]

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

Exit-Code `1`, Reason `Error`, kein `OOMKilled`. Das Image wurde gezogen, der Container gestartet. Damit sind Scheduling, Image und Runtime ausgeschlossen. Der Prozess selbst hat aufgegeben. Nächste Frage: Was hat er gesagt?

#cmd("Mac")[```bash
kubectl --context rke2 logs -n dbg-01 deploy/app --previous
```][Das Log des vorherigen, abgestürzten Laufs.]

```text
FEHLER: DB_HOST ist nicht gesetzt
```

#ursache[
  Die Anwendung prüft beim Start, ob `DB_HOST` gesetzt ist, und beendet sich sonst mit Exit-Code 1. Das Deployment setzt die Variable nicht. Weil ein Deployment `restartPolicy: Always` hat, startet das kubelet den Container immer wieder und verlängert die Pause zwischen den Versuchen bis auf fünf Minuten.
]

Die Lösung ist die fehlende Variable, nicht ein Neustart des Pods. Die Datei `fix.yaml` enthält dasselbe Deployment mit einem `env`-Block:

#datei("szenarien/01-methode/fix.yaml (Ausschnitt)", ```yaml
          env:
            - name: DB_HOST
              value: db.dbg-01.svc.cluster.local
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/01-methode/fix.yaml
kubectl --context rke2 rollout status deploy/app -n dbg-01
```][Die Änderung am Pod-Template löst einen Rollout aus. `rollout status` wartet, bis der neue Pod bereit ist.]

#pruefe[
  - `rollout status` meldet `deployment "app" successfully rolled out`.
  - `get pods -n dbg-01` zeigt einen neuen Pod: `1/1`, `Running`, `0` Neustarts.
  - `logs -n dbg-01 deploy/app` gibt `verbinde mit db.dbg-01.svc.cluster.local` aus.
]

Auf Talos verläuft das Beispiel genauso. Wiederhole es mit `--context talos`, wenn du magst. Danach räumst du auf:

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-01
kubectl --context talos delete ns dbg-01 --ignore-not-found
```][Löscht den Namespace samt Deployment und Pods.]

Die Untersuchung hat drei Befehle gebraucht. Jeder hat eine Frage beantwortet und eine Schicht ausgeschlossen. Genau so laufen alle Szenarien in diesem Buch, nur dass die Fragen schwerer werden.

#aufgabe[
  Ändere in einer Kopie von `kaputt.yaml` den Befehl so, dass statt `exit 1` die Zeile `slep 3600` ausgeführt wird, und wende sie an. Welchen Exit-Code erwartest du, bevor du nachsiehst? Prüfe deine Vermutung mit `describe` und `logs --previous`. Hinweis: Die Shell meldet `sh: slep: not found` und endet mit 127. Lösche den Namespace danach wieder.
]

#gelernt(
  [Jeder Fehler durchläuft fünf Schritte: reproduzieren, untersuchen, verstehen, beheben, prüfen.],
  [Die Landkarte ordnet ein Symptom einer Schicht zu: Scheduling, Image und Runtime, Workload, Netzwerk, Storage, Policy, Knoten, Control Plane.],
  [Die Untersuchung geht von außen nach innen: `get`, `describe`, `events`, `logs`, `debug`, dann Knoten und Control Plane.],
  [`STATUS` ist eine Zusammenfassung. Pod-Phase, Container-State und Reason sind drei verschiedene Ebenen, und `lastState` erklärt den vorigen Lauf.],
  [Exit-Codes über 128 bedeuten ein Signal. 137 mit `OOMKilled` ist das Speicherlimit, 137 ohne ist ein hartes Beenden.],
  [`kubectl debug` braucht auf Talos `--profile=baseline`, weil das Standardprofil eine Capability hinzufügt, die Pod Security `baseline` verbietet.],
)
