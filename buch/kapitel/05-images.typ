#import "../lib.typ": *

#kapitel(
  [Images und Container-Start],
  ziel: [Du unterscheidest die Pull-Fehler an ihrer Meldung, prüfst Images direkt auf dem Knoten, richtest einen Registry-Mirror auf RKE2 und Talos ein und findest Fehler, die zwischen Pull und Start eines Containers passieren.],
  zeit: [60 Minuten],
  braucht: [Kapitel 2 und 4],
)

== Was in diesem Kapitel kaputtgeht

Nach dem Scheduling ist der Kubelet am Zug. Er lässt containerd das Image ziehen, baut die Konfiguration des Containers aus Umgebungsvariablen, Secrets und Volumes zusammen und startet ihn. An jedem dieser drei Schritte kann es scheitern, und jeder Schritt hat seinen eigenen Status.

#tabelle(
  (auto, auto, 1fr),
  ([Schritt], [Status in `get pods`], [Szenario]),
  [Image ziehen], [`ErrImagePull`, `ImagePullBackOff`], [Tippfehler im Tag, Registry nicht erreichbar, privates Repository, Rate-Limit],
  [Konfiguration bauen], [`CreateContainerConfigError`], [ConfigMap fehlt, Schlüssel im Secret fehlt],
  [Prozess starten], [`CrashLoopBackOff`, Log `exec format error`], [Skript ohne Shebang, falsche Architektur],
)

Alle Szenarien laufen im Namespace `dbg-05`. Den Pod hat der Scheduler in diesem Kapitel immer schon platziert. Die Spalte `NODE` in `kubectl get pods -o wide` sagt dir, auf welchem Knoten du nachsehen musst.

== Drei Pull-Fehler, drei Meldungen

`ImagePullBackOff` ist kein Fehler, sondern ein Wartezustand: Der Kubelet hat einen Pull versucht, er ist gescheitert, und jetzt wartet er mit wachsendem Abstand (bis zu fünf Minuten) auf den nächsten Versuch. Die Ursache steht in der Meldung des *ersten* Fehlschlags. Das Manifest erzeugt drei kaputte Deployments auf einmal:

#datei("szenarien/05-images/kaputt-pull.yaml (Ausschnitt)", ```yaml
  name: tippfehler
# ...
        - name: web
          image: nginx:1.29-alpnie
---
  name: unerreichbar
# ...
          image: registry.labor.invalid:5000/web:1.0
---
  name: privat
# ...
          image: docker.io/dbglabor/privat-app:1.0
```, erklaerung: [Ein vertauschter Buchstabe im Tag, eine Registry, die es nicht gibt (die Domain `.invalid` ist dafür reserviert), und ein Repository, für das du keine Zugangsdaten hast.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/kaputt-pull.yaml
kubectl --context talos apply -f szenarien/05-images/kaputt-pull.yaml
```][Legt Namespace und drei Deployments an.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-05
NAME                            READY   STATUS             RESTARTS   AGE
privat-6c7d9f8b5-4kq9m          0/1     ImagePullBackOff   0          58s
tippfehler-7b9c5d4f6-p8x2l      0/1     ErrImagePull       0          58s
unerreichbar-5f6d8c7b9-r3n7v    0/1     ImagePullBackOff   0          58s
```
Der Status wechselt zwischen `ErrImagePull` (gerade gescheitert) und `ImagePullBackOff` (wartet). Am Status allein erkennst du die drei Fälle nicht.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 describe pod -n dbg-05 -l app=tippfehler | tail -n 6
```][Die Events zeigen den ganzen Ablauf eines Pull-Versuchs.]

```text
  Normal   Pulling    40s (x3 over 82s)  kubelet  Pulling image "nginx:1.29-alpnie"
  Warning  Failed     39s (x3 over 81s)  kubelet  Failed to pull image "nginx:1.29-alpnie": rpc
  error: code = NotFound desc = failed to pull and unpack image "docker.io/library/nginx:1.29-
  alpnie": failed to resolve reference "docker.io/library/nginx:1.29-alpnie": docker.io/library/
  nginx:1.29-alpnie: not found
  Warning  Failed     39s (x3 over 81s)  kubelet  Error: ErrImagePull
  Normal   BackOff    12s (x4 over 80s)  kubelet  Back-off pulling image "nginx:1.29-alpnie"
  Warning  Failed     12s (x4 over 80s)  kubelet  Error: ImagePullBackOff
```

Wichtig ist nur die Zeile `Failed to pull image`. Lies sie von hinten: Das letzte Glied ist die eigentliche Antwort von containerd bzw. der Registry. Davor steht, was containerd gerade tun wollte. Beachte auch, dass der Kubelet den kurzen Namen `nginx` zu `docker.io/library/nginx` ergänzt. Für die beiden anderen Pods holst du dir nur diese Zeile:

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-05 --types=Warning | grep "Failed to pull"
```][Filtert alle Pull-Fehler im Namespace. Auf Talos sieht die Ausgabe gleich aus, nur die Adresse des DNS-Resolvers kann sich unterscheiden.]

Die drei Meldungen enden so:

#tabelle(
  (auto, 1fr),
  ([Deployment], [Ende der Meldung (gekürzt)]),
  [`tippfehler`], [`docker.io/library/nginx:1.29-alpnie: not found`],
  [`unerreichbar`], [`dial tcp: lookup registry.labor.invalid ...: no such host`],
  [`privat`], [`pull access denied, repository does not exist or may require authorization: server message: insufficient_scope: authorization failed`],
)

In k9s: `:pods dbg-05⏎`, Pod wählen, `d` (Events unten) oder `Shift-E` (Plugin aus Kapitel 3).

#ursache[
  Drei verschiedene Fehler unter demselben Status. `not found` heißt: Die Registry kennt das Repository, aber nicht diesen Tag. `no such host` heißt: Der *Knoten* kann den Namen der Registry nicht auflösen. Den Pull macht containerd auf dem Knoten, nicht der Pod, deshalb zählt das DNS des Knotens und nicht CoreDNS. `pull access denied` heißt: Die Registry verweigert den Zugriff. Docker Hub unterscheidet dabei absichtlich nicht zwischen „gibt es nicht“ und „darfst du nicht sehen“.
]

Weitere Enden, die du kennen solltest:

#tabelle(
  (auto, 1fr),
  ([Meldung endet mit], [Wahrscheinliche Ursache]),
  [`i/o timeout`], [Firewall oder Proxy zwischen Knoten und Registry],
  [`x509: certificate signed by unknown authority`], [Registry mit eigener CA, der Knoten vertraut ihr nicht],
  [`401 Unauthorized`], [Zugangsdaten vorhanden, aber falsch oder abgelaufen],
  [`429 Too Many Requests`, `toomanyrequests`], [Rate-Limit von Docker Hub, siehe unten],
  [`no match for platform in manifest`], [Image gibt es nicht für die Architektur des Knotens],
)

=== Beheben

Tippfehler und falsche Registry behebt nur ein korrigiertes Manifest:

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/fix-pull.yaml
kubectl --context talos apply -f szenarien/05-images/fix-pull.yaml
```][Setzt bei `tippfehler` und `unerreichbar` das Image `nginx:1.29-alpine`.]

Für ein privates Repository braucht der Pod Zugangsdaten in einem Secret vom Typ `kubernetes.io/dockerconfigjson` im *selben* Namespace. Du legst es mit `kubectl -n dbg-05 create secret docker-registry regcred --docker-server=docker.io --docker-username=... --docker-password=...` an, am besten mit einem Token, das nur lesen darf, und referenzierst es im Pod:

#datei("szenarien/05-images/fix-pull-privat.yaml (Ausschnitt)", ```yaml
    spec:
      imagePullSecrets:
        - name: regcred
      containers:
        - name: web
          image: docker.io/dbglabor/privat-app:1.0
```, erklaerung: [Das Repository `dbglabor/privat-app` gibt es nicht, im Labor bleibt dieser Pod deshalb auch mit Secret hängen. Ersetze das Image durch ein eigenes privates Repository, um den Weg durchzuspielen. Alternativ hängst du das Secret an den ServiceAccount: `kubectl -n dbg-05 patch serviceaccount default -p '{"imagePullSecrets":[{"name":"regcred"}]}'`. Dann bekommen alle neuen Pods dieses ServiceAccounts es automatisch.])

#pruefe[
  `tippfehler` und `unerreichbar` stehen auf `Running`. In den Events erscheint `Successfully pulled image "nginx:1.29-alpine" in ...`. Den Pod `privat` löschst du, wenn du kein eigenes privates Repository hast: `kubectl --context rke2 -n dbg-05 delete deployment privat`.
]

== Auf dem Knoten nachsehen

Manchmal willst du wissen, ob ein Pull am Knoten selbst funktioniert, ohne Kubelet dazwischen: etwa um Zugangsdaten, Mirror oder Proxy zu prüfen. Auf RKE2 geht das mit `crictl`, auf Talos mit `talosctl image`. Beide sprechen mit derselben containerd-Instanz, die auch der Kubelet benutzt.

#cmd("rke2-w1")[```bash
sudo -i
export PATH=$PATH:/var/lib/rancher/rke2/bin
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
crictl pull nginx:1.29-alpnie
crictl pull nginx:1.29-alpine
crictl images | grep nginx
```][Der erste Pull scheitert mit derselben Meldung wie im Event. Der zweite endet mit `Image is up to date for sha256:...`. `crictl images` listet die Spalten `IMAGE`, `TAG`, `IMAGE ID` und `SIZE`.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.171 image pull docker.io/library/nginx:1.29-alpine
talosctl -n 172.16.0.171 image list | grep nginx
```][`image pull` meldet `172.16.0.171: pulled image ...`. `image list` zeigt die Spalten `NODE`, `IMAGE`, `DIGEST`, `SIZE` und mehr. Ohne Angabe arbeitet `talosctl image` im Namespace `cri`, also mit den Images der Kubernetes-Workloads.]

#distro[
  Ausführlichere Pull-Fehler stehen im containerd-Log `/var/lib/rancher/rke2/agent/containerd/containerd.log`.
][
  Das Log der Workload-Laufzeit liest du mit `talosctl -n 172.16.0.171 logs cri`.
]

== Rate-Limit und Registry-Mirror

Docker Hub begrenzt anonyme Pulls auf 100 je sechs Stunden und IP-Adresse. Hinter einem NAT teilen sich alle Knoten und alle Kollegen diese eine Adresse. Wird das Limit erreicht, scheitern Pulls von `docker.io` mit `429 Too Many Requests`, und die Meldung von Docker enthält `toomanyrequests: You have reached your pull rate limit`. Im Labor provozierst du das nicht absichtlich. Du richtest aber die Abhilfe ein, die auch gegen eine langsame oder ausgefallene Registry hilft: einen Mirror auf Knotenebene.

Ein Mirror wird nicht im Pod konfiguriert, sondern in containerd auf jedem Knoten. Der Pod schreibt weiter `nginx:1.29-alpine`, containerd fragt zuerst den Mirror. Im Labor ist das `mirror.gcr.io`, ein öffentlicher Cache von Google für beliebte Images von Docker Hub.

=== RKE2: registries.yaml

#datei("labor/rke2/registries-mirror.yaml (Ausschnitt)", ```yaml
mirrors:
  docker.io:
    endpoint:
      - "https://mirror.gcr.io"
# Zugangsdaten für eine eigene Registry (nicht ins Repo einchecken):
# configs:
#   "registry.example.com:5000":
#     auth:
#       username: xxxxxx
#       password: xxxxxx
```, erklaerung: [Das Format ist RKE2-eigen. RKE2 erzeugt daraus beim Start die containerd-Konfiguration. Zugangsdaten stehen unter `configs`, mit dem Hostnamen der Registry als Schlüssel.])

Kopiere die Datei mit `scp` und deinem SSH-Benutzer aus Kapitel 2 nach `/tmp/registries.yaml` auf jeden Knoten und installiere sie dort:

#cmd("rke2-w1")[```bash
sudo install -m 600 /tmp/registries.yaml /etc/rancher/rke2/registries.yaml
sudo systemctl restart rke2-agent
sudo cat /var/lib/rancher/rke2/agent/etc/containerd/certs.d/docker.io/hosts.toml
```][RKE2 liest `registries.yaml` nur beim Start, deshalb der Neustart (auf `rke2-cp`: `rke2-server`). Laufende Pods überstehen ihn. In der erzeugten `hosts.toml` muss ein Eintrag für `https://mirror.gcr.io` stehen.]

#falle[
  RKE2 probiert die Original-Registry immer als letzten Ausweg, auch wenn ein Mirror eingetragen ist. Ein kaputter Mirror fällt deshalb nicht sofort auf, Pulls werden nur langsamer und zählen wieder gegen das Limit. Willst du das Fallback abschalten, setzt du in `/etc/rancher/rke2/config.yaml` die Option `disable-default-registry-endpoint: true`.
]

=== Talos: RegistryMirrorConfig

Talos 1.14 beschreibt Mirrors in einem eigenen Konfigurationsdokument. Der alte Weg über `machine.registries` in der Machine-Config funktioniert noch, gilt aber als veraltet.

#datei("labor/talos/patch-registry.yaml (Ausschnitt)", ```yaml
apiVersion: v1alpha1
kind: RegistryMirrorConfig
name: docker.io
endpoints:
  - url: https://mirror.gcr.io
```, erklaerung: [`name` ist die Registry, die gespiegelt wird. Zugangsdaten für einen Mirror kommen in ein weiteres Dokument vom Typ `RegistryAuthConfig` mit `name`, `username` und `password`, eigene CAs in `RegistryTLSConfig`. Mit `skipFallback: true` fragt Talos die Original-Registry gar nicht mehr.])

#cmd("Mac")[```bash
talosctl -n 172.16.0.170,172.16.0.171 patch machineconfig \
  --patch @labor/talos/patch-registry.yaml
talosctl -n 172.16.0.171 ls /etc/cri/conf.d/hosts
```][Der Patch fügt das Dokument auf beiden Knoten hinzu. Talos schreibt daraus die containerd-Konfiguration unter `/etc/cri/conf.d/hosts`, mit einem Eintrag für `docker.io`. `talosctl patch` meldet, ob die Änderung ohne Neustart angewendet wurde.]

#pruefe[
  Ein Pull eines noch nicht vorhandenen Images von Docker Hub gelingt weiter, auf RKE2 mit `crictl pull busybox:1.37`, auf Talos mit `talosctl -n 172.16.0.171 image pull docker.io/library/busybox:1.37`. Das Image erscheint unter seinem Originalnamen `docker.io/library/busybox`, nicht unter dem des Mirrors. Ob der Mirror tatsächlich gefragt wurde, zeigt auf RKE2 das containerd-Log, auf Talos `talosctl logs cri`.
]

== CreateContainerConfigError

Das Image ist da, aber der Kubelet kann den Container nicht konfigurieren. Fehlt eine ConfigMap oder ein Secret, das in `env` oder `envFrom` referenziert wird, startet der Container gar nicht erst.

#datei("szenarien/05-images/kaputt-config.yaml (Ausschnitt)", ```yaml
kind: Secret
metadata:
  name: app-secret
stringData:
  db-password: geheim-nur-im-labor
---
# ... Deployment "app"
          envFrom:
            - configMapRef:
                name: app-config
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-secret
                  key: DB_PASSWORD
```, erklaerung: [Zwei Fehler: Die ConfigMap `app-config` existiert nicht, und das Secret hat den Schlüssel `db-password`, nicht `DB_PASSWORD`.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/kaputt-config.yaml
```][Auf Talos verhält sich dieses Szenario genauso.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-05 -l app=app
NAME                   READY   STATUS                       RESTARTS   AGE
app-6f9d7c8b5d-w2xkq   0/1     CreateContainerConfigError   0          21s
```
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-05 --types=Warning
```][Alle Warnungen im Namespace, die neueste unten. In k9s: Pod wählen, `Shift-E`.]

```text
LAST SEEN   TYPE      REASON    OBJECT                     MESSAGE
3s          Warning   Failed    Pod/app-6f9d7c8b5d-w2xkq   Error: configmap "app-config" not found
```

Der Kubelet meldet immer nur den ersten Fehler, auf den er trifft. Lege die ConfigMap an und sieh, was danach kommt:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-05 create configmap app-config \
  --from-literal=DB_HOST=db.dbg-05.svc.cluster.local
```][Der Kubelet versucht es von selbst wieder. Nach einigen Sekunden steht ein neues Event da.]

```text
Warning   Failed    Pod/app-6f9d7c8b5d-w2xkq   Error: couldn't find key DB_PASSWORD in Secret
dbg-05/app-secret
```

Welche Schlüssel das Secret wirklich hat, zeigt `kubectl --context rke2 describe secret app-secret -n dbg-05` unter `Data`, ohne die Werte auszugeben: nur `db-password`.

#ursache[
  Umgebungsvariablen löst der Kubelet unmittelbar vor dem Start des Containers auf. Fehlt das Objekt oder der Schlüssel, und ist die Referenz nicht `optional: true`, bricht er ab, setzt `CreateContainerConfigError` und versucht es periodisch wieder. Der Pod ist dabei schon geplant und das Image gezogen, deshalb sieht der Fehler auf den ersten Blick wie ein Image-Problem aus.
]

=== Beheben

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/fix-config.yaml
```][Legt die ConfigMap deklarativ an und referenziert den richtigen Schlüssel `db-password`.]

#pruefe[
  Der Pod ist `Running`, und `kubectl --context rke2 logs -n dbg-05 deploy/app` zeigt `Verbinde mit db.dbg-05.svc.cluster.local`.
]

#falle[
  Ist die fehlende ConfigMap nicht als Umgebungsvariable, sondern als *Volume* eingebunden, sieht der Fehler anders aus: Der Pod hängt in `ContainerCreating`, und das Event heißt `FailedMount` mit `MountVolume.SetUp failed for volume "config" : configmap "app-config" not found`. Dieselbe Ursache, ein anderer Status.
]

== exec format error

Dieser Fehler entsteht, wenn der Kernel die Datei, die als Prozess gestartet werden soll, nicht ausführen kann. Der klassische Fall ist ein Image für die falsche CPU-Architektur, etwa auf einem Mac mit Apple Silicon für `arm64` gebaut und auf `amd64`-Knoten gestartet. Im Labor reproduzierst du ihn mit einem zweiten, ebenso häufigen Auslöser: einem Startskript ohne Shebang-Zeile.

#datei("szenarien/05-images/kaputt-exec.yaml (Ausschnitt)", ```yaml
kind: ConfigMap
data:
  start.sh: |
    echo "Starte Dienst"
    exec sleep infinity
---
# ... Deployment "skript"
          command: ["/scripts/start.sh"]
          volumeMounts:
            - name: skript
              mountPath: /scripts
      volumes:
        - name: skript
          configMap:
            name: start-skript
            defaultMode: 0755
```, erklaerung: [Das Skript ist ausführbar, aber die erste Zeile `#!/bin/sh` fehlt.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/kaputt-exec.yaml
kubectl --context talos apply -f szenarien/05-images/kaputt-exec.yaml
```][Legt ConfigMap und Deployment `skript` an.]

#symptom[
  `kubectl --context rke2 get pods -n dbg-05 -l app=skript` zeigt nach kurzer Zeit `CrashLoopBackOff` mit steigender Zahl in `RESTARTS`.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 logs -n dbg-05 deploy/skript --previous
```][`--previous` liest das Log des letzten beendeten Containers. In k9s: Pod wählen, `p`.]

```text
exec /scripts/start.sh: exec format error
```

Die Zeile stammt nicht vom Skript, sondern von der Container-Runtime (runc), die den Prozess starten wollte. Ob Architektur oder Shebang schuld ist, klärst du in zwei Schritten:

#cmd("Mac")[```bash
kubectl --context rke2 get nodes -L kubernetes.io/arch
kubectl --context rke2 get cm start-skript -n dbg-05 -o jsonpath='{.data.start\.sh}' | head -n 1
```][Die erste Zeile zeigt die Architektur jedes Knotens in der Spalte `ARCH`. Die zweite zeigt die erste Zeile des Skripts: Hier fehlt `#!/bin/sh`.]

#ursache[
  runc startet den Befehl des Containers direkt mit dem Systemaufruf `execve`, ohne Shell. Der Kernel erkennt ausführbare Dateien an ihren ersten Bytes: ELF-Binaries für die eigene Architektur oder Skripte mit `#!`. Alles andere lehnt er mit `ENOEXEC` ab, und das erscheint als `exec format error`. In einer interaktiven Shell würde dasselbe Skript laufen, weil die Shell es in diesem Fall selbst interpretiert.
]

=== Beheben

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/05-images/fix-exec.yaml
kubectl --context rke2 -n dbg-05 rollout restart deployment skript
```][Die neue ConfigMap beginnt mit `#!/bin/sh`. Der Neustart sorgt dafür, dass der Pod die neue Fassung sofort sieht. Auf Talos dieselben Befehle mit `--context talos`.]

#pruefe[
  `kubectl --context rke2 logs -n dbg-05 deploy/skript` zeigt `Starte Dienst`, der Pod ist `Running` mit `RESTARTS 0`.
]

#warum[
  Bei falscher Architektur scheitert oft schon der Pull (`no match for platform in manifest`), wenn das Image die Architektur des Knotens gar nicht anbietet. Stimmen die Metadaten, aber das Binary nicht, kommt `exec format error`. Welche Plattformen ein Image hat, zeigt `docker buildx imagetools inspect nginx:1.29`.
]

#aufgabe[
  Wende `szenarien/05-images/aufgabe-pullpolicy.yaml` auf `--context talos` an. Das Deployment `offline` startet nicht. Finde die Ursache über die Events und bringe den Pod zum Laufen, *ohne* das Manifest zu ändern.

  Hinweis: Der Status heißt `ErrImageNeverPull`, die Meldung `Container image "nginx:1.29-alpine-slim" is not present with pull policy of Never`. Der Kubelet zieht bei `imagePullPolicy: Never` nie selbst. Lade das Image auf dem Knoten, auf dem der Pod liegt, mit `talosctl image pull` vor. Der Pod startet beim nächsten Versuch des Kubelets.
]

Aufräumen auf beiden Clustern:

#cmd("Mac")[```bash
kubectl --context rke2 delete namespace dbg-05
kubectl --context talos delete namespace dbg-05
```][Der Registry-Mirror bleibt aktiv. Er schadet nicht und schont das Rate-Limit in den folgenden Kapiteln.]

#gelernt(
  [`ImagePullBackOff` ist ein Wartezustand. Die Ursache steht im Event `Failed to pull image`, am Ende der Meldung.],
  [`not found`, `no such host`, `pull access denied`, `x509`, `429`: Jede Endung zeigt auf eine andere Ursache. Den Pull macht der Knoten, nicht der Pod.],
  [`crictl` auf RKE2 und `talosctl image` auf Talos prüfen Pulls direkt an containerd, ohne Kubelet.],
  [Mirrors und Registry-Zugangsdaten auf Knotenebene: RKE2 `/etc/rancher/rke2/registries.yaml` plus Neustart, Talos `RegistryMirrorConfig` per `talosctl patch`.],
  [`CreateContainerConfigError` meldet fehlende ConfigMaps, Secrets und Schlüssel, immer nur den ersten Fehler.],
  [`exec format error` heißt: Der Kernel kann die Datei nicht ausführen. Falsche Architektur oder fehlender Shebang.],
)
