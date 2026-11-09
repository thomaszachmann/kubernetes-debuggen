#import "../lib.typ": *

#kapitel(
  [Control Plane, etcd und Webhooks],
  ziel: [Du prüfst API-Server und etcd auf beiden Distributionen, sicherst etcd vor jedem Eingriff, holst einen abgestürzten API-Server zurück und erkennst abgelaufene Zertifikate, hängende Webhooks und Namespaces, die nicht sterben wollen.],
  zeit: [90 Minuten],
  braucht: [Kapitel 2, 3 und 13],
)

== Was in diesem Kapitel kaputtgeht

Alles, was du bisher untersucht hast, lief über den API-Server. In diesem Kapitel ist er selbst das Problem, oder etwas, das er bei jeder Anfrage fragt: etcd, ein Webhook, eine aggregierte API. Fehler auf dieser Ebene treffen nicht einen Pod, sondern alle Benutzer des Clusters gleichzeitig.

#tabelle(
  (auto, 1fr, 1fr),
  ([Szenario], [Symptom], [Wo die Antwort steht]),
  [API-Server startet nicht], [`connection refused` bei jedem `kubectl`], [Log des Containers `kube-apiserver` auf dem Knoten],
  [Client-Zertifikat abgelaufen], [`You must be logged in to the server`], [`openssl x509 -enddate`, Log des API-Servers],
  [Webhook nicht erreichbar], [`failed calling webhook` beim Anlegen], [`ValidatingWebhookConfiguration`, Endpoints des Service],
  [Namespace hängt], [`Terminating` ohne Ende], [Conditions des Namespace, `kubectl get apiservice`],
)

Die Szenarien laufen im Namespace `dbg-14`. Zwei davon greifen in die Control Plane selbst ein. Lies deshalb den Abschnitt über etcd-Snapshots, bevor du anfängst.

== Ist die API gesund?

Der API-Server beschreibt seinen Zustand selbst, über zwei Endpunkte. `/livez` beantwortet die Frage, ob der Prozess lebt und neu gestartet werden sollte. `/readyz` sagt, ob er Anfragen bedienen kann, also auch, ob etcd antwortet. Mit `?verbose` listet er jede Einzelprüfung auf.

#cmd("Mac")[```bash
kubectl --context rke2 get --raw='/readyz?verbose'
kubectl --context talos get --raw='/livez?verbose' | tail -n 3
```][Beide Aufrufe gehen über dieselbe Verbindung wie jedes `kubectl get`, mit deinen Admin-Rechten.]

```text
[+]ping ok
[+]log ok
[+]etcd ok
[+]etcd-readiness ok
[+]informer-sync ok
...
[+]shutdown ok
readyz check passed
```

Eine gescheiterte Prüfung steht mit `[-]` da, etwa `[-]etcd failed: reason withheld`. Den Grund hält der API-Server bewusst zurück, er steht in seinem eigenen Log. Einzelne Prüfungen fragst du direkt ab, zum Beispiel `/readyz/etcd`.

#warum[
  Kommt gar keine Antwort, sondern `The connection to the server 172.16.0.160:6443 was refused - did you specify the right host or port?`, läuft auf diesem Port kein API-Server. Dann hilft kein `kubectl` mehr. Du brauchst einen Weg, der nicht über die Kubernetes-API führt: SSH auf RKE2, die Talos-API auf Talos.
]

== Vor jedem Eingriff: etcd prüfen und sichern

etcd ist das Gedächtnis des Clusters. Jedes Objekt, jedes Secret liegt dort. Bevor du an der Control Plane schraubst, prüfst du, ob etcd gesund ist, und ziehst einen Snapshot. Beide Labor-Cluster haben genau ein etcd-Mitglied, auf `rke2-cp` und `talos-cp`.

=== RKE2

RKE2 betreibt etcd als Static Pod. `etcdctl` liegt im Image, die Client-Zertifikate liegen auf dem Knoten unter `/var/lib/rancher/rke2/server/tls/etcd/` und sind in den Pod eingehängt.

#cmd("rke2-cp")[```bash
etcdcontainer=$(crictl ps --name etcd --quiet)
TLS="--cacert /var/lib/rancher/rke2/server/tls/etcd/server-ca.crt
  --cert /var/lib/rancher/rke2/server/tls/etcd/server-client.crt
  --key /var/lib/rancher/rke2/server/tls/etcd/server-client.key"
crictl exec "$etcdcontainer" etcdctl $TLS endpoint health
crictl exec "$etcdcontainer" etcdctl $TLS endpoint status -w table
crictl exec "$etcdcontainer" etcdctl $TLS alarm list
```][In der RKE2-Umgebung aus Kapitel 2 als root. `$TLS` steht absichtlich ohne Anführungszeichen, die Shell soll es in einzelne Argumente zerlegen.]

```text
127.0.0.1:2379 is healthy: successfully committed proposal: took = 2.4ms
```

`endpoint status` zeigt Version, Datenbankgröße, Leader und Raft-Index als Tabelle. `alarm list` gibt nichts aus, solange kein Alarm aktiv ist. Ein `NOSPACE`-Alarm heißt: Die Datenbank hat ihre Quota erreicht, etcd nimmt keine Schreibzugriffe mehr an.

#cmd("rke2-cp")[```bash
rke2 etcd-snapshot save --name vor-kapitel-14
rke2 etcd-snapshot list
```][Ein Snapshot von Hand. `list` (Alias `ls`) zeigt Name, Ort, Größe und Zeitpunkt aller Snapshots.]

#pruefe[
  Eine Zeile `vor-kapitel-14-rke2-cp-...` mit dem Ort `file:///var/lib/rancher/rke2/server/db/snapshots/...`. Dazu kommen die automatischen Snapshots, die RKE2 standardmäßig um 0 und 12 Uhr zieht und von denen es fünf behält. Manuelle Snapshots räumt RKE2 nicht automatisch weg.
]

=== Talos

Auf Talos ist etcd kein Pod, sondern ein Talos-Dienst. Alles geht über die Talos-API, auch wenn Kubernetes gar nicht mehr antwortet.

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 service etcd
talosctl -n 172.16.0.170 etcd members
talosctl -n 172.16.0.170 etcd status
talosctl -n 172.16.0.170 etcd alarm list
```][Dienststatus, Mitgliederliste, Größe und Leader, zuletzt die Alarme.]

```text
NODE           MEMBER             DB SIZE   IN USE            LEADER
172.16.0.170   3f1c2b9a7d4e6a10   28 MB     9.1 MB (32.50%)   3f1c2b9a7d4e6a10
```

#cmd("Mac")[```bash
mkdir -p ~/talos-backup
talosctl -n 172.16.0.170 etcd snapshot ~/talos-backup/etcd-$(date +%F).snapshot
```][Streamt einen konsistenten Snapshot auf den Mac. Die Datei enthält alle Secrets des Clusters. Sie gehört deshalb nicht ins Repo.]

#distro(
  [Wiederherstellen: `systemctl stop rke2-server`, dann `rke2 server --cluster-reset --cluster-reset-restore-path=<snapshot>`, danach `systemctl start rke2-server`. RKE2 legt Snapshots selbst nach Zeitplan an.],
  [Wiederherstellen: etcd-Daten des Knotens löschen und neu bootstrappen mit `talosctl bootstrap --recover-from=<snapshot>` (Ablauf im Guide „Disaster Recovery“). Einen Zeitplan für Snapshots bringt Talos nicht mit, den baust du selbst, etwa als Cron-Job mit `talosctl`.],
)

== Der API-Server startet nicht

Ein häufiger Grund für einen toten API-Server nach einem Upgrade: ein Argument, das die neue Version nicht mehr kennt. Feature-Gates sind dafür besonders anfällig. Ist ein Feature GA geworden, verschwindet sein Gate nach einigen Versionen, und wer es noch setzt, bekommt einen API-Server, der beim Start abbricht. Du baust das mit einem erfundenen Gate nach.

#datei("szenarien/14-controlplane/rke2-config-kaputt.yaml (Ausschnitt)", ```yaml
kube-apiserver-arg:
  - "feature-gates=DebugBuchGate=true"
```, erklaerung: [Eine Drop-in-Datei für RKE2. Sie kommt nach `/etc/rancher/rke2/config.yaml.d/`, RKE2 liest sie nach der `config.yaml`. Zum Zurücknehmen löschst du sie einfach.])

#datei("labor/talos/patch-apiserver-featuregate.yaml (Ausschnitt)", ```yaml
apiVersion: v1alpha1
kind: KubeAPIServerConfig
extraArgs:
  feature-gates: DebugBuchGate=true
```, erklaerung: [Dasselbe für Talos. Seit 1.14 konfiguriert das Dokument `KubeAPIServerConfig` den API-Server, `cluster.apiServer` ist veraltet.])

#cmd("Mac")[```bash
scp szenarien/14-controlplane/rke2-config-kaputt.yaml <user>@172.16.0.160:/tmp/
ssh <user>@172.16.0.160
```][Kopiert die Datei auf `rke2-cp` und meldet dich dort an.]

#cmd("rke2-cp")[```bash
install -D -m 600 /tmp/rke2-config-kaputt.yaml \
  /etc/rancher/rke2/config.yaml.d/90-kaputt.yaml
systemctl restart rke2-server --no-block
```][Als root. `--no-block` kehrt sofort zurück, statt auf einen Start zu warten, der nie fertig wird. Die Workloads laufen weiter, nur die Control Plane ist weg.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 patch mc \
  --patch @labor/talos/patch-apiserver-featuregate.yaml
```][Talos rendert den Static Pod des API-Servers neu, ohne den Knoten neu zu starten.]

#symptom[
```text
$ kubectl --context rke2 get nodes
The connection to the server 172.16.0.160:6443 was refused - did you specify
the right host or port?
```
Auf dem Talos-Cluster dasselbe mit `172.16.0.170:6443`. Je nach Zeitpunkt siehst du auch einen Timeout oder `EOF`.
]

=== Untersuchen auf RKE2

Der API-Server ist ein Container wie jeder andere. `crictl` fragt containerd direkt und braucht keinen API-Server.

#cmd("rke2-cp")[```bash
crictl ps -a --name kube-apiserver
crictl logs $(crictl ps -a --name kube-apiserver --quiet | head -n 1) 2>&1 \
  | tail -n 5
journalctl -u rke2-server --since "5 min ago" --no-pager | tail -n 10
```][Die Container-Liste zeigt `Exited`-Einträge mit steigender Zahl in der Spalte `ATTEMPT`. Das Log des jüngsten Versuchs nennt den Grund. Das Journal zeigt, dass RKE2 auf den API-Server wartet.]

```text
Error: invalid argument "DebugBuchGate=true" for "--feature-gates" flag:
unrecognized feature gate: DebugBuchGate
```

Dieselben Logs liegen als Dateien unter `/var/log/pods/kube-system_kube-apiserver-rke2-cp_*/kube-apiserver/`. Das Manifest, das RKE2 aus der Konfiguration erzeugt hat, liegt in `/var/lib/rancher/rke2/agent/pod-manifests/kube-apiserver.yaml`. Ein `grep feature-gates` darin bestätigt, woher das Argument kommt.

=== Untersuchen auf Talos

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 containers --namespace cri | grep kube-apiserver
talosctl -n 172.16.0.170 logs --namespace cri \
  kube-system/kube-apiserver-talos-cp:kube-apiserver:<id>
```][Die erste Zeile zeigt die Pod-Sandbox und den Container des API-Servers mit seiner ID. Setze sie in die zweite Zeile ein. Weil der Container ständig neu startet, ändert sich die ID mit jedem Versuch.]

Das Log enthält dieselbe Meldung wie auf RKE2. Welche Konfiguration Talos gerendert hat, zeigt `talosctl -n 172.16.0.170 get staticpods kube-apiserver -o yaml`. Einen schnellen Gesamtüberblick liefert `talosctl -n 172.16.0.170 health`: Es bleibt bei der Prüfung der Kubernetes-Komponenten hängen.

#ursache[
  kube-apiserver bricht beim Parsen seiner Flags ab, weil es das Feature-Gate `DebugBuchGate` nicht kennt. Das Kubelet startet den Static Pod immer wieder neu, jeder Versuch endet sofort. Ohne API-Server antwortet keine Kubernetes-Schnittstelle mehr. Controller, Scheduler und `kubectl` stehen still, die laufenden Pods arbeiten aber weiter.
]

=== Beheben

#cmd("rke2-cp")[```bash
rm /etc/rancher/rke2/config.yaml.d/90-kaputt.yaml
systemctl restart rke2-server
```][RKE2 schreibt das Manifest des API-Servers bei jedem Start neu, ohne das Gate.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 edit mc
```][Lösche im Dokument `KubeAPIServerConfig` die Zeile `feature-gates: DebugBuchGate=true`. Talos rendert den Static Pod sofort neu.]

#pruefe[
  `kubectl --context rke2 get --raw='/readyz'` und dasselbe für `talos` antworten mit `ok`. `talosctl -n 172.16.0.170 health` läuft ohne Fehler durch.
]

#distro(
  [Ohne API-Server gehst du per SSH auf den Knoten. `crictl`, `journalctl` und die Dateien unter `/var/log/pods/` funktionieren unabhängig von Kubernetes. Die Konfiguration korrigierst du in `config.yaml` oder `config.yaml.d/`.],
  [Die Talos-API (Port 50000) läuft weiter, wenn Kubernetes tot ist. `containers`, `logs`, `edit mc` und `etcd status` gehen alle über sie. Ist auch die Talos-API weg, bleibt nur die Konsole der VM.],
)

== Abgelaufenes Client-Zertifikat

Zertifikate laufen ab, und zwar genau dann, wenn niemand daran denkt. Du erzeugst dir deshalb ein Zertifikat, das nach zehn Minuten abläuft. Das Skript schickt einen CertificateSigningRequest mit `expirationSeconds: 600` an den Cluster, genehmigt ihn und baut eine eigene kubeconfig für den Benutzer `dbg14-user`.

#datei("szenarien/14-controlplane/kurzlebiges-zertifikat.sh (Ausschnitt)", ```bash
kubectl --context "$CTX" apply -f - <<YAML
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${NAME}
spec:
  request: $(base64 < "${DIR}/${NAME}.csr" | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 600
  usages:
    - client auth
YAML
kubectl --context "$CTX" certificate approve "$NAME"
```, erklaerung: [600 Sekunden sind das kleinste erlaubte `expirationSeconds`. Schlüssel und kubeconfig landen in `szenarien/14-controlplane/tmp-<kontext>/`, das Verzeichnis ist von Git ausgenommen.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/14-controlplane/kaputt-zertifikat.yaml
szenarien/14-controlplane/kurzlebiges-zertifikat.sh rke2
export KC=szenarien/14-controlplane/tmp-rke2/dbg14-user.kubeconfig
kubectl --kubeconfig $KC get configmaps
```][Legt Namespace, ConfigMap und RoleBinding an, erzeugt das Zertifikat und liest mit ihm die ConfigMaps in `dbg-14`. Das klappt. Jetzt zehn Minuten Pause.]

#symptom[
```text
$ kubectl --kubeconfig $KC get configmaps
error: You must be logged in to the server (Unauthorized)
```
Je nach kubectl-Version steht in der Klammer auch `the server has asked for the client to provide credentials`. An der kubeconfig hat sich nichts geändert.
]

=== Untersuchen

`Unauthorized` heißt: Der API-Server weiß nicht, wer du bist. Bei Client-Zertifikaten ist der erste Verdacht das Ablaufdatum.

#cmd("Mac")[```bash
kubectl config view --kubeconfig $KC --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject -enddate
```][Holt das Zertifikat aus der kubeconfig und zeigt Inhaber und Ablaufzeit.]

```text
subject=CN=dbg14-user
notAfter=Nov  9 21:50:12 2026 GMT
```

Der Zeitpunkt liegt in der Vergangenheit. Die Gegenprobe steht im Log des API-Servers, das du mit deinem Admin-Zugang lesen kannst:

#cmd("Mac")[```bash
kubectl --context rke2 logs -n kube-system kube-apiserver-rke2-cp --since=15m \
  | grep -m 1 "certificate has expired"
```][Auf Talos heißt der Pod `kube-apiserver-talos-cp`.]

Dort steht sinngemäß `"Unable to authenticate the request" err="[x509: certificate has expired or is not yet valid: current time ... is after ...]"`.

#ursache[
  Das Client-Zertifikat ist abgelaufen. Der API-Server prüft bei jeder Anfrage die Gültigkeit und weist abgelaufene Zertifikate ab. Dem Client sagt er aus Sicherheitsgründen nur `Unauthorized`, den genauen Grund schreibt er ins eigene Log.
]

#tabelle(
  (auto, 1fr),
  ([Meldung beim Client], [Was abgelaufen oder falsch ist]),
  [`You must be logged in to the server (Unauthorized)`], [dein Client-Zertifikat (oder Token) aus der kubeconfig],
  [`x509: certificate has expired or is not yet valid`], [das Serving-Zertifikat des API-Servers, oder die Uhr deines Rechners geht falsch],
  [`x509: certificate signed by unknown authority`], [die CA in deiner kubeconfig passt nicht zum Cluster, etwa nach einer Neuinstallation],
)

=== Beheben

Für den Testbenutzer erzeugst du einfach ein neues Zertifikat: das Skript noch einmal aufrufen. Wichtiger ist die Frage, wann die echten Zertifikate deiner Cluster ablaufen.

#cmd("rke2-cp")[```bash
rke2 certificate check --output table
```][Listet alle Zertifikate von RKE2 mit Ablaufdatum, Restlaufzeit und Status.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.170 get kubernetesdynamiccerts -o yaml | head -n 20
talosctl config info
kubectl config view --context talos --minify --raw \
  -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -enddate
```][Die dynamischen Kubernetes-Zertifikate von Talos im PEM-Format, dann die Laufzeit deiner `talosconfig` in der Zeile `Certificate expires`, zuletzt das Ablaufdatum deines Admin-Zertifikats für den Kontext `talos`.]

#pruefe[
  Nach erneutem Aufruf des Skripts liefert `kubectl --kubeconfig $KC get configmaps` wieder die ConfigMap `hallo`. Für den Rest des Kapitels brauchst du `$KC` nicht mehr: `unset KC`.
]

#distro(
  [Zertifikate gelten 365 Tage. RKE2 erneuert beim Start jedes Zertifikat, das abgelaufen ist oder in weniger als 120 Tagen abläuft. Von Hand: `systemctl stop rke2-server`, `rke2 certificate rotate`, `systemctl start rke2-server`. Danach musst du `/etc/rancher/rke2/rke2.yaml` erneut auf den Mac kopieren, denn auch das Admin-Zertifikat ist neu.],
  [Talos erneuert die Server-Zertifikate selbst, das Kubelet braucht dafür mindestens einen Neustart im Jahr. Client-Zertifikate sind deine Sache: Jedes `talosctl kubeconfig` erzeugt eine kubeconfig mit einem Jahr Laufzeit. Die `talosconfig` erneuerst du mit `talosctl config new`, solange die alte noch gilt.],
)

== Ein Webhook blockiert den Namespace

Admission-Webhooks fragt der API-Server bei jedem passenden Schreibzugriff. Ist der Webhook nicht erreichbar, entscheidet `failurePolicy`: `Ignore` lässt die Anfrage durch, `Fail` lehnt sie ab. Kyverno ist ein Beispiel (Kapitel 11), hier geht es um den allgemeinen Fall.

#datei("szenarien/14-controlplane/kaputt-webhook.yaml (Ausschnitt)", ```yaml
kind: ValidatingWebhookConfiguration
metadata:
  name: dbg14-pruefung
webhooks:
  - name: pruefung.dbg14.example.com
    failurePolicy: Fail
    timeoutSeconds: 5
    clientConfig:
      service:
        name: pruefer
        namespace: dbg-14
        path: /validate
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: dbg-14
    rules:
      - operations: ["CREATE", "UPDATE"]
        resources: ["configmaps"]
# ...
```, erklaerung: [Der Service `pruefer` hat keinen einzigen Pod. Der `namespaceSelector` begrenzt den Schaden auf `dbg-14`.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/14-controlplane/kaputt-webhook.yaml
kubectl --context rke2 create configmap test -n dbg-14 --from-literal=a=b
```][Legt Webhook und Service an und versucht danach, eine ConfigMap zu erstellen.]

#symptom[
```text
error: failed to create configmap: Internal error occurred: failed calling webhook
"pruefung.dbg14.example.com": failed to call webhook: Post
"https://pruefer.dbg-14.svc:443/validate?timeout=5s": <Grund>
```
Am Ende steht der eigentliche Grund. Er hängt davon ab, wie der API-Server den Service auflöst und was das Netz antwortet: `connect: connection refused`, `no endpoints available for service "pruefer"` oder, bei einem Backend, das nicht antwortet, `context deadline exceeded` nach `timeoutSeconds`.
]

=== Untersuchen

Die Meldung nennt den Namen des Webhooks, nicht den der Konfiguration. Beide findest du in der Liste:

#cmd("Mac")[```bash
kubectl --context rke2 get \
  validatingwebhookconfigurations,mutatingwebhookconfigurations
kubectl --context rke2 get validatingwebhookconfiguration dbg14-pruefung \
  -o jsonpath='{.webhooks[*].clientConfig.service}{"\n"}'
kubectl --context rke2 get endpointslices -n dbg-14
```][Alle Webhook-Konfigurationen, dann das Ziel des fraglichen Webhooks, zuletzt die Endpunkte des Ziel-Service.]

```text
NAME            ADDRESSTYPE   PORTS     ENDPOINTS   AGE
pruefer-x8k2d   IPv4          <unset>   <unset>     2m
```

In k9s öffnest du die Liste mit `:validatingwebhookconfigurations` und mit `y` das YAML des Eintrags. Keine Endpunkte, also kein Pod hinter dem Service.

#ursache[
  Der API-Server muss für jede ConfigMap in `dbg-14` den Webhook fragen. Der Service dahinter hat keine Pods, der Aufruf scheitert. Wegen `failurePolicy: Fail` lehnt der API-Server die Anfrage ab. Ohne `namespaceSelector` träfe das jeden Namespace, und bei Pods als Ziel könnte der Cluster nicht einmal seine eigenen Komponenten neu starten.
]

=== Beheben

Richtig ist, das Backend wieder zum Laufen zu bringen. Ist es dauerhaft weg, entfernst du die Konfiguration. Im Notfall schaltest du vorübergehend auf `Ignore`:

#cmd("Mac")[```bash
kubectl --context rke2 patch validatingwebhookconfiguration dbg14-pruefung \
  --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
kubectl --context rke2 delete validatingwebhookconfiguration dbg14-pruefung
```][Die erste Zeile ist der Notausgang, die zweite die eigentliche Lösung. Webhook-Konfigurationen selbst laufen nie durch Webhooks, du kannst sie also immer ändern oder löschen.]

#pruefe[
  `kubectl --context rke2 create configmap test -n dbg-14 --from-literal=a=b` meldet `configmap/test created`.
]

== Der Namespace bleibt in Terminating

Ein Namespace verschwindet erst, wenn der Namespace-Controller alles darin gelöscht hat. Dafür muss er wissen, welche Ressourcentypen es überhaupt gibt, und fragt die Discovery des API-Servers. Antwortet eine aggregierte API nicht, ist die Liste unvollständig, und der Controller löscht den Namespace sicherheitshalber nicht. Der Klassiker: Jemand entfernt den metrics-server, aber die APIService `v1beta1.metrics.k8s.io` bleibt stehen.

#datei("szenarien/14-controlplane/kaputt-apiservice.yaml (Ausschnitt)", ```yaml
kind: APIService
metadata:
  name: v1alpha1.debug.dbg14.example.com
spec:
  group: debug.dbg14.example.com
  version: v1alpha1
  service:
    name: debug-api
    namespace: dbg-14
# ...
---
kind: ConfigMap
metadata:
  name: festgehalten
  namespace: dbg-14
  finalizers:
    - dbg14.example.com/aufraeumen
```, erklaerung: [Eine API-Gruppe, deren Service keine Pods hat, und eine ConfigMap mit einem Finalizer, den kein Controller je entfernt. Zwei typische Gründe für hängende Namespaces in einer Datei.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/14-controlplane/kaputt-apiservice.yaml
kubectl --context rke2 delete ns dbg-14 --wait=false
```][`--wait=false`, weil `kubectl` sonst ewig auf das Ende wartet.]

#symptom[
```text
$ kubectl --context rke2 get ns dbg-14
NAME     STATUS        AGE
dbg-14   Terminating   14m
```
Auch nach Minuten keine Änderung. Manche `kubectl`-Befehle melden nebenbei Fehler zur Gruppe `debug.dbg14.example.com`.
]

=== Untersuchen

Der Namespace-Controller schreibt in die Conditions des Namespace, woran er hängt.

#cmd("Mac")[```bash
kubectl --context rke2 get ns dbg-14 -o json | jq -r \
  '.status.conditions[] | select(.status=="True") | "\(.reason): \(.message)"'
```][Nur die Conditions mit Status `True`, also die tatsächlichen Probleme.]

```text
DiscoveryFailed: Discovery failed for some groups, 1 failing: unable to retrieve
  the complete list of server APIs: debug.dbg14.example.com/v1alpha1: ...
SomeResourcesRemain: Some resources are remaining: configmaps. has 1 resource
  instances
SomeFinalizersRemain: Some content in the namespace has finalizers remaining:
  dbg14.example.com/aufraeumen in 1 resource instances
```

#cmd("Mac")[```bash
kubectl --context rke2 get apiservice v1alpha1.debug.dbg14.example.com
kubectl --context rke2 get configmaps -n dbg-14
```][Die APIService der Gruppe und was im Namespace noch übrig ist. Ohne Namen listet `get apiservice` alle, die vom API-Server selbst tragen in `SERVICE` den Wert `Local`.]

```text
NAME                               SERVICE            AVAILABLE                 AGE
v1alpha1.debug.dbg14.example.com   dbg-14/debug-api   False (ServiceNotFound)   15m
```

Vor dem Löschen stand dort `False (MissingEndpoints)`. Jetzt hat der Namespace-Controller den Service schon entfernt, die APIService zeigt ins Leere. In k9s findest du beide Listen unter `:apiservices` und `:namespaces`.

#ursache[
  Zwei Dinge halten den Namespace fest. Erstens ist die APIService nicht verfügbar, die Discovery bleibt unvollständig, und der Controller verweigert das endgültige Löschen. Weil die APIService cluster-weit gilt, betrifft das jeden Namespace, den du in dieser Zeit löschst. Zweitens trägt die ConfigMap einen Finalizer. Der API-Server löscht sie erst, wenn jemand ihn entfernt, und dieser Jemand existiert nicht.
]

=== Beheben

#cmd("Mac")[```bash
kubectl --context rke2 delete apiservice v1alpha1.debug.dbg14.example.com
kubectl --context rke2 patch configmap festgehalten -n dbg-14 \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```][Erst die verwaiste APIService weg, dann den Finalizer entfernen. Bei echten Finalizern prüfst du vorher, welcher Controller ihn setzt und warum er ihn nicht entfernt.]

#pruefe[
  Wenige Sekunden später meldet `kubectl --context rke2 get ns dbg-14` `NotFound`. `kubectl --context rke2 get apiservice` zeigt nur noch `True` in der Spalte `AVAILABLE`.
]

#falle[
  Im Netz kursiert der Tipp, den Finalizer `kubernetes` direkt am Namespace über `/finalize` zu entfernen. Der Namespace ist dann weg, seine Objekte aber nicht unbedingt: Sie bleiben verwaist in etcd und tauchen wieder auf, sobald jemand einen Namespace gleichen Namens anlegt. Behebe immer die Ursache.
]

#aufgabe[
  Spiele das Webhook-Szenario auf `talos` nach, aber ändere vorher in einer Kopie der Datei `failurePolicy` auf `Ignore` und `timeoutSeconds` auf `10`. Starte dann im Service `pruefer` statt keines Pods einen Pod, der Verbindungen annimmt, aber kein TLS spricht (etwa `nicolaka/netshoot:v0.15` mit `nc -lk 8443`, Selektor und Label anpassen). Wie lange dauert jetzt `kubectl create configmap`, und was steht im Log des API-Servers?

  Hinweis: Mit `Ignore` geht die ConfigMap durch, aber erst nach dem Timeout. Ein langsamer Webhook mit `Ignore` macht den Cluster träge statt kaputt. Räume danach mit `kubectl --context talos delete validatingwebhookconfiguration dbg14-pruefung` und `kubectl --context talos delete ns dbg-14` auf.
]

#gelernt(
  [`/readyz?verbose` und `/livez?verbose` zeigen die Einzelprüfungen des API-Servers. Kommt gar keine Antwort, brauchst du SSH oder die Talos-API.],
  [Vor jedem Eingriff an der Control Plane: etcd prüfen (`etcdctl` im etcd-Container bzw. `talosctl etcd status`) und einen Snapshot ziehen (`rke2 etcd-snapshot save` bzw. `talosctl etcd snapshot`).],
  [Ein API-Server, der nicht startet, schreibt den Grund in sein Container-Log: auf RKE2 über `crictl logs`, auf Talos über `talosctl logs --namespace cri`.],
  [`Unauthorized` heißt: dein Client-Zertifikat. `x509` beim Client heißt: das Zertifikat oder die CA des Servers.],
  [Ein Webhook mit `failurePolicy: Fail` und ohne Backend blockiert jede passende Anfrage. Webhook-Konfigurationen lassen sich trotzdem immer löschen.],
  [Hängende Namespaces erklären sich in ihren Conditions. Häufigste Ursachen: nicht verfügbare APIService und Finalizer ohne Controller.],
)
