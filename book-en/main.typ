#import "lib.typ": *

#cover(
  [Debugging\ Kubernetes],
  [Finding and fixing failures on RKE2 and Talos, with kubectl, k9s and talosctl],
  [Thomas Zachmann],
  [As of November 9, 2026],
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
  [Debugging Kubernetes],
  [
    One pod is stuck in `Pending`, another has been restarting for an hour, and the webhook rejects every change. Where do you start?

    This book turns troubleshooting into a routine. You build two clusters, one with RKE2 and one with Talos Linux, and break them on purpose. For every failure you see the symptom, the investigation with `kubectl` and k9s, the cause and the fix, on both distributions.
  ],
  (
    ([Method], [From symptom to layer to cause]),
    ([Tools], [kubectl, k9s, crictl, talosctl and kubectl debug]),
    ([Workloads], [Pending, ImagePullBackOff, CrashLoopBackOff, OOMKilled]),
    ([Network], [Services, DNS, NetworkPolicies, Ingress and TLS]),
    ([Security], [RBAC, Pod Security, Kyverno and Falco as a source of failures]),
    ([Platform], [Nodes, etcd, certificates, webhooks and rollouts]),
    ([Distributions], [RKE2 and Talos side by side]),
  ),
  [Hands-on guide · As of November 9, 2026],
  autor: [Thomas Zachmann],
  autor-bild: "bilder/autor.jpg",
  autor-text: [Author on Leanpub],
)
