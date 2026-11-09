#import "../lib.typ": *

#kapitel(
  [Services, DNS and NetworkPolicies],
  ziel: [You follow a request from the client pod through the name, the Service and the EndpointSlice to the target pod. You can tell at which stop it gets stuck, and you know why a NetworkPolicy works on RKE2 and not on Talos.],
  zeit: [75 minutes],
  braucht: [Chapters 2 and 3],
)

== What Breaks in This Chapter

A request to `http://backend` passes four stops: DNS turns the name into the IP of the Service, kube-proxy redirects the Service IP to a pod IP from the EndpointSlice, the packet travels through the CNI to the target pod, and there a process has to listen on the port. Each stop has its own typical failure.

#tabelle(
  (auto, 1fr, 1fr),
  ([Scenario], [Symptom], [Stop]),
  [Selector does not match], [`Connection refused` or timeout, Service without endpoints], [EndpointSlice],
  [Wrong `targetPort`], [`Could not connect to server`, even though endpoints exist], [Target pod],
  [Wrong name], [`Could not resolve host`, `NXDOMAIN`], [DNS],
  [Default deny without DNS], [Name does not resolve, IP works], [NetworkPolicy],
  [Policy without effect], [Everything works, even though it should be blocked], [CNI],
)

All tests run from a tool pod `client` with the image `nicolaka/netshoot:v0.15`. It contains `curl`, `dig`, `nslookup`, `ss` and `tcpdump`. The target is `traefik/whoami`, a tiny web server on port 80 that includes its own pod name in its response. That way you see right away which pod answered.

== The Service Finds No Pods

#datei("szenarien/07-netzwerk/kaputt-selektor.yaml (excerpt)", ```yaml
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
    app: backend-api        # ERROR: the pods are labeled app=backend
  ports:
    - name: http
      port: 80
      targetPort: 80
```, erklaerung: [The full file creates the namespace `dbg-07`, the pod `client`, the Deployment and the Service. The Service selector looks for a label that no pod carries.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/kaputt-selektor.yaml
kubectl --context rke2 -n dbg-07 exec client -- curl -sS -m 5 http://backend
```][Creates everything and calls the Service from the client pod. `-m 5` gives up after five seconds, `-sS` hides the progress bar but still shows errors.]

#symptom[
  ```text
  curl: (7) Failed to connect to backend port 80 after 3 ms: Could not connect to server
  command terminated with exit code 7
  ```
  The name resolves, otherwise you would get `Could not resolve host`. The connection fails immediately. Depending on the proxy mode and the CNI, you may see a timeout after five seconds instead of an immediate rejection. Both mean the same thing: nobody is waiting behind the Service IP.
]

The first question is not “What is wrong with the network?” but “Does the Service have any targets at all?”. The answer is in the EndpointSlice, which the EndpointSlice controller maintains for every Service with a selector.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 get endpointslices -l kubernetes.io/service-name=backend
```][Every EndpointSlice carries the label `kubernetes.io/service-name` with the name of its Service. The older `kubectl get endpoints` still works, but since Kubernetes 1.33 it prints a deprecation warning.]

```text
NAME            ADDRESSTYPE   PORTS     ENDPOINTS   AGE
backend-7xqzl   IPv4          <unset>   <unset>     41s
```

`<unset>` in the `ENDPOINTS` column means: not a single pod matches. Now compare the selector and the labels directly:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 get svc backend -o jsonpath='{.spec.selector}{"\n"}'
kubectl --context rke2 -n dbg-07 get pods --show-labels
```][The first line shows what the Service looks for, the second what the pods carry.]

```text
{"app":"backend-api"}
NAME                       READY   STATUS    RESTARTS   AGE   LABELS
backend-5b8d9f6c7d-4kq2m   1/1     Running   0          58s   app=backend,pod-template-hash=...
backend-5b8d9f6c7d-xv7jt   1/1     Running   0          58s   app=backend,pod-template-hash=...
client                     1/1     Running   0          58s   app=client
```

The cross-check with the Service selector returns an empty list: `kubectl --context rke2 -n dbg-07 get pods -l app=backend-api` answers `No resources found in dbg-07 namespace.` In k9s you see the same thing as a tree:

#cmd("k9s")[```text
:xray svc dbg-07⏎
```][XRay shows every Service with the pods it reaches below it. Nothing hangs below `backend`. With `Esc` and `:pods dbg-07⏎` you get to the pod list, and `y` on a pod shows its labels in the YAML.]

#ursache[
  A Service is just a selector plus a virtual IP. The EndpointSlice controller keeps looking for all pods in the namespace whose labels match the selector and that are ready, and it adds them to the EndpointSlice. If no pod matches, the slice stays empty, and kube-proxy has no target for the Service IP. Kubernetes does not report this as an error anywhere. There is no event and no status. You get the same empty slice when the selector is right but the pods are not ready (Chapter 6). `0/1` in `kubectl get pods` points to the probe, `1/1` to the selector.
]

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/fix-service.yaml
kubectl --context rke2 -n dbg-07 get endpointslices -l kubernetes.io/service-name=backend
```][Replaces the selector with `app: backend`. The file also uses `targetPort: http` to point to the named port from the pod template instead of a number.]

#pruefe[
  ```text
  NAME            ADDRESSTYPE   PORTS   ENDPOINTS               AGE
  backend-7xqzl   IPv4          80      10.42.0.21,10.42.1.17   2m
  ```
  Two pod IPs, port 80. `kubectl --context rke2 -n dbg-07 exec client -- curl -s http://backend` answers with `Hostname: backend-5b8d9f6c7d-...`. If you call it several times, the name switches between the two pods.
]

== Endpoints Exist, Connection Still Refused

#datei("szenarien/07-netzwerk/kaputt-port.yaml (excerpt)", ```yaml
spec:
  selector:
    app: backend
  ports:
    - name: http
      port: 80
      targetPort: 8080      # ERROR: whoami listens on port 80
```)

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/kaputt-port.yaml
kubectl --context rke2 -n dbg-07 exec client -- curl -sS -m 5 http://backend
```][This time the selector is right, only the target port is wrong.]

#symptom[
  Again `curl: (7) Failed to connect to backend port 80 ... Could not connect to server`. But this time the EndpointSlice is filled:
  ```text
  NAME            ADDRESSTYPE   PORTS   ENDPOINTS               AGE
  backend-7xqzl   IPv4          8080    10.42.0.21,10.42.1.17   4m
  ```
]

The `PORTS` column already gives the error away: the slice shows the port on which the *pod* is addressed, not the Service port. To be sure, ask the pod directly and bypass the Service:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 exec client -- curl -s -o /dev/null -w '%{http_code}\n' http://10.42.0.21:80
```][Calls a pod IP from the slice directly on port 80 and prints only the HTTP status: `200`. The same call on port 8080 is refused.]

You see which ports a container has really opened with `ss`. The whoami image contains no shell and no `ss`. But an ephemeral container with netshoot shares the network namespace of the pod and sees the same sockets:

#cmd("Mac")[```bash
POD=$(kubectl --context rke2 -n dbg-07 get pod -l app=backend -o name | head -n1)
kubectl --context rke2 -n dbg-07 debug -it "$POD" \
  --image=nicolaka/netshoot:v0.15 --profile=baseline --target=whoami -- ss -tlnp
```][`--target=whoami` also attaches the debug container to the process namespace of the container `whoami`, so `ss` shows the process name too. `--profile=baseline` is not needed on RKE2, but it is required on Talos: the default profile `general` adds `SYS_PTRACE`, and Talos' PSA `baseline` rejects that. In k9s, the plugin from Chapter 3 does the same step: `Shift-D` in the container view of the pod.]

```text
State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      4096               *:80              *:*     users:(("whoami",pid=1,fd=3))
```

#ursache[
  `targetPort` is the port in the pod that kube-proxy forwards the packets to. Nobody listens there, so the pod's kernel answers with a TCP reset. The Service, the EndpointSlice and the pods are all “healthy”. Only their agreement on the port is wrong. Named ports (`targetPort: http`) avoid this error, because the port number then lives in only one place: the pod template.
]

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/fix-service.yaml
```][Sets `targetPort` back to the named port `http`.]

#pruefe[
  The EndpointSlice shows port `80`, and `curl -s http://backend` from the client pod returns the whoami response.
]

== Names, Namespaces and ndots

DNS errors look different from connection errors: `curl: (6) Could not resolve host`. Before you suspect CoreDNS, look at how the pod resolves names.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 exec client -- cat /etc/resolv.conf
```][The kubelet writes this file when the pod starts.]

```text
search dbg-07.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.43.0.10
options ndots:5
```

With `ndots:5`, every name with fewer than five dots counts as relative. The resolver then appends the search domains one after the other. `backend` first becomes `backend.dbg-07.svc.cluster.local`, and that exists. `backend.dbg07` (a typo, the hyphen is missing) becomes `backend.dbg07.dbg-07.svc.cluster.local`, then `backend.dbg07.svc.cluster.local`, then `backend.dbg07.cluster.local` and finally `backend.dbg07.` as an absolute name. All four queries end with `NXDOMAIN`.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 exec client -- nslookup backend.dbg07
kubectl --context rke2 -n dbg-07 exec client -- nslookup backend.dbg-07
```][The first name is misspelled, the second is the correct short form `<service>.<namespace>`.]

```text
** server can't find backend.dbg07: NXDOMAIN
# ...
Name:   backend.dbg-07.svc.cluster.local
Address: 10.43.118.204
```

In practice, the most common case is not a typo but a missing namespace: an application in `dbg-07` calls `postgres`, but the Service lives in `datenbank`. The short name only works in your own namespace. Across namespaces you need at least `postgres.datenbank`. In the lab, CoreDNS itself is a good example, because its Service has a different name on each cluster:

#cmd("Mac")[```bash
kubectl --context rke2 -n kube-system get svc -l k8s-app=kube-dns
kubectl --context talos -n kube-system get svc -l k8s-app=kube-dns
```][Both distributions set the label `k8s-app=kube-dns`, but the names differ.]

```text
NAME                        TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)         AGE
rke2-coredns-rke2-coredns   ClusterIP   10.43.0.10   <none>        53/UDP,53/TCP   3d
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   3d
```

So a script that queries `kube-dns.kube-system` works on Talos and fails on RKE2 with `NXDOMAIN`. This book is about differences like that.

=== Investigating CoreDNS Itself

Only when `kubernetes.default` does not resolve either is the problem in CoreDNS or on the way there.

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 exec client -- dig +short kubernetes.default.svc.cluster.local
kubectl --context rke2 -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl --context rke2 -n kube-system logs deploy/rke2-coredns-rke2-coredns --tail=20
```][First the function, then the pods, then their logs. `dig +short` returns only the address, on RKE2 `10.43.0.1`.]

In k9s: `:pods kube-system⏎`, then `/coredns⏎`, `l` for the logs and `d` for restarts and probes.

Messages like `[ERROR] plugin/errors: 2 example.org. A: read udp ...: i/o timeout` mean that CoreDNS cannot reach its upstream server. This only affects external names. CoreDNS answers internal names like `backend.dbg-07.svc.cluster.local` itself, from the Kubernetes API.

#distro(
  [Deployment and Service are called `rke2-coredns-rke2-coredns`, and the Corefile is in the ConfigMap of the same name. You do not make changes there, but through a `HelmChartConfig` named `rke2-coredns` in `kube-system`. Otherwise the Helm controller overwrites them. Service IP `10.43.0.10`, the upstream is the node's `/etc/resolv.conf`.],
  [Deployment `coredns`, Service `kube-dns`, ConfigMap `coredns`, Service IP `10.96.0.10`. For new clusters, Talos enables `forwardKubeDNSToHost`: CoreDNS sends external queries to the node's DNS cache at `169.254.116.108`. You then look for upstream errors on the node: `talosctl -n 172.16.0.171 get dnsupstream` shows whether the upstream servers are reachable, and `talosctl -n 172.16.0.171 logs dns-resolve-cache` shows the cache logs.],
)

== Default Deny Blocks DNS

A NetworkPolicy that selects everything with `podSelector: {}` and lists `Egress` blocks all outgoing traffic that no other policy makes an exception for. That includes DNS.

#datei("szenarien/07-netzwerk/kaputt-policy.yaml (excerpt)", ```yaml
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
# ... plus backend-von-client: ingress to backend only from client
```, erklaerung: [The idea was: everything is closed, only the client may reach the backend. What was forgotten: the client first has to resolve the name `backend`.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/kaputt-policy.yaml
kubectl --context rke2 -n dbg-07 exec client -- curl -sS -m 10 http://backend
```][Applies the three policies and tests again with `curl`.]

#symptom[
  ```text
  curl: (6) Could not resolve host: backend
  command terminated with exit code 6
  ```
  The message appears after a few seconds of waiting. The call via the Service IP, for example `curl -s http://10.43.118.204`, on the other hand works right away.
]

This pattern is clear: the IP works, the name does not. To confirm it, ask the DNS server directly:

#cmd("Mac")[```bash
kubectl --context rke2 -n dbg-07 exec client -- dig +time=2 +tries=1 backend.dbg-07.svc.cluster.local
kubectl --context rke2 -n dbg-07 get networkpolicy
```][Without an answer, `dig` reports a timeout. Then you list all policies in the namespace.]

```text
;; communications error to 10.43.0.10#53: timed out
;; no servers could be reached

NAME                 POD-SELECTOR   AGE
backend-von-client   app=backend    1m
client-zu-backend    app=client     1m
default-deny         <none>         1m
```

`<none>` for `default-deny` means: empty selector, the policy applies to every pod in the namespace. With `kubectl describe networkpolicy client-zu-backend` you see the allowed targets spelled out. Port 53 does not show up anywhere. In k9s, open `:netpol dbg-07⏎` and press `d` on the highlighted policy.

#ursache[
  NetworkPolicies are allowlists, and they add up. As soon as any policy selects a pod for `Egress`, all outgoing traffic that no policy explicitly allows is blocked for that pod. The query to CoreDNS is outgoing traffic to a pod in `kube-system` on UDP and TCP port 53. Because the policy applies after the Service IP has been translated to the pod IP, the rule must select the CoreDNS pods, not the Service IP.
]

#datei("szenarien/07-netzwerk/fix-policy.yaml (excerpt)", ```yaml
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
```, erklaerung: [`namespaceSelector` and `podSelector` are in the *same* list entry, so both apply at once: CoreDNS pods in `kube-system`. With a hyphen in front of `podSelector` they would be two entries, and the rule would allow all pods in `kube-system` *or* all pods with `k8s-app=kube-dns` in `dbg-07`. Kubernetes sets the label `kubernetes.io/metadata.name` on every namespace automatically.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/07-netzwerk/fix-policy.yaml
kubectl --context rke2 -n dbg-07 exec client -- curl -s -m 10 http://backend
```][Adds a fourth policy that allows DNS for all pods in the namespace.]

#pruefe[
  `curl` returns the whoami response right away. The cross-check shows that everything else stays closed: `kubectl --context rke2 -n dbg-07 exec client -- curl -sS -m 5 https://kubernetes.io` ends with a timeout, because `client` may only reach `backend`.
]

#falle[
  Do not forget TCP port 53. DNS falls back to TCP when an answer does not fit into a UDP packet. With UDP only, most queries work, but some large answers fail now and then, and troubleshooting becomes tedious.
]

== The Policy That Does Nothing

Now the same on Talos. Apply the broken policy, this time expecting DNS to fail:

#cmd("Mac")[```bash
kubectl --context talos apply -f szenarien/07-netzwerk/kaputt-selektor.yaml \
  -f szenarien/07-netzwerk/fix-service.yaml -f szenarien/07-netzwerk/kaputt-policy.yaml
kubectl --context talos -n dbg-07 exec client -- curl -s -m 5 http://backend
kubectl --context talos -n dbg-07 exec client -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' https://kubernetes.io
```][Rebuilds the starting point of this chapter and tests both the allowed and a blocked path. During `apply` you see warnings `would violate PodSecurity "restricted:latest"`. These are only warnings, Talos enforces `baseline`.]

#symptom[
  Both calls work. `curl http://backend` returns the whoami response, and the call to the internet returns an HTTP status instead of a timeout. The policies exist, `kubectl get networkpolicy -n dbg-07` lists all three. There is no error and no warning.
]

The Kubernetes API stores NetworkPolicies, but it does not enforce them itself. The CNI plugin does that. `kubectl --context talos -n kube-system get ds` shows which CNI is running: on Talos you find `kube-flannel`, on RKE2 `rke2-canal`.

#ursache[
  Talos installs Flannel by default. Flannel only builds the overlay network between the nodes and knows nothing about NetworkPolicies. The API still accepts the objects, because they are part of core Kubernetes. Nobody evaluates them. Canal on RKE2 combines Flannel for the overlay with the policy part of Calico (Felix), which turns the rules into iptables rules on every node.
]

Here the solution is not a patch but an architecture decision. On Talos you set `cluster.network.cni.name: none` when you generate the machine config, and then install Cilium or Calico yourself. On a running cluster, switching the CNI is a rebuild with downtime, not a quick fix. That is why Talos stays on Flannel in the lab, and this scenario stays a demonstration.

#distro(
  [Canal enforces NetworkPolicies. Felix writes the rules into iptables chains with the prefix `cali-`. On the node, `sudo iptables-save | grep -c cali-` gives you a rough count. A new policy takes effect after a few seconds.],
  [Flannel ignores NetworkPolicies completely. If you need policies on Talos, you have to replace the CNI when you build the cluster (`cni.name: none` plus Cilium or Calico). The Talos docs describe both options.],
)

#warum[
  Test every policy with a cross-check that *must* fail. A green test of the allowed path only proves that the policy does not block too much. Only the blocked path shows you whether it blocks anything at all. On Talos you would never have noticed the problem otherwise.
]

#cmd("Mac")[```bash
kubectl --context rke2 delete ns dbg-07
kubectl --context talos delete ns dbg-07
```][Cleans up both clusters. Policies, Services and pods disappear with the namespace.]

#aufgabe[
  Apply `kaputt-selektor.yaml` and `fix-service.yaml` on RKE2 again. Then add a second label `version: v2` to the selector of the Service `backend` (`kubectl edit svc backend` or `e` in k9s). What does the EndpointSlice show, and what does `curl` show? How do you get the Service filled again without taking the selector back?

  Hint: the labels of a selector are combined with AND. No pod carries `version: v2`, so the slice becomes empty. Add the label to the pod template of the Deployment (not to the Deployment's `selector`, which is immutable). After the rollout, the slice fills up again.
]

#gelernt(
  [Check the EndpointSlice first: a Service without endpoints is a selector or readiness problem, not a network problem.],
  [The `PORTS` column of the EndpointSlice shows the port in the pod. Named ports prevent mismatches between Service and pod.],
  [`ndots:5` and the search domains explain why short names only work in your own namespace. CoreDNS is called `rke2-coredns-rke2-coredns` on RKE2, and `coredns` or `kube-dns` on Talos.],
  [A default deny policy with `Egress` needs an exception for UDP and TCP 53 to the CoreDNS pods.],
  [NetworkPolicies only work if the CNI enforces them: Canal on RKE2 does, Flannel on Talos does not. Every policy needs a cross-check that must fail.],
)
