#import "../lib.typ": *

#kapitel(
  [Ingress, Gateway and TLS],
  ziel: [You find the ingress controller on both clusters, read its logs and tell 404, 503 and the wrong certificate apart by their cause. On Talos you install Traefik yourself, so that both clusters behave the same.],
  zeit: [75 minutes],
  braucht: [Chapters 2 and 7],
)

== What Breaks in This Chapter

An Ingress is only a description. An ingress controller turns it into routing rules. In this book, that is Traefik on both clusters. So between your `curl` and the pod there are three questions: Does the controller consider this Ingress its own? Does it find the host and path? Does the target have ready pods on the right port? With HTTPS, the certificate comes on top.

#tabelle(
  (auto, 1fr, auto),
  ([Scenario], [Symptom], [Traefik log]),
  [Wrong `ingressClassName`], [`404 page not found`], [nothing],
  [Wrong Service port in the Ingress], [`404 page not found`], [`Cannot create service`],
  [No ready pods], [`503 Service Unavailable`], [Access log with 503],
  [TLS Secret with wrong keys], [Certificate `TRAEFIK DEFAULT CERT`], [`Error configuring TLS`],
  [Expired certificate], [`certificate has expired` in the client], [nothing],
)

The column on the right is the key: Traefik reports some errors loudly and others not at all. The silence itself is a clue.

== Traefik on Both Clusters

=== RKE2: Included

Since RKE2 1.36, Traefik is the default ingress controller for new clusters. In the lab, `ingress-controller: traefik` is also set explicitly in `config-cp.yaml` (Chapter 2). ingress-nginx is still available as an option in 1.36, but it is deprecated and will be removed in 1.37. RKE2 installs Traefik through its Helm controller as the chart `rke2-traefik` in `kube-system`.

#cmd("Mac")[```bash
kubectl --context rke2 -n kube-system get helmchart rke2-traefik
kubectl --context rke2 -n kube-system get ds rke2-traefik -o wide
kubectl --context rke2 get ingressclass
```][Shows the HelmChart object, the DaemonSet and the IngressClass.]

```text
NAME           DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
rke2-traefik   2         2         2       2            2           kubernetes.io/os=linux   3d
NAME      CONTROLLER                      PARAMETERS   AGE
traefik   traefik.io/ingress-controller   <none>       3d
```

The RKE2 chart differs from the upstream chart in three ways: Traefik runs as a *DaemonSet*, it binds the *hostPorts* 80 and 443 on every node, and the Service is only of type `ClusterIP`. So you reach Traefik directly through the node IPs `172.16.0.160` and `172.16.0.161`, without a load balancer. The IngressClass is called `traefik`, and it is the default class as long as Traefik is the selected controller.

You never set your own values for a bundled chart with `helm upgrade`. You use a `HelmChartConfig` with the same name instead. For troubleshooting in this chapter, turn on the access logs and the dashboard:

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
```, erklaerung: [The Helm controller merges these values with the RKE2 defaults and rolls out the DaemonSet again. You get the same result if you put the file into `/var/lib/rancher/rke2/server/manifests/` on `rke2-cp`.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f werkzeuge/rke2-traefik-config.yaml
kubectl --context rke2 -n kube-system rollout status ds/rke2-traefik
```][The Helm controller starts a job `helm-install-rke2-traefik`. If it fails, for example because of a YAML error in `valuesContent`, you find the reason in `kubectl logs job/helm-install-rke2-traefik -n kube-system`.]

=== Talos: Install It Yourself

Talos does not ship an ingress controller. You install Traefik from the official chart, with values that recreate the RKE2 behavior.

#datei("werkzeuge/traefik-values-talos.yaml (excerpt)", ```yaml
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
```, erklaerung: [Same class, same ports, same behavior as on RKE2. Internally, Traefik listens on 8000 and 8443 and runs as UID 65532. The `portmap` plugin of the CNI maps them to 80 and 443.])

#cmd("Mac")[```bash
kubectl --context talos create namespace traefik
kubectl --context talos label namespace traefik pod-security.kubernetes.io/enforce=privileged
helm --kube-context talos upgrade --install traefik traefik/traefik \
  --version 42.3.1 -n traefik -f werkzeuge/traefik-values-talos.yaml --wait
```][The label is needed because Talos enforces `baseline` cluster-wide, and `baseline` does not allow hostPorts. Without the label, the API accepts the DaemonSet, but the controller cannot create any pods.]

#falle[
  If the label is missing, `helm --wait` only reports a timeout. You find the reason on the DaemonSet, not on the pod, because there is no pod: `kubectl --context talos -n traefik describe ds traefik` shows the event `FailedCreate` with `violates PodSecurity "baseline:latest": hostPort (container "traefik" uses hostPorts 80, 443)`. More on this in Chapter 10.
]

#pruefe[
  `curl -s http://172.16.0.171/` and `curl -s http://172.16.0.161/` both answer with `404 page not found`. Here that is a good sign: Traefik is running and answering, there is just no route yet.
]

== 404: The Controller Does Not Feel Responsible

#datei("szenarien/08-ingress/kaputt-klasse.yaml (excerpt)", ```yaml
kind: Ingress
metadata:
  name: shop
  namespace: dbg-08
spec:
  ingressClassName: nginx     # ERROR: copied from an old tutorial
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
```, erklaerung: [The file also creates the namespace `dbg-08`, the Deployment `shop` with two whoami pods and the Service `shop`. The error is realistic: countless tutorials and charts still set `nginx` as the class.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/08-ingress/kaputt-klasse.yaml
curl -s --resolve shop.dbg08.example:80:172.16.0.161 http://shop.dbg08.example/
```][`--resolve` makes `shop.dbg08.example` point to `172.16.0.161` for this call. That way you do not need a DNS entry, and `curl` still sends the right `Host` header and, with HTTPS, the right SNI name.]

#symptom[
  ```text
  404 page not found
  ```
  The pods are running, the Service has endpoints, the Ingress exists. Still, Traefik answers with its default 404 page.
]

A 404 from Traefik means: no route matches this request. The Ingress tells you whether that is because of the host, the path or the missing route itself:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-08 get ingress shop \
  -o custom-columns=NAME:.metadata.name,CLASS:.spec.ingressClassName,HOSTS:.spec.rules[*].host
kubectl --context rke2 get ingressclass
```][Compares the class of the Ingress with the classes that exist in the cluster.]

```text
NAME   CLASS   HOSTS
shop   nginx   shop.dbg08.example
NAME      CONTROLLER                      PARAMETERS   AGE
traefik   traefik.io/ingress-controller   <none>       3d
```

There is no IngressClass `nginx`. The Traefik logs stay empty, and there is no event on the Ingress. In k9s you check this with `:ingress dbg-08⏎` and `d`: the line `Ingress Class:` shows `nginx`, and `Events` says `<none>`.

#ursache[
  Traefik only processes Ingresses whose `ingressClassName` points to an IngressClass with the controller `traefik.io/ingress-controller`, or Ingresses without a class if its own class is the default class. Traefik silently skips an Ingress with a foreign class, because it might belong to another controller. That is why there is no log and no event, and the request simply has no route.
]

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/08-ingress/fix-ingress.yaml
curl -s --resolve shop.dbg08.example:80:172.16.0.161 http://shop.dbg08.example/ | head -n2
```][Sets `ingressClassName: traefik`. The class is a normal field and can be changed. You do not have to recreate the Ingress.]

#pruefe[
  ```text
  Hostname: shop-6c9b7d5f48-r8wzn
  IP: 127.0.0.1
  ```
  A call without `--resolve`, so `curl http://172.16.0.161/`, still returns 404. The Ingress requires the host `shop.dbg08.example`, and without it the rule does not match. This is also a common cause of a 404.
]

== 404 Despite the Right Class

#datei("szenarien/08-ingress/kaputt-port.yaml (excerpt)", ```yaml
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
                  number: 8080   # ERROR: the Service only has port 80
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/08-ingress/kaputt-port.yaml
curl -s --resolve shop.dbg08.example:80:172.16.0.161 http://shop.dbg08.example/
```][Again you get `404 page not found`. But this time Traefik is responsible.]

#symptom[
  Same answer as in the previous scenario. From the outside, you cannot tell the two errors apart. Only the Traefik log separates them.
]

#cmd("Mac")[```bash
kubectl --context rke2 -n kube-system logs -l app.kubernetes.io/name=rke2-traefik \
  --prefix --since=5m | grep -v '"GET'
```][`-l` reads the logs of all Traefik pods, `--prefix` puts the pod name in front, and `grep -v` hides the access log lines. On Talos the label is `app.kubernetes.io/name=traefik` in the namespace `traefik`.]

```text
[pod/rke2-traefik-8kq4d/rke2-traefik] 2026-11-09T19:42:07Z ERR Cannot create service
  error="service port not found" ingress=shop namespace=dbg-08 providerName=kubernetes
  serviceName=shop servicePort=&ServiceBackendPort{Name:,Number:8080,}
```

The line repeats with every configuration change in the cluster. In k9s you find it with `:pods kube-system⏎`, `/traefik⏎`, `l`, and then `/` with the search term `ERR` in the log window.

#ursache[
  Traefik looks for a port with the number 8080 or a matching name in the Service `shop`. There is none, so Traefik cannot build a backend service and drops the whole path. Without the path there is no route, and the request ends at the default 404. The Kubernetes API does not check this cross-reference when you create the Ingress. Remember: `service.port` in the Ingress means the *Service* port, not the container port.
]

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/08-ingress/fix-ingress.yaml
```][Port 80, as in the Service.]

#pruefe[
  `curl` with `--resolve` returns the whoami response again, and no new `ERR` lines show up in the log.
]

== 503: The Route Exists, but Nobody Is Ready

#datei("szenarien/08-ingress/kaputt-bereit.yaml (excerpt)", ```yaml
      containers:
        - name: whoami
          image: traefik/whoami:v1.11.0
          readinessProbe:
            tcpSocket:
              port: 8080         # ERROR: whoami listens on port 80
            periodSeconds: 5
```)

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-08 delete deploy shop
kubectl --context rke2 apply -f szenarien/08-ingress/kaputt-bereit.yaml
kubectl --context rke2 -n dbg-08 get pods
curl -s -i --resolve shop.dbg08.example:80:172.16.0.161 http://shop.dbg08.example/ | head -n1
```][Deletes the old Deployment first. With a normal update, the old, ready pods would stay, because the rollout would get stuck on the new ones (Chapter 15), and you would not see the error from the outside.]

#symptom[
  ```text
  NAME                    READY   STATUS    RESTARTS   AGE
  shop-7f4d8c9b6d-2xkqv   0/1     Running   0          2m
  shop-7f4d8c9b6d-tn5wz   0/1     Running   0          2m
  HTTP/1.1 503 Service Unavailable
  ```
]

Traefik knows the route and the Service, but the Service has no ready endpoints. With `allowEmptyServices`, which both charts turn on, Traefik then answers with 503 instead of 404. The access log confirms it:

```text
172.16.0.1 - - [09/Nov/2026:19:51:33 +0000] "GET / HTTP/1.1" 503 19 "-" "curl/8.7.1" 41
  "dbg-08-shop-shop-dbg08-example@kubernetes" "-" 0ms
```

The second-to-last field shows the server URL that Traefik forwarded to. `"-"` means: there was no server. So the cause is not in the Ingress but one layer further down. From here on, the chain from Chapter 7 applies: look at the EndpointSlice, then at the readiness of the pods.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-08 events --types=Warning
```][The probe events are attached to the pods, not to the Deployment. They say `Readiness probe failed: dial tcp 10.42.1.31:8080: connect: connection refused`. In k9s: `:events dbg-08⏎`.]

#ursache[
  The readiness probe checks a port where nobody listens. The pods are running, but they never count as ready. The EndpointSlice controller adds them with `ready: false`. Traefik only takes ready endpoints, so it has no server for the Service.
]

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/08-ingress/fix-bereit.yaml
kubectl --context rke2 -n dbg-08 rollout status deploy/shop
```][The probe now checks the path `/health` via HTTP on the named port `http`. whoami answers it with `200`.]

#pruefe[
  Both pods show `1/1`, `curl -i` returns `HTTP/1.1 200 OK`, and the access log shows a server URL like `"http://10.42.1.34:80"`.
]

#tabelle(
  (auto, 1fr),
  ([Status], [What it means in Traefik]),
  [404], [No route: wrong class, wrong host or path, backend service cannot be built],
  [503], [Route exists, but no ready endpoints],
  [502], [Endpoint exists, but the connection to the pod fails, for example a wrong `targetPort` (Chapter 7)],
  [504], [Pod accepts the connection but does not answer in time],
)

== TLS: The Wrong Certificate

For HTTPS, the Ingress needs a Secret with a certificate and a key. Because keys do not belong in the repo, you create them with a script.

The script `szenarien/08-ingress/zertifikat.sh` creates a lab CA once and uses it to sign a certificate for `shop.dbg08.example`. Pass `gueltig` (valid) for a certificate that is valid for 30 days, or `abgelaufen` (expired) for one that expired in February 2025. The files end up in `szenarien/08-ingress/tls/`, which `.gitignore` keeps out of the repo. For the expired certificate, the script uses `openssl x509 -not_before/-not_after`, which only exists since OpenSSL 3.4. The LibreSSL that comes with macOS is not enough, so use OpenSSL from Homebrew.

=== Secret with the Wrong Key Names

#cmd("Mac")[```bash
szenarien/08-ingress/zertifikat.sh gueltig
kubectl --context rke2 -n dbg-08 create secret generic shop-tls \
  --from-file=cert.pem=szenarien/08-ingress/tls/shop.crt \
  --from-file=key.pem=szenarien/08-ingress/tls/shop.key
kubectl --context rke2 apply -f szenarien/08-ingress/ingress-tls.yaml
```][A generic Secret with the file names as keys. For type `Opaque`, the API checks nothing. `ingress-tls.yaml` is the Ingress from `fix-ingress.yaml` plus a `tls` section with `secretName: shop-tls`.]

#cmd("Mac")[```bash
curl -sS --cacert szenarien/08-ingress/tls/ca.crt \
  --resolve shop.dbg08.example:443:172.16.0.161 https://shop.dbg08.example/
openssl s_client -connect 172.16.0.161:443 -servername shop.dbg08.example </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```][First the call that verifies against the lab CA, then a look at the certificate that Traefik actually serves.]

#symptom[
  ```text
  curl: (60) SSL certificate problem: self-signed certificate
  subject=CN=TRAEFIK DEFAULT CERT
  issuer=CN=TRAEFIK DEFAULT CERT
  ```
  Traefik serves its own self-generated default certificate, not the one from the Secret. With `curl -k` the page works, and that is exactly why the error often shows up late in the browser.
]

#cmd("Mac")[```bash
kubectl --context rke2 -n kube-system logs -l app.kubernetes.io/name=rke2-traefik \
  --since=5m | grep 'configuring TLS'
kubectl --context rke2 -n dbg-08 get secret shop-tls -o jsonpath='{.type}{"\n"}'
```][Traefik names the error word for word. The Secret reveals its type, and `kubectl describe secret shop-tls` shows the keys `cert.pem` and `key.pem`.]

```text
2026-11-09T20:03:12Z ERR Error configuring TLS error="secret dbg-08/shop-tls is missing
  the following TLS data entries: tls.crt, tls.key" ingress=shop namespace=dbg-08 providerName=kubernetes
Opaque
```

#ursache[
  Ingress controllers expect a Secret of type `kubernetes.io/tls` with exactly the keys `tls.crt` and `tls.key`. Traefik does not find the keys, discards the certificate and uses the default certificate for the host. The route itself stays active, which is why HTTPS keeps working with `-k`.
]

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-08 delete secret shop-tls
kubectl --context rke2 -n dbg-08 create secret tls shop-tls \
  --cert=szenarien/08-ingress/tls/shop.crt --key=szenarien/08-ingress/tls/shop.key
```][`create secret tls` sets the type and keys correctly. For this type, the API rejects a Secret without `tls.crt` or `tls.key` right away. Traefik notices the new Secret on its own, no restart needed.]

#pruefe[
  `curl --cacert ... https://shop.dbg08.example/` returns the whoami response without `-k`, and `openssl s_client` shows `subject=CN=shop.dbg08.example` and `issuer=CN=dbg-08 Labor-CA`.
]

=== Expired Certificate

#cmd("Mac")[```bash
szenarien/08-ingress/zertifikat.sh abgelaufen
kubectl --context rke2 -n dbg-08 create secret tls shop-tls \
  --cert=szenarien/08-ingress/tls/shop.crt --key=szenarien/08-ingress/tls/shop.key \
  --dry-run=client -o yaml | kubectl --context rke2 apply -f -
curl -sS --cacert szenarien/08-ingress/tls/ca.crt \
  --resolve shop.dbg08.example:443:172.16.0.161 https://shop.dbg08.example/
```][Replaces the Secret with the expired certificate. `--dry-run=client -o yaml | apply` is the usual pattern for overwriting an existing Secret.]

#symptom[
  ```text
  curl: (60) SSL certificate problem: certificate has expired
  ```
  Traefik logs nothing. For Traefik, the Secret is formally fine, and it serves the certificate.
]

Here only a look at the served certificate itself helps. `openssl s_client ... | openssl x509 -noout -subject -dates` shows `notAfter=Feb  1 00:00:00 2025 GMT`. The same date is in the Secret, which you can check without the network:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-08 get secret shop-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -enddate -checkend 0
```][`-checkend 0` checks whether the certificate is still valid right now and answers with `Certificate will expire` and exit code 1. With `-checkend 1209600` you check the next 14 days. That works well for a cron job or an alert rule.]

#ursache[
  Neither Kubernetes nor Traefik checks how long a certificate is valid. That is the client's job. Without cert-manager or another renewal mechanism, every certificate silently expires at some point, and the first sign is an error on the user's side.
]

To fix it, create a new certificate from the same CA with `zertifikat.sh gueltig` and replace the Secret with the same `--dry-run=client -o yaml | apply` pattern.

#pruefe[
  `curl --cacert ...` returns the whoami response again, and `-checkend 0` reports `Certificate will not expire`.
]

#distro(
  [All scenarios work as shown. Traefik pods are in the namespace `kube-system`, label `app.kubernetes.io/name=rke2-traefik`. You change values through the `HelmChartConfig` `rke2-traefik`, never with `helm upgrade`, otherwise the Helm controller overwrites your change.],
  [Replace `--context rke2` with `--context talos` and `172.16.0.161` with `172.16.0.171`. Traefik pods are in the namespace `traefik`, label `app.kubernetes.io/name=traefik`. You change values with `helm upgrade` and `werkzeuge/traefik-values-talos.yaml`.],
)

== The Dashboard and the Gateway API

The Traefik dashboard shows all routers, services and middlewares that Traefik has built from the Ingresses, including errors and warnings. It runs on the internal entrypoint `traefik` (port 8080) and cannot be reached from the outside:

#cmd("Mac")[```bash
kubectl --context rke2 -n kube-system port-forward ds/rke2-traefik 8080:8080
```][Then open `http://localhost:8080/dashboard/` in your browser. On Talos the command is `kubectl --context talos -n traefik port-forward ds/traefik 8080:8080`. In k9s you get the same with `Shift-f` on a Traefik pod.]

An Ingress that is missing from the dashboard under *HTTP Routers* was not processed.

The Gateway API is the successor of Ingress: `GatewayClass` and `Gateway` belong to the platform team, `HTTPRoute` belongs to the application team. RKE2 1.36 ships the Gateway API CRDs together with Traefik, but Traefik's Gateway provider is off. You turn it on with `providers.kubernetesGateway.enabled: true` in the `HelmChartConfig`. Starting with RKE2 1.37, the CRDs come from a separate chart. On Talos you install them yourself. For troubleshooting, the Gateway API is nicer because it sets status conditions: `kubectl describe httproute` shows `Accepted` and `ResolvedRefs` with reasons like `BackendNotFound` or `NotAllowedByListeners` instead of a silent 404.

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-08
rm -f szenarien/08-ingress/tls/*.crt szenarien/08-ingress/tls/*.key szenarien/08-ingress/tls/*.srl
```][Cleans up the namespace and deletes the generated certificates and keys.]

#aufgabe[
  Repeat the scenario from “404: The Controller Does Not Feel Responsible” on Talos, but remove the `ingressClassName` line completely instead of setting it to `traefik`. Does the Ingress work? Why?

  Hint: an Ingress without a class gets the default class when it is created, which is the IngressClass with the annotation `ingressclass.kubernetes.io/is-default-class: "true"`. In `traefik-values-talos.yaml`, `isDefaultClass: true` sets exactly this annotation. If there is no default class, the field stays empty, and whether a controller feels responsible depends on its configuration. So always set the class explicitly.
]

#gelernt(
  [RKE2 1.36 ships Traefik as a DaemonSet with hostPorts 80/443 and the IngressClass `traefik`. You set values through the `HelmChartConfig` `rke2-traefik`. On Talos you install the same behavior with Helm, in a namespace with PSA `privileged`.],
  [`curl --resolve` tests host rules and SNI without a DNS entry.],
  [404 without a log: Traefik is not responsible (class), or host and path do not match. 404 with `Cannot create service`: the Ingress points to a port that the Service does not have.],
  [In Traefik, 503 means: the route exists, but there are no ready endpoints. Continue with the EndpointSlice and readiness.],
  [`TRAEFIK DEFAULT CERT` points to an unusable TLS Secret. Only the client reports expired certificates, and you can check them with `openssl x509 -checkend`.],
)
