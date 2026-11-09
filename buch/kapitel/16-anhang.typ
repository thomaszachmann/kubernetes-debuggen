#import "../lib.typ": *

#kapitel(
  [Anhang],
  ziel: [Fehlermeldungen, Befehle und Tasten zum schnellen Nachschlagen, wenn es brennt.],
)

#show table: set par(justify: false)

== Spickzettel: Von der Meldung zum ersten Befehl

Die linke Spalte ist das, was du siehst. Die mittlere nennt die häufigste Ursache, nicht die einzige. Die rechte sagt dir, wo du zuerst hinschaust.

#tabelle(
  (1.15fr, 1fr, 0.8fr, auto),
  ([Meldung oder Status], [Häufigste Ursache], [Erster Blick], [Kap.]),
  [`Pending`, `Insufficient cpu`], [Requests größer als der freie Platz auf jedem Knoten], [`describe pod`, Events], [4],
  [`didn't match Pod's node affinity/selector`], [Label fehlt auf dem Knoten oder Tippfehler im Selektor], [`get nodes --show-labels`], [4],
  [`had untolerated taint(s)`], [Taint ohne passende Toleration], [`describe node`, `Taints:`], [4],
  [`unbound immediate PersistentVolumeClaims`], [PVC ohne StorageClass oder mit falschem Namen], [`describe pvc`], [4, 9],
  [Deployment ohne Pods, `FailedCreate`], [ResourceQuota, LimitRange oder Pod Security lehnt ab], [Events am ReplicaSet], [4, 10],
  [`ImagePullBackOff`, `not found`], [Tippfehler im Tag oder Repository], [`describe pod`, Events], [5],
  [`ImagePullBackOff`, `pull access denied`], [Privates Repository ohne `imagePullSecrets`], [Secret im selben Namespace], [5],
  [`toomanyrequests`], [Rate-Limit von Docker Hub], [Registry-Mirror auf dem Knoten], [5],
  [`CreateContainerConfigError`], [Secret, ConfigMap oder Key fehlt], [`describe pod`], [5],
  [`exec format error`], [Skript ohne Shebang oder falsche Architektur], [Image und Entrypoint prüfen], [5],
  [`CrashLoopBackOff`, Exit 127], [Befehl im Container nicht gefunden], [`logs --previous`], [6],
  [`CrashLoopBackOff`, Exit 1], [Anwendung beendet sich mit Fehler], [`logs --previous`], [6],
  [`OOMKilled`, Exit 137], [Speicherlimit zu klein oder Speicherleck], [`lastState`, Limits], [6],
  [Neustarts, `failed liveness probe`], [Probe zu streng, Start dauert länger], [Events, `startupProbe`], [6],
  [`Running`, aber `0/1` ready], [Readiness-Probe schlägt fehl], [Events, EndpointSlice], [6, 7],
  [`Read-only file system`], [`readOnlyRootFilesystem` ohne beschreibbares Volume], [`securityContext`], [6],
  [Service ohne Endpoints], [Selektor passt nicht zu den Pod-Labels], [`get endpointslices`], [7],
  [`connection refused`], [Falscher `targetPort` oder Prozess lauscht woanders], [`kubectl debug`, `ss -ltn`], [7],
  [`NXDOMAIN`, DNS-Timeout], [Falscher Name, Namespace oder Egress auf Port 53 blockiert], [`nslookup` aus einem Pod], [7],
  [NetworkPolicy wirkt nicht], [CNI setzt keine Policies durch (Flannel auf Talos)], [CNI prüfen], [7],
  [HTTP 404 vom Ingress], [Falsche `ingressClassName`, falscher Host oder Service-Port], [Controller-Logs], [8],
  [HTTP 503 vom Ingress], [Kein bereiter Pod hinter dem Service], [Endpoints, Readiness], [8],
  [`TRAEFIK DEFAULT CERT`], [TLS-Secret falsch aufgebaut oder nicht gefunden], [`describe secret`, Traefik-Log], [8],
  [`Permission denied` auf Volume], [Prozess-UID darf nicht schreiben], [`ls -ln` im Pod], [9],
  [`Multi-Attach`, Pod auf anderem Knoten hängt], [RWO-Volume, Replikas auf mehreren Knoten], [`get pods -o wide`], [9],
  [`Forbidden`, `cannot list resource`], [RBAC: Binding fehlt, falscher Namespace oder Role statt ClusterRole], [`auth can-i --as`], [10],
  [`violates PodSecurity`], [Pod Security Admission des Namespace], [Namespace-Labels], [10],
  [`admission webhook ... denied the request`], [Kyverno-Policy greift], [Policy-Name aus der Meldung], [11],
  [`failed calling webhook`], [Webhook-Backend nicht erreichbar, `failurePolicy: Fail`], [`get validatingwebhookconfigurations`], [11, 14],
  [Falco-Alarm], [Ein Prozess tut etwas, das eine Regel als verdächtig einstuft], [Alarm-Felder, Pod, Container-ID], [12],
  [Knoten `NotReady`], [Kubelet läuft nicht oder erreicht den API-Server nicht], [Kubelet-Log auf dem Knoten], [13],
  [Pod `Terminating`, `Unknown`], [Knoten ausgefallen, Eviction nach 300 s], [`get nodes`, Tolerations], [13],
  [`Evicted`], [Knoten oder Pod hat ein Limit für Speicher oder Platz überschritten], [`status.message`], [13],
  [Drain hängt], [PodDisruptionBudget erlaubt keine Unterbrechung], [`get pdb`], [13],
  [`x509: certificate has expired`], [Client-Zertifikat in der kubeconfig abgelaufen], [Zertifikat dekodieren], [14],
  [Namespace bleibt `Terminating`], [Nicht erreichbarer APIService oder Finalizer], [`get apiservice`, Conditions], [14],
  [`ProgressDeadlineExceeded`], [Neue Pods werden nie ready], [`rollout status`, neue Pods], [15],
  [HPA zeigt `<unknown>`], [metrics-server fehlt oder Pods ohne CPU-Requests], [`top pods`, `describe hpa`], [15],
  [`another operation ... is in progress`], [Abgebrochenes Helm-Release im Zustand `pending-*`], [`helm history`], [15],
  [`BackoffLimitExceeded`], [Job-Pods scheitern öfter als erlaubt], [Logs der Job-Pods], [15],
)

== RKE2 und Talos: dieselbe Frage, zwei Befehle

Auf RKE2 laufen die Befehle auf dem Knoten, nach `sudo -i` und den Exporten aus Kapitel 2. Auf Talos laufen sie auf dem Mac, mit `-n` und der IP des Knotens.

#tabelle(
  (0.8fr, 1fr, 1fr),
  ([Frage], [RKE2 (auf dem Knoten)], [Talos (auf dem Mac)]),
  [Läuft der Knoten-Dienst?], [`systemctl status rke2-server` bzw. `rke2-agent`], [`talosctl -n <IP> services`],
  [Log des Knoten-Dienstes], [`journalctl -u rke2-server`], [`talosctl -n <IP> logs kubelet`],
  [Kubelet-Log], [`/var/lib/rancher/rke2/agent/logs/kubelet.log`], [`talosctl -n <IP> logs kubelet`],
  [Kernel-Meldungen, OOM-Killer], [`journalctl -k`], [`talosctl -n <IP> dmesg`],
  [Container des Knotens], [`crictl ps -a`], [`talosctl -n <IP> containers --namespace cri`],
  [Log eines Containers], [`crictl logs <id>`], [`talosctl -n <IP> logs --namespace cri <id>`],
  [Image prüfen oder holen], [`crictl images`, `crictl pull`], [`talosctl -n <IP> image list`, `image pull`],
  [Überblick in Echtzeit], [`top`, `df -h`], [`talosctl -n <IP> dashboard`],
  [Konfiguration], [`/etc/rancher/rke2/config.yaml`], [`talosctl -n <IP> get machineconfig -o yaml`],
  [Konfiguration ändern], [Datei bearbeiten, Dienst neu starten], [`talosctl -n <IP> patch mc --patch @datei`],
  [Registry-Mirror], [`/etc/rancher/rke2/registries.yaml`], [Dokument `RegistryMirrorConfig`],
  [etcd-Zustand], [`etcdctl` im etcd-Pod], [`talosctl -n <IP> etcd status`, `etcd members`],
  [etcd-Snapshot], [`rke2 etcd-snapshot save`], [`talosctl -n <IP> etcd snapshot <datei>`],
  [Zertifikate prüfen], [`rke2 certificate check`], [`talosctl config info`, `get kubernetesdynamiccerts`],
  [Alles einsammeln], [Logs und `crictl`-Ausgaben von Hand], [`talosctl -n <IP> support --no-encryption`],
)

== k9s: die wichtigsten Tasten

#tabelle(
  (auto, 1fr),
  ([Taste], [Wirkung]),
  [`:pods`, `:deploy`, `:events`], [Ressourcenansicht wechseln, mit Namespace dahinter: `:pods dbg-04`],
  [`:ctx`], [Kontext wechseln],
  [`0`], [Alle Namespaces anzeigen],
  [`/text`, `/!text`, `/-l app=web`], [Filtern, invertiert filtern, nach Label filtern],
  [`d`, `y`, `e`], [Describe, YAML, Bearbeiten],
  [`l`, `p`], [Logs, Logs des vorherigen Laufs],
  [`s`], [Shell im Container],
  [`Enter`], [Container-Ansicht eines Pods öffnen],
  [`o`, `Shift-j`], [Zum Knoten springen, zum Besitzer springen],
  [`Shift-f`], [Port-Forward einrichten],
  [`Ctrl-w`], [Weitere Spalten einblenden],
  [`Ctrl-d`, `Ctrl-k`], [Löschen mit Bestätigung, sofort löschen],
  [`:xray deploy`, `:pulses`], [Abhängigkeitsbaum, Überblick über den Cluster],
  [`Shift-D`], [Plugin aus Kapitel 3: netshoot-Debug-Container am Pod],
  [`Shift-E`], [Plugin aus Kapitel 3: Events der markierten Ressource],
  [`Esc`, `?`], [Zurück, Hilfe mit allen Tasten der aktuellen Ansicht],
)

Starte k9s mit `--readonly`, wenn du nur suchst und nichts ändern willst.

== Versionen

Alle Angaben gelten für den Stand dieses Buches, 9. November 2026.

#tabelle(
  (1fr, auto),
  ([Komponente], [Version]),
  [RKE2], [`v1.36.6+rke2r1`],
  [Talos Linux und `talosctl`], [`v1.14.5`],
  [Kubernetes auf beiden Clustern], [`1.36.6`],
  [k9s], [`v0.51.0`],
  [Kyverno (Chart `kyverno/kyverno`)], [`v1.19.2` (Chart `3.9.2`)],
  [Falco (Chart `falcosecurity/falco`)], [`0.45.2` (Chart `9.2.2`)],
  [Traefik für Talos (Chart `traefik/traefik`)], [`v3.7.17` (Chart `42.3.1`)],
  [metrics-server für Talos (Chart `metrics-server/metrics-server`)], [Chart `3.14.0`],
  [local-path-provisioner], [`v0.0.37`],
  [netshoot], [`nicolaka/netshoot:v0.15`],
)

== Das Repo im Überblick

```
kubernetes-debuggen/
├── buch/            Quelle dieses Buches (Typst), book-en/ die englische Ausgabe
├── labor/
│   ├── rke2/        config-cp.yaml, config-w1.yaml, registries-mirror.yaml
│   └── talos/       patch-cp.yaml, patch-w1.yaml, patch-local-path.yaml,
│                    patch-registry.yaml und die Patches aus Kapitel 13 und 14
├── k9s/             plugins.yaml                                  (Kap. 2, 3)
├── werkzeuge/       Helm-Werte für Kyverno, Falco, Traefik, metrics-server,
│                    local-path für Talos
├── policies/        Kyverno-Policies mit Tests unter tests/       (Kap. 11)
└── szenarien/       ein Ordner pro Kapitel, darin kaputt-*.yaml und fix-*.yaml
```

Jede Datei `kaputt-*.yaml` legt ihren Namespace `dbg-<kapitel>` selbst an. Das Aufräumen ist deshalb immer dasselbe: `kubectl --context <cluster> delete namespace dbg-<kapitel>`.

== Offizielle Dokumentation

- Kubernetes, Debugging: #link("https://kubernetes.io/docs/tasks/debug/")[kubernetes.io/docs/tasks/debug]
- RKE2: #link("https://docs.rke2.io")[docs.rke2.io]
- Talos Linux 1.14: #link("https://docs.siderolabs.com/talos/v1.14")[docs.siderolabs.com/talos/v1.14]
- k9s: #link("https://k9scli.io")[k9scli.io]
- Kyverno: #link("https://kyverno.io/docs")[kyverno.io/docs]
- Falco: #link("https://falco.org/docs")[falco.org/docs]
- Traefik: #link("https://doc.traefik.io/traefik")[doc.traefik.io/traefik]

#gelernt(
  [Fehlersuche ist eine Methode, kein Talent: Symptom, Schicht, Ursache, Fix, Prüfung.],
  [Die meisten Antworten stehen in Events, im `describe` und in den Logs des vorherigen Laufs.],
  [Auf RKE2 gehst du per SSH auf den Knoten, auf Talos fragst du die API mit `talosctl`.],
  [Policies, Admission und Laufzeit-Sicherheit sind eigene Fehlerquellen. Lies die Meldung bis zum Ende, sie nennt fast immer den Schuldigen.],
)
