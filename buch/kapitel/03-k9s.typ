#import "../lib.typ": *

#kapitel(
  [k9s als Cockpit],
  ziel: [Du bewegst dich in k9s ohne Maus durch beide Cluster, filterst, liest Logs auch vom vorherigen Lauf, öffnest Shells und Port-Forwards und startest mit einem Tastendruck einen Debug-Container. Du weißt auch, wann `kubectl` die bessere Wahl ist.],
  zeit: [45 Minuten],
  braucht: [Kapitel 2],
)

== Warum ein zweites Werkzeug

`kubectl` zeigt dir einen Zustand zu einem Zeitpunkt. Für die Fehlersuche ist das oft zu wenig. Du willst sehen, wie ein Pod neu startet, wie ein Rollout voranschreitet, und dabei schnell zwischen Pod, Logs, Events und Deployment springen. Genau dafür ist k9s gebaut: eine Terminal-Oberfläche, die alle zwei Sekunden aktualisiert und jede Ansicht mit wenigen Tasten erreichbar macht.

k9s spricht dieselbe API wie `kubectl` und nutzt dieselbe Kubeconfig. Es sieht also nichts, was `kubectl` nicht auch sehen könnte, und darf nichts, was dein Benutzer nicht darf. Der Vorteil ist allein die Geschwindigkeit. Dieses Buch zeigt deshalb in jedem Szenario beide Wege: `kubectl` für Befehle, die du dokumentieren und wiederholen willst, k9s für die schnelle Runde durch den Cluster.

Damit du etwas zum Anschauen hast, legst du zuerst ein paar Übungsobjekte an:

#datei("szenarien/03-k9s/demo.yaml (Ausschnitt)", ```yaml
kind: Deployment
metadata:
  name: web
  namespace: dbg-03
spec:
  replicas: 2
  # ... busybox httpd auf Port 8080, dazu Service web (80 -> 8080)
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
  `web` ist ein kleiner Webserver mit zwei Replikas und einem Service. `wackel` stürzt nach 15 Sekunden mit Exit-Code 3 ab und landet nach ein paar Runden in `CrashLoopBackOff`. Beide laufen ohne Root, damit Talos keine Warnungen ausgibt.
])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/03-k9s/demo.yaml
```][Legt Namespace `dbg-03`, beide Deployments und den Service an.]

== Starten und Orientieren

#cmd("Mac")[```bash
k9s --context rke2 -n dbg-03
```][Startet k9s im Kontext `rke2` und direkt im Namespace `dbg-03`. Ohne `-n` öffnet k9s den zuletzt benutzten Namespace dieses Kontexts. `-A` startet in allen Namespaces, `-c deploy` mit einer anderen Ansicht als Pods.]

Der Bildschirm hat drei Bereiche. Oben links stehen Kontext, Cluster, Benutzer und die Versionen von k9s und Kubernetes, daneben die Tasten, die in der aktuellen Ansicht gelten. Die Mitte zeigt die Tabelle, darüber den Titel mit Ressource, Namespace und Anzahl der Objekte. Unten zeigen die *Crumbs*, wie du hierher gekommen bist.

#falle[
  Schau vor jeder ändernden Aktion auf den Kontext oben links. Wer mit k9s in zwei Terminals arbeitet, eines pro Cluster, löscht sonst leicht im falschen. Eine Hilfe: k9s kann pro Kontext einen eigenen Skin laden, etwa rot für das Labor, das du gerade kaputt machst.
]

Die wichtigsten Tasten sind wenige. `?` zeigt alle Tasten der aktuellen Ansicht. Das ist die zuverlässigste Quelle, denn die Belegung hängt von Ressource und Version ab.

#tabelle(
  (auto, 1fr),
  ([Taste], [Wirkung]),
  [`:`], [Befehlszeile: Ressource öffnen, etwa `:deploy⏎`, `:svc⏎`, `:events⏎`],
  [`/`], [Filter auf die aktuelle Tabelle],
  [`Esc`], [Filter oder Befehlszeile abbrechen, eine Ansicht zurück],
  [`Enter`], [Objekt öffnen: Pod zeigt Container, Deployment zeigt Pods],
  [`?`], [Hilfe zur aktuellen Ansicht],
  [`Ctrl-a`], [Alle Ressourcen und ihre Aliase],
  [`-`], [Zurück zum vorigen Befehl, wie `cd -`],
  [`:q⏎` oder `Ctrl-c`], [k9s beenden],
)

== Ressourcen, Namespaces und Filter

Hinter `:` akzeptiert k9s jeden Namen, den auch `kubectl` versteht: Singular, Plural und Kurzname. `:po`, `:pod` und `:pods` öffnen dieselbe Ansicht. Auch CRDs funktionieren, sobald sie im Cluster sind, etwa `:policyreports` in Kapitel 11.

#cmd("k9s")[```text
:deploy dbg-03⏎
:pods kube-system⏎
:pods app=web⏎
:pods /wackel⏎
```][Ressource mit Namespace öffnen, Pods mit einem Label-Selektor anzeigen und die Liste gleich beim Öffnen filtern.]

Den Namespace wechselst du auf drei Wegen. `0` zeigt alle Namespaces. Die Ziffern `1` bis `9` springen zu den zuletzt benutzten Namespaces, k9s blendet sie oben in der Tastenliste ein. Und `:ns⏎` listet alle Namespaces, `u` macht den markierten zum aktiven.

Der Filter mit `/` ist das Werkzeug, das du am häufigsten brauchst:

#tabelle(
  (auto, 1fr),
  ([Eingabe], [Wirkung]),
  [`/web⏎`], [Nur Zeilen, die `web` enthalten. Reguläre Ausdrücke sind erlaubt, etwa `web|wackel`.],
  [`/!Running⏎`], [Umgekehrt: alle Zeilen, die *nicht* `Running` enthalten],
  [`/-l app=web⏎`], [Filter über Labels],
  [`/-f wkl⏎`], [Unscharfe Suche],
  [`Ctrl-z`], [Nur Objekte mit Fehlern zeigen, ein zweites `Ctrl-z` schaltet zurück],
)

#cmd("k9s")[```text
:pods⏎
0
/!Running|Completed⏎
```][Alle Pods in allen Namespaces, die weder laufen noch fertig sind. Das ist eine gute erste Runde, wenn du nicht weißt, was in einem Cluster kaputt ist.]

Sortiert wird mit Großbuchstaben: `Shift-s` nach Status, `Shift-a` nach Alter, `Shift-n` nach Name. `Ctrl-w` blendet zusätzliche Spalten ein, bei Pods etwa IP und Knoten. Das entspricht `kubectl get -o wide`.

== Ein Pod im Detail

Markiere in der Pod-Ansicht einen Pod von `wackel`. Alle folgenden Tasten wirken auf die markierte Zeile:

#tabelle(
  (auto, 1fr, auto),
  ([Taste], [Wirkung], [kubectl-Gegenstück]),
  [`d`], [Describe], [`describe pod`],
  [`y`], [YAML des Objekts samt `status`], [`get -o yaml`],
  [`e`], [Im Editor ändern], [`edit`],
  [`l`], [Logs], [`logs -f`],
  [`p`], [Logs des vorherigen Laufs], [`logs --previous`],
  [`s`], [Shell im Container], [`exec -it ... -- sh`],
  [`a`], [An den Container anhängen], [`attach`],
  [`o`], [Zum Knoten des Pods springen], [`get node`],
  [`Shift-j`], [Zum Besitzer springen, etwa zum ReplicaSet], [—],
  [`Shift-f`], [Port-Forward einrichten], [`port-forward`],
  [`Ctrl-d`], [Löschen, mit Bestätigung], [`delete`],
  [`Ctrl-k`], [Sofort löschen, *ohne* Bestätigung], [`delete --now`],
)

#cmd("k9s")[```text
:pods dbg-03⏎
/wackel⏎
d
```][Describe des abstürzenden Pods. Mit den Pfeiltasten scrollst du, `Esc` führt zurück zur Liste.]

#pruefe[
  Unter `Last State` steht `Terminated`, `Reason: Error`, `Exit Code: 3`. Ganz unten wiederholt sich das Event `BackOff` mit `Back-off restarting failed container wackel`.
]

`Enter` auf einem Pod öffnet die Container-Ansicht. Dort gelten `l`, `p` und `s` für genau einen Container. Das brauchst du bei Pods mit Sidecars oder Init-Containern. In der Pod-Ansicht wählt k9s sonst den ersten Container oder fragt nach.

#falle[
  `s` startet `bash`, wenn das Image eines hat, sonst `sh`. Hat das Image gar keine Shell, wie bei distroless-Images, scheitert das mit einer Fehlermeldung von `exec`. Dann hilft nur ein Debug-Container. Dafür gibt es weiter unten das Plugin auf `Shift-d`.
]

== Logs lesen

#cmd("k9s")[```text
:pods dbg-03⏎
/wackel⏎
p
```][Zeigt das Log des vorherigen Laufs. Dort steht die letzte Zeile vor dem Absturz: `FEHLER: Cache voll, gebe auf`.]

In der Log-Ansicht gelten eigene Tasten. Sie unterscheiden sich von der Tabelle, zum Beispiel heißt `w` hier Zeilenumbruch und nicht Namespace-Wechsel:

#tabelle(
  (auto, 1fr),
  ([Taste], [Wirkung]),
  [`0`], [Ab jetzt mitlaufen (tail)],
  [`1`], [Von Anfang an (head)],
  [`2` bis `6`], [Zeitfenster: 1, 5, 15, 30 Minuten, 1 Stunde],
  [`s`], [Autoscroll an oder aus],
  [`w`], [Lange Zeilen umbrechen],
  [`t`], [Zeitstempel einblenden],
  [`f`], [Vollbild],
  [`/`], [Filter auf die Logzeilen],
  [`Ctrl-s`], [Log in eine Datei speichern],
)

Zeitstempel sind beim Debuggen fast immer hilfreich. Sie zeigen, ob ein Fehler gerade erst auftrat oder schon seit Stunden. Wenn du sie immer sehen willst, setzt du in der `config.yaml` von k9s unter `k9s.logger` den Wert `showTime: true`. Dort legst du auch mit `tail` fest, wie viele Zeilen k9s beim Öffnen lädt, und mit `textWrap` den Umbruch.

== Events, XRay und Pulses

#cmd("k9s")[```text
:events dbg-03⏎
```][Events des Namespace als Tabelle, die sich laufend aktualisiert. `Ctrl-z` zeigt nur Warnungen und Fehler.]

Zwei Ansichten gibt es nur in k9s. *XRay* zeigt Objekte als Baum: Deployment, darunter ReplicaSet, darunter Pods mit ihren Containern, ConfigMaps, Secrets und dem ServiceAccount. Ein rotes Element im Baum führt dich direkt zur Ursache. Das hilft besonders, wenn ein Deployment angenommen wurde, aber keine Pods entstehen.

#cmd("k9s")[```text
:xray deploy dbg-03⏎
```][Baum aller Deployments in `dbg-03`. Erlaubt sind unter anderem `po`, `svc`, `dp`, `rs`, `sts` und `ds`.]

*Pulses* (`:pulses⏎`) zeigt kleine Verlaufsgrafiken für Knoten, Namespaces, Services, Events, Pods, Deployments, StatefulSets, DaemonSets, Jobs, PVCs und weitere Objekte, jeweils mit der Zahl der gesunden und fehlerhaften, dazu CPU und Speicher, sofern ein metrics-server läuft. Das ist kein Werkzeug für eine einzelne Ursache, aber ein guter Blick darauf, ob ein Rollout gerade Wellen schlägt.

Ältere Anleitungen erwähnen `:popeye` für eine Prüfung des ganzen Clusters. In k9s 0.51 ist diese Ansicht nicht mehr enthalten. Wer Popeye nutzen will, startet es als eigenes Programm.

== Port-Forward

#cmd("k9s")[```text
:svc dbg-03⏎
/web⏎
Shift-f
```][Öffnet den Dialog für einen Port-Forward auf den Service `web`. Trage unter `Local Port` den Wert `8080` ein und bestätige mit `OK`.]

#cmd("Mac")[```bash
curl -s localhost:8080
```][Ein zweites Terminal fragt den Webserver über den Port-Forward ab.]

#pruefe[
  Die Antwort lautet `hallo aus web-…` mit dem Namen eines der beiden Pods. Die Taste `f` in der Service- oder Pod-Ansicht zeigt alle aktiven Port-Forwards, ebenso `:pf⏎`. Dort beendest du einen mit `Ctrl-d`. Port-Forwards leben nur so lange wie k9s.
]

== Kontexte und Read-only

`:ctx⏎` listet alle Kontexte aus deiner Kubeconfig, `Enter` wechselt. Schneller geht `:ctx talos⏎`. k9s merkt sich für jeden Kontext Namespace und Ansicht getrennt.

Für dieses Buch empfehle ich trotzdem zwei Terminals mit je einem k9s: `k9s --context rke2` und `k9s --context talos`. Dann siehst du beide Cluster nebeneinander und musst nie überlegen, wo du gerade bist.

Wer in einem fremden oder produktiven Cluster nur schauen will, startet k9s schreibgeschützt:

#cmd("Mac")[```bash
k9s --context talos --readonly
```][Schaltet alle ändernden Aktionen ab: Edit, Delete, Kill, Shell, Attach und alle Plugins, die als `dangerous` markiert sind. Dauerhaft geht das mit `readOnly: true` in der `config.yaml`, und `--write` hebt es für einen Start wieder auf.]

#warum[
  Read-only schützt nicht vor Neugier, sondern vor Tippfehlern. `Ctrl-k` löscht ohne Rückfrage. In einem Cluster, in dem du nur Fehler suchst, gibt es keinen Grund, dieses Risiko zu tragen.
]

== Die Plugins dieses Buchs

Plugins hängen eigene Befehle an eine Taste. k9s ersetzt dabei Variablen wie `$NAME`, `$NAMESPACE`, `$CONTEXT` und in der Container-Ansicht `$POD` durch die Werte der markierten Zeile. Die Datei `k9s/plugins.yaml` hast du in Kapitel 2 nach `~/Library/Application Support/k9s/` kopiert. Sie definiert drei Plugins:

#tabelle(
  (auto, auto, 1fr),
  ([Taste], [Ansicht], [Wirkung]),
  [`Shift-d`], [Pods], [Plugin `netshoot`: startet `nicolaka/netshoot:v0.15` als Ephemeral Container im markierten Pod. Teilt das Netzwerk des Pods.],
  [`Shift-d`], [Container], [Plugin `netshoot-target`: wie oben, zusätzlich mit `--target` auf den markierten Container. Sieht dessen Prozesse.],
  [`Shift-e`], [Pods, Deployments, ReplicaSets, StatefulSets, DaemonSets, Jobs, Services, PVCs], [Plugin `events`: `kubectl events --for` genau dieses Objekts, chronologisch, in `less`. Beenden mit `q`.],
)

#datei("k9s/plugins.yaml (Ausschnitt)", ```yaml
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
  # ... netshoot-target (containers) und events
```, erklaerung: [
  `scopes` legt fest, in welchen Ansichten die Taste gilt. `confirm: true` zeigt den fertigen Befehl vor dem Start und fragt nach. `dangerous: true` blendet das Plugin im Read-only-Modus aus, denn ein Ephemeral Container verändert den Pod dauerhaft. `--profile=baseline` ist nötig, weil Talos sonst den Debug-Container ablehnt (Kapitel 1). `background: false` übergibt das Terminal an `kubectl`, bis du die Shell mit `exit` verlässt.
])

Die Tasten sind so gewählt, dass sie mit keiner Belegung von k9s 0.51 kollidieren. Das ist wichtig: Belegt ein Plugin eine Taste, die k9s in dieser Ansicht schon nutzt, lädt k9s das Plugin nicht, zeigt oben rechts `Plugins load failed!` und schreibt den Grund (`duplicate plugin key`) ins Log. Erst mit `override: true` ersetzt das Plugin die eingebaute Funktion. Wenn ein Plugin fehlt, schau mit `?` nach, ob die Taste erscheint, und in die Logdatei, deren Pfad `k9s info` zeigt.

#cmd("k9s")[```text
:pods dbg-03⏎
/web⏎
Shift-d
```][Markiere einen der `web`-Pods und drücke `Shift-d`. Bestätige den angezeigten Befehl. Nach ein paar Sekunden landest du in einer Shell von netshoot.]

#cmd("Pod")[```bash
ss -ltn
curl -s localhost:8080
exit
```][`ss` zeigt den Webserver, der im *anderen* Container auf Port 8080 lauscht. Beide teilen das Netzwerk des Pods, deshalb erreicht `curl` ihn über `localhost`. Mit `exit` kehrst du zu k9s zurück.]

#pruefe[
  `ss -ltn` listet eine Zeile mit `*:8080` im Zustand `LISTEN`, `curl` liefert `hallo aus web-…`. Ein `describe` des Pods (`d`) zeigt danach einen Abschnitt `Ephemeral Containers` mit dem Debug-Container im Zustand `Terminated`. Ephemeral Container lassen sich nicht entfernen, sie verschwinden erst mit dem Pod.
]

Probier zum Schluss `Shift-e` auf dem Deployment `wackel` in der Ansicht `:deploy⏎`. Du siehst die Events des Deployments selbst, also die Skalierung des ReplicaSets, nicht die der Pods. Auf dem Pod zeigt dieselbe Taste die `BackOff`-Events. Diese Trennung ist beabsichtigt und hilft dir in Kapitel 10 und 11, wenn Pods gar nicht erst entstehen.

== Wo kubectl besser ist

k9s ersetzt `kubectl` nicht. Für einige Aufgaben ist die Kommandozeile klar überlegen:

- *Dokumentieren und teilen.* Ein Befehl mit Ausgabe lässt sich in ein Ticket kopieren und von anderen wiederholen. Eine Folge von Tastendrücken nicht.
- *Skripte und Schleifen.* Alles, was du über mehrere Cluster oder Namespaces wiederholst, gehört in `kubectl` mit `-o jsonpath` oder `-o json`.
- *Fragen an die API.* `kubectl explain`, `kubectl auth can-i --as`, `kubectl get --raw '/readyz?verbose'` und `kubectl debug --copy-to` haben in k9s kein Gegenstück.
- *Zustand nach dem Neustart.* `p` zeigt wie `--previous` genau einen vorherigen Lauf. Kombinationen wie `--previous --all-containers --since=10m` gehen nur mit `kubectl`.
- *Kurze Ereignisse.* k9s aktualisiert in Intervallen von zwei Sekunden. Ein Pod, der nur eine Sekunde existiert, kann dazwischen verschwinden. `kubectl get pods -w` und Events zeigen jede Änderung.

Und k9s sieht nur, was dein Benutzer sehen darf. Bleibt eine Ansicht leer, obwohl `kubectl` mit Admin-Rechten Objekte zeigt, liegt es an RBAC, nicht an k9s.

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-03
```][Räumt auf. In k9s ginge das mit `:ns⏎`, Namespace markieren und `Ctrl-d`.]

#aufgabe[
  Wende `szenarien/03-k9s/demo.yaml` auf `talos` an und arbeite ausschließlich in `k9s --context talos`. Finde heraus, auf welchem Knoten der Pod von `wackel` läuft (`o`), wie oft er schon neu gestartet ist, und lies die letzte Logzeile vor dem Absturz. Starte dann `Shift-d` auf einem `web`-Pod und prüfe mit `dig web.dbg-03.svc.cluster.local`, ob der Service-Name aufgelöst wird. Hinweis: Ohne `--profile=baseline` im Plugin würde Talos den Debug-Container mit `violates PodSecurity "baseline:latest"` ablehnen. Lösche den Namespace danach.
]

#gelernt(
  [k9s nutzt dieselbe API und Kubeconfig wie `kubectl`. Sein Vorteil ist Geschwindigkeit, nicht zusätzliches Wissen.],
  [`:` öffnet Ressourcen, `/` filtert (auch `/!`, `/-l`), `0` zeigt alle Namespaces, `Ctrl-z` nur Fehler, `?` die Tasten der Ansicht.],
  [`d`, `y`, `l` und `p` decken die meisten Untersuchungen ab. `p` entspricht `kubectl logs --previous`.],
  [`--readonly` schaltet ändernde Aktionen und gefährliche Plugins ab.],
  [Die Plugins dieses Buchs: `Shift-d` startet netshoot im Pod oder mit `--target` im Container, `Shift-e` zeigt die Events eines Objekts.],
  [Für Dokumentation, Skripte und API-Fragen wie `auth can-i` ist `kubectl` die bessere Wahl.],
)
