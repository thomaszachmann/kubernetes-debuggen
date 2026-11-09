# Kubernetes debuggen

Begleit-Repo zum Hands-on-Handbuch **Kubernetes debuggen** (englisch: *Debugging Kubernetes*) von Thomas Zachmann.

Zwei Labor-Cluster, einer mit **RKE2** und einer mit **Talos Linux**, werden gezielt kaputt gemacht. Zu jedem Fehler zeigt das Buch das Symptom, die Untersuchung mit `kubectl`, k9s, `crictl` und `talosctl`, die Ursache und den Fix. Behandelt werden unter anderem Pending-Pods, Image-Pulls, CrashLoopBackOff und OOMKilled, Services, DNS und NetworkPolicies, Ingress und TLS, Storage, RBAC und Pod Security, Fehler durch Kyverno und Falco, Knoten, etcd, Zertifikate, Webhooks, Rollouts, HPA und Helm.

Die PDFs gibt es kostenlos auf [nyrvex.com/hands-on](https://nyrvex.com/hands-on) und [nyrvex.de/hands-on](https://nyrvex.de/hands-on).

## Aufbau

| Ordner | Inhalt |
|---|---|
| `buch/` | Typst-Quelle der deutschen Ausgabe |
| `book-en/` | Typst-Quelle der englischen Ausgabe |
| `labor/` | Konfiguration für RKE2 (`rke2/`) und Talos-Patches (`talos/`) |
| `k9s/` | k9s-Plugins aus Kapitel 3 |
| `werkzeuge/` | Helm-Werte für Kyverno, Falco, Traefik, metrics-server und local-path |
| `policies/` | Kyverno-Policies mit Tests (`kyverno test policies/tests`) |
| `szenarien/` | Ein Ordner pro Kapitel: `kaputt-*.yaml` erzeugt den Fehler, `fix-*.yaml` behebt ihn |

Jede `kaputt-*.yaml` legt ihren Namespace `dbg-<kapitel>` selbst an. Aufräumen:

```bash
kubectl --context rke2 delete namespace dbg-04
kubectl --context talos delete namespace dbg-04
```

## Versionen (Stand 9. November 2026)

RKE2 `v1.36.6+rke2r1`, Talos `v1.14.5` mit Kubernetes `1.36.6`, k9s `v0.51.0`, Kyverno `v1.19.2` (Chart `3.9.2`), Falco `0.45.2` (Chart `9.2.2`), Traefik Chart `42.3.1`, metrics-server Chart `3.14.0`, local-path-provisioner `v0.0.37`.

## Was geprüft wurde

- Alle Manifeste: `kubeconform -strict -kubernetes-version 1.36.6`
- Kyverno-Policies: `kyverno test policies/tests`
- Helm-Werte: `helm template` gegen die genannten Chart-Versionen
- Shell-Skripte: `shellcheck`

Das Buch wurde **nicht** auf echten Clustern durchgespielt. Die Ausgaben im Buch sind Beispiele im Format der echten Werkzeuge.

## PDF bauen

```bash
cd buch && typst compile main.typ Kubernetes-Debuggen-Hands-On.pdf
cd book-en && typst compile main.typ Debugging-Kubernetes-Hands-On-en.pdf
```

Benötigt [Typst](https://typst.app) 0.14 und die Schriften Charter, Avenir Next und Menlo (unter macOS vorinstalliert).

## Lizenz

Alles ist kostenlos.

- **Buch** (Ordner `buch/` und `book-en/`): [CC BY-ND 4.0](https://creativecommons.org/licenses/by-nd/4.0/). Weitergeben ausdrücklich erlaubt, unverändert und mit Namensnennung.
- **Alles andere** (Manifeste, Policies, Helm-Werte, Skripte, k9s-Plugins): [MIT](LICENSE). Frei verwenden, ändern und weitergeben, auch kommerziell.
