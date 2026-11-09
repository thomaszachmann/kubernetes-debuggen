#import "../lib.typ": *

#kapitel(
  [Ingress, Gateway und TLS],
  ziel: [Du findest den Ingress-Controller auf beiden Clustern, liest seine Logs und unterscheidest 404, 503 und das falsche Zertifikat nach ihrer Ursache. Auf Talos installierst du Traefik selbst, so dass sich beide Cluster gleich verhalten.],
  zeit: [75 Minuten],
  braucht: [Kapitel 2 und 7],
)

== Was in diesem Kapitel kaputtgeht

Ein Ingress ist nur eine Beschreibung. Erst ein Ingress-Controller macht daraus Routing-Regeln. In diesem Buch ist das auf beiden Clustern Traefik. Zwischen deinem `curl` und dem Pod stehen damit drei Fragen: Fühlt sich der Controller für diesen Ingress zuständig? Findet er Host und Pfad? Hat das Ziel bereite Pods auf dem richtigen Port? Dazu kommt bei HTTPS das Zertifikat.

#tabelle(
  (auto, 1fr, auto),
  ([Szenario], [Symptom], [Traefik-Log]),
  [Falsche `ingressClassName`], [`404 page not found`], [nichts],
  [Falscher Service-Port im Ingress], [`404 page not found`], [`Cannot create service`],
  [Keine bereiten Pods], [`503 Service Unavailable`], [Access-Log mit 503],
  [TLS-Secret mit falschen Keys], [Zertifikat `TRAEFIK DEFAULT CERT`], [`Error configuring TLS`],
  [Abgelaufenes Zertifikat], [`certificate has expired` im Client], [nichts],
)

Die Spalte rechts ist der Schlüssel: Manche Fehler meldet Traefik laut, andere gar nicht. Gerade das Schweigen ist ein Hinweis.

== Traefik auf beiden Clustern

=== RKE2: mitgeliefert

Seit RKE2 1.36 ist Traefik der Standard-Ingress-Controller für neue Cluster. Im Labor steht zusätzlich `ingress-controller: traefik` ausdrücklich in `config-cp.yaml` (Kapitel 2). ingress-nginx ist in 1.36 noch als Option enthalten, aber abgekündigt und fällt mit 1.37 weg. RKE2 installiert Traefik über seinen Helm-Controller als Chart `rke2-traefik` in `kube-system`.

#cmd("Mac")[```bash
kubectl --context rke2 -n kube-system get helmchart rke2-traefik
kubectl --context rke2 -n kube-system get ds rke2-traefik -o wide
kubectl --context rke2 get ingressclass
```][Zeigt das HelmChart-Objekt, das DaemonSet und die IngressClass.]

```text
NAME           DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
rke2-traefik   2         2         2       2            2           kubernetes.io/os=linux   3d
NAME      CONTROLLER                      PARAMETERS   AGE
traefik   traefik.io/ingress-controller   <none>       3d
```

Das RKE2-Chart weicht in drei Punkten vom Upstream-Chart ab: Traefik läuft als *DaemonSet*, bindet auf jedem Knoten die *hostPorts* 80 und 443, und der Service ist nur vom Typ `ClusterIP`. Du erreichst Traefik also direkt über die Knoten-IPs `172.16.0.160` und `172.16.0.161`, ohne Load Balancer. Die IngressClass heißt `traefik` und ist die Standardklasse, solange Traefik der gewählte Controller ist.

Eigene Werte für ein mitgeliefertes Chart setzt du nie mit `helm upgrade`, sondern über eine `HelmChartConfig` gleichen Namens. Für die Fehlersuche in diesem Kapitel schaltest du die Access-Logs und das Dashboard ein:

#datei("werkzeuge/rke2-traefik-config.yaml", ```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-traefik
  namespace: kube-system
spec:
  valuesContent: |-
    accessLog:
      enabled: true
    ingressRoute:
      dashboard:
        enabled: true
```, erklaerung: [Der Helm-Controller führt diese Werte mit den RKE2-Vorgaben zusammen und rollt das DaemonSet neu aus. Dasselbe erreichst du, wenn du die Datei auf `rke2-cp` nach `/var/lib/rancher/rke2/server/manifests/` legst.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f werkzeuge/rke2-traefik-config.yaml
kubectl --context rke2 -n kube-system rollout status ds/rke2-traefik
```][Der Helm-Controller startet einen Job `helm-install-rke2-traefik`. Scheitert der, etwa wegen eines YAML-Fehlers in `valuesContent`, steht der Grund in `kubectl logs job/helm-install-rke2-traefik -n kube-system`.]

=== Talos: selbst installieren

Talos bringt keinen Ingress-Controller mit. Du installierst Traefik aus dem offiziellen Chart, mit Werten, die das RKE2-Verhalten nachbauen.

#datei("werkzeuge/traefik-values-talos.yaml (Ausschnitt)", ```yaml
deployment:
  kind: DaemonSet
ingressClass:
  enabled: true
  isDefaultClass: true
  name: traefik
ports:
  web:
    hostPort: 80
  websecure:
    hostPort: 443
service:
  spec:
    type: ClusterIP
ingressRoute:
  dashboard:
    enabled: true
accessLog:
  enabled: true
```, erklaerung: [Gleiche Klasse, gleiche Ports, gleiches Verhalten wie auf RKE2. Intern lauscht Traefik auf 8000 und 8443 und läuft als UID 65532. Die Abbildung auf 80 und 443 übernimmt das `portmap`-Plugin des CNI.])

#cmd("Mac")[```bash
kubectl --context talos create namespace traefik
kubectl --context talos label namespace traefik pod-security.kubernetes.io/enforce=privileged
helm --kube-context talos upgrade --install traefik traefik/traefik \
  --version 42.3.1 -n traefik -f werkzeuge/traefik-values-talos.yaml --wait
```][Das Label ist nötig, weil Talos cluster-weit `baseline` erzwingt und `baseline` keine hostPorts erlaubt. Ohne Label nimmt die API das DaemonSet an, aber der Controller kann keine Pods anlegen.]

#falle[
  Fehlt das Label, meldet `helm --wait` nur einen Timeout. Den Grund findest du am DaemonSet, nicht am Pod, denn es gibt keinen Pod: `kubectl --context talos -n traefik describe ds traefik` zeigt das Event `FailedCreate` mit `violates PodSecurity "baseline:latest": hostPort (container "traefik" uses hostPorts 80, 443)`. Mehr dazu in Kapitel 10.
]

#pruefe[
  `curl -s http://172.16.0.171/` und `curl -s http://172.16.0.161/` antworten beide mit `404 page not found`. Das ist hier ein gutes Zeichen: Traefik läuft und antwortet, es gibt nur noch keine Route.
]

== 404: Der Controller fühlt sich nicht zuständig

#datei("szenarien/08-ingress/kaputt-klasse.yaml (Ausschnitt)", ```yaml
kind: Ingress
metadata:
  name: shop
  namespace: dbg-08
spec:
  ingressClassName: nginx     # FEHLER: aus einer alten Anleitung kopiert
  rules:
    - host: shop.dbg08.example
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: shop
                port:
                  number: 80
```, erklaerung: [Die Datei legt außerdem den Namespace `dbg-08`, das Deployment `shop` mit zwei whoami-Pods und den Service `shop` an. Der Fehler ist realistisch: Unzählige Anleitungen und Charts setzen noch `nginx` als Klasse.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/08-ingress/kaputt-klasse.yaml
curl -s --resolve shop.dbg08.example:80:172.16.0.161 http://shop.dbg08.example/
```][`--resolve` legt fest, dass `shop.dbg08.example` für diesen Aufruf auf `172.16.0.161` zeigt. So brauchst du keinen DNS-Eintrag, und `curl` schickt trotzdem den richtigen `Host`-Header und bei HTTPS den richtigen SNI-Namen.]

#symptom[
  ```text
  404 page not found
  ```
  Die Pods laufen, der Service hat Endpoints, der Ingress existiert. Trotzdem antwortet Traefik mit seiner Standard-404-Seite.
]

Eine 404 von Traefik heißt: Keine Route passt auf diese Anfrage. Ob das an Host, Pfad oder an der fehlenden Route selbst liegt, verrät der Ingress:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-08 get ingress shop \
  -o custom-columns=NAME:.metadata.name,CLASS:.spec.ingressClassName,HOSTS:.spec.rules[*].host
kubectl --context rke2 get ingressclass
```][Vergleicht die Klasse des Ingress mit den Klassen, die es im Cluster gibt.]

```text
NAME   CLASS   HOSTS
shop   nginx   shop.dbg08.example
NAME      CONTROLLER                      PARAMETERS   AGE
traefik   traefik.io/ingress-controller   <none>       3d
```

Eine IngressClass `nginx` gibt es nicht. Die Traefik-Logs bleiben leer, kein Event am Ingress. In k9s prüfst du das mit `:ingress dbg-08⏎` und `d`: Die Zeile `Ingress Class:` zeigt `nginx`, unter `Events` steht `<none>`.

#ursache[
  Traefik verarbeitet nur Ingresses, deren `ingressClassName` auf eine IngressClass mit dem Controller `traefik.io/ingress-controller` zeigt, oder Ingresses ohne Klasse, wenn seine Klasse die Standardklasse ist. Einen Ingress mit fremder Klasse überspringt Traefik still, denn er könnte ja einem anderen Controller gehören. Deshalb gibt es weder Log noch Event, und für die Anfrage existiert einfach keine Route.
]

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/08-ingress/fix-ingress.yaml
curl -s --resolve shop.dbg08.example:80:172.16.0.161 http://shop.dbg08.example/ | head -n2
```][Setzt `ingressClassName: traefik`. Die Klasse ist ein normales Feld und lässt sich ändern, der Ingress muss nicht neu angelegt werden.]

#pruefe[
  ```text
  Hostname: shop-6c9b7d5f48-r8wzn
  IP: 127.0.0.1
  ```
  Ein Aufruf ohne `--resolve`, also `curl http://172.16.0.161/`, liefert weiterhin 404. Der Ingress verlangt den Host `shop.dbg08.example`, und ohne ihn passt die Regel nicht. Auch das ist eine häufige Ursache für eine 404.
]

== 404 trotz richtiger Klasse

#datei("szenarien/08-ingress/kaputt-port.yaml (Ausschnitt)", ```yaml
spec:
  ingressClassName: traefik
  rules:
    - host: shop.dbg08.example
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: shop
                port:
                  number: 8080   # FEHLER: der Service hat nur Port 80
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/08-ingress/kaputt-port.yaml
curl -s --resolve shop.dbg08.example:80:172.16.0.161 http://shop.dbg08.example/
```][Wieder kommt `404 page not found`. Diesmal ist Traefik aber zuständig.]

#symptom[
  Gleiche Antwort wie im vorigen Szenario. Von außen sind beide Fehler nicht zu unterscheiden. Erst das Log von Traefik trennt sie.
]

#cmd("Mac")[```bash
kubectl --context rke2 -n kube-system logs -l app.kubernetes.io/name=rke2-traefik \
  --prefix --since=5m | grep -v '"GET'
```][`-l` liest die Logs aller Traefik-Pods, `--prefix` setzt den Pod-Namen davor, `grep -v` blendet die Access-Log-Zeilen aus. Auf Talos lautet das Label `app.kubernetes.io/name=traefik` im Namespace `traefik`.]

```text
[pod/rke2-traefik-8kq4d/rke2-traefik] 2026-11-09T19:42:07Z ERR Cannot create service
  error="service port not found" ingress=shop namespace=dbg-08 providerName=kubernetes
  serviceName=shop servicePort=&ServiceBackendPort{Name:,Number:8080,}
```

Die Zeile wiederholt sich bei jeder Konfigurationsänderung im Cluster. In k9s findest du sie mit `:pods kube-system⏎`, `/traefik⏎`, `l` und dann `/` mit dem Suchbegriff `ERR` im Log-Fenster.

#ursache[
  Traefik sucht im Service `shop` einen Port mit der Nummer 8080 oder einem passenden Namen. Den gibt es nicht, also kann Traefik keinen Backend-Service bauen und lässt den ganzen Pfad weg. Ohne Pfad gibt es keine Route, und die Anfrage endet bei der Standard-404. Die Kubernetes-API prüft diesen Querverweis beim Anlegen des Ingress nicht. Merke: `service.port` im Ingress meint den *Service*-Port, nicht den Container-Port.
]

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/08-ingress/fix-ingress.yaml
```][Port 80, wie im Service.]

#pruefe[
  `curl` mit `--resolve` liefert wieder die whoami-Antwort, und im Log erscheinen keine neuen `ERR`-Zeilen mehr.
]

== 503: Die Route steht, aber niemand ist bereit

#datei("szenarien/08-ingress/kaputt-bereit.yaml (Ausschnitt)", ```yaml
      containers:
        - name: whoami
          image: traefik/whoami:v1.11.0
          readinessProbe:
            tcpSocket:
              port: 8080         # FEHLER: whoami lauscht auf Port 80
            periodSeconds: 5
```)

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-08 delete deploy shop
kubectl --context rke2 apply -f szenarien/08-ingress/kaputt-bereit.yaml
kubectl --context rke2 -n dbg-08 get pods
curl -s -i --resolve shop.dbg08.example:80:172.16.0.161 http://shop.dbg08.example/ | head -n1
```][Löscht zuerst das alte Deployment. Bei einem normalen Update blieben die alten, bereiten Pods stehen, weil der Rollout an den neuen hängen bliebe (Kapitel 15), und der Fehler wäre von außen nicht zu sehen.]

#symptom[
  ```text
  NAME                    READY   STATUS    RESTARTS   AGE
  shop-7f4d8c9b6d-2xkqv   0/1     Running   0          2m
  shop-7f4d8c9b6d-tn5wz   0/1     Running   0          2m
  HTTP/1.1 503 Service Unavailable
  ```
]

Traefik kennt die Route und den Service, aber der Service hat keine bereiten Endpoints. Mit `allowEmptyServices`, das beide Charts einschalten, antwortet Traefik dann mit 503 statt mit 404. Das Access-Log bestätigt es:

```text
172.16.0.1 - - [09/Nov/2026:19:51:33 +0000] "GET / HTTP/1.1" 503 19 "-" "curl/8.7.1" 41
  "dbg-08-shop-shop-dbg08-example@kubernetes" "-" 0ms
```

Das vorletzte Feld zeigt die Server-URL, an die Traefik weitergeleitet hat. `"-"` heißt: Es gab keinen Server. Die Ursache liegt also nicht im Ingress, sondern eine Ebene tiefer. Ab hier gilt die Kette aus Kapitel 7: EndpointSlice ansehen, dann die Readiness der Pods.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-08 events --types=Warning
```][Die Probe-Events hängen an den Pods, nicht am Deployment. Sie nennen `Readiness probe failed: dial tcp 10.42.1.31:8080: connect: connection refused`. In k9s: `:events dbg-08⏎`.]

#ursache[
  Die Readiness-Probe fragt einen Port ab, auf dem niemand lauscht. Die Pods laufen, gelten aber nie als bereit. Der EndpointSlice-Controller trägt sie mit `ready: false` ein, Traefik übernimmt nur bereite Endpoints und hat damit keinen Server für den Service.
]

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/08-ingress/fix-bereit.yaml
kubectl --context rke2 -n dbg-08 rollout status deploy/shop
```][Die Probe fragt jetzt per HTTP den Pfad `/health` auf dem benannten Port `http` ab. whoami beantwortet ihn mit `200`.]

#pruefe[
  Beide Pods stehen auf `1/1`, `curl -i` liefert `HTTP/1.1 200 OK`, und das Access-Log zeigt eine Server-URL wie `"http://10.42.1.34:80"`.
]

#tabelle(
  (auto, 1fr),
  ([Status], [Bedeutung bei Traefik]),
  [404], [Keine Route: falsche Klasse, falscher Host oder Pfad, Backend-Service nicht baubar],
  [503], [Route da, aber keine bereiten Endpoints],
  [502], [Endpoint da, aber die Verbindung zum Pod scheitert, etwa falscher `targetPort` (Kapitel 7)],
  [504], [Pod nimmt an, antwortet aber nicht rechtzeitig],
)

== TLS: das falsche Zertifikat

Für HTTPS braucht der Ingress ein Secret mit Zertifikat und Schlüssel. Weil Schlüssel nicht ins Repo gehören, erzeugst du sie mit einem Skript.

Das Skript `szenarien/08-ingress/zertifikat.sh` legt einmalig eine Labor-CA an und signiert damit ein Zertifikat für `shop.dbg08.example`, wahlweise gültig (`gueltig`, 30 Tage) oder seit Februar 2025 abgelaufen (`abgelaufen`). Die Dateien landen in `szenarien/08-ingress/tls/`, das per `.gitignore` aus dem Repo herausgehalten wird. Für das abgelaufene Zertifikat nutzt das Skript `openssl x509 -not_before/-not_after`, das es erst ab OpenSSL 3.4 gibt. Das LibreSSL von macOS reicht nicht, nimm OpenSSL aus Homebrew.

=== Secret mit falschen Schlüsselnamen

#cmd("Mac")[```bash
szenarien/08-ingress/zertifikat.sh gueltig
kubectl --context rke2 -n dbg-08 create secret generic shop-tls \
  --from-file=cert.pem=szenarien/08-ingress/tls/shop.crt \
  --from-file=key.pem=szenarien/08-ingress/tls/shop.key
kubectl --context rke2 apply -f szenarien/08-ingress/ingress-tls.yaml
```][Ein generisches Secret mit den Dateinamen als Keys. Die API prüft bei Typ `Opaque` nichts. `ingress-tls.yaml` ist der Ingress aus `fix-ingress.yaml` plus ein Abschnitt `tls` mit `secretName: shop-tls`.]

#cmd("Mac")[```bash
curl -sS --cacert szenarien/08-ingress/tls/ca.crt \
  --resolve shop.dbg08.example:443:172.16.0.161 https://shop.dbg08.example/
openssl s_client -connect 172.16.0.161:443 -servername shop.dbg08.example </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```][Erst der Aufruf mit Prüfung gegen die Labor-CA, dann der Blick auf das Zertifikat, das Traefik wirklich ausliefert.]

#symptom[
  ```text
  curl: (60) SSL certificate problem: self-signed certificate
  subject=CN=TRAEFIK DEFAULT CERT
  issuer=CN=TRAEFIK DEFAULT CERT
  ```
  Traefik liefert sein selbst erzeugtes Standardzertifikat aus, nicht das aus dem Secret. Mit `curl -k` funktioniert die Seite, und genau deshalb fällt der Fehler im Browser oft erst spät auf.
]

#cmd("Mac")[```bash
kubectl --context rke2 -n kube-system logs -l app.kubernetes.io/name=rke2-traefik \
  --since=5m | grep 'configuring TLS'
kubectl --context rke2 -n dbg-08 get secret shop-tls -o jsonpath='{.type}{"\n"}'
```][Traefik nennt den Fehler wörtlich. Das Secret verrät seinen Typ, `kubectl describe secret shop-tls` zeigt die Keys `cert.pem` und `key.pem`.]

```text
2026-11-09T20:03:12Z ERR Error configuring TLS error="secret dbg-08/shop-tls is missing
  the following TLS data entries: tls.crt, tls.key" ingress=shop namespace=dbg-08 providerName=kubernetes
Opaque
```

#ursache[
  Ingress-Controller erwarten ein Secret im Format `kubernetes.io/tls` mit genau den Keys `tls.crt` und `tls.key`. Traefik findet die Keys nicht, verwirft das Zertifikat und nimmt für den Host das Standardzertifikat. Die Route selbst bleibt aktiv, deshalb funktioniert HTTPS mit `-k` weiter.
]

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-08 delete secret shop-tls
kubectl --context rke2 -n dbg-08 create secret tls shop-tls \
  --cert=szenarien/08-ingress/tls/shop.crt --key=szenarien/08-ingress/tls/shop.key
```][`create secret tls` setzt Typ und Keys richtig. Bei diesem Typ lehnt die API ein Secret ohne `tls.crt` oder `tls.key` gleich ab. Traefik bemerkt das neue Secret von selbst, ein Neustart ist nicht nötig.]

#pruefe[
  `curl --cacert ... https://shop.dbg08.example/` liefert die whoami-Antwort ohne `-k`, und `openssl s_client` zeigt `subject=CN=shop.dbg08.example` und `issuer=CN=dbg-08 Labor-CA`.
]

=== Abgelaufenes Zertifikat

#cmd("Mac")[```bash
szenarien/08-ingress/zertifikat.sh abgelaufen
kubectl --context rke2 -n dbg-08 create secret tls shop-tls \
  --cert=szenarien/08-ingress/tls/shop.crt --key=szenarien/08-ingress/tls/shop.key \
  --dry-run=client -o yaml | kubectl --context rke2 apply -f -
curl -sS --cacert szenarien/08-ingress/tls/ca.crt \
  --resolve shop.dbg08.example:443:172.16.0.161 https://shop.dbg08.example/
```][Ersetzt das Secret durch das abgelaufene Zertifikat. `--dry-run=client -o yaml | apply` ist das übliche Muster, um ein bestehendes Secret zu überschreiben.]

#symptom[
  ```text
  curl: (60) SSL certificate problem: certificate has expired
  ```
  Traefik loggt nichts. Für ihn ist das Secret formal in Ordnung, und er liefert das Zertifikat aus.
]

Hier hilft nur der Blick auf das ausgelieferte Zertifikat selbst. `openssl s_client ... | openssl x509 -noout -subject -dates` zeigt `notAfter=Feb  1 00:00:00 2025 GMT`. Dasselbe Datum steckt im Secret, das du ohne Netzwerk prüfen kannst:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-08 get secret shop-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -enddate -checkend 0
```][`-checkend 0` prüft, ob das Zertifikat jetzt noch gilt, und antwortet mit `Certificate will expire` und Exit-Code 1. Mit `-checkend 1209600` prüfst du die nächsten 14 Tage. Das eignet sich für einen Cronjob oder eine Alarmregel.]

#ursache[
  Weder Kubernetes noch Traefik prüfen die Laufzeit eines Zertifikats. Das ist Sache des Clients. Ohne cert-manager oder einen anderen Erneuerungsmechanismus läuft jedes Zertifikat irgendwann still ab, und der erste Hinweis ist ein Fehler beim Nutzer.
]

Zur Behebung erzeugst du mit `zertifikat.sh gueltig` ein neues Zertifikat von derselben CA und ersetzt das Secret mit demselben `--dry-run=client -o yaml | apply`-Muster.

#pruefe[
  `curl --cacert ...` liefert wieder die whoami-Antwort, `-checkend 0` meldet `Certificate will not expire`.
]

#distro(
  [Alle Szenarien laufen wie gezeigt. Traefik-Pods im Namespace `kube-system`, Label `app.kubernetes.io/name=rke2-traefik`. Werte änderst du über die `HelmChartConfig` `rke2-traefik`, nie mit `helm upgrade`, sonst überschreibt der Helm-Controller deine Änderung.],
  [Ersetze `--context rke2` durch `--context talos` und `172.16.0.161` durch `172.16.0.171`. Traefik-Pods im Namespace `traefik`, Label `app.kubernetes.io/name=traefik`. Werte änderst du mit `helm upgrade` und `werkzeuge/traefik-values-talos.yaml`.],
)

== Das Dashboard und die Gateway API

Das Traefik-Dashboard zeigt alle Router, Services und Middlewares, die Traefik aus den Ingresses gebaut hat, mit Fehlern und Warnungen. Es läuft auf dem internen Entrypoint `traefik` (Port 8080) und ist von außen nicht erreichbar:

#cmd("Mac")[```bash
kubectl --context rke2 -n kube-system port-forward ds/rke2-traefik 8080:8080
```][Danach öffnest du `http://localhost:8080/dashboard/` im Browser. Auf Talos lautet der Befehl `kubectl --context talos -n traefik port-forward ds/traefik 8080:8080`. In k9s erreichst du dasselbe mit `Shift-f` auf einem Traefik-Pod.]

Ein Ingress, der im Dashboard unter *HTTP Routers* fehlt, wurde nicht verarbeitet.

Die Gateway API ist der Nachfolger von Ingress: `GatewayClass` und `Gateway` gehören dem Plattform-Team, `HTTPRoute` dem Anwendungsteam. RKE2 1.36 bringt die Gateway-API-CRDs mit Traefik mit, der Gateway-Provider von Traefik ist aber aus. Du schaltest ihn mit `providers.kubernetesGateway.enabled: true` in der `HelmChartConfig` ein. Ab RKE2 1.37 kommen die CRDs aus einem eigenen Chart, auf Talos installierst du sie selbst. Für die Fehlersuche ist die Gateway API angenehmer, weil sie Status-Conditions setzt: `kubectl describe httproute` zeigt `Accepted` und `ResolvedRefs` mit Gründen wie `BackendNotFound` oder `NotAllowedByListeners` statt einer stillen 404.

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-08
rm -f szenarien/08-ingress/tls/*.crt szenarien/08-ingress/tls/*.key szenarien/08-ingress/tls/*.srl
```][Räumt den Namespace auf und löscht die erzeugten Zertifikate und Schlüssel.]

#aufgabe[
  Spiele das Szenario aus „404: Der Controller fühlt sich nicht zuständig“ auf Talos nach, aber entferne die Zeile `ingressClassName` ganz, statt sie auf `traefik` zu setzen. Funktioniert der Ingress? Warum?

  Hinweis: Ein Ingress ohne Klasse bekommt beim Anlegen die Standardklasse, also die IngressClass mit der Annotation `ingressclass.kubernetes.io/is-default-class: "true"`. In `traefik-values-talos.yaml` setzt `isDefaultClass: true` genau diese Annotation. Gibt es keine Standardklasse, bleibt das Feld leer, und ob sich ein Controller zuständig fühlt, hängt von seiner Konfiguration ab. Setz die Klasse deshalb immer ausdrücklich.
]

#gelernt(
  [RKE2 1.36 bringt Traefik als DaemonSet mit hostPorts 80/443 und IngressClass `traefik` mit. Werte setzt du per `HelmChartConfig` `rke2-traefik`. Auf Talos installierst du dasselbe Verhalten per Helm, im Namespace mit PSA `privileged`.],
  [`curl --resolve` testet Host-Regeln und SNI ohne DNS-Eintrag.],
  [404 ohne Log: Traefik ist nicht zuständig (Klasse) oder Host und Pfad passen nicht. 404 mit `Cannot create service`: Der Ingress zeigt auf einen Port, den der Service nicht hat.],
  [503 heißt bei Traefik: Route da, aber keine bereiten Endpoints. Weiter geht es mit der EndpointSlice und der Readiness.],
  [`TRAEFIK DEFAULT CERT` deutet auf ein unbrauchbares TLS-Secret hin. Abgelaufene Zertifikate meldet nur der Client, prüfen kannst du sie mit `openssl x509 -checkend`.],
)
