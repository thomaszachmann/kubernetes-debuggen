#import "../lib.typ": *

#kapitel(
  [Knoten],
  ziel: [Du erkennst, wann ein Fehler nicht im Pod, sondern im Knoten steckt, untersuchst Kubelet und Container-Runtime auf RKE2 per SSH und auf Talos per `talosctl`, und verstehst, warum Pods nach einem Knotenausfall minutenlang hängen.],
  zeit: [75 Minuten],
  braucht: [Kapitel 2 und 3],
)

== Was in diesem Kapitel kaputtgeht

Bisher lag die Ursache immer in einem Manifest. In diesem Kapitel liegt sie eine Ebene tiefer: beim Kubelet, das auf jedem Knoten die Pods startet, überwacht und an den API-Server meldet. Fällt es aus, sieht der Cluster nur noch Schweigen. Und Schweigen interpretiert Kubernetes vorsichtig, mit Fristen, die man kennen muss.

#tabelle(
  (auto, 1fr, 1fr),
  ([Szenario], [Symptom], [Wo die Antwort steht]),
  [Kubelet läuft nicht], [Knoten `NotReady`], [`describe node`, dann Kubelet-Log auf dem Knoten],
  [Knotenausfall], [Pods hängen in `Terminating`, Ersatz erst nach 5 Minuten], [Taints des Knotens, Tolerations des Pods],
  [Lokaler Speicher voll], [Pods `Error`, Reason `Evicted`, immer neue Pods], [`.status.message` des Pods, Events],
  [Drain hängt], [`kubectl drain` wiederholt endlos], [`kubectl get pdb`, Spalte `ALLOWED DISRUPTIONS`],
)

Alle Szenarien laufen im Namespace `dbg-13`. Er trägt das Label `pod-security.kubernetes.io/enforce: privileged`. Das braucht nur der Debug-Pod aus dem Eviction-Szenario auf Talos, die Anwendungen selbst halten `restricted` ein.

== Der Werkzeugkasten für Knoten

Auf einem RKE2-Knoten meldest du dich per SSH an und arbeitest mit den gewohnten Linux-Werkzeugen. Auf Talos gibt es keine Shell. Jede Frage an den Knoten geht als API-Aufruf über `talosctl`. Die Tabelle stellt die Befehle gegenüber, die du in diesem Kapitel brauchst.

#tabelle(
  (auto, 1fr, 1fr),
  ([Frage], [RKE2 (auf dem Knoten, als root)], [Talos (auf dem Mac)]),
  [Läuft das Kubelet?], [`systemctl status rke2-agent` (Server: `rke2-server`)], [`talosctl -n <IP> service kubelet`],
  [Kubelet-Log], [`/var/lib/rancher/rke2/agent/logs/kubelet.log`], [`talosctl -n <IP> logs kubelet`],
  [Log des Dienstes], [`journalctl -u rke2-agent`], [`talosctl -n <IP> services`, `logs <dienst>`],
  [Kernel-Meldungen], [`dmesg -T`], [`talosctl -n <IP> dmesg`],
  [Container des Knotens], [`crictl ps -a`, `crictl logs <id>`], [`talosctl -n <IP> containers --namespace cri`],
  [Überblick live], [`top`, `df -h`], [`talosctl -n <IP> dashboard`],
  [Alles für den Support], [`journalctl` und Logs von Hand sammeln], [`talosctl -n <IP> support`],
)

Für RKE2 gilt die Umgebung aus Kapitel 2: `sudo -i`, dann `KUBECONFIG`, `PATH` und `CRI_CONFIG_FILE` setzen. Ohne `CRI_CONFIG_FILE` findet `crictl` den containerd-Socket von RKE2 nicht.

#falle[
  Seit Talos 1.14 heißt der Schalter für Kubernetes-Container bei `talosctl containers` und `talosctl logs` `--namespace cri`. Das ältere `-k` funktioniert noch, ist aber als veraltet markiert. Außerdem verschlüsselt `talosctl support` das Archiv ab 1.14 standardmäßig für das Support-Team von Sidero Labs. Für die eigene Analyse brauchst du `--no-encryption` oder eigene Empfänger über `--encryption-recipients`.
]

== Knoten wird NotReady

Das Kubelet meldet sich regelmäßig beim API-Server: über ein Lease-Objekt im Namespace `kube-node-lease` und über den Status des Node-Objekts. Bleibt diese Meldung aus, wartet der Node-Lifecycle-Controller im Controller-Manager eine Frist ab, die `node-monitor-grace-period`. Sie beträgt in Kubernetes 1.36 standardmäßig 50 Sekunden (früher 40). Danach setzt er alle Conditions des Knotens auf `Unknown`.

Auf RKE2 hältst du das Kubelet an, indem du den Agenten stoppst. Auf Talos geht das nicht so einfach, also baust du einen Fehler, der in der Praxis häufig vorkommt: einen Tippfehler in den Kubelet-Argumenten.

#datei("labor/talos/patch-kubelet-tippfehler.yaml", ```yaml
apiVersion: v1alpha1
kind: KubeletConfig
extraArgs:
  max-pod: "150"
```, erklaerung: [Gemeint war `max-pods`. Seit Talos 1.14 steht die Kubelet-Konfiguration im eigenen Dokument `KubeletConfig`, das alte Feld `machine.kubelet` ist veraltet.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/web.yaml
kubectl --context talos apply -f szenarien/13-nodes/web.yaml
ssh <user>@172.16.0.161
```][Legt die Testanwendung `web` auf beiden Clustern an und öffnet eine Sitzung auf `rke2-w1`.]

#cmd("rke2-w1")[```bash
sudo systemctl stop rke2-agent
```][Stoppt den RKE2-Agenten und damit das Kubelet. Die Container der Pods laufen in der Regel weiter, nur meldet sie niemand mehr.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.171 patch mc --patch @labor/talos/patch-kubelet-tippfehler.yaml
```][Talos übernimmt die Änderung ohne Neustart des Knotens und startet das Kubelet mit dem neuen Argument neu.]

#symptom[
```text
$ kubectl --context rke2 get nodes
NAME      STATUS     ROLES                       AGE   VERSION
rke2-cp   Ready      control-plane,etcd,master   9d    v1.36.6+rke2r1
rke2-w1   NotReady   <none>                      9d    v1.36.6+rke2r1
```
Nach etwa einer Minute steht `rke2-w1` auf `NotReady`, ebenso `talos-w1` im Cluster `talos`. Die Pods darauf zeigen weiterhin `Running`.
]

=== Untersuchen

Der erste Blick gilt dem Node-Objekt. Dort steht, seit wann und warum der Knoten nicht mehr bereit ist.

#cmd("Mac")[```bash
kubectl --context rke2 describe node rke2-w1 | sed -n '/^Taints/,/^Addresses/p'
```][Zeigt Taints und Conditions. Der Rest der Ausgabe (Kapazität, Pods, Events) ist hier zweitrangig.]

```text
Taints:             node.kubernetes.io/unreachable:NoExecute
                    node.kubernetes.io/unreachable:NoSchedule
Unschedulable:      false
...
Conditions:
Type            Status   ... Reason              Message
----            ------   ... ------              -------
MemoryPressure  Unknown  ... NodeStatusUnknown   Kubelet stopped posting node status.
DiskPressure    Unknown  ... NodeStatusUnknown   Kubelet stopped posting node status.
PIDPressure     Unknown  ... NodeStatusUnknown   Kubelet stopped posting node status.
Ready           Unknown  ... NodeStatusUnknown   Kubelet stopped posting node status.
```

`Unknown` heißt: Der Controller weiß es nicht, weil das Kubelet schweigt. Steht dort dagegen `False` mit einer Meldung des Kubelets, läuft das Kubelet und meldet selbst ein Problem, etwa ein fehlendes CNI. Diese Unterscheidung spart viel Zeit. Der Taint `unreachable` gehört zum Status `Unknown`, bei `False` setzt der Controller `node.kubernetes.io/not-ready`.

In k9s siehst du dasselbe in der Knotenansicht:

#cmd("k9s")[```text
:nodes⏎            Knoten auswählen, d = describe
```][Die Spalte `STATUS` zeigt `NotReady`. In der Describe-Ansicht findest du mit `/` und `Conditions` schnell die richtige Stelle.]

Weil das Kubelet nicht antwortet, hilft `kubectl` hier nicht weiter. Auch `kubectl debug node/rke2-w1` scheitert: Den Debug-Pod müsste genau das Kubelet starten, das ausgefallen ist. Du musst auf den Knoten.

#cmd("rke2-w1")[```bash
systemctl status rke2-agent --no-pager
journalctl -u rke2-agent --since "15 min ago" --no-pager | tail -n 20
tail -n 20 /var/lib/rancher/rke2/agent/logs/kubelet.log
```][Zustand des Dienstes, seine letzten Meldungen und das Ende des Kubelet-Logs. `inactive (dead)` mit einem `Stopped`-Eintrag im Journal heißt: Jemand hat den Dienst angehalten. Ein Absturz sähe anders aus, mit Exit-Code und Neustartversuchen.]

#ursache[
  Auf `rke2-w1` läuft das Kubelet nicht, weil der Dienst `rke2-agent` gestoppt wurde. Ohne Kubelet erneuert niemand das Lease des Knotens. Nach 50 Sekunden setzt der Node-Lifecycle-Controller die Conditions auf `Unknown` und den Taint `node.kubernetes.io/unreachable`. Neue Pods landen nicht mehr auf dem Knoten, die alten bleiben vorerst, wo sie sind.
]

=== Dasselbe auf Talos

Auf Talos fragst du nicht `systemd`, sondern die Dienstverwaltung von Talos. Das Kubelet ist dort ein eigener Dienst, genau wie `etcd`, `containerd` oder `apid`.

#cmd("Mac")[```bash
talosctl -n 172.16.0.171 services
talosctl -n 172.16.0.171 service kubelet
talosctl -n 172.16.0.171 logs kubelet --tail 20
```][Liste aller Dienste mit Zustand und Health, dann die Details zum Kubelet mit den letzten Ereignissen, zuletzt sein Log.]

Im Dienststatus wechseln sich Starts und Fehlschläge ab, Talos startet das Kubelet immer wieder neu. Den Grund liefert das Log, sinngemäß:

```text
Error: failed to parse kubelet flag: unknown flag: --max-pod
```

#ursache[
  Das Kubelet bricht beim Parsen seiner Argumente ab, weil es `--max-pod` nicht kennt. Talos reicht `extraArgs` ungeprüft durch. Es lehnt nur Argumente ab, die es selbst verwaltet, etwa `kubeconfig` oder `container-runtime-endpoint`. Dasselbe passiert mit Flags, die eine neue Kubernetes-Version entfernt hat. Nach einem Upgrade ist das eine typische Ursache für `NotReady`.
]

=== Beheben

#cmd("rke2-w1")[```bash
sudo systemctl start rke2-agent
```][Startet den Agenten wieder. Das Kubelet meldet sich innerhalb weniger Sekunden.]

#cmd("Mac")[```bash
talosctl -n 172.16.0.171 edit mc
```][Öffnet die Machine-Config im Editor. Lösche im Dokument `KubeletConfig` die Zeile `max-pod: "150"` (und `extraArgs:`, falls es leer wird), speichere und schließe. Talos wendet die Änderung sofort an.]

#pruefe[
  `kubectl --context rke2 get nodes` und `kubectl --context talos get nodes` zeigen wieder zweimal `Ready`. Der Taint `unreachable` ist verschwunden, `talosctl -n 172.16.0.171 service kubelet` meldet `STATE Running` und `HEALTH OK`.
]

#distro(
  [Kubelet, containerd und die Steuerung laufen als Kindprozesse von `rke2-agent` (auf dem Server: `rke2-server`). Logs liegen als Dateien unter `/var/lib/rancher/rke2/agent/logs/` und im Journal. Kubelet-Argumente setzt du mit `kubelet-arg` in `/etc/rancher/rke2/config.yaml`, danach Neustart des Dienstes.],
  [Das Kubelet ist ein Talos-Dienst, kein Prozess, den du anfassen kannst. Status und Log kommen nur über `talosctl service` und `talosctl logs`. Argumente stehen im Dokument `KubeletConfig`. Ist sogar die Talos-API weg, bleibt nur die Konsole der VM mit dem Dashboard.],
)

== Pods hängen nach einem Knotenausfall

Ein `NotReady`-Knoten verliert seine Pods nicht sofort. Jeder Pod bekommt beim Anlegen vom Admission-Plugin `DefaultTolerationSeconds` zwei Tolerations: Er duldet die Taints `not-ready` und `unreachable` für 300 Sekunden. Erst danach räumt der Taint-Eviction-Controller ihn ab. Diesmal lässt du den Knoten lange genug ausgefallen.

#cmd("Mac")[```bash
kubectl --context rke2 get pod -n dbg-13 -l app=web \
  -o jsonpath='{.items[0].spec.tolerations}' | jq
```][Zeigt die Tolerations eines `web`-Pods. Im Manifest steht keine einzige, beide stammen vom API-Server.]

Zwei Einträge, für `node.kubernetes.io/not-ready` und `node.kubernetes.io/unreachable`, beide mit `"effect": "NoExecute"` und `"tolerationSeconds": 300`.

#cmd("rke2-w1")[```bash
sudo systemctl stop rke2-agent
```][Derselbe Ausfall wie eben. Diesmal wartest du sechs Minuten, bevor du weitermachst.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-13 -o wide
NAME                   READY   STATUS        RESTARTS   AGE   IP           NODE
web-7c9d8f6b5d-4kq2m   1/1     Running       0          31m   10.42.0.37   rke2-cp
web-7c9d8f6b5d-r8vtn   1/1     Terminating   0          31m   10.42.1.12   rke2-w1
web-7c9d8f6b5d-x7lpd   1/1     Running       0          47s   10.42.0.41   rke2-cp
```
Fünf Minuten lang stand der Pod auf `rke2-w1` scheinbar gesund auf `Running`. Jetzt hängt er in `Terminating`, und erst jetzt gibt es Ersatz auf `rke2-cp`.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-13 --for pod/web-7c9d8f6b5d-r8vtn
```][Die Events des hängenden Pods. Den Namen übernimmst du aus deiner Ausgabe.]

```text
LAST SEEN   TYPE     REASON                 OBJECT                     MESSAGE
5m10s       Normal   TaintManagerEviction   pod/web-7c9d8f6b5d-r8vtn   Marking ...
```

Die vollständige Message lautet `Marking for deletion Pod dbg-13/web-7c9d8f6b5d-r8vtn`. Der Controller hat den Pod zum Löschen markiert. Gelöscht ist er erst, wenn das Kubelet bestätigt, dass die Container weg sind. Dieses Kubelet läuft aber nicht. Der Pod bleibt deshalb in `Terminating`, bis der Knoten zurückkommt oder jemand das Node-Objekt entfernt.

#cmd("k9s")[```text
:pods dbg-13⏎      Spalte NODE beachten, Pod wählen, d = describe
:nodes⏎            rke2-w1 wählen, d = describe, Taints prüfen
```][In der Pod-Liste fällt der Ersatz-Pod mit kleinem `AGE` sofort auf.]

#ursache[
  Der Knoten war nicht erreichbar, also hat der Controller den Taint `node.kubernetes.io/unreachable:NoExecute` gesetzt. Die Pods dulden ihn 300 Sekunden lang. Danach markiert der Controller sie zum Löschen. Bestätigen kann das nur das Kubelet des ausgefallenen Knotens, also hängen sie in `Terminating`. Der Ersatz entsteht trotzdem, weil der ReplicaSet-Controller Pods mit gesetztem `deletionTimestamp` nicht mehr mitzählt.
]

#warum[
  Die Wartezeit ist Absicht. Kubernetes kann einen toten Knoten nicht von einer Netzwerkstörung unterscheiden. Vielleicht laufen die Container noch und schreiben in eine Datenbank. Bei einem StatefulSet würde ein vorschneller Ersatz zwei Pods mit derselben Identität erzeugen. Deshalb entsteht dort auch nach 300 Sekunden kein Ersatz, solange der alte Pod nicht wirklich gelöscht ist.
]

=== Beheben

Der akute Fix ist, den Knoten zurückzuholen. Sobald das Kubelet wieder läuft, beendet es die markierten Pods und bestätigt das Löschen.

#cmd("rke2-w1")[```bash
sudo systemctl start rke2-agent
```][Der hängende Pod verschwindet nach wenigen Sekunden.]

Ist der Knoten dauerhaft verloren, löschst du das Node-Objekt mit `kubectl --context rke2 delete node rke2-w1`. Dann räumt der Garbage Collector die Pods ab, die an den nicht mehr vorhandenen Knoten gebunden waren. Für zustandslose Anwendungen kannst du die Frist außerdem selbst festlegen:

#datei("szenarien/13-nodes/fix-toleranz.yaml (Ausschnitt)", ```yaml
      tolerations:
        - key: node.kubernetes.io/unreachable
          operator: Exists
          effect: NoExecute
          tolerationSeconds: 30
        # ... dasselbe für node.kubernetes.io/not-ready
```, erklaerung: [Steht die Toleration schon im Manifest, ergänzt der API-Server keine eigene.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/fix-toleranz.yaml
```][Rollt `web` mit den kürzeren Tolerations neu aus.]

#pruefe[
  Wiederholst du den Ausfall, steht nach etwa 50 Sekunden `NotReady` und weitere 30 Sekunden später der Ersatz-Pod auf `rke2-cp`. Starte den Agenten danach wieder.
]

#distro(
  [`systemctl stop rke2-agent` simuliert den harten Ausfall gut: Das Kubelet ist weg, die Container laufen weiter. Erst `rke2-killall.sh` würde auch sie beenden.],
  [`talosctl shutdown` und `talosctl reboot` cordonen und drainen den Knoten vorher. Die Pods ziehen dann sauber um, das Szenario tritt nicht auf. Erst `--force` überspringt Cordon und Drain. Einen echten Ausfall simulierst du, indem du die VM im Hypervisor hart ausschaltest.],
)


== Pods werden evicted

Das Kubelet schützt seinen Knoten. Wird der Speicher knapp, die Platte voll (auch bei den Inodes) oder gehen die Prozess-IDs aus, setzt es die Conditions `MemoryPressure`, `DiskPressure` oder `PIDPressure` und wirft Pods hinaus. Dieses Hinauswerfen heißt Eviction. Es greift aber auch ohne Knotennot, wenn ein Pod sein eigenes Limit für lokalen Speicher (`ephemeral-storage`) überschreitet. Das ist das Szenario hier, denn eine volle Platte möchtest du im Labor nicht wirklich provozieren.

#datei("szenarien/13-nodes/kaputt-evicted.yaml (Ausschnitt)", ```yaml
          command:
            - sh
            - -c
            - dd if=/dev/zero of=/daten/block bs=1M count=200 && sleep 3600
          resources:
            limits:
              ephemeral-storage: 100Mi
          volumeMounts:
            - name: daten
              mountPath: /daten
      volumes:
        - name: daten
          emptyDir: {}
```, erklaerung: [200 MiB in ein `emptyDir`, erlaubt sind 100 MiB. Ein `emptyDir` ohne eigenes Medium liegt auf der Platte des Knotens und zählt zum lokalen Speicher des Pods.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/kaputt-evicted.yaml
```][Legt das Deployment `fueller` an. Auf Talos verhält es sich gleich.]

#symptom[
```text
$ kubectl --context rke2 get pods -n dbg-13 -l app=fueller
NAME                       READY   STATUS              RESTARTS   AGE
fueller-6f8b7d9c4b-2xjzq   0/1     Error               0          2m4s
fueller-6f8b7d9c4b-9tqwe   0/1     Error               0          71s
fueller-6f8b7d9c4b-mz5rk   1/1     Running             0          9s
```
Alle paar Sekunden ein neuer Pod, die alten bleiben mit `Error` liegen. Je nach Zeitpunkt siehst du auch `ContainerStatusUnknown`.
]

=== Untersuchen

Die Spalte `STATUS` zeigt den Zustand des Containers. Der Grund, warum der Pod beendet wurde, steht eine Ebene höher im Pod-Status.

#cmd("Mac")[```bash
kubectl --context rke2 get pods -n dbg-13 -l app=fueller \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason
kubectl --context rke2 get pod -n dbg-13 <pod> -o jsonpath='{.status.message}{"\n"}'
```][Phase und Reason jedes Pods, dann die Message eines der Pods mit `Error`.]

```text
NAME                       PHASE     REASON
fueller-6f8b7d9c4b-2xjzq   Failed    Evicted
fueller-6f8b7d9c4b-9tqwe   Failed    Evicted
fueller-6f8b7d9c4b-mz5rk   Running   <none>

Pod ephemeral local storage usage exceeds the total limit of containers 100Mi.
```

Dieselbe Meldung steht als Event mit dem Reason `Evicted` am Pod. In k9s öffnest du einen der Pods mit `d`. Oben in der Describe-Ansicht stehen `Status: Failed`, `Reason: Evicted` und die Message.

Bei einer echten Knotennot sieht die Message anders aus, etwa `The node was low on resource: ephemeral-storage.`, und am Knoten steht `DiskPressure=True` mit dem Taint `node.kubernetes.io/disk-pressure`. Die Schwellen, ab denen das Kubelet eingreift, liest du über den API-Server direkt aus seiner laufenden Konfiguration:

#cmd("Mac")[```bash
kubectl --context rke2 get --raw /api/v1/nodes/rke2-w1/proxy/configz \
  | jq .kubeletconfig.evictionHard
```][Der Endpunkt `configz` liefert die aktive Kubelet-Konfiguration. Das funktioniert auf beiden Distributionen gleich.]

```text
{
  "imagefs.available": "15%",
  "imagefs.inodesFree": "5%",
  "memory.available": "100Mi",
  "nodefs.available": "10%",
  "nodefs.inodesFree": "5%"
}
```

Das sind die Kubernetes-Standardwerte. Fällt der freie Platz unter 10 Prozent, beginnt das Kubelet zu räumen: erst ungenutzte Images und tote Container, dann Pods. Wie voll die Platte wirklich ist, siehst du auf RKE2 mit `df -h /var/lib` auf dem Knoten. Ohne SSH geht es auch mit einem Debug-Pod:

#cmd("Mac")[```bash
kubectl --context rke2 debug node/rke2-w1 -n dbg-13 -it \
  --image=busybox:1.37 --profile=sysadmin -- df -h /host/var/lib
```][Startet einen privilegierten Pod im Host-Netzwerk von `rke2-w1`. Das Dateisystem des Knotens liegt unter `/host`. Der Pod heißt `node-debugger-rke2-w1-` plus Zufallsendung und bleibt danach als `Completed` stehen. Lösche ihn mit `kubectl delete pod` oder in k9s mit `Ctrl-d`.]

#ursache[
  Der Container belegt mit seinem `emptyDir` mehr lokalen Speicher, als `limits.ephemeral-storage` erlaubt. Das Kubelet prüft das bei jedem Durchlauf seines Eviction-Managers und beendet den Pod sofort, ohne Schonfrist. Ein evicted Pod startet nicht neu: Er bleibt mit Phase `Failed` stehen, das Deployment ersetzt ihn durch einen neuen, der dasselbe tut.
]

=== Beheben

Der Fix setzt das Limit auf den echten Bedarf und begrenzt das Volume zusätzlich direkt. Mit `sizeLimit` am `emptyDir` lautet die Message bei Überschreitung `Usage of EmptyDir volume "daten" exceeds the limit "250Mi".`. Damit weißt du sofort, welches Volume schuld ist.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/fix-evicted.yaml
kubectl --context rke2 delete pods -n dbg-13 --field-selector=status.phase=Failed
```][Neues Limit von 300 MiB, `sizeLimit: 250Mi` am Volume. Die zweite Zeile räumt die liegengebliebenen evicted Pods weg. Kubernetes löscht sie sonst erst, wenn der Pod-Garbage-Collector eine sehr hohe Schwelle erreicht.]

#pruefe[
  Ein einziger `fueller`-Pod steht dauerhaft auf `Running`, `RESTARTS` bleibt bei 0, es kommen keine neuen Pods nach.
]

#distro(
  [`kubectl debug node/...` funktioniert ohne Weiteres, mit `chroot /host` hast du sogar die Werkzeuge des Knotens. Auf dem Knoten selbst zeigen `df -h` und `crictl stats` den Verbrauch.],
  [`kubectl debug node/...` braucht einen Namespace mit `enforce: privileged`, sonst lehnt die cluster-weite PSA `baseline` den Pod ab. In neu erzeugten 1.14-Clustern laufen Pods zudem in einer eigenen Sandbox (`workloadIsolation`) und sehen nicht alles vom Host. Besser direkt über die Talos-API: `talosctl mounts` zeigt die Belegung, `talosctl debug <image>` öffnet eine Debug-Shell, ganz ohne Kubelet.],
)

== Drain hängt an einem PodDisruptionBudget

Vor Wartungsarbeiten leerst du einen Knoten mit `kubectl drain`. Der Befehl cordont den Knoten und evictet dann jeden Pod über die Eviction-API. Diese API fragt vorher alle PodDisruptionBudgets, ob der Pod gehen darf. Ein zu strenges PDB sagt immer nein.

#datei("szenarien/13-nodes/kaputt-pdb.yaml (Ausschnitt)", ```yaml
kind: Deployment
metadata:
  name: api
spec:
  replicas: 2
# ...
---
kind: PodDisruptionBudget
metadata:
  name: api
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: api
```, erklaerung: [Zwei Replikas, und das PDB verlangt, dass immer beide verfügbar sind. Das sieht nach maximaler Sicherheit aus und verbietet jede freiwillige Unterbrechung.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/kaputt-pdb.yaml
kubectl --context rke2 drain rke2-w1 --ignore-daemonsets \
  --delete-emptydir-data --timeout=90s
```][`--ignore-daemonsets` ist nötig, weil auf jedem Knoten DaemonSet-Pods wie `rke2-canal` laufen. `--delete-emptydir-data` erlaubt das Evicten von Pods mit `emptyDir`, etwa dem `fueller`. Der Timeout sorgt dafür, dass der Befehl irgendwann aufgibt.]

#symptom[
```text
node/rke2-w1 cordoned
evicting pod dbg-13/api-5b8f9c7d6-hx2lw
error when evicting pods/"api-5b8f9c7d6-hx2lw" -n "dbg-13" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.
evicting pod dbg-13/api-5b8f9c7d6-hx2lw
error when evicting pods/"api-5b8f9c7d6-hx2lw" -n "dbg-13" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.
...
```
Alle fünf Sekunden derselbe Versuch, bis nach 90 Sekunden `global timeout reached` kommt. Liegen beide `api`-Pods zufällig auf `rke2-cp`, läuft der Drain durch. Dann prüfe mit `kubectl get pods -o wide` und drain den Knoten, auf dem ein `api`-Pod liegt.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 get pdb -n dbg-13
```][Die Spalte `ALLOWED DISRUPTIONS` ist die einzige, die zählt.]

```text
NAME   MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
api    2               N/A               0                     3m
```

Null erlaubte Unterbrechungen. Das ändert sich auch nicht, solange beide Pods laufen. In k9s erreichst du die Liste mit `:pdb`, den Knoten mit `:nodes`. Dort steht `rke2-w1` jetzt auf `Ready,SchedulingDisabled`.

#ursache[
  `minAvailable: 2` bei zwei Replikas erlaubt null Evictions. Die Eviction-API antwortet deshalb mit HTTP 429 (`Too Many Requests`), und `kubectl drain` versucht es endlos weiter. Ein PDB schützt nur vor freiwilligen Unterbrechungen. Gegen einen Knotenausfall hilft es nicht, gegen Wartung blockiert es, wenn es zu streng ist.
]

=== Beheben

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/13-nodes/fix-pdb.yaml
kubectl --context rke2 drain rke2-w1 --ignore-daemonsets --delete-emptydir-data
kubectl --context rke2 uncordon rke2-w1
```][Das neue PDB erlaubt mit `maxUnavailable: 1` eine Unterbrechung. Der Drain läuft durch, danach gibst du den Knoten mit `uncordon` wieder frei. In k9s gehen Cordon, Uncordon und Drain in der Knotenansicht mit `c`, `u` und `r`.]

#pruefe[
  `kubectl --context rke2 get pdb -n dbg-13` zeigt `ALLOWED DISRUPTIONS 1`, der Drain endete mit `node/rke2-w1 drained`. Nach `uncordon` steht der Knoten wieder auf `Ready` ohne `SchedulingDisabled`.
]

#falle[
  Ein abgebrochener Drain lässt den Knoten gecordont zurück. Neue Pods landen dann nie auf ihm, ohne dass irgendwo ein Fehler steht. Nach jedem Drain, auch einem gescheiterten, gehört ein Blick auf `kubectl get nodes` dazu.
]

#distro(
  [Drain machst du vor jeder Wartung selbst, etwa vor einem Upgrade von RKE2. Das PDB greift genau dabei.],
  [`talosctl reboot`, `shutdown` und `upgrade` cordonen und drainen den Knoten selbst, ebenfalls über die Eviction-API. Ein zu strenges PDB verzögert also auch diese Befehle. Prüfe die PDBs vor einem Talos-Upgrade.],
)

== Aufräumen

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-13
kubectl --context talos delete ns dbg-13
```][Löscht alle Objekte dieses Kapitels. Prüfe vorher, dass beide Worker `Ready` sind und keiner mehr gecordont ist.]

#aufgabe[
  Ein Kollege meldet: „Auf `talos-w1` startet seit gestern kein neuer Pod mehr, der Knoten ist aber `Ready`.“ Spiele das nach mit `kubectl --context talos cordon talos-w1` und lege danach das Deployment `web` mit vier Replikas an. Finde die Ursache nur über `kubectl get nodes`, `describe node` und die Events der Pods. Welche Zeile in `describe node` verrät es, und welcher Taint steht dabei?

  Hinweis: Achte auf `Unschedulable: true` und den Taint `node.kubernetes.io/unschedulable:NoSchedule`. Mit `uncordon` ist der Spuk vorbei.
]

#gelernt(
  [`Unknown` in den Conditions heißt: Das Kubelet schweigt. `False` heißt: Das Kubelet läuft und meldet selbst ein Problem.],
  [Auf RKE2 untersuchst du das Kubelet mit `systemctl`, `journalctl` und `kubelet.log`, auf Talos mit `talosctl services`, `service kubelet` und `logs kubelet`.],
  [Nach 50 Sekunden ohne Meldung wird ein Knoten `NotReady`, nach weiteren 300 Sekunden werden seine Pods zum Löschen markiert und hängen in `Terminating`, bis das Kubelet zurück ist.],
  [Evicted Pods haben Phase `Failed` und Reason `Evicted`. Die Message nennt die Ressource und das Limit.],
  [Ein PDB mit `minAvailable` gleich der Replikazahl blockiert jeden Drain. `ALLOWED DISRUPTIONS` zeigt es auf einen Blick.],
)
