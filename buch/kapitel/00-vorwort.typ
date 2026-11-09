#import "../lib.typ": *
#set heading(numbering: none)

#heading(level: 1, numbering: none, outlined: false)[Inhalt]

#{
  show outline.entry.where(level: 1): it => {
    v(0.55em, weak: true)
    strong(it)
  }
  outline(title: none, depth: 2, indent: 1.2em)
}

#pagebreak(to: "odd")
#heading(level: 1, numbering: none)[So benutzt du dieses Buch]

Ein Kubernetes-Cluster gibt selten zu, was ihm fehlt. Er zeigt dir `Pending`, `CrashLoopBackOff` oder ein knappes `Forbidden` und überlässt dir den Rest. Wer schon einmal eine Stunde auf einen Pod gestarrt hat, der einfach nicht startet, kennt das Gefühl. Meist lag die Antwort die ganze Zeit in einem Event, das niemand gelesen hat.

Dieses Buch macht aus der Fehlersuche eine Routine. Du baust dir zwei kleine Cluster und machst sie absichtlich kaputt, immer wieder und auf viele Arten. Zu jedem Fehler siehst du, wie er sich zeigt, wie du ihn mit `kubectl` und k9s untersuchst, was die eigentliche Ursache ist und wie du ihn behebst. Nach einigen Kapiteln wirst du merken, dass sich die Fragen wiederholen. Genau das ist das Ziel.

== Warum zwei Distributionen

Kubernetes ist überall gleich, die Plattform darunter nicht. Die Fehlersuche endet oft nicht beim Pod, sondern auf dem Knoten: beim Kubelet, bei containerd, beim etcd oder bei einer Einstellung, die die Distribution mitbringt. Deshalb arbeitest du mit zwei sehr unterschiedlichen Vertretern:

#tabelle(
  (auto, 1fr, 1fr),
  ([], [RKE2], [Talos Linux]),
  [Betriebssystem], [Ubuntu 24.04, RKE2 als systemd-Dienst], [Talos, unveränderliches Linux nur für Kubernetes],
  [Zugang zum Knoten], [SSH, `journalctl`, `crictl`], [keine Shell, nur die API mit `talosctl`],
  [Konfiguration], [`/etc/rancher/rke2/config.yaml`], [Machine-Config, per `talosctl` angewendet],
  [Netzwerk], [Canal, setzt NetworkPolicies durch], [Flannel, ignoriert NetworkPolicies],
  [Mitgeliefert], [Traefik, metrics-server, CoreDNS], [CoreDNS, sonst bewusst wenig],
)

RKE2 fühlt sich an wie ein klassischer Linux-Server. Bei Talos funktionieren viele gewohnte Handgriffe nicht, weil es keine Shell gibt. Wo sich die Fehlersuche unterscheidet, zeigt ein Kasten beide Wege nebeneinander:

#distro(
  [Hier steht, wie du auf RKE2 vorgehst, meist per SSH auf dem Knoten.],
  [Hier steht der Weg über `talosctl`, ohne Shell auf dem Knoten.],
)

== Zuerst das Repo klonen

Alle Dateien, auf die sich das Buch bezieht, liegen in einem öffentlichen Repository: #link("https://github.com/thomaszachmann/kubernetes-debuggen")[github.com/thomaszachmann/kubernetes-debuggen]. Jedes Fehlerszenario hat dort einen eigenen Ordner unter `szenarien/` mit einer Datei, die den Fehler erzeugt, und einer, die ihn behebt.

#cmd("Mac")[```bash
git clone https://github.com/thomaszachmann/kubernetes-debuggen.git
cd kubernetes-debuggen
```][Lädt das Repo und wechselt ins Wurzelverzeichnis. Von hier aus laufen alle Befehle mit dem Etikett *Mac*. Pfade wie `szenarien/04-pending/` sind immer relativ zu diesem Ordner.]

== Wo du einen Befehl ausführst

Jeder Befehl trägt ein farbiges Etikett:

#tabelle(
  (auto, 1fr),
  ([Etikett], [Bedeutung]),
  [#etikett(akzent, "Mac")], [Dein Terminal auf dem Laptop, im Wurzelverzeichnis des Repos. Von hier aus steuerst du beide Cluster mit `kubectl --context rke2` oder `--context talos` und die Talos-Knoten mit `talosctl`.],
  [#etikett(probe, "k9s")], [Tastatureingaben in k9s. `⏎` steht für die Eingabetaste.],
  [#etikett(warn, "rke2-cp")], [Eine SSH-Sitzung auf dem RKE2-Server `rke2-cp` (`172.16.0.160`).],
  [#etikett(warn, "rke2-w1")], [Eine SSH-Sitzung auf dem RKE2-Agent `rke2-w1` (`172.16.0.161`).],
  [#etikett(lila, "Pod")], [Eine Shell in einem Container, geöffnet mit `kubectl exec` oder `kubectl debug`.],
)

Für Talos gibt es kein eigenes Etikett. Auf einen Talos-Knoten loggst du dich nie ein, `talosctl` läuft immer auf dem Mac.

#warum[
  Mit zwei Clustern ist der häufigste Fehler der falsche Kontext. Deshalb nennt jeder Befehl ausdrücklich `--context rke2` oder `--context talos`. Den aktiven Standardkontext von `kubectl` nutzt dieses Buch nie. Gewöhn dir das auch im Alltag an: Ein Fix im falschen Cluster ist schlimmer als gar kein Fix.
]

== Die Kästen

#symptom[Was du siehst, wenn der Fehler auftritt. So beginnt jede Fehlersuche.]
#ursache[Was wirklich dahintersteckt, und warum Kubernetes sich so verhält.]
#pruefe[Das erwartete Ergebnis. Weicht deine Ausgabe ab, geh nicht weiter, sondern kläre zuerst den Unterschied.]
#warum[Der Hintergrund, der dir beim nächsten, ähnlichen Problem hilft.]
#falle[Was typischerweise schiefgeht und woran du es erkennst.]
#aufgabe[Hier bist du dran. Überlege zuerst selbst, bevor du nachschlägst.]

== Wie ein Szenario abläuft

Ab Kapitel 4 folgt jedes Szenario demselben Muster. Du wendest eine Datei an, die einen Fehler enthält. Dann siehst du das Symptom, untersuchst es Schritt für Schritt und findest die Ursache. Erst danach behebst du den Fehler und prüfst das Ergebnis. Lies die Ursache nicht vorab. Der Lerneffekt entsteht beim Suchen, nicht beim Lesen der Lösung.

Jedes Szenario läuft in einem eigenen Namespace, etwa `dbg-04` für Kapitel 4. Was du dort kaputtmachst, bleibt dort. Am Ende eines Kapitels räumst du mit einem einzigen Befehl auf:

#cmd("Mac")[```bash
kubectl --context rke2 delete namespace dbg-04
kubectl --context talos delete namespace dbg-04
```][Löscht den Namespace samt allen Objekten darin, auf beiden Clustern.]

Die Kapitel bauen lose aufeinander auf. Kapitel 1 bis 3 solltest du der Reihe nach lesen. Danach kannst du springen, etwa direkt zu Kyverno in Kapitel 11, wenn dich das gerade beschäftigt.

== Was geprüft wurde und was nicht

Ein Buch voller Befehle ist nur so gut wie seine Prüfung. Deshalb steht hier ehrlich, wie weit sie ging.

*Geprüft am 9. November 2026:*
- Alle Versionen stammen aus den offiziellen Release-Seiten und Helm-Repositories: RKE2, Talos, k9s, Kyverno, Falco, Traefik, metrics-server und local-path-provisioner.
- Alle Kubernetes-Manifeste im Repo wurden mit `kubeconform` gegen Kubernetes 1.36 geprüft.
- Alle Kyverno-Policies bestehen `kyverno test` mit der Kyverno-CLI 1.19.1 gegen die Testressourcen im Repo.
- Alle Helm-Werte wurden mit `helm template` gegen die genannten Chart-Versionen gerendert, die Shell-Skripte bestehen `shellcheck`.
- Die Talos-Patches wurden in eine vollständige Konfiguration eingebaut und mit `talosctl validate` geprüft, allerdings mit `talosctl` 1.12. Befehle, die erst Talos 1.14 kennt, wurden in Dokumentation und Quellcode von 1.14.5 nachgeschlagen.
- Fehlermeldungen von Kubernetes, Kyverno, Traefik und Helm wurden im Quellcode der genannten Versionen nachgelesen. Befehle, Flags und Pfade von RKE2, k9s und `kubectl` stammen aus der offiziellen Dokumentation und den CLIs selbst.

*Nicht geprüft:*
- Das Buch wurde *nicht* auf echten Clustern durchgespielt. Alle Ausgaben in den Kästen und Codeblöcken sind Beispiele, die dem Format der echten Werkzeuge folgen. Namen von Pods, Zeitangaben und IDs werden bei dir anders aussehen.
- Fehlermeldungen können sich zwischen Versionen leicht im Wortlaut ändern. Der Kern, also das Schlüsselwort wie `Insufficient cpu` oder `violates PodSecurity`, bleibt in aller Regel gleich.

Rechne also damit, dass an einer Stelle etwas abweicht. Für dieses Buch ist das ein Geschenk: Es ist ein echter Fehler, und du hast gerade das Werkzeug in der Hand, ihn zu finden.

== Was du brauchst

- Vier VMs mit festen IP-Adressen im selben Netz:

#tabelle(
  (auto, auto, auto, 1fr),
  ([Rolle], [Hostname], [IP], [Größe]),
  [RKE2-Server], [`rke2-cp`], [`172.16.0.160`], [4 CPUs, 8 GB RAM, 60 GB Disk, Ubuntu 24.04],
  [RKE2-Agent], [`rke2-w1`], [`172.16.0.161`], [2 CPUs, 4 GB RAM, 40 GB Disk, Ubuntu 24.04],
  [Talos-Control-Plane], [`talos-cp`], [`172.16.0.170`], [4 CPUs, 8 GB RAM, 60 GB Disk, Talos-ISO],
  [Talos-Worker], [`talos-w1`], [`172.16.0.171`], [2 CPUs, 4 GB RAM, 40 GB Disk, Talos-ISO],
)

- Auf dem Laptop `kubectl`, `talosctl`, `helm`, `k9s`, `jq`, `curl`, `openssl` und `git`. Für Kapitel 11 zusätzlich die Kyverno-CLI.
- SSH-Zugang zu den beiden Ubuntu-VMs mit einem Benutzer, der `sudo` darf.
- Kubernetes-Grundwissen: Du weißt, was Pods, Deployments, Services und Namespaces sind. Alles Weitere erklärt das Buch.

#hinweis("Andere IP-Adressen?", akzent, akzent-hell)[
  Die vier Adressen stehen in den Konfigurationen unter `labor/` und in vielen Befehlen. Hast du andere, ersetze sie überall, bevor du mit Kapitel 2 beginnst. Ein `grep -rn "172.16.0.1[67]" .` zeigt dir jede Stelle.
]
