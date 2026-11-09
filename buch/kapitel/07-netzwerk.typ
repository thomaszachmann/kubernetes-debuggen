#import "../lib.typ": *

#kapitel(
  [Services, DNS und NetworkPolicies],
  ziel: [Du verfolgst eine Anfrage vom Client-Pod über den Namen, den Service und die EndpointSlice bis zum Ziel-Pod. Du erkennst, an welcher Station sie hängen bleibt, und weißt, warum eine NetworkPolicy auf RKE2 wirkt und auf Talos nicht.],
  zeit: [75 Minuten],
  braucht: [Kapitel 2 und 3],
)

== Was in diesem Kapitel kaputtgeht

Eine Anfrage an `http://backend` passiert vier Stationen: Der Name wird per DNS zur IP des Service, kube-proxy leitet die Service-IP auf eine Pod-IP aus der EndpointSlice um, das Paket läuft durch das CNI zum Ziel-Pod, und dort muss ein Prozess auf dem Port lauschen. Jede Station hat ihren eigenen typischen Fehler.

#tabelle(
  (auto, 1fr, 1fr),
  ([Szenario], [Symptom], [Station]),
  [Selektor passt nicht], [`Connection refused` oder Timeout, Service ohne Endpoints], [EndpointSlice],
  [Falscher `targetPort`], [`Could not connect to server`, obwohl Endpoints da sind], [Ziel-Pod],
  [Falscher Name], [`Could not resolve host`, `NXDOMAIN`], [DNS],
  [Default-Deny ohne DNS], [Name löst nicht auf, IP funktioniert], [NetworkPolicy],
  [Policy ohne Wirkung], [Alles geht, obwohl es verboten sein sollte], [CNI],
)

Alle Tests laufen aus einem Werkzeug-Pod `client` mit dem Image `nicolaka/netshoot:v0.15`. Darin stecken `curl`, `dig`, `nslookup`, `ss` und `tcpdump`. Als Ziel dient `traefik/whoami`, ein winziger Webserver auf Port 80, der in seiner Antwort den eigenen Pod-Namen nennt. So siehst du sofort, welcher Pod geantwortet hat.

== Der Service findet keine Pods

#datei("szenarien/07-netzwerk/kaputt-selektor.yaml (Ausschnitt)", ```yaml
kind: Deployment
metadata:
  name: backend
spec:
  replicas: 2
  template:
    metadata:
      labels:
        app: backend
# ...
---
kind: Service
metadata:
  name: backend
spec:
  selector:
    app: backend-api        # FEHLER: die Pods heißen app=backend
  ports:
    - name: http
      port: 80
      targetPort: 80
```, erklaerung: [Die vollständige Datei legt den Namespace `dbg-07`, den Pod `client`, das Deployment und den Service an. Der Selektor des Service sucht nach einem Label, das kein Pod trägt.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/kaputt-selektor.yaml
kubectl --context rke2 -n dbg-07 exec client -- curl -sS -m 5 http://backend
```][Legt alles an und ruft den Service aus dem Client-Pod auf. `-m 5` bricht nach fünf Sekunden ab, `-sS` unterdrückt den Fortschrittsbalken, zeigt aber Fehler.]

#symptom[
  ```text
  curl: (7) Failed to connect to backend port 80 after 3 ms: Could not connect to server
  command terminated with exit code 7
  ```
  Der Name löst auf, sonst käme `Could not resolve host`. Die Verbindung scheitert sofort. Je nach Proxy-Modus und CNI siehst du statt der sofortigen Ablehnung auch einen Timeout nach fünf Sekunden. Beides heißt: Hinter der Service-IP wartet niemand.
]

Die erste Frage lautet nicht „Was ist mit dem Netzwerk?“, sondern „Hat der Service überhaupt Ziele?“. Die Antwort steht in der EndpointSlice, die der EndpointSlice-Controller für jeden Service mit Selektor pflegt.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 get endpointslices -l kubernetes.io/service-name=backend
```][Jede EndpointSlice trägt das Label `kubernetes.io/service-name` mit dem Namen ihres Service. Das ältere `kubectl get endpoints` funktioniert noch, gibt seit Kubernetes 1.33 aber eine Deprecation-Warnung aus.]

```text
NAME            ADDRESSTYPE   PORTS     ENDPOINTS   AGE
backend-7xqzl   IPv4          <unset>   <unset>     41s
```

`<unset>` in der Spalte `ENDPOINTS` heißt: Kein einziger Pod passt. Jetzt vergleichst du Selektor und Labels direkt:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 get svc backend -o jsonpath='{.spec.selector}{"\n"}'
kubectl --context rke2 -n dbg-07 get pods --show-labels
```][Die erste Zeile zeigt, wonach der Service sucht, die zweite, was die Pods tragen.]

```text
{"app":"backend-api"}
NAME                       READY   STATUS    RESTARTS   AGE   LABELS
backend-5b8d9f6c7d-4kq2m   1/1     Running   0          58s   app=backend,pod-template-hash=...
backend-5b8d9f6c7d-xv7jt   1/1     Running   0          58s   app=backend,pod-template-hash=...
client                     1/1     Running   0          58s   app=client
```

Die Gegenprobe mit dem Selektor des Service liefert eine leere Liste: `kubectl --context rke2 -n dbg-07 get pods -l app=backend-api` antwortet mit `No resources found in dbg-07 namespace.` In k9s siehst du dasselbe als Baum:

#cmd("k9s")[```text
:xray svc dbg-07⏎
```][XRay zeigt jeden Service mit den Pods darunter, die er erreicht. Unter `backend` hängt nichts. Mit `Esc` und `:pods dbg-07⏎` gelangst du zur Pod-Liste, `y` auf einem Pod zeigt die Labels im YAML.]

#ursache[
  Ein Service ist nur ein Selektor plus eine virtuelle IP. Der EndpointSlice-Controller sucht laufend alle Pods im Namespace, deren Labels zum Selektor passen und die ready sind, und trägt sie in die EndpointSlice ein. Passt kein Pod, bleibt die Slice leer, und kube-proxy hat kein Ziel für die Service-IP. Kubernetes meldet das nirgends als Fehler, es gibt kein Event und keinen Status. Dieselbe leere Slice entsteht, wenn der Selektor stimmt, die Pods aber nicht ready sind (Kapitel 6). `0/1` in `kubectl get pods` spricht für die Probe, `1/1` für den Selektor.
]

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/fix-service.yaml
kubectl --context rke2 -n dbg-07 get endpointslices -l kubernetes.io/service-name=backend
```][Ersetzt den Selektor durch `app: backend`. Die Datei verweist außerdem mit `targetPort: http` auf den benannten Port aus dem Pod-Template statt auf eine Zahl.]

#pruefe[
  ```text
  NAME            ADDRESSTYPE   PORTS   ENDPOINTS               AGE
  backend-7xqzl   IPv4          80      10.42.0.21,10.42.1.17   2m
  ```
  Zwei Pod-IPs, Port 80. `kubectl --context rke2 -n dbg-07 exec client -- curl -s http://backend` antwortet mit `Hostname: backend-5b8d9f6c7d-...`. Rufst du mehrmals auf, wechselt der Name zwischen beiden Pods.
]

== Endpoints da, Verbindung trotzdem abgelehnt

#datei("szenarien/07-netzwerk/kaputt-port.yaml (Ausschnitt)", ```yaml
spec:
  selector:
    app: backend
  ports:
    - name: http
      port: 80
      targetPort: 8080      # FEHLER: whoami lauscht auf Port 80
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/kaputt-port.yaml
kubectl --context rke2 -n dbg-07 exec client -- curl -sS -m 5 http://backend
```][Der Selektor stimmt diesmal, nur der Zielport ist falsch.]

#symptom[
  Wieder `curl: (7) Failed to connect to backend port 80 ... Could not connect to server`. Diesmal ist die EndpointSlice aber gefüllt:
  ```text
  NAME            ADDRESSTYPE   PORTS   ENDPOINTS               AGE
  backend-7xqzl   IPv4          8080    10.42.0.21,10.42.1.17   4m
  ```
]

Die Spalte `PORTS` verrät den Fehler bereits: Die Slice zeigt den Port, auf dem der *Pod* angesprochen wird, nicht den Service-Port. Um sicherzugehen, fragst du den Pod direkt, am Service vorbei:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://10.42.0.21:80
```][Fragt eine Pod-IP aus der Slice direkt auf Port 80 ab und gibt nur den HTTP-Status aus: `200`. Derselbe Aufruf auf Port 8080 wird abgelehnt.]

Welche Ports ein Container wirklich geöffnet hat, siehst du mit `ss`. Das whoami-Image enthält keine Shell und kein `ss`. Ein Ephemeral Container mit netshoot teilt sich aber den Netzwerk-Namespace des Pods und sieht dieselben Sockets:

#cmd("Mac")[```bash
POD=$(kubectl --context rke2 -n dbg-07 get pod -l app=backend -o name | head -n1)
kubectl --context rke2 -n dbg-07 debug -it "$POD" \
  --image=nicolaka/netshoot:v0.15 --profile=baseline --target=whoami -- ss -tlnp
```][`--target=whoami` hängt den Debug-Container zusätzlich an den Prozess-Namespace des Containers `whoami`, so zeigt `ss` auch den Prozessnamen. `--profile=baseline` ist auf RKE2 nicht nötig, auf Talos aber Pflicht: Das Standardprofil `general` fügt `SYS_PTRACE` hinzu, und das lehnt Talos' PSA `baseline` ab. In k9s erledigt das Plugin aus Kapitel 3 denselben Schritt: In der Container-Ansicht des Pods `Shift-D`.]

```text
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      4096               *:80              *:*     users:(("whoami",pid=1,fd=3))
```

#ursache[
  `targetPort` ist der Port im Pod, an den kube-proxy die Pakete weiterreicht. Dort lauscht niemand, also antwortet der Kernel des Pods mit einem TCP-Reset. Der Service, die EndpointSlice und die Pods sind alle „gesund“, nur ihre Verabredung über den Port stimmt nicht. Benannte Ports (`targetPort: http`) vermeiden diesen Fehler, weil der Port dann nur an einer Stelle steht: im Pod-Template.
]

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/fix-service.yaml
```][Setzt `targetPort` wieder auf den benannten Port `http`.]

#pruefe[
  Die EndpointSlice zeigt Port `80`, und `curl -s http://backend` aus dem Client-Pod liefert die whoami-Antwort.
]

== Namen, Namespaces und ndots

DNS-Fehler sehen anders aus als Verbindungsfehler: `curl: (6) Could not resolve host`. Bevor du CoreDNS verdächtigst, schau dir an, wie der Pod Namen auflöst.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 exec client -- cat /etc/resolv.conf
```][Diese Datei schreibt das Kubelet beim Start des Pods.]

```text
search dbg-07.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.43.0.10
options ndots:5
```

Mit `ndots:5` gilt jeder Name mit weniger als fünf Punkten als relativ. Der Resolver hängt dann nacheinander die Suchdomänen an. Aus `backend` wird zuerst `backend.dbg-07.svc.cluster.local`, und das existiert. Aus `backend.dbg07` (Tippfehler, Bindestrich fehlt) wird `backend.dbg07.dbg-07.svc.cluster.local`, dann `backend.dbg07.svc.cluster.local`, dann `backend.dbg07.cluster.local` und zuletzt `backend.dbg07.` als absoluter Name. Alle vier Anfragen enden mit `NXDOMAIN`.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 exec client -- nslookup backend.dbg07
kubectl --context rke2 -n dbg-07 exec client -- nslookup backend.dbg-07
```][Der erste Name ist falsch geschrieben, der zweite ist die richtige Kurzform `<service>.<namespace>`.]

```text
** server can't find backend.dbg07: NXDOMAIN
# ...
Name:   backend.dbg-07.svc.cluster.local
Address: 10.43.118.204
```

Der häufigste Fall in der Praxis ist kein Tippfehler, sondern ein fehlender Namespace: Eine Anwendung in `dbg-07` ruft `postgres` auf, der Service liegt aber in `datenbank`. Der Kurzname funktioniert nur im eigenen Namespace, über Namespace-Grenzen hinweg brauchst du mindestens `postgres.datenbank`. Das lässt sich im Labor gut an CoreDNS selbst zeigen, denn sein Service heißt auf beiden Clustern unterschiedlich:

#cmd("Mac")[```bash
kubectl --context rke2 -n kube-system get svc -l k8s-app=kube-dns
kubectl --context talos -n kube-system get svc -l k8s-app=kube-dns
```][Beide Distributionen setzen das Label `k8s-app=kube-dns`, die Namen unterscheiden sich.]

```text
NAME                        TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)         AGE
rke2-coredns-rke2-coredns   ClusterIP   10.43.0.10   <none>        53/UDP,53/TCP   3d
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   3d
```

Ein Skript, das `kube-dns.kube-system` abfragt, funktioniert also auf Talos und scheitert auf RKE2 mit `NXDOMAIN`. Von solchen Unterschieden handelt dieses Buch.

=== CoreDNS selbst untersuchen

Erst wenn auch `kubernetes.default` nicht auflöst, liegt das Problem bei CoreDNS oder auf dem Weg dorthin.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 exec client -- dig +short kubernetes.default.svc.cluster.local
kubectl --context rke2 -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl --context rke2 -n kube-system logs deploy/rke2-coredns-rke2-coredns --tail=20
```][Erst die Funktion, dann die Pods, dann ihre Logs. `dig +short` liefert nur die Adresse, auf RKE2 `10.43.0.1`.]

In k9s: `:pods kube-system⏎`, dann `/coredns⏎`, `l` für die Logs und `d` für Restarts und Probes.

Meldungen wie `[ERROR] plugin/errors: 2 example.org. A: read udp ...: i/o timeout` heißen: CoreDNS erreicht seinen Upstream-Server nicht. Das betrifft nur externe Namen. Interne Namen wie `backend.dbg-07.svc.cluster.local` beantwortet CoreDNS selbst aus der Kubernetes-API.

#distro(
  [Deployment und Service heißen `rke2-coredns-rke2-coredns`, die Corefile liegt in der gleichnamigen ConfigMap. Änderungen machst du nicht dort, sondern über eine `HelmChartConfig` namens `rke2-coredns` in `kube-system`, sonst überschreibt der Helm-Controller sie. Service-IP `10.43.0.10`, Upstream ist `/etc/resolv.conf` des Knotens.],
  [Deployment `coredns`, Service `kube-dns`, ConfigMap `coredns`, Service-IP `10.96.0.10`. Talos aktiviert für neue Cluster `forwardKubeDNSToHost`: CoreDNS schickt externe Anfragen an den DNS-Cache des Knotens unter `169.254.116.108`. Upstream-Fehler suchst du dann auf dem Knoten: `talosctl -n 172.16.0.171 get dnsupstream` zeigt, ob die Upstream-Server erreichbar sind, `talosctl -n 172.16.0.171 logs dns-resolve-cache` die Logs des Caches.],
)

== Default-Deny blockiert DNS

Eine NetworkPolicy, die mit `podSelector: {}` alles erfasst und `Egress` nennt, verbietet jeden ausgehenden Verkehr, für den keine andere Policy eine Ausnahme macht. Das schließt DNS ein.

#datei("szenarien/07-netzwerk/kaputt-policy.yaml (Ausschnitt)", ```yaml
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
kind: NetworkPolicy
metadata:
  name: client-zu-backend
spec:
  podSelector:
    matchLabels:
      app: client
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: backend
      ports:
        - protocol: TCP
          port: 80
# ... dazu backend-von-client: Ingress auf backend nur von client
```, erklaerung: [Gedacht war: Alles ist zu, nur der Client darf zum Backend. Vergessen wurde, dass der Client vorher den Namen `backend` auflösen muss.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/kaputt-policy.yaml
kubectl --context rke2 -n dbg-07 exec client -- curl -sS -m 10 http://backend
```][Wendet die drei Policies an und testet wieder mit `curl`.]

#symptom[
  ```text
  curl: (6) Could not resolve host: backend
  command terminated with exit code 6
  ```
  Nach einigen Sekunden Wartezeit kommt die Meldung. Der Aufruf über die Service-IP, etwa `curl -s http://10.43.118.204`, funktioniert dagegen sofort.
]

Dieses Muster ist eindeutig: Die IP geht, der Name nicht. Zur Bestätigung fragst du den DNS-Server direkt:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 exec client -- dig +time=2 +tries=1 backend.dbg-07.svc.cluster.local
kubectl --context rke2 -n dbg-07 get networkpolicy
```][Ohne Antwort meldet `dig` einen Timeout. Danach listest du alle Policies im Namespace.]

```text
;; communications error to 10.43.0.10#53: timed out
;; no servers could be reached

NAME                 POD-SELECTOR   AGE
backend-von-client   app=backend    1m
client-zu-backend    app=client     1m
default-deny         <none>         1m
```

`<none>` bei `default-deny` bedeutet: leerer Selektor, die Policy gilt für jeden Pod im Namespace. Mit `kubectl describe networkpolicy client-zu-backend` siehst du die erlaubten Ziele ausgeschrieben. Port 53 taucht nirgends auf. In k9s öffnest du dafür `:netpol dbg-07⏎` und drückst `d` auf der markierten Policy.

#ursache[
  NetworkPolicies sind Whitelists und wirken additiv. Sobald irgendeine Policy einen Pod für `Egress` auswählt, ist für ihn jeder ausgehende Verkehr verboten, den keine Policy ausdrücklich erlaubt. Die Anfrage an CoreDNS ist ausgehender Verkehr zu einem Pod in `kube-system` auf UDP- und TCP-Port 53. Weil die Policy nach der Umsetzung der Service-IP auf die Pod-IP greift, muss die Regel die CoreDNS-Pods auswählen, nicht die Service-IP.
]

#datei("szenarien/07-netzwerk/fix-policy.yaml (Ausschnitt)", ```yaml
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```, erklaerung: [`namespaceSelector` und `podSelector` stehen im *selben* Listeneintrag, also gilt beides zugleich: CoreDNS-Pods in `kube-system`. Mit einem Bindestrich vor `podSelector` wären es zwei Einträge, und die Regel würde alle Pods in `kube-system` *oder* alle Pods mit `k8s-app=kube-dns` in `dbg-07` erlauben. Das Label `kubernetes.io/metadata.name` setzt Kubernetes auf jedem Namespace automatisch.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/fix-policy.yaml
kubectl --context rke2 -n dbg-07 exec client -- curl -s -m 10 http://backend
```][Ergänzt eine vierte Policy, die DNS für alle Pods im Namespace freigibt.]

#pruefe[
  `curl` liefert sofort die whoami-Antwort. Die Gegenprobe zeigt, dass der Rest zu bleibt: `kubectl --context rke2 -n dbg-07 exec client -- curl -sS -m 5 https://kubernetes.io` endet mit einem Timeout, weil `client` nur `backend` erreichen darf.
]

#falle[
  TCP-Port 53 nicht vergessen. DNS weicht auf TCP aus, wenn eine Antwort nicht in ein UDP-Paket passt. Mit nur UDP funktionieren die meisten Abfragen, einzelne große Antworten scheitern dann sporadisch, und die Fehlersuche wird mühsam.
]

== Die Policy, die nichts tut

Jetzt dasselbe auf Talos. Wende die kaputte Policy an, diesmal mit der Erwartung, dass DNS scheitert:

#cmd("Mac")[```bash
kubectl --context talos apply -f szenarien/07-netzwerk/kaputt-selektor.yaml \
  -f szenarien/07-netzwerk/fix-service.yaml -f szenarien/07-netzwerk/kaputt-policy.yaml
kubectl --context talos -n dbg-07 exec client -- curl -s -m 5 http://backend
kubectl --context talos -n dbg-07 exec client -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' https://kubernetes.io
```][Baut die Ausgangslage aus diesem Kapitel nach und testet sowohl den erlaubten als auch einen verbotenen Weg. Beim `apply` siehst du Warnungen `would violate PodSecurity "restricted:latest"`. Das sind nur Warnungen, Talos erzwingt `baseline`.]

#symptom[
  Beide Aufrufe funktionieren. `curl http://backend` liefert die whoami-Antwort, der Aufruf ins Internet einen HTTP-Status statt eines Timeouts. Die Policies existieren, `kubectl get networkpolicy -n dbg-07` listet alle drei. Es gibt keinen Fehler und keine Warnung.
]

Die Kubernetes-API speichert NetworkPolicies, setzt sie aber nicht selbst durch. Das macht das CNI-Plugin. Welches CNI läuft, zeigt `kubectl --context talos -n kube-system get ds`: Auf Talos findest du `kube-flannel`, auf RKE2 dagegen `rke2-canal`.

#ursache[
  Talos installiert standardmäßig Flannel. Flannel baut nur das Overlay-Netz zwischen den Knoten und kennt keine NetworkPolicies. Die API nimmt die Objekte trotzdem an, weil sie zum Kern von Kubernetes gehören. Niemand wertet sie aus. Canal auf RKE2 kombiniert Flannel für das Overlay mit dem Policy-Teil von Calico (Felix), der die Regeln als iptables-Regeln auf jedem Knoten umsetzt.
]

Die Lösung ist hier kein Patch, sondern eine Architekturentscheidung. Auf Talos setzt du dafür beim Erzeugen der Machine-Config `cluster.network.cni.name: none` und installierst danach Cilium oder Calico selbst. Für einen laufenden Cluster ist der Wechsel des CNI ein Umbau mit Ausfall, kein Fix für zwischendurch. Im Labor bleibt Talos deshalb bei Flannel, und dieses Szenario bleibt eine Demonstration.

#distro(
  [Canal setzt NetworkPolicies durch. Felix schreibt die Regeln in iptables-Ketten mit dem Präfix `cali-`. Auf dem Knoten zählt `sudo iptables-save | grep -c cali-` sie grob durch. Eine neue Policy wirkt nach wenigen Sekunden.],
  [Flannel ignoriert NetworkPolicies vollständig. Wer auf Talos Policies braucht, muss das CNI beim Aufbau ersetzen (`cni.name: none` plus Cilium oder Calico). Die Talos-Doku beschreibt beide Wege.],
)

#warum[
  Teste jede Policy mit einer Gegenprobe, die scheitern *muss*. Ein grüner Test des erlaubten Weges beweist nur, dass die Policy nicht zu viel verbietet. Ob sie überhaupt etwas verbietet, zeigt dir erst der verbotene Weg. Auf Talos wäre dir der Fehler sonst nie aufgefallen.
]

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-07
kubectl --context talos delete ns dbg-07
```][Räumt beide Cluster auf. Policies, Services und Pods verschwinden mit dem Namespace.]

#aufgabe[
  Wende `kaputt-selektor.yaml` und `fix-service.yaml` auf RKE2 erneut an. Ergänze dann im Service `backend` den Selektor um ein zweites Label `version: v2` (`kubectl edit svc backend` oder `e` in k9s). Was zeigt die EndpointSlice, was `curl`? Wie bekommst du den Service wieder gefüllt, ohne den Selektor zurückzunehmen?

  Hinweis: Die Labels eines Selektors sind UND-verknüpft. Kein Pod trägt `version: v2`, also wird die Slice leer. Ergänze das Label im Pod-Template des Deployments (nicht im `selector` des Deployments, der ist unveränderlich). Nach dem Rollout füllt sich die Slice wieder.
]

#gelernt(
  [Zuerst die EndpointSlice prüfen: Ein Service ohne Endpoints ist ein Selektor- oder Readiness-Problem, kein Netzwerkproblem.],
  [Die Spalte `PORTS` der EndpointSlice zeigt den Port im Pod. Benannte Ports verhindern Abweichungen zwischen Service und Pod.],
  [`ndots:5` und die Suchdomänen erklären, warum Kurznamen nur im eigenen Namespace funktionieren. CoreDNS heißt auf RKE2 `rke2-coredns-rke2-coredns`, auf Talos `coredns` bzw. `kube-dns`.],
  [Eine Default-Deny-Policy mit `Egress` braucht eine Ausnahme für UDP und TCP 53 zu den CoreDNS-Pods.],
  [NetworkPolicies wirken nur, wenn das CNI sie umsetzt: Canal auf RKE2 ja, Flannel auf Talos nein. Jede Policy braucht eine Gegenprobe, die scheitern muss.],
)
