#import "lib.typ": *

#cover(
  [Kubernetes\ debuggen],
  [Fehler finden und beheben auf RKE2 und Talos, mit kubectl, k9s und talosctl],
  [Thomas Zachmann],
  [Stand: 9. November 2026],
)

#show: buch

#set page(numbering: "1")
#counter(page).update(1)

#include "kapitel/00-vorwort.typ"
#include "kapitel/01-methode.typ"
#include "kapitel/02-labor.typ"
#include "kapitel/03-k9s.typ"
#include "kapitel/04-pending.typ"
#include "kapitel/05-images.typ"
#include "kapitel/06-crash.typ"
#include "kapitel/07-netzwerk.typ"
#include "kapitel/08-ingress.typ"
#include "kapitel/09-storage.typ"
#include "kapitel/10-rbac-psa.typ"
#include "kapitel/11-kyverno.typ"
#include "kapitel/12-falco.typ"
#include "kapitel/13-nodes.typ"
#include "kapitel/14-controlplane.typ"
#include "kapitel/15-rollouts.typ"
#include "kapitel/16-anhang.typ"

#rueckseite(
  [Kubernetes debuggen],
  [
    Ein Pod hängt in `Pending`, ein anderer startet seit einer Stunde neu, und der Webhook lehnt jede Änderung ab. Wo fängst du an?

    Dieses Buch macht Fehlersuche zur Routine. Du baust zwei Cluster, einen mit RKE2 und einen mit Talos Linux, und machst sie gezielt kaputt. Zu jedem Fehler siehst du das Symptom, die Untersuchung mit `kubectl` und k9s, die Ursache und den Fix, jeweils auf beiden Distributionen.
  ],
  (
    ([Methode], [Vom Symptom über die Schicht zur Ursache]),
    ([Werkzeuge], [kubectl, k9s, crictl, talosctl und kubectl debug]),
    ([Workloads], [Pending, ImagePullBackOff, CrashLoopBackOff, OOMKilled]),
    ([Netzwerk], [Services, DNS, NetworkPolicies, Ingress und TLS]),
    ([Sicherheit], [RBAC, Pod Security, Kyverno und Falco als Fehlerquelle]),
    ([Plattform], [Nodes, etcd, Zertifikate, Webhooks und Rollouts]),
    ([Distributionen], [RKE2 und Talos im direkten Vergleich]),
  ),
  [Hands-on-Handbuch · Stand: 9. November 2026],
  autor: [Thomas Zachmann],
  autor-bild: "bilder/autor.jpg",
  autor-text: [Autor auf Leanpub],
)
