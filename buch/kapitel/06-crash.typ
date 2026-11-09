#import "../lib.typ": *

#kapitel(
  [Abstürze und Neustarts],
  ziel: [Du liest Exit-Codes und das Log des vorigen Containers, erkennst OOMKilled und Probe-Fehler und untersuchst Container ohne Shell mit `kubectl debug`.],
  zeit: [75 Minuten],
  braucht: [Kapitel 1, 3 und 5],
)

== Was in diesem Kapitel kaputtgeht

Jetzt läuft der Container, aber nicht lange oder nicht richtig. Die zwei wichtigsten Werkzeuge dafür sind der Block `Last State` in `kubectl describe pod` und das Log des *vorigen* Containers. Nach einem Neustart zeigt `kubectl logs` nur den neuen Container, die Fehlermeldung des alten steht in `kubectl logs --previous`.

#tabelle(
  (auto, auto, 1fr),
  ([Szenario], [Symptom], [Erster Hinweis]),
  [Falscher Befehl, App-Fehler], [`CrashLoopBackOff`], [Exit-Code 127 bzw. 1, `logs --previous`],
  [Speicherlimit], [`OOMKilled`, dann `CrashLoopBackOff`], [Exit-Code 137, Reason `OOMKilled`],
  [Liveness zu streng, Readiness falsch], [Neustarts bzw. `0/1` ohne Neustart], [Events `Unhealthy`],
  [`readOnlyRootFilesystem`], [`CrashLoopBackOff`], [`Read-only file system` im Log],
  [Distroless-Image], [`exec` scheitert, keine Shell], [`kubectl debug`],
)

Alle Szenarien laufen im Namespace `dbg-06`. Die Exit-Codes aus Kapitel 1 brauchst du hier ständig: 1 ist ein Fehler der Anwendung, 126 und 127 bedeuten „nicht ausführbar“ und „nicht gefunden“ in einer Shell, 137 ist 128 + 9, also `SIGKILL`.

== CrashLoopBackOff: Befehl und Anwendung

`CrashLoopBackOff` ist wie `ImagePullBackOff` ein Wartezustand. Der Container ist beendet, der Kubelet startet ihn neu und verdoppelt die Wartezeit nach jedem Absturz, von 10 Sekunden bis höchstens 5 Minuten. Die Ursache steht nicht im Status, sondern im Exit-Code und im Log.

#datei("szenarien/06-crash/kaputt-crash.yaml (Ausschnitt)", ```yaml
  name: tippfehler
# ...
          command: ["sh", "-c", "serv -p 8080 -h /www"]
---
  name: appfehler
# ...
          command:
            - sh
            - -c
            - |
              echo "Konfiguration wird geladen"
              if [ -z "$DATABASE_URL" ]; then
                echo "FEHLER: DATABASE_URL ist nicht gesetzt" >&2
                exit 1
              fi
              exec sleep infinity
```, erklaerung: [`tippfehler` soll `httpd` starten, aber da steht `serv`. `appfehler` bricht ab, weil eine Umgebungsvariable fehlt, wie viele echte Anwendungen beim Start.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/kaputt-crash.yaml
kubectl --context talos apply -f szenarien/06-crash/kaputt-crash.yaml
```][Legt Namespace und zwei Deployments an.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-06
NAME                          READY   STATUS             RESTARTS      AGE
appfehler-5c8d7b6f4-n4w8k     0/1     CrashLoopBackOff   3 (25s ago)   71s
tippfehler-6b9f8c7d5-k2v7x    0/1     CrashLoopBackOff   3 (28s ago)   71s
```
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-06 -l app=tippfehler | grep -A 9 "State:"
```][Der Ausschnitt um `State` und `Last State` zeigt, wie der letzte Container geendet hat.]

```text
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    127
      Started:      Mon, 09 Nov 2026 10:12:41 +0100
      Finished:     Mon, 09 Nov 2026 10:12:41 +0100
    Ready:          False
    Restart Count:  3
```

Started und Finished in derselben Sekunde, Exit-Code 127: Die Shell hat einen Befehl nicht gefunden. Das Log bestätigt es:

#cmd("Mac")[```bash
kubectl --context rke2 logs -n dbg-06 deploy/tippfehler --previous
kubectl --context rke2 logs -n dbg-06 deploy/appfehler --previous
```][`--previous` liest den vorigen, abgestürzten Container. Ohne die Option erwischst du je nach Zeitpunkt einen gerade gestarteten Container mit leerem Log.]

```text
sh: serv: not found
Konfiguration wird geladen
FEHLER: DATABASE_URL ist nicht gesetzt
```

`appfehler` endet mit Exit-Code 1, die Meldung hat die Anwendung selbst geschrieben. In k9s ist der Weg kürzer: `:pods dbg-06⏎`, Pod wählen, `p` öffnet die Logs des vorigen Containers (`l` die des aktuellen), `d` zeigt `Last State`.

#ursache[
  `tippfehler`: Die Shell findet `serv` nicht und endet mit 127. `appfehler`: Die Anwendung prüft ihre Konfiguration und beendet sich mit 1. In beiden Fällen ist der Container fertig, und weil `restartPolicy` eines Deployments immer `Always` ist, startet der Kubelet ihn neu. Wiederholt sich das, wartet er zunehmend länger: `CrashLoopBackOff`.
]

=== Beheben

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/fix-crash.yaml
kubectl --context talos apply -f szenarien/06-crash/fix-crash.yaml
```][`tippfehler` startet jetzt `httpd`, `appfehler` bekommt `DATABASE_URL` als Umgebungsvariable.]

#pruefe[
  Beide Pods sind `Running` mit `RESTARTS 0`, denn das Deployment hat neue Pods angelegt.
]

#falle[
  Steht der falsche Befehl direkt in `command` statt hinter `sh -c`, also `command: ["serv"]`, gibt es keine Shell, die 127 melden könnte. Dann kann die Runtime den Prozess gar nicht starten. `Last State` zeigt `Reason: StartError` mit Exit-Code 128, und die Meldung enthält `exec: "serv": executable file not found in $PATH`. Ein Log gibt es in diesem Fall nicht.
]

== OOMKilled

Ein Speicherlimit ist eine harte Grenze. Überschreitet ein Container sie, beendet der Kernel ihn mit `SIGKILL`. Es gibt keine Warnung, keine Log-Zeile der Anwendung und keinen geordneten Shutdown.

#datei("szenarien/06-crash/kaputt-oom.yaml (Ausschnitt)", ```yaml
        - name: app
          image: polinux/stress:1.0.4
          command: ["/usr/local/bin/stress"]
          args: ["--vm", "1", "--vm-bytes", "200M", "--vm-hang", "0"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 128Mi
```, erklaerung: [`stress` belegt 200 MB und hält sie. Das Limit erlaubt 128 MiB.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/kaputt-oom.yaml
kubectl --context talos apply -f szenarien/06-crash/kaputt-oom.yaml
```][Legt das Deployment `speicher` an.]

#symptom[
  `kubectl --context rke2 get pods -n dbg-06 -l app=speicher` zeigt kurz `OOMKilled` in der Spalte `STATUS`, danach `CrashLoopBackOff`. Wer nur gelegentlich hinsieht, sieht nur Letzteres.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 get pod -n dbg-06 -l app=speicher \
  -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated}' | jq .
```][Liest den letzten Endzustand direkt aus dem Status. Ohne `jq` kommt dieselbe Information in einer Zeile.]

```text
{
  "containerID": "containerd://9f2c4e1b7a...",
  "exitCode": 137,
  "finishedAt": "2026-11-09T09:31:07Z",
  "reason": "OOMKilled",
  "startedAt": "2026-11-09T09:31:06Z"
}
```

`reason: OOMKilled` und Exit-Code 137 sind eindeutig. Das Log hilft hier kaum: `logs --previous` zeigt nur `stress: info: [1] dispatching hogs: 0 cpu, 0 io, 1 vm, 0 hdd`, danach nichts mehr. Den Beweis liefert der Kernel des Knotens:

#distro[
  Auf dem Knoten des Pods (Spalte `NODE` in `get pods -o wide`), per SSH:
  ```bash
  sudo journalctl -k --since "10 min ago" \
    | grep -i "out of memory"
  ```
][
  Ohne SSH, vom Mac aus:
  ```bash
  talosctl -n 172.16.0.171 dmesg \
    | grep -i "out of memory"
  ```
]

Beide liefern eine Zeile wie `Memory cgroup out of memory: Killed process 23817 (stress) total-vm:208712kB, anon-rss:130816kB, ...`.

#ursache[
  Das Speicherlimit wird als cgroup-Grenze im Kernel durchgesetzt. Überschreitet der Container sie, wählt der OOM-Killer des Kernels einen Prozess in dieser cgroup und beendet ihn mit `SIGKILL` (Signal 9, daher 128 + 9 = 137). Der Kubelet erfährt davon über die Runtime und setzt den Reason `OOMKilled`. Requests helfen nicht: Sie sind nur Buchhaltung für den Scheduler.
]

=== Beheben

Entweder braucht die Anwendung wirklich mehr Speicher, dann hebst du das Limit an. Oder sie verbraucht zu viel, dann ist es ein Fehler der Anwendung, etwa ein Leck oder ein zu großer Cache. Im Labor bekommt sie mehr:

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/fix-oom.yaml
kubectl --context talos apply -f szenarien/06-crash/fix-oom.yaml
```][Setzt Request und Limit für Speicher auf `256Mi`.]

#pruefe[
  Der Pod bleibt `Running`. Auf RKE2 zeigt `kubectl --context rke2 top pod -n dbg-06 -l app=speicher` etwa 200 MiB. Auf Talos fehlt noch der metrics-server (Kapitel 15), dort meldet `kubectl top` nur `error: Metrics API not available`.
]

#falle[
  `OOMKilled` betrifft einen Container, der sein *eigenes* Limit sprengt. Wird der *Knoten* knapp, räumt der Kubelet ganze Pods, sie stehen dann auf `Failed` mit Reason `Evicted` (Kapitel 13).
]

== Probes: zu streng und falsch gezielt

Probes sind die Fragen, die der Kubelet regelmäßig an einen Container stellt. Die Liveness-Probe fragt „lebst du noch?“ und startet den Container bei wiederholtem Nein neu. Die Readiness-Probe fragt „kannst du Anfragen annehmen?“ und nimmt den Pod bei Nein aus dem Service. Beide falsch zu setzen, erzeugt zwei völlig verschiedene Symptome.

#datei("szenarien/06-crash/kaputt-probes.yaml (Ausschnitt)", ```yaml
  name: langsam
# ...
              echo "Lade Daten (dauert 40 Sekunden) ..."
              sleep 40
              # ... danach httpd auf Port 8080
          livenessProbe:
            httpGet: {path: /healthz, port: 8080}
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
---
  name: nieready
# ... httpd auf Port 8080, liefert nur /healthz
          readinessProbe:
            httpGet: {path: /ready, port: 8080}
# ... dazu ein Service "nieready"
```, erklaerung: [`langsam` braucht 40 Sekunden bis zum ersten Lebenszeichen, die Liveness-Probe gibt ihm nur etwa 20. `nieready` fragt einen Pfad ab, den es nicht gibt.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/kaputt-probes.yaml
kubectl --context talos apply -f szenarien/06-crash/kaputt-probes.yaml
```][Zwei Deployments und ein Service.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-06 -l 'app in (langsam,nieready)'
NAME                        READY   STATUS    RESTARTS      AGE
langsam-7d6c9b8f5-x4q2m     1/1     Running   3 (12s ago)   2m5s
nieready-5f7b8d9c6-j6t3p    0/1     Running   0             2m5s
```
`langsam` läuft, startet aber ständig neu. `nieready` läuft ohne Neustart, wird aber nie bereit.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-06 | grep -E "Unhealthy|Killing"
```][Probe-Fehler haben den Reason `Unhealthy` (Typ `Warning`). Den Neustart meldet ein Event vom Typ `Normal` mit Reason `Killing`, deshalb hier kein Filter `--types=Warning`.]

```text
Warning   Unhealthy   Pod/langsam-7d6c9b8f5-x4q2m    Liveness probe failed: Get
"http://10.42.1.23:8080/healthz": dial tcp 10.42.1.23:8080: connect: connection refused
Warning   Unhealthy   Pod/nieready-5f7b8d9c6-j6t3p   Readiness probe failed: HTTP probe failed
with statuscode: 404
Normal    Killing     Pod/langsam-7d6c9b8f5-x4q2m    Container app failed liveness probe, will be
restarted
```

Bei `langsam` lohnt noch ein Blick auf `Last State` und das vorige Log: Exit-Code 137 und als letzte Zeile `Lade Daten (dauert 40 Sekunden) ...`. Der Container wurde mitten im Laden beendet. Exit-Code 137 entsteht, weil die Shell das `SIGTERM` des Kubelets ignoriert und nach der Grace Period `SIGKILL` folgt. Bei `nieready` interessiert, was der Service sieht:

#cmd("Mac")[```bash
kubectl --context rke2 get endpointslices -n dbg-06 -l kubernetes.io/service-name=nieready \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}'
```][Listet jede Adresse der EndpointSlice mit ihrem Zustand.]

```text
10.42.1.24 ready=false
```

In k9s zeigt `d` auf dem Pod die Probe-Konfiguration unter `Liveness` bzw. `Readiness` samt `delay`, `period` und `#failure`.

#ursache[
  `langsam`: Die Liveness-Probe beginnt nach 10 Sekunden und gibt nach drei Fehlschlägen im Abstand von 5 Sekunden auf, also nach rund 20 Sekunden. Die Anwendung braucht 40. Der Kubelet tötet sie also jedes Mal vor dem Ziel, ein Kreislauf ohne Ausweg. `nieready`: Die Readiness-Probe fragt `/ready`, httpd liefert 404. Der Pod bleibt in der EndpointSlice, aber mit `ready=false`, und der Service schickt keinen Verkehr hin. Readiness startet nie neu, deshalb gibt es hier keinen Absturz, nur Stille.
]

=== Beheben

Für langsame Starts gibt es die Startup-Probe. Solange sie nicht erfolgreich war, setzt der Kubelet Liveness und Readiness aus. Danach übernimmt die strenge Liveness-Probe wie gewohnt.

#datei("szenarien/06-crash/fix-probes.yaml (Ausschnitt)", ```yaml
          startupProbe:
            httpGet: {path: /healthz, port: 8080}
            periodSeconds: 5
            failureThreshold: 24
          livenessProbe:
            httpGet: {path: /healthz, port: 8080}
            periodSeconds: 5
            failureThreshold: 3
# ... bei nieready:
          readinessProbe:
            httpGet: {path: /healthz, port: 8080}
```, erklaerung: [Die Startup-Probe gibt dem Container bis zu 24 × 5 = 120 Sekunden. `initialDelaySeconds` der Liveness-Probe entfällt.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/fix-probes.yaml
kubectl --context talos apply -f szenarien/06-crash/fix-probes.yaml
```][Beide Deployments rollen neu aus.]

#pruefe[
  Nach gut 40 Sekunden zeigt `get pods` beide mit `1/1 Running` und `RESTARTS 0`. Die EndpointSlice meldet `ready=true`, und `kubectl --context rke2 run test -n dbg-06 --rm -it --image=busybox:1.37 --restart=Never -- wget -qO- nieready/healthz` antwortet mit `ok`.
]

== readOnlyRootFilesystem

Ein schreibgeschütztes Root-Dateisystem ist eine verbreitete Härtung, auch wenn Pod Security `restricted` sie nicht verlangt. Viele Images schreiben aber beim Start an Stellen, die der Entwickler nie bewusst gewählt hat.

#datei("szenarien/06-crash/kaputt-readonly.yaml (Ausschnitt)", ```yaml
        - name: web
          image: nginx:1.29
          securityContext:
            readOnlyRootFilesystem: true
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/kaputt-readonly.yaml
```][Auf Talos verhält es sich gleich.]

#symptom[
  `webro` steht nach wenigen Sekunden auf `CrashLoopBackOff`, `Last State` zeigt Exit-Code 1.
]

#cmd("Mac")[```bash
kubectl --context rke2 logs -n dbg-06 deploy/webro --previous
```][Das Log des abgestürzten Containers.]

```text
/docker-entrypoint.sh: Launching /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
10-listen-on-ipv6-by-default.sh: info: can not modify /etc/nginx/conf.d/default.conf (read-only file system?)
...
2026/11/09 09:44:12 [emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)
```

Die `info`-Zeile ist harmlos, erst `[emerg]` beendet nginx.

#ursache[
  Mit `readOnlyRootFilesystem: true` wird das Dateisystem des Images nur lesbar eingehängt. nginx braucht beim Start schreibbare Verzeichnisse für temporäre Dateien (`/var/cache/nginx`) und die PID-Datei (unter `/run`). Der Fehlercode 30 ist `EROFS`, „Read-only file system“. Volumes bleiben auch bei schreibgeschütztem Root schreibbar.
]

#datei("szenarien/06-crash/fix-readonly.yaml (Ausschnitt)", ```yaml
          volumeMounts:
            - name: cache
              mountPath: /var/cache/nginx
            - name: run
              mountPath: /run
      volumes:
        - name: cache
          emptyDir: {}
        - name: run
          emptyDir:
            medium: Memory
            sizeLimit: 16Mi
```, erklaerung: [Zwei `emptyDir`-Volumes genau an den Stellen, an denen nginx schreibt. Alles andere bleibt geschützt.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/fix-readonly.yaml
```][Ebenso auf Talos.]

#pruefe[
  `webro` ist `Running`, das Log endet mit `Configuration complete; ready for start up` und den Startmeldungen der Worker-Prozesse. `kubectl --context rke2 exec -n dbg-06 deploy/webro -- touch /test` schlägt weiterhin mit `Read-only file system` fehl, wie gewünscht.
]

== Distroless: Debuggen ohne Shell

Distroless-Images enthalten nur die Anwendung, keine Shell, kein `ls`. `kubectl exec ... -- sh` endet mit einer Meldung, die `exec: "sh": executable file not found in $PATH` enthält. Als Beispiel dient CoreDNS, dessen offizielles Image distroless ist.

#datei("szenarien/06-crash/kaputt-distroless.yaml (Ausschnitt)", ```yaml
kind: ConfigMap
data:
  corefile: |
    .:1053 {
        whoami
        health :8080
        log
    }
---
# ... Deployment "dns-test"
          image: registry.k8s.io/coredns/coredns:v1.14.7
          args: ["-conf", "/etc/coredns/Corefile"]
          volumeMounts:
            - name: config
              mountPath: /etc/coredns
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/06-crash/kaputt-distroless.yaml
kubectl --context rke2 logs -n dbg-06 deploy/dns-test --previous
```][Ebenso auf Talos. Der Pod stürzt sofort ab.]

```text
open /etc/coredns/Corefile: no such file or directory
```

#symptom[
  `dns-test` in `CrashLoopBackOff`, Exit-Code 1. Die Datei fehlt angeblich, obwohl die ConfigMap eingehängt ist. Nachsehen per `exec` geht nicht: keine Shell, und der Container läuft kaum.
]

=== Untersuchen mit einem Ephemeral Container

`kubectl debug` fügt dem Pod einen zusätzlichen Container mit einem Image deiner Wahl hinzu. Er teilt das Netzwerk des Pods, Volumes bekommt er nur über `--custom`:

#datei("szenarien/06-crash/debug-custom.yaml (Ausschnitt)", ```yaml
securityContext:
  runAsUser: 65532
  runAsGroup: 65532
volumeMounts:
  - name: config
    mountPath: /etc/coredns
```, erklaerung: [Kein vollständiges Manifest, nur die Felder, die `kubectl debug` in den Debug-Container übernimmt. Benutzer 65532 ist der Benutzer `nonroot` des CoreDNS-Images.])

#cmd("Mac")[```bash
POD=$(kubectl --context rke2 get pod -n dbg-06 -l app=dns-test -o name)
kubectl --context rke2 debug -it -n dbg-06 $POD --image=busybox:1.37 \
  --profile=baseline --custom=szenarien/06-crash/debug-custom.yaml -- sh
```][Startet busybox als Ephemeral Container im kaputten Pod und öffnet eine Shell. `--profile=baseline` ist auf Talos Pflicht, siehe unten.]

#cmd("Pod")[```bash
ls -l /etc/coredns
lrwxrwxrwx    1 root     root            15 Nov  9 10:31 corefile -> ..data/corefile
```][Im Debug-Container, hier mit Ausgabe. Mit `exit` verlässt du ihn, er bleibt beendet in der Pod-Spezifikation stehen.]

Da ist sie: `corefile` klein geschrieben. Bevor du die ConfigMap änderst, prüfst du die Vermutung an einer Kopie des Pods mit geändertem Befehl:

#cmd("Mac")[```bash
kubectl --context rke2 debug -n dbg-06 $POD --copy-to=dns-test-kopie --profile=baseline \
  --container=coredns -- /coredns -conf /etc/coredns/corefile
kubectl --context rke2 logs -n dbg-06 dns-test-kopie -c coredns
```][`--copy-to` legt einen neuen Pod an, der dem Original gleicht, aber ohne Labels, also ohne Service und Deployment. `--container` mit Befehl ersetzt dessen Startbefehl. Das Log beginnt mit `.:1053` und `CoreDNS-1.14.7`: Mit dem richtigen Dateinamen läuft es.]

#ursache[
  Der Schlüssel einer ConfigMap wird beim Einhängen zum Dateinamen, mit Groß- und Kleinschreibung. Die ConfigMap liefert `corefile`, CoreDNS sucht `Corefile`. Ohne Shell im Image bringst du das Werkzeug zum Nachsehen mit `kubectl debug` selbst mit.
]

=== Beheben und gegenprüfen

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-06 delete pod dns-test-kopie
kubectl --context rke2 apply -f szenarien/06-crash/fix-distroless.yaml
kubectl --context rke2 -n dbg-06 rollout restart deployment dns-test
```][Kopie löschen, ConfigMap mit dem Schlüssel `Corefile` anwenden, Pods neu starten, damit sie die geänderte ConfigMap sofort sehen.]

Jetzt läuft der Container, und du kannst dich mit `--target` in seinen Prozess-Namensraum hängen:

#cmd("Mac")[```bash
POD=$(kubectl --context rke2 get pod -n dbg-06 -l app=dns-test -o name)
kubectl --context rke2 debug -it -n dbg-06 $POD --image=busybox:1.37 --target=coredns \
  --profile=baseline --custom=szenarien/06-crash/debug-custom.yaml -- sh
```][`--target=coredns` teilt die Prozesse dieses Containers mit dem Debug-Container.]

#cmd("Pod")[```bash
ps
ls /proc/1/root/etc/coredns/
```][PID 1 ist jetzt CoreDNS. Über `/proc/1/root` siehst du dessen Dateisystem, weil der Debug-Container als derselbe Benutzer 65532 läuft.]

#pruefe[
```text
PID   USER     TIME  COMMAND
    1 65532     0:00 /coredns -conf /etc/coredns/Corefile
   14 65532     0:00 sh
   21 65532     0:00 ps
Corefile
```
`kubectl get pods -n dbg-06 -l app=dns-test` zeigt `1/1 Running`.
]

#distro[
  RKE2 erzwingt ohne CIS-Profil keinen Pod-Security-Standard. Das Standardprofil `general` von `kubectl debug` funktioniert. Es fügt die Capability `SYS_PTRACE` hinzu, mit der ein Debug-Container als root auch in fremde Prozesse schauen darf.
][
  Talos erzwingt cluster-weit `baseline`. Mit dem Profil `general` lehnt der API-Server den Debug-Container ab: `violates PodSecurity "baseline:latest": non-default capabilities (container "debugger-..." must not include "SYS_PTRACE" in securityContext.capabilities.add)`. Deshalb `--profile=baseline` und für `/proc/1/root` derselbe Benutzer wie der Zielprozess. Das k9s-Plugin `Shift-D` aus Kapitel 3 nutzt ebenfalls `baseline`.
]

#aufgabe[
  Wende `szenarien/06-crash/aufgabe-probe.yaml` an. Der Pod `waechter` läuft, die Anwendung antwortet auf Port 8080, trotzdem steigt `RESTARTS` stetig. Finde die Ursache und korrigiere sie mit `kubectl edit` (in k9s: `e`).

  Hinweis: Die Events `Unhealthy` nennen `dial tcp ...:80: connect: connection refused`. Die Liveness-Probe prüft per `tcpSocket` Port 80, httpd lauscht auf 8080.
]

Aufräumen:

#cmd("Mac")[```bash
kubectl --context rke2 delete namespace dbg-06
kubectl --context talos delete namespace dbg-06
```][Ephemeral Container lassen sich nicht einzeln entfernen. Sie verschwinden erst mit ihrem Pod.]

#gelernt(
  [`CrashLoopBackOff` ist ein Wartezustand. Ursache: Exit-Code in `Last State` und das Log von `kubectl logs --previous` (k9s: `p`).],
  [127 heißt Befehl nicht gefunden (in einer Shell), `StartError` mit 128 heißt: Die Runtime konnte nicht starten. 1 ist ein Fehler der Anwendung.],
  [`OOMKilled` mit 137 ist ein Kernel-Eingriff an der cgroup-Grenze. Beweis: `dmesg` bzw. `journalctl -k`.],
  [Liveness startet neu, Readiness nimmt aus dem Service. Langsame Starts gehören in eine Startup-Probe.],
  [`readOnlyRootFilesystem` braucht `emptyDir`-Volumes an den Stellen, an denen die Anwendung schreibt.],
  [Ohne Shell: `kubectl debug` mit Ephemeral Container, `--target`, `--custom` und `--copy-to`. Auf Talos immer mit `--profile=baseline`.],
)
