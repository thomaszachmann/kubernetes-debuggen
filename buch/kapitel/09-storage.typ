#import "../lib.typ": *

#kapitel(
  [Storage],
  ziel: [Du liest die Events von PVC, PV und Provisioner, erkennst, warum ein Volume nicht entsteht oder nicht eingebunden wird, und findest die Daten eines Volumes auf dem Knoten wieder, auf RKE2 per SSH und auf Talos per `talosctl`.],
  zeit: [75 Minuten],
  braucht: [Kapitel 2 (StorageClass `local-path`) und Kapitel 4],
)

== Was in diesem Kapitel kaputtgeht

Beide Labor-Cluster nutzen den local-path-provisioner aus Kapitel 2. Er legt für jeden PersistentVolumeClaim ein Verzeichnis auf genau einem Knoten an und erzeugt dazu ein PersistentVolume vom Typ `hostPath`, das an diesen Knoten gebunden ist. Das ist einfach und schnell, hat aber Eigenheiten, die in Produktion mit Netzwerk-Storage anders aussehen. Beides kommt in diesem Kapitel vor.

#tabelle(
  (auto, 1fr, auto),
  ([Szenario], [Symptom], [Zu sehen an]),
  [Falscher StorageClass-Name], [PVC und Pod `Pending`], [Events am PVC],
  [Provisioner ohne `privileged` (Talos)], [PVC `Pending`, `ProvisioningFailed`], [Events am PVC],
  [RWO-Volume, zwei Knoten], [zweite Replika `Pending`], [Events am Pod],
  [Falsche Rechte im Volume], [`Permission denied`, CrashLoopBackOff], [Logs des Pods],
  [emptyDir läuft über], [Pod wird geräumt, neuer startet], [Status und Events],
)

Die Reihenfolge der Fehlersuche ist immer gleich: Pod, dann PVC, dann PV, dann Provisioner, dann Knoten. Die ersten drei Stationen zeigt `kubectl get pod,pvc,pv`, die vierte das Log des Provisioners in `local-path-storage`.

#warum[
  Die StorageClass `local-path` nutzt `volumeBindingMode: WaitForFirstConsumer`. Ein neuer PVC steht deshalb auf `Pending`, bis ein Pod ihn nutzt, und das Event lautet `waiting for first consumer to be created before binding`. Das ist kein Fehler. Erst wenn der Scheduler einen Knoten für den Pod gewählt hat, legt der Provisioner das Volume genau dort an. Ein `Pending`-PVC ist also nur dann verdächtig, wenn schon ein Pod auf ihn wartet.
]

== Der PVC findet seine StorageClass nicht

#datei("szenarien/09-storage/kaputt-klasse.yaml (Ausschnitt)", ```yaml
kind: PersistentVolumeClaim
metadata:
  name: daten
  namespace: dbg-09
spec:
  storageClassName: local-paht    # FEHLER: Tippfehler
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```, erklaerung: [Die Datei legt außerdem den Namespace `dbg-09` und einen Pod `app` an, der den PVC unter `/data` einbindet.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/09-storage/kaputt-klasse.yaml
kubectl --context rke2 -n dbg-09 get pod,pvc
```][Legt PVC und Pod an und zeigt beide.]

#symptom[
  ```text
  NAME      READY   STATUS    RESTARTS   AGE
  pod/app   0/1     Pending   0          35s

  NAME                          STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
  persistentvolumeclaim/daten   Pending                                      local-paht     35s
  ```
]

Beide hängen. Der Pod wartet auf den PVC, also beginnt die Suche beim PVC:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-09 describe pvc daten | tail -n 4
kubectl --context rke2 get storageclass
```][Die letzten Zeilen von `describe` sind die Events. Danach die Liste aller StorageClasses.]

```text
  Type     Reason              Age               From                         Message
  ----     ------              ----              ----                         -------
  Warning  ProvisioningFailed  4s (x4 over 49s)  persistentvolume-controller  storageclass.storage.k8s.io "local-paht" not found
NAME         PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
local-path   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  3d
```

Am Pod steht das Event `0/2 nodes are available: pod has unbound immediate PersistentVolumeClaims.` Der Scheduler behandelt einen PVC mit unbekannter Klasse wie einen mit sofortiger Bindung, der eben noch nicht gebunden ist. In k9s findest du dieselben Events mit `:pvc dbg-09⏎` und `d` auf dem PVC.

#ursache[
  Der PersistentVolume-Controller sucht die StorageClass `local-paht`, um den passenden Provisioner zu finden. Die gibt es nicht, also wird nie ein Volume angelegt, und der PVC bleibt `Pending`. Fehlt `storageClassName` ganz, gibt es eine ähnliche Sackgasse: Beide Labor-Cluster haben keine Default-StorageClass, der PVC wartet dann auf ein passendes, manuell angelegtes PV (Kapitel 4).
]

Der naheliegende Fix ist ein `kubectl edit`. Die API lehnt ihn ab:

```text
error: persistentvolumeclaims "daten" is invalid: spec: Forbidden: spec is immutable after
creation except resources.requests and volumeAttributesClassName for bound claims
```

Die Spec eines PVC ist nach dem Anlegen unveränderlich. Du löschst deshalb Pod und PVC und legst beide neu an. Im Labor gehen dabei keine Daten verloren, es gab ja nie ein Volume.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-09 delete pod app
kubectl --context rke2 -n dbg-09 delete pvc daten
kubectl --context rke2 apply -f szenarien/09-storage/fix-klasse.yaml
kubectl --context rke2 -n dbg-09 get pvc daten
```][Erst den Pod löschen, sonst hält der Finalizer `kubernetes.io/pvc-protection` den PVC fest. `fix-klasse.yaml` enthält PVC und Pod, diesmal mit `storageClassName: local-path`.]

#pruefe[
  ```text
  NAME    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
  daten   Bound    pvc-3f1c2a9e-8b7d-4e21-9c55-1d0a6b2e7f43   1Gi        RWO            local-path     12s
  ```
  `kubectl --context rke2 -n dbg-09 events --for pvc/daten` zeigt den Ablauf: `WaitForFirstConsumer`, `ExternalProvisioning`, `Provisioning` und `ProvisioningSucceeded` vom Provisioner `rancher.io/local-path`.
]

== Talos: Der Helper-Pod darf nicht starten

Der local-path-provisioner legt das Verzeichnis nicht selbst an. Er startet dafür kurz einen Helper-Pod im Namespace `local-path-storage`, der das Verzeichnis des Knotens per `hostPath` einbindet. Genau das verbietet der Pod-Security-Standard `baseline`, den Talos cluster-weit erzwingt. In Kapitel 2 hast du den Namespace deshalb mit `pod-security.kubernetes.io/enforce=privileged` gekennzeichnet. Was passiert ohne dieses Label, zeigt dieses Szenario.

#cmd("Mac")[```bash
kubectl --context talos label namespace local-path-storage pod-security.kubernetes.io/enforce-
kubectl --context talos apply -f szenarien/09-storage/pvc-test.yaml
```][Das Minus am Ende entfernt das Label. Danach gilt wieder der Talos-Standard `baseline`. `pvc-test.yaml` enthält nur einen PVC `probe` und einen Pod, der ihn nutzt.]

#symptom[
  Pod und PVC bleiben `Pending`. Diesmal existiert die StorageClass, und das Event `WaitForFirstConsumer` ist längst vorbei, denn der Pod hat einen Knoten bekommen.
]

#cmd("Mac")[```bash
kubectl --context talos -n dbg-09 events --for pvc/probe
```][Die Events des PVC, chronologisch sortiert.]

```text
LAST SEEN   TYPE      REASON                 OBJECT                        MESSAGE
40s         Normal    WaitForFirstConsumer   PersistentVolumeClaim/probe   waiting for first consumer to be created before binding
38s         Normal    Provisioning           PersistentVolumeClaim/probe   External provisioner is provisioning volume for claim "dbg-09/probe"
38s         Warning   ProvisioningFailed     PersistentVolumeClaim/probe   failed to provision volume with StorageClass "local-path": failed to create volume pvc-8e2d...: pods "helper-pod-create-pvc-8e2d..." is forbidden: violates PodSecurity "baseline:latest": hostPath volumes (volume "data")
```

Die Meldung nennt alles: den Helper-Pod, den Standard `baseline` und das verbotene Feld. Der Provisioner wiederholt den Versuch mit wachsendem Abstand. Im Log des Provisioners siehst du jeden Versuch:

#cmd("Mac")[```bash
kubectl --context talos -n local-path-storage logs deploy/local-path-provisioner --tail=20
```][In k9s: `:pods local-path-storage⏎`, Pod markieren, `l`. Die Zeile `create the helper pod helper-pod-create-pvc-... into local-path-storage` steht direkt vor der Fehlermeldung.]

#ursache[
  Pod Security Admission prüft jeden Pod beim Anlegen gegen den Standard des Namespace. Der Helper-Pod braucht ein `hostPath`-Volume, um auf dem Knoten ein Verzeichnis anzulegen, und `baseline` verbietet `hostPath` vollständig. Die API lehnt den Pod ab, der Provisioner kann das Volume nicht anlegen. Die Anwendung selbst ist nicht betroffen: Ihr Pod bindet nur einen PVC ein, kein `hostPath`, und darf deshalb in einem `baseline`-Namespace laufen.
]

#cmd("Mac")[```bash
kubectl --context talos label namespace local-path-storage \
  pod-security.kubernetes.io/enforce=privileged
kubectl --context talos -n dbg-09 get pvc probe -w
```][Setzt das Label wieder. Beim nächsten Versuch des Provisioners klappt es, `-w` zeigt den Wechsel auf `Bound`. Beenden mit `Ctrl-C`.]

#pruefe[
  Der PVC ist `Bound`, der Pod `Running`. Auf dem Knoten liegt jetzt das Verzeichnis, das der Provisioner angelegt hat:
  ```text
  $ talosctl -n 172.16.0.171 ls /var/mnt/local-path-provisioner
  NODE           NAME
  172.16.0.171   .
  172.16.0.171   pvc-8e2d4b1a-77c3-4f0e-a9d2-5b6c0e1f3a88_dbg-09_probe
  ```
  Steht der Pod auf `talos-cp`, fragst du `-n 172.16.0.170`. Den Knoten nennt `kubectl get pod probe -o wide`.
]

#distro(
  [RKE2 ohne CIS-Profil erzwingt keinen Pod-Security-Standard. Der Helper-Pod startet auch ohne Label. Mit `profile: cis` gilt dagegen cluster-weit `restricted`, und du brauchst eine Ausnahme für `local-path-storage` (Kapitel 10). Die Volumes liegen unter `/opt/local-path-provisioner`, dem Standardpfad des Provisioners.],
  [Talos erzwingt `baseline` in allen Namespaces außer `kube-system`. Der Namespace des Provisioners braucht `enforce=privileged`. Die Volumes liegen im User-Volume `local-path-provisioner` unter `/var/mnt/local-path-provisioner` auf der EPHEMERAL-Partition. Den Zustand zeigt `talosctl -n 172.16.0.171 get volumestatus u-local-path-provisioner`.],
)

== Zwei Replikas, ein Volume, zwei Knoten

#datei("szenarien/09-storage/kaputt-rwo.yaml (Ausschnitt)", ```yaml
kind: Deployment
metadata:
  name: cache
spec:
  replicas: 2
  template:
    spec:
      affinity:
        podAntiAffinity:         # jede Replika auf einen anderen Knoten
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  app: cache
      # ...
      volumes:
        - name: daten
          persistentVolumeClaim:
            claimName: cache     # FEHLER: beide Replikas teilen ein RWO-Volume
```, erklaerung: [Der PVC `cache` hat `accessModes: [ReadWriteOnce]`. Die Anti-Affinity soll die Replikas auf beide Knoten verteilen, damit der Ausfall eines Knotens nicht beide trifft.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/09-storage/kaputt-rwo.yaml
kubectl --context rke2 -n dbg-09 get pods -l app=cache -o wide
```][`-o wide` zeigt, auf welchem Knoten jeder Pod gelandet ist.]

#symptom[
  ```text
  NAME                     READY   STATUS    RESTARTS   AGE   IP           NODE      ...
  cache-6f8d7b9c5d-hx2lp   1/1     Running   0          40s   10.42.1.41   rke2-w1   ...
  cache-6f8d7b9c5d-q9m4z   0/1     Pending   0          40s   <none>       <none>    ...
  ```
]

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-09 describe pod cache-6f8d7b9c5d-q9m4z | grep -A3 Events
```][Die Events des wartenden Pods. In k9s: `:pods dbg-09⏎`, den Pending-Pod markieren, `d`.]

```text
  Warning  FailedScheduling  25s  default-scheduler  0/2 nodes are available: 1 node(s) didn't match
  PersistentVolume's node affinity, 1 node(s) didn't match pod anti-affinity rules. preemption: 0/2
  nodes are available: 2 Preemption is not helpful for scheduling.
```

Lies die Meldung Knoten für Knoten: `rke2-w1` scheidet aus, weil dort schon eine Replika läuft (Anti-Affinity). `rke2-cp` scheidet aus, weil das PV nur auf `rke2-w1` existiert. Die Node-Affinity des PV bestätigt das: `kubectl --context rke2 get pv -o yaml` zeigt unter `spec.nodeAffinity` den Knoten `rke2-w1`.

#ursache[
  Ein local-path-Volume ist ein Verzeichnis auf genau einem Knoten. Das PV trägt deshalb eine Node-Affinity, und jeder Pod, der es nutzt, muss auf diesen Knoten. Die Anti-Affinity verlangt das Gegenteil. Beides zugleich ist unmöglich. `ReadWriteOnce` heißt übrigens „von einem *Knoten* beschreibbar“, nicht „von einem Pod“. Ohne Anti-Affinity liefen beide Replikas auf `rke2-w1` und teilten sich das Verzeichnis, was für die meisten Anwendungen ebenso falsch wäre.
]

#warum[
  Mit Netzwerk-Storage wie Longhorn, Ceph RBD oder Cloud-Disks sieht derselbe Fehler anders aus. Der Scheduler setzt die zweite Replika auf den anderen Knoten, das Volume ist aber schon am ersten Knoten angehängt. Der Pod bleibt in `ContainerCreating`, und das Event lautet `Multi-Attach error for volume "pvc-..." Volume is already used by pod(s) ...`. Ursache und Lösung sind dieselben. Wer garantieren will, dass wirklich nur ein Pod schreibt, nutzt `ReadWriteOncePod`.
]

Die Lösung: Jede Replika bekommt ein eigenes Volume. Genau dafür gibt es das StatefulSet mit `volumeClaimTemplates`.

#datei("szenarien/09-storage/fix-rwo.yaml (Ausschnitt)", ```yaml
kind: StatefulSet
metadata:
  name: cache
spec:
  serviceName: cache
  replicas: 2
  # ... gleiche Anti-Affinity und gleicher Container
  volumeClaimTemplates:
    - metadata:
        name: daten
      spec:
        storageClassName: local-path
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
```, erklaerung: [Das StatefulSet erzeugt die PVCs `daten-cache-0` und `daten-cache-1`. Jeder wird erst angelegt, wenn sein Pod einen Knoten hat, und landet dank `WaitForFirstConsumer` auf diesem Knoten. Die Datei enthält außerdem den Headless-Service, den `serviceName` verlangt.])

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-09 delete deploy cache
kubectl --context rke2 -n dbg-09 delete pvc cache
kubectl --context rke2 apply -f szenarien/09-storage/fix-rwo.yaml
kubectl --context rke2 -n dbg-09 get pods,pvc -l app=cache -o wide
```][Altes Deployment und alten PVC entfernen, StatefulSet anlegen. Der StatefulSet-Controller kopiert die `matchLabels` des Selektors auf jeden PVC aus `volumeClaimTemplates`. Deshalb findet `-l app=cache` Pods und PVCs zugleich.]

#pruefe[
  `cache-0` und `cache-1` laufen auf verschiedenen Knoten, `kubectl get pvc -n dbg-09` zeigt `daten-cache-0` und `daten-cache-1` als `Bound`. Die PVCs bleiben stehen, wenn du das StatefulSet löschst. So überleben die Daten auch ein `delete sts`.
]

== Permission denied auf dem Volume

#datei("szenarien/09-storage/kaputt-rechte.yaml (Ausschnitt)", ```yaml
      initContainers:
        - name: vorbereiten       # läuft als root und legt das Verzeichnis an
          image: busybox:1.37
          command: ["sh", "-c", "mkdir -p /data/notizen"]
      containers:
        - name: app
          image: busybox:1.37
          command: ["sh", "-c", "date >> /data/notizen/log.txt && sleep infinity"]
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
```, erklaerung: [Ein typisches Muster nach dem Härten: Die Anwendung läuft nicht mehr als root, ein älterer Init-Container schon.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/09-storage/kaputt-rechte.yaml
kubectl --context rke2 -n dbg-09 get pods -l app=notizen
kubectl --context rke2 -n dbg-09 logs deploy/notizen -c app --previous
```][`--previous` zeigt die Ausgabe des letzten abgestürzten Containers. In k9s: Pod markieren, `l`, dann `p` für die vorherigen Logs.]

#symptom[
  ```text
  NAME                       READY   STATUS             RESTARTS      AGE
  notizen-7c8f9d6b5f-l4wqk   0/1     CrashLoopBackOff   3 (25s ago)   80s
  sh: can't create /data/notizen/log.txt: Permission denied
  ```
]

Wem gehört das Verzeichnis? Das zeigt ein Blick auf den Knoten. Wo das Volume liegt, steht im PV:

#cmd("Mac")[```bash
PV=$(kubectl --context rke2 -n dbg-09 get pvc notizen -o jsonpath='{.spec.volumeName}')
kubectl --context rke2 get pv "$PV" -o jsonpath='{.spec.hostPath.path}{"\n"}'
kubectl --context rke2 -n dbg-09 get pod -l app=notizen -o wide
```][Der Pfad des Verzeichnisses auf dem Knoten und der Knoten selbst.]

#cmd("rke2-w1")[```bash
sudo ls -ln /opt/local-path-provisioner/pvc-5a0e..._dbg-09_notizen/
```][Auf RKE2 schaust du direkt per SSH nach. `-n` zeigt numerische UIDs.]

```text
drwxr-xr-x 2 0 0 4096 Nov  9 20:31 notizen
```

Auf Talos fragst du dasselbe mit `talosctl -n 172.16.0.171 ls -l /var/mnt/local-path-provisioner/pvc-..._dbg-09_notizen`. Die Spalten `UID` und `GID` zeigen ebenfalls `0`.

#ursache[
  Das Wurzelverzeichnis des Volumes legt der Provisioner mit den Rechten `0777` an, dort darf jeder schreiben. Das Unterverzeichnis `notizen` hat aber der Init-Container als root mit `0755` angelegt. Die Anwendung läuft als UID 1000 und darf darin nichts anlegen. Der Fehler liegt also nicht in Kubernetes, sondern in den Dateirechten auf dem Volume.
]

Der Reflex wäre `fsGroup: 1000` im `securityContext` des Pods. Bei vielen Volume-Typen ändert der Kubelet damit beim Einbinden die Gruppe aller Dateien. Hier nicht:

#falle[
  local-path legt standardmäßig PVs vom Typ `hostPath` an, und für `hostPath` wendet der Kubelet `fsGroup` nicht an. Der Pod startet mit `fsGroup`, die Rechte auf dem Volume bleiben aber unverändert, und der Fehler bleibt. Das kostet viel Zeit, wenn man es nicht weiß. Bei den meisten CSI-Treibern funktioniert `fsGroup` dagegen.
]

Die zuverlässige Lösung: Wer das Verzeichnis anlegt, übergibt es dem Benutzer der Anwendung.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/09-storage/fix-rechte.yaml
kubectl --context rke2 -n dbg-09 rollout status deploy/notizen
```][Der Init-Container führt jetzt `mkdir -p /data/notizen && chown -R 1000:1000 /data/notizen` aus. Er läuft weiterhin als root. Das ist für einen Einmal-Schritt in Ordnung, verletzt aber den Standard `restricted` (Kapitel 10).]

#pruefe[
  Der Pod ist `1/1 Running`, und `kubectl --context rke2 -n dbg-09 exec deploy/notizen -c app -- cat /data/notizen/log.txt` zeigt einen Zeitstempel. `ls -ln` auf dem Knoten zeigt jetzt `1000 1000` für `notizen`.
]

== Wenn der Platz ausgeht

Nicht jeder Speicher ist ein PVC. Ein `emptyDir` liegt auf der Platte des Knotens unter `/var/lib/kubelet/pods/`, und der Kubelet überwacht seine Größe. Überschreitet ein Pod sein Limit, räumt der Kubelet ihn: Er wird *evicted*.

#datei("szenarien/09-storage/kaputt-platte.yaml (Ausschnitt)", ```yaml
      containers:
        - name: export
          image: busybox:1.37
          command: ["sh", "-c", "dd if=/dev/zero of=/cache/export.tmp bs=1M count=80 && sleep infinity"]
          volumeMounts:
            - name: cache
              mountPath: /cache
      volumes:
        - name: cache
          emptyDir:
            sizeLimit: 50Mi        # FEHLER: kleiner als die Zwischendaten
```)

#cmd("Mac")[```bash
kubectl --context talos apply -f szenarien/09-storage/kaputt-platte.yaml
kubectl --context talos -n dbg-09 get pods -l app=export -w
```][Diesmal auf Talos, das Verhalten ist auf beiden Clustern gleich. Nach einigen Sekunden wird der erste Pod geräumt, und das Deployment startet einen neuen.]

#symptom[
  Nach kurzer Zeit verschwindet der laufende Pod, ein neuer startet, und die alten bleiben mit `0/1` stehen. Ihr Status heißt je nach Zeitpunkt `Error`, `ContainerStatusUnknown` oder `Evicted`. `RESTARTS` steht überall auf 0, denn es ist kein Neustart, sondern ein neuer Pod.
]

#cmd("Mac")[```bash
kubectl --context talos -n dbg-09 get pods -l app=export \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason,MESSAGE:.status.message
```][`status.reason` und `status.message` erklären jede Räumung. In k9s: `:events dbg-09⏎`, dort steht der Grund `Evicted`.]

```text
NAME                      PHASE     REASON    MESSAGE
export-6d5c8f7b9d-9kq2x   Failed    Evicted   Usage of EmptyDir volume "cache" exceeds the limit "50Mi".
export-6d5c8f7b9d-x7wlm   Running   <none>    <none>
```

#ursache[
  `sizeLimit` begrenzt ein `emptyDir` nicht wie ein Dateisystem. Der Prozess kann weiterschreiben, `dd` meldet keinen Fehler. Der Kubelet misst den Verbrauch aber regelmäßig, und sobald er über dem Limit liegt, beendet er den Pod. Das Deployment ersetzt ihn, der neue Pod schreibt dieselben 80 MiB, und der Kreislauf beginnt von vorn.
]

#cmd("Mac")[```bash
kubectl --context talos apply -f szenarien/09-storage/fix-platte.yaml
kubectl --context talos -n dbg-09 delete pod --field-selector=status.phase=Failed
```][Hebt `sizeLimit` auf 200 MiB und setzt Request und Limit für `ephemeral-storage`, damit der Scheduler den Platz einplant. Der zweite Befehl räumt die geräumten Pods weg, die sonst als Leichen stehen bleiben.]

#pruefe[
  Ein Pod `1/1 Running`, der auch nach Minuten noch läuft. `kubectl describe pod` zeigt unter `Requests` den Eintrag `ephemeral-storage: 200Mi`.
]

Wird nicht ein einzelner Pod, sondern der ganze Knoten knapp, setzt der Kubelet die Condition `DiskPressure`, versieht den Knoten mit dem Taint `node.kubernetes.io/disk-pressure` und räumt Pods nach Priorität. Wie du das untersuchst, zeigt Kapitel 13. Für Storage bleibt eine Erkenntnis: local-path-Volumes liegen auf derselben Platte wie Images, Logs und `emptyDir`.

#distro(
  [Volumes unter `/opt/local-path-provisioner` auf der Root-Partition. Prüfen per SSH mit `df -h /opt /var/lib/kubelet` und `sudo du -sh /opt/local-path-provisioner/*`. Ein volles Volume füllt die Systemplatte von Ubuntu.],
  [Volumes unter `/var/mnt/local-path-provisioner` auf der EPHEMERAL-Partition, zusammen mit Images und Kubelet-Daten. Prüfen mit `talosctl -n 172.16.0.171 mounts` (Belegung je Mount) und `talosctl -n 172.16.0.171 usage /var/mnt/local-path-provisioner`.],
)

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-09
kubectl --context talos delete ns dbg-09
```][Räumt beide Cluster auf. Weil `local-path` die `reclaimPolicy: Delete` hat, löscht der Provisioner mit den PVCs auch die PVs und die Verzeichnisse auf den Knoten. Dafür startet er wieder Helper-Pods, `helper-pod-delete-...`.]

#aufgabe[
  Lege auf RKE2 den PVC aus `fix-klasse.yaml` an, ohne einen Pod. Warte eine Minute. Welchen Status hat der PVC, und welches Event siehst du? Lege dann einen Pod an, der den PVC mit `nodeSelector: kubernetes.io/hostname: rke2-cp` nutzt. Auf welchem Knoten liegt das Volume danach?

  Hinweis: Ohne Pod bleibt der PVC `Pending` mit `WaitForFirstConsumer`, das ist korrekt. Sobald der Pod auf `rke2-cp` geplant ist, legt der Provisioner das Verzeichnis dort an. Die Node-Affinity im PV zeigt `rke2-cp`. Jeder spätere Pod mit diesem PVC muss ebenfalls auf `rke2-cp` laufen.
]

#gelernt(
  [Bei Storage-Problemen gilt die Reihenfolge Pod, PVC, PV, Provisioner, Knoten. Die Events am PVC sind fast immer der schnellste Weg zur Ursache.],
  [`WaitForFirstConsumer` ist kein Fehler. Die Spec eines PVC ist unveränderlich, eine falsche StorageClass heißt neu anlegen.],
  [Auf Talos braucht der local-path-provisioner einen Namespace mit PSA `privileged`, sonst lehnt die API seine Helper-Pods ab (`hostPath volumes`).],
  [local-path-Volumes sind an einen Knoten gebunden. `ReadWriteOnce` gilt pro Knoten. Mehrere Replikas mit eigenen Daten brauchen ein StatefulSet mit `volumeClaimTemplates`.],
  [Für `hostPath`-PVs wirkt `fsGroup` nicht. Rechte im Volume setzt du beim Anlegen, etwa im Init-Container. Ein `emptyDir` über seinem `sizeLimit` führt zur Räumung, nicht zu einem Schreibfehler.],
)
