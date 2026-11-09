#import "../lib.typ": *

#kapitel(
  [Das Labor],
  ziel: [Aus vier leeren VMs werden zwei Cluster: RKE2 auf Ubuntu und Talos Linux. Dein Mac steuert sie über die Kontexte `rke2` und `talos`, beide haben eine StorageClass `local-path`, und k9s ist mit den Plugins dieses Buchs eingerichtet.],
  zeit: [120 Minuten],
  braucht: [Vier VMs (zwei mit Ubuntu 24.04 und SSH, zwei leer), ein Mac mit Homebrew, das geklonte Repo],
)

== Was du aufbaust

Jeder Fehler in diesem Buch läuft auf zwei Clustern. Beide nutzen dieselbe Kubernetes-Version, unterscheiden sich aber im Betriebsmodell: RKE2 ist ein Paket auf einem gewöhnlichen Linux, in das du dich per SSH einloggst. Talos ist ein eigenes Betriebssystem ohne Shell und ohne SSH, das du nur über eine API steuerst. Gerade diese Unterschiede machen das Debuggen interessant.

#tabelle(
  (auto, auto, auto, auto, 1fr),
  ([Knoten], [IP], [Kontext], [System], [Rolle]),
  [`rke2-cp`], [`172.16.0.160`], [`rke2`], [Ubuntu 24.04], [Server: Control Plane, etcd, nimmt auch Workloads],
  [`rke2-w1`], [`172.16.0.161`], [`rke2`], [Ubuntu 24.04], [Agent],
  [`talos-cp`], [`172.16.0.170`], [`talos`], [Talos v1.14.5], [Control Plane, Scheduling erlaubt],
  [`talos-w1`], [`172.16.0.171`], [`talos`], [Talos v1.14.5], [Worker],
)

Die Control-Plane-Knoten brauchen 4 CPUs, 8 GB RAM und 60 GB Platte, die beiden anderen 2 CPUs, 4 GB und 40 GB. Gib jeder VM eine feste IP oder eine DHCP-Reservierung. Die Adressen stehen in Konfigurationen und Zertifikaten und dürfen sich später nicht ändern. Hast du andere Adressen, ersetze sie in den Dateien unter `labor/` und in den Befehlen.

Beide Cluster laufen mit Kubernetes 1.36.6. Was sie mitbringen, unterscheidet sich deutlich:

#tabelle(
  (auto, 1fr, 1fr),
  ([], [RKE2 v1.36.6+rke2r1], [Talos v1.14.5]),
  [CNI], [Canal (Flannel plus Calico für NetworkPolicies)], [Flannel, setzt *keine* NetworkPolicies durch],
  [Ingress], [Traefik (`rke2-traefik`)], [keiner],
  [metrics-server], [ja], [nein],
  [StorageClass], [keine], [keine],
  [Pod Security], [keine Vorgabe], [cluster-weit `enforce: baseline`, `warn` und `audit` auf `restricted`],
  [Zugang zum Knoten], [SSH, `journalctl`, `crictl`], [nur `talosctl` über Port 50000],
)

Die fehlenden Teile ergänzen spätere Kapitel, wenn sie gebraucht werden. Nur die StorageClass legst du schon hier an.

#warum[
  Mach von allen vier VMs einen Snapshot, sobald dieses Kapitel durch ist. Du wirst die Cluster in den nächsten Kapiteln absichtlich beschädigen. Meistens behebst du den Fehler danach selbst, aber wenn ein Experiment schiefgeht, bist du mit dem Snapshot in einer Minute wieder am Ausgangspunkt.
]

== Werkzeuge auf dem Mac

#cmd("Mac")[```bash
brew install kubernetes-cli helm siderolabs/tap/talosctl derailed/k9s/k9s
```][Installiert `kubectl`, `helm`, `talosctl` und k9s. Homebrew installiert jeweils die neueste Version. Das Buch beschreibt kubectl 1.36, talosctl 1.14.5, helm 4 und k9s 0.51.0.]

#cmd("Mac")[```bash
kubectl version --client
talosctl version --client
k9s version
```][Zeigt die installierten Versionen.]

#falle[
  `talosctl` sollte zur Talos-Version der Knoten passen. Ein deutlich neueres `talosctl` erzeugt mit `gen config` Konfigurationen für seine eigene Talos-Version und trägt das passende Installer-Image ein. Liegt deine Version nicht bei 1.14, lade das Binary für v1.14.5 von der Release-Seite des Projekts auf GitHub.
]

#cmd("Mac")[```bash
git clone https://github.com/thomaszachmann/kubernetes-debuggen.git
cd kubernetes-debuggen
```][Alle Pfade im Buch sind relativ zu diesem Verzeichnis. Befehle mit dem Etikett *Mac* führst du hier aus.]

== RKE2: die Konfiguration

RKE2 liest beim Start die Datei `/etc/rancher/rke2/config.yaml`. Jeder Schlüssel entspricht einer Option des Befehls `rke2 server` oder `rke2 agent`. Die Dateien für beide Knoten liegen im Repo:

#datei("labor/rke2/config-cp.yaml", ```yaml
node-name: rke2-cp
node-ip: 172.16.0.160
token: TOKEN-HIER-EINSETZEN
tls-san:
  - 172.16.0.160
  - rke2-cp
write-kubeconfig-mode: "0600"
cni: canal
ingress-controller: traefik
```, erklaerung: [
  `token` ist das gemeinsame Geheimnis, mit dem sich der Agent beim Server ausweist. `tls-san` nimmt IP und Namen in das Zertifikat des API-Servers auf, sonst lehnt `kubectl` vom Mac die Verbindung mit einem `x509`-Fehler ab. `write-kubeconfig-mode` lässt die Admin-Kubeconfig nur für root lesbar. `cni` und `ingress-controller` entsprechen den Standardwerten von RKE2 1.36. Sie stehen trotzdem hier, damit die Datei zeigt, womit das Labor arbeitet.
])

#datei("labor/rke2/config-w1.yaml", ```yaml
server: https://172.16.0.160:9345
node-name: rke2-w1
node-ip: 172.16.0.161
token: TOKEN-HIER-EINSETZEN
```, erklaerung: [
  Der Agent meldet sich über den Supervisor-Port 9345 beim Server an, nicht über den API-Port 6443. Über diese Verbindung holt er sich Zertifikate und die Adresse des API-Servers.
])

Das Repo ist öffentlich, deshalb steht dort kein echtes Token. Du erzeugst es jetzt und setzt es beim Kopieren ein:

#cmd("Mac")[```bash
RKE2_TOKEN=$(openssl rand -hex 32)
sed "s/TOKEN-HIER-EINSETZEN/$RKE2_TOKEN/" labor/rke2/config-cp.yaml \
  | ssh <user>@172.16.0.160 'umask 077; cat > ~/rke2-config.yaml'
sed "s/TOKEN-HIER-EINSETZEN/$RKE2_TOKEN/" labor/rke2/config-w1.yaml \
  | ssh <user>@172.16.0.161 'umask 077; cat > ~/rke2-config.yaml'
```][Erzeugt ein zufälliges Token und legt jedem Knoten seine Konfiguration ins Home-Verzeichnis, nur für deinen Benutzer lesbar. Ersetze `<user>` durch deinen SSH-Benutzer. Das Token brauchst du später nicht mehr. Der Server legt es zusätzlich unter `/var/lib/rancher/rke2/server/node-token` ab.]

== RKE2: der Server

#cmd("Mac")[```bash
ssh <user>@172.16.0.160
```][Öffnet die Sitzung auf dem Server. Alle Schritte mit dem Etikett *rke2-cp* laufen hier.]

#cmd("rke2-cp")[```bash
sudo hostnamectl set-hostname rke2-cp
sudo install -D -m 600 -o root -g root \
  ~/rke2-config.yaml /etc/rancher/rke2/config.yaml
rm ~/rke2-config.yaml
```][Setzt den Hostnamen passend zum `node-name` und legt die Konfiguration an ihren Platz. Sie muss dort liegen, *bevor* RKE2 zum ersten Mal startet. `-D` legt das Verzeichnis an.]

#cmd("rke2-cp")[```bash
curl -sfL https://get.rke2.io | \
  sudo INSTALL_RKE2_VERSION=v1.36.6+rke2r1 sh -
sudo systemctl enable --now rke2-server.service
```][Das Skript installiert genau die Version dieses Buchs. Ohne `INSTALL_RKE2_VERSION` bekämst du die neueste Version aus dem Kanal `stable`. Der erste Start dauert einige Minuten, weil RKE2 die Images der Control Plane lädt.]

#cmd("rke2-cp")[```bash
sudo journalctl -u rke2-server -f
```][Verfolgt das Log des Dienstes. Beenden mit `Ctrl-C`. Fehler in der `config.yaml` stehen hier ganz am Anfang.]

Für die Arbeit direkt auf dem Knoten brauchst du in späteren Kapiteln immer dieselbe Umgebung. RKE2 legt `kubectl`, `crictl` und `ctr` in ein eigenes Verzeichnis und schreibt seine Kubeconfig an einen eigenen Ort:

#cmd("rke2-cp")[```bash
sudo -i
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
kubectl get pods -n kube-system
```][Wechselt zu root und setzt die drei Variablen. Ohne `CRI_CONFIG_FILE` findet `crictl` den Socket von containerd nicht. Wenn spätere Kapitel auf einem RKE2-Knoten arbeiten, setzen sie genau diese vier Zeilen voraus.]

#pruefe[
  In `kube-system` laufen `etcd-rke2-cp`, `kube-apiserver-rke2-cp` und die anderen Static Pods der Control Plane, dazu `rke2-canal`, `rke2-coredns`, `rke2-metrics-server` und `rke2-traefik`. Mehrere `helm-install-rke2-…`-Pods stehen auf `Completed`. Das ist richtig: Sie haben die mitgelieferten Charts installiert und sind fertig.
]

Die Admin-Kubeconfig gehört root. Für den Mac legst du eine Kopie an, die dein Benutzer holen darf:

#cmd("rke2-cp")[```bash
install -m 600 -o <user> /etc/rancher/rke2/rke2.yaml /tmp/rke2.yaml
exit
exit
```][Läuft noch als root aus der `sudo -i`-Sitzung. Das erste `exit` beendet die root-Shell, das zweite die SSH-Sitzung.]

== RKE2: der Agent

#cmd("Mac")[```bash
ssh <user>@172.16.0.161
```][Öffnet die Sitzung auf dem Agent.]

#cmd("rke2-w1")[```bash
sudo hostnamectl set-hostname rke2-w1
sudo install -D -m 600 -o root -g root \
  ~/rke2-config.yaml /etc/rancher/rke2/config.yaml
rm ~/rke2-config.yaml
curl -sfL https://get.rke2.io | \
  sudo INSTALL_RKE2_VERSION=v1.36.6+rke2r1 INSTALL_RKE2_TYPE=agent sh -
sudo systemctl enable --now rke2-agent.service
```][Wie beim Server, aber mit `INSTALL_RKE2_TYPE=agent`. Der Dienst heißt jetzt `rke2-agent`, sein Log liest du mit `sudo journalctl -u rke2-agent -f`.]

#falle[
  Bleibt der Agent hängen und das Log meldet wiederholt Verbindungsfehler zu `172.16.0.160:9345`, blockiert meist eine Firewall. Ubuntu Server hat `ufw` standardmäßig inaktiv, `sudo ufw status` zeigt es. Ist sie aktiv, braucht RKE2 mindestens TCP 6443 und 9345 zum Server, TCP 10250 zwischen allen Knoten und für Canal UDP 8472 (VXLAN) und TCP 9099. Lass Port 22 offen, sonst sperrst du dich aus.
]

== Die Kubeconfig von RKE2

Die Datei vom Server zeigt auf `127.0.0.1` und nennt Cluster, Benutzer und Kontext `default`. Beides änderst du, bevor sie in deine `~/.kube/config` wandert.

#cmd("Mac")[```bash
mkdir -p ~/.kube
[ -f ~/.kube/config ] && cp -p ~/.kube/config ~/.kube/config.bak
scp <user>@172.16.0.160:/tmp/rke2.yaml ~/.kube/rke2.raw
ssh <user>@172.16.0.160 'rm /tmp/rke2.yaml'
```][Sichert eine vorhandene Kubeconfig, holt die Datei vom Server und löscht die Kopie dort. Sie enthält volle Admin-Rechte.]

#cmd("Mac")[```bash
sed -e 's/127\.0\.0\.1/172.16.0.160/' -e 's/: default$/: rke2/' \
  ~/.kube/rke2.raw > ~/.kube/rke2.yaml
KUBECONFIG=~/.kube/config:~/.kube/rke2.yaml \
  kubectl config view --flatten > ~/.kube/config.neu
chmod 600 ~/.kube/config.neu
mv ~/.kube/config.neu ~/.kube/config
rm ~/.kube/rke2.raw ~/.kube/rke2.yaml
```][`sed` setzt die IP ein und benennt alles in `rke2` um. Mehrere Dateien in `KUBECONFIG` führt `kubectl` zusammen, `--flatten` schreibt die Zertifikate direkt in die Ausgabe. Gibt es schon einen Kontext `rke2`, entferne ihn vorher mit `kubectl config delete-context rke2`, sonst gewinnt der alte Eintrag.]

#cmd("Mac")[```bash
kubectl --context rke2 get nodes
```][Erster Zugriff vom Mac.]

#pruefe[
  Zwei Knoten, `rke2-cp` und `rke2-w1`, beide `Ready`, Version `v1.36.6+rke2r1`. Fehlt `rke2-w1`, prüfe das Log des Agents.
]

== Talos: booten

Talos installierst du nicht per Paket, sondern bootest es von einem ISO. Hol dir das ISO aus der Image Factory unter `factory.talos.dev`: Version v1.14.5, Plattform Bare Metal, Architektur amd64. Erweiterungen brauchst du für das Labor keine. Läuft dein Hypervisor mit einem Gast-Agenten, etwa Proxmox mit `qemu-guest-agent`, kannst du die passende Erweiterung hinzufügen.

Boote beide Talos-VMs von diesem ISO. Auf der Konsole erscheint das Talos-Dashboard mit der IP-Adresse. Der Knoten ist jetzt im *Maintenance-Modus*: Er läuft im RAM, hat noch keine Konfiguration und wartet auf eine. Die Maintenance-API nimmt in diesem Zustand Konfigurationen ohne Anmeldung an. Das ist so gewollt, deshalb gehört das Labor in ein Netz, das nur du erreichst.

#cmd("Mac")[```bash
talosctl get disks --insecure --nodes 172.16.0.170
talosctl get disks --insecure --nodes 172.16.0.171
```][Listet die Platten der Knoten. `--insecure` spricht die Maintenance-API an. Merk dir den Namen der Systemplatte, etwa `sda` oder `vda`.]

Entferne danach das ISO aus den virtuellen Laufwerken. Der Knoten läuft weiter, weil Talos komplett im RAM ist. So kann Talos nach der Installation nicht versehentlich wieder vom ISO starten.

== Talos: die Patches

Eine Talos-Konfiguration ist ein langes YAML-Dokument, das `talosctl gen config` erzeugt. Du änderst es nicht von Hand, sondern beschreibst deine Abweichungen in kleinen Patches. Drei liegen im Repo:

#datei("labor/talos/patch-cp.yaml", ```yaml
machine:
  install:
    disk: /dev/sda
cluster:
  allowSchedulingOnControlPlanes: true
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: talos-cp
auto: off
```, erklaerung: [
  `machine.install.disk` ist die Platte, auf die Talos sich installiert. Hieß sie bei `get disks` anders, passe sie hier und in `patch-w1.yaml` an. `allowSchedulingOnControlPlanes` entfernt den Taint, mit dem Talos normale Pods von der Control Plane fernhält. Das zweite Dokument setzt den Hostnamen. `auto: off` schaltet den automatisch erzeugten Namen wie `talos-2ld-dvw` ab.
])

#datei("labor/talos/patch-w1.yaml", ```yaml
machine:
  install:
    disk: /dev/sda
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: talos-w1
auto: off
```)

#datei("labor/talos/patch-local-path.yaml", ```yaml
apiVersion: v1alpha1
kind: UserVolumeConfig
name: local-path-provisioner
volumeType: directory
```, erklaerung: [
  Ein *User Volume* vom Typ `directory` legt das Verzeichnis `/var/mnt/local-path-provisioner` auf der Partition `EPHEMERAL` an und reicht es in den Container des kubelet durch. Dort legt der local-path-provisioner später die Volumes ab. Ein eigenes Verzeichnis ist nötig, weil das Standardverzeichnis `/opt/local-path-provisioner` auf Talos schreibgeschützt ist und das kubelet nicht jeden Pfad unter `/var` sieht.
])

== Talos: Konfiguration erzeugen

#cmd("Mac")[```bash
talosctl gen secrets -o labor/talos/secrets.yaml
```][Erzeugt die Zertifizierungsstellen und Schlüssel des Clusters. Mit dieser Datei kannst du die Konfiguration jederzeit neu erzeugen, ohne dass sich die Zertifikate ändern. Sie steht wie alle erzeugten Dateien in `.gitignore`.]

#cmd("Mac")[```bash
talosctl gen config talos https://172.16.0.170:6443 \
  --with-secrets labor/talos/secrets.yaml \
  --kubernetes-version 1.36.6 \
  --config-patch @labor/talos/patch-local-path.yaml \
  --config-patch-control-plane @labor/talos/patch-cp.yaml \
  --config-patch-worker @labor/talos/patch-w1.yaml \
  --output labor/talos/
```][`talos` ist der Name des Clusters, die URL der Endpunkt des API-Servers. `--config-patch` gilt für alle Knoten, die beiden anderen nur für Control Plane bzw. Worker. Ohne `--kubernetes-version` nimmt `talosctl` seine eigene Vorgabe, und die passt nicht unbedingt zum RKE2-Cluster.]

#cmd("Mac")[```bash
talosctl validate --config labor/talos/controlplane.yaml --mode metal
talosctl validate --config labor/talos/worker.yaml --mode metal
```][Prüft beide Dateien, bevor sie auf einen Knoten gehen.]

#pruefe[
  Im Verzeichnis `labor/talos/` liegen jetzt `controlplane.yaml`, `worker.yaml` und `talosconfig`. `validate` meldet für beide Dateien `is valid for metal mode`.
]

== Talos: anwenden und bootstrappen

#cmd("Mac")[```bash
talosctl apply-config --insecure --nodes 172.16.0.170 \
  --file labor/talos/controlplane.yaml
talosctl apply-config --insecure --nodes 172.16.0.171 \
  --file labor/talos/worker.yaml
```][Schickt jedem Knoten seine Konfiguration. Talos installiert sich auf die Platte und startet neu. Ab jetzt ist der Knoten nur noch mit den Zertifikaten aus `talosconfig` erreichbar, `--insecure` funktioniert nicht mehr.]

#cmd("Mac")[```bash
export TALOSCONFIG=$PWD/labor/talos/talosconfig
talosctl config endpoint 172.16.0.170
echo "export TALOSCONFIG=$PWD/labor/talos/talosconfig" >> ~/.zshrc
```][`TALOSCONFIG` sagt `talosctl`, wo Zertifikate und Kontext liegen. Der Endpunkt ist der Knoten, über den `talosctl` alle Anfragen schickt. Die letzte Zeile trägt die Variable dauerhaft in deine Shell ein. Alle späteren Kapitel setzen sie voraus.]

#cmd("Mac")[```bash
talosctl --nodes 172.16.0.170 bootstrap
```][Startet etcd auf der Control Plane. Der Befehl läuft genau *einmal* und nur auf einem Knoten. Wartet der Knoten noch auf den Neustart, wiederhole ihn nach einer Minute.]

#cmd("Mac")[```bash
talosctl --nodes 172.16.0.170 health
```][Prüft etcd, kubelet, die Control Plane und ob alle Knoten im Cluster angekommen sind. Der Befehl wartet bis zu 20 Minuten und meldet jeden Schritt.]

#falle[
  Wer `bootstrap` ein zweites Mal auf einem anderen Control-Plane-Knoten ausführt, erzeugt einen zweiten, unabhängigen etcd-Cluster. Im Labor gibt es nur einen Control-Plane-Knoten, die Gefahr ist also gering. In echten Clustern mit drei Knoten ist das ein häufiger Fehler.
]

#cmd("Mac")[```bash
talosctl --nodes 172.16.0.170 kubeconfig --force-context-name talos
kubectl --context talos get nodes
```][Lädt die Admin-Kubeconfig und fügt sie in `~/.kube/config` ein. Ohne `--force-context-name` hieße der Kontext `admin@talos`.]

#pruefe[
  Zwei Knoten, `talos-cp` und `talos-w1`, beide `Ready`, Version `v1.36.6`. `kubectl config get-contexts` zeigt `rke2` und `talos` nebeneinander.
]

#distro([
  Du verwaltest den Knoten wie jedes Linux. Konfiguration ist eine Datei unter `/etc/rancher/rke2/`, Änderungen wirken nach `systemctl restart rke2-server`. Logs liest du mit `journalctl`.
], [
  Der Knoten hat keine Shell. Die gesamte Konfiguration ist die Machine-Config, die du mit `talosctl patch machineconfig` änderst. Logs liest du mit `talosctl logs kubelet` oder `talosctl dmesg`, immer mit `--nodes`.
])

== Storage: local-path-provisioner

Beide Cluster haben noch keine StorageClass. Ein PVC bliebe für immer `Pending`. Der local-path-provisioner von Rancher legt für jedes PVC ein Verzeichnis auf dem Knoten an, auf dem der Pod läuft. Für ein Labor ist das genau richtig: kein Netzwerkspeicher, keine Zusatzplatten.

Die StorageClass heißt auf beiden Clustern `local-path`. Sie wird bewusst *nicht* zur Default-StorageClass. Ein PVC muss sie ausdrücklich mit `storageClassName: local-path` anfordern. Ein PVC ohne diese Angabe bleibt `Pending`, und genau diesen Fehler untersuchen die Kapitel 4 und 9.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f \
  https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
```][Installiert Version v0.0.37 im Namespace `local-path-storage`. Auf Ubuntu ist das Standardverzeichnis `/opt/local-path-provisioner` beschreibbar, eine Anpassung ist nicht nötig.]

Für Talos braucht es zwei Änderungen am selben Manifest. Eine Kustomization im Repo setzt sie:

#datei("werkzeuge/local-path-talos/kustomization.yaml (Ausschnitt)", ```yaml
resources:
  - https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
patches:
  - patch: |-
      kind: ConfigMap
      # ... local-path-config: "paths": ["/var/mnt/local-path-provisioner"]
  - patch: |-
      apiVersion: v1
      kind: Namespace
      metadata:
        name: local-path-storage
        labels:
          pod-security.kubernetes.io/enforce: privileged
```, erklaerung: [
  Der erste Patch lenkt die Volumes in das User Volume aus `patch-local-path.yaml`. Der zweite erlaubt im Namespace privilegierte Pods. Der Provisioner startet für jedes Volume einen kurzlebigen Helper-Pod mit `hostPath`, und den würde Pod Security `baseline` auf Talos ablehnen.
])

#cmd("Mac")[```bash
kubectl --context talos apply -k werkzeuge/local-path-talos/
```][`-k` baut die Kustomization und wendet das Ergebnis an. Das Manifest lädt `kubectl` dabei direkt von GitHub.]

#cmd("Mac")[```bash
kubectl --context rke2 get storageclass
kubectl --context talos get storageclass
```][Zeigt die StorageClasses beider Cluster.]

#pruefe[
  Auf jedem Cluster genau eine StorageClass:

  ```text
  NAME         PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
  local-path   rancher.io/local-path   Delete          WaitForFirstConsumer
  ```
  Die Ausgabe hat noch die Spalten `ALLOWVOLUMEEXPANSION` und `AGE`. Wichtig ist der Name: Dahinter steht *kein* `(default)`.
]

Ob wirklich ein Volume entsteht, zeigt ein kleiner Test: ein PVC und ein Pod, der eine Datei hineinschreibt.

#cmd("Mac")[```bash
for c in rke2 talos; do
  kubectl --context $c apply -f labor/pvc-test.yaml
  kubectl --context $c wait pod/schreiber -n dbg-02 \
    --for=condition=Ready --timeout=120s
  kubectl --context $c get pvc,pod -n dbg-02 -o wide
done
```][Legt Namespace `dbg-02`, PVC `daten` und Pod `schreiber` auf beiden Clustern an und wartet, bis der Pod läuft. Wegen `WaitForFirstConsumer` entsteht das Volume erst, wenn der Pod einem Knoten zugeteilt ist.]

#pruefe[
  Das PVC steht auf `Bound`, der Pod auf `Running`, und `logs -n dbg-02 schreiber` zeigt Datum und Uhrzeit. Auf Talos siehst du das Volume auch auf dem Knoten. Nimm die IP des Knotens aus der Spalte `NODE`:

  ```text
  talosctl --nodes 172.16.0.171 ls /var/mnt/local-path-provisioner
  ```
]

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-02
kubectl --context talos delete ns dbg-02
```][Räumt auf. Wegen `reclaimPolicy: Delete` löscht der Provisioner auch die Verzeichnisse auf den Knoten.]

== k9s einrichten

k9s hast du schon installiert. Es fehlen die Plugins dieses Buchs. k9s sucht sie in seinem Konfigurationsverzeichnis, und das liegt auf macOS nicht unter `~/.config`:

#cmd("Mac")[```bash
k9s info
```][Zeigt, wo k9s Konfiguration, Plugins, Skins und Logs erwartet.]

#pruefe[
  Die Zeile `Plugins` nennt `~/Library/Application Support/k9s/plugins.yaml`, ausgeschrieben mit deinem Home-Verzeichnis. Unter Linux steht dort `~/.config/k9s/plugins.yaml`.
]

#cmd("Mac")[```bash
mkdir -p "$HOME/Library/Application Support/k9s"
cp k9s/plugins.yaml "$HOME/Library/Application Support/k9s/plugins.yaml"
```][Kopiert die Plugins an ihren Platz. Hast du dort schon eine `plugins.yaml`, führe beide Dateien von Hand zusammen, statt sie zu überschreiben. Was die Plugins tun, zeigt Kapitel 3.]

== Abschluss: beide Cluster im Überblick

#cmd("Mac")[```bash
kubectl --context rke2 get nodes -o wide
kubectl --context talos get nodes -o wide
```][Der Abschluss des Kapitels. Diese beiden Befehle stehen auch am Anfang jeder Fehlersuche, wenn du nicht weißt, in welchem Zustand das Labor gerade ist.]

#pruefe[
  Vier Knoten, alle `Ready`. Bei RKE2 zeigt `VERSION` `v1.36.6+rke2r1` und `OS-IMAGE` Ubuntu 24.04, bei Talos `v1.36.6` und `Talos (v1.14.5)`. Die `INTERNAL-IP` stimmt mit der Tabelle am Anfang des Kapitels überein. Jetzt ist der richtige Moment für die Snapshots.
]

#aufgabe[
  Vergleiche, was in `kube-system` der beiden Cluster läuft: `kubectl --context rke2 get pods -n kube-system` und dasselbe für `talos`. Welcher Pod ist auf welchem Cluster für DNS zuständig, und wie heißt er? Welcher für das Pod-Netz? Hinweis: Auf RKE2 tragen die mitgelieferten Komponenten das Präfix `rke2-`, auf Talos heißen sie schlicht `coredns` und `kube-flannel`. Kapitel 7 braucht genau diese Namen.
]

#gelernt(
  [RKE2 liest `/etc/rancher/rke2/config.yaml`. Server und Agent teilen sich ein Token, der Agent meldet sich über Port 9345 an.],
  [Talos wird über eine Machine-Config gesteuert, die `talosctl gen config` aus Secrets und kleinen Patches erzeugt. `bootstrap` läuft genau einmal.],
  [Die Kontexte heißen `rke2` und `talos`, `TALOSCONFIG` zeigt auf `labor/talos/talosconfig`.],
  [Beide Cluster haben die StorageClass `local-path`, aber keine Default-StorageClass. Auf Talos liegen die Volumes unter `/var/mnt/local-path-provisioner`, und der Namespace des Provisioners braucht Pod Security `privileged`.],
  [k9s erwartet seine Plugins auf macOS unter `~/Library/Application Support/k9s/`. `k9s info` zeigt den genauen Pfad.],
)
