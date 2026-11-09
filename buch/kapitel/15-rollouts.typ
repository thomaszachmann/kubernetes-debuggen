#import "../lib.typ": *

#kapitel(
  [Rollouts, Autoscaling und Helm],
  ziel: [Du erkennst hängende Rollouts und rollst sie zurück, bringst einen HPA mit `<unknown>` zum Messen, installierst dafür auf Talos den metrics-server, befreist ein festgefahrenes Helm-Release und liest, warum Jobs aufgeben und ConfigMap-Änderungen nicht ankommen.],
  zeit: [75 Minuten],
  braucht: [Kapitel 2, 3 und 6],
)

== Was in diesem Kapitel kaputtgeht

Die Fehler dieses Kapitels entstehen nicht beim ersten Deployment, sondern bei der zweiten Version, beim Skalieren und beim Automatisieren. Typisch für sie: Nichts stürzt sichtbar ab. Die alte Version läuft weiter, der HPA tut nichts, Helm verweigert sich. Wer nicht nachsieht, merkt es erst Tage später.

#tabelle(
  (auto, 1fr, 1fr),
  ([Szenario], [Symptom], [Wo die Antwort steht]),
  [Rollout hängt], [`rollout status` endet mit `exceeded its progress deadline`], [Condition `Progressing`, Events des neuen Pods],
  [HPA misst nicht], [`TARGETS` zeigt `cpu: <unknown>/50%`], [Events des HPA, `kubectl top`],
  [Helm-Release hängt], [`another operation ... is in progress`], [`helm history`, Status `pending-upgrade`],
  [Job gibt auf], [Job `Failed`, mehrere Pods `Error`], [Condition und Event `BackoffLimitExceeded`],
  [ConfigMap ohne Wirkung], [Pod zeigt den alten Wert], [Wie die ConfigMap eingebunden ist],
)

Alle Szenarien laufen im Namespace `dbg-15`. Die Manifeste erfüllen `restricted`, auf Talos gibt es also keine Warnungen der Pod Security Admission.

== Der Rollout hängt

Ein Deployment tauscht Pods schrittweise aus. Mit `maxSurge: 1` und `maxUnavailable: 0` startet es zuerst einen neuen Pod und entfernt erst dann einen alten, wenn der neue ready ist. Wird er nie ready, bleibt der Rollout stehen. Nach `progressDeadlineSeconds` erklärt der Deployment-Controller ihn für gescheitert, rollt aber nichts zurück.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/web-v1.yaml
kubectl --context rke2 rollout status deploy/web -n dbg-15
```][Version 1 mit drei Replikas. `rollout status` endet mit `deployment "web" successfully rolled out`.]

#datei("szenarien/15-rollouts/kaputt-rollout.yaml (Ausschnitt)", ```yaml
  annotations:
    kubernetes.io/change-cause: "v2: httpd auf 8081"
spec:
  progressDeadlineSeconds: 60
# ...
          command: ["httpd", "-f", "-p", "8081", "-h", "/tmp"]
          readinessProbe:
            tcpSocket:
              port: 8080
```, erklaerung: [Version 2 lauscht auf einem neuen Port, die Readiness-Probe prüft weiter den alten. Die Frist ist mit 60 Sekunden kurz, der Standard sind 600.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/kaputt-rollout.yaml
kubectl --context rke2 rollout status deploy/web -n dbg-15
```][Startet den Rollout auf Version 2 und beobachtet ihn.]

#symptom[
```text
Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been
updated...
error: deployment "web" exceeded its progress deadline
```
Die Anwendung antwortet trotzdem: `kubectl get deploy -n dbg-15` zeigt `READY 3/3`, `UP-TO-DATE 1`. Die drei alten Pods laufen weiter.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 describe deploy web -n dbg-15 \
  | sed -n '/^Conditions/,/^Events/p'
kubectl --context rke2 get rs,pods -n dbg-15 -l app=web
```][Die Conditions des Deployments, dann die ReplicaSets und Pods. Das neue ReplicaSet hat einen Pod, der `0/1` ready ist.]

```text
Conditions:
  Type           Status  Reason
  ----           ------  ------
  Available      True    MinimumReplicasAvailable
  Progressing    False   ProgressDeadlineExceeded
```

`Available True` und `Progressing False` zusammen heißen: Die Anwendung läuft, aber die neue Version kommt nicht an. Den Grund liefert der neue Pod:

#cmd("Mac")[```bash
kubectl --context rke2 events -n dbg-15 --types=Warning
```][Nur Warnungen im Namespace.]

```text
LAST SEEN   TYPE      REASON      OBJECT                    MESSAGE
4s          Warning   Unhealthy   pod/web-6d5f8c9b7-tq4lz   Readiness probe ...
```

Die volle Message lautet `Readiness probe failed: dial tcp 10.42.1.23:8080: connect: connection refused`. In k9s öffnest du mit `:deploy dbg-15` die Deployments und mit `z` die ReplicaSets des gewählten Eintrags. Mit `Enter` gehst du weiter zu den Pods, mit `d` zu den Events.

#ursache[
  Der neue Pod lauscht auf 8081, die Readiness-Probe klopft auf 8080 und bekommt `connection refused`. Der Pod wird nie ready, also entfernt das Deployment keinen alten Pod und startet keinen weiteren neuen. Nach 60 Sekunden ohne Fortschritt setzt der Controller `Progressing=False` mit `ProgressDeadlineExceeded`. Das ist nur eine Meldung, der Rollout bleibt in diesem Zustand stehen.
]

=== Beheben

#cmd("Mac")[```bash
kubectl --context rke2 rollout history deploy/web -n dbg-15
kubectl --context rke2 rollout undo deploy/web -n dbg-15
```][`history` listet die Revisionen mit der `change-cause`-Annotation. `undo` geht auf die vorherige Revision zurück, mit `--to-revision=<n>` auf eine bestimmte.]

```text
REVISION  CHANGE-CAUSE
1         v1: httpd auf 8080
2         v2: httpd auf 8081
```

Danach rollst du die korrigierte Version aus, in der Probe und Port zusammenpassen:

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/fix-rollout.yaml
kubectl --context rke2 rollout status deploy/web -n dbg-15
```][Version 2 mit `readinessProbe` auf Port 8081.]

#pruefe[
  `deployment "web" successfully rolled out`, `kubectl --context rke2 get deploy web -n dbg-15` zeigt `3/3` bei `UP-TO-DATE 3`. In `rollout history` steht jetzt die neue `change-cause`.
]

#falle[
  `kubectl apply` meldet bei einem kaputten Rollout `configured` und endet erfolgreich. Pipelines, die nur `apply` ausführen, merken nichts. Ein `kubectl rollout status --timeout=...` danach liefert bei überschrittener Frist einen Exit-Code ungleich 0 und lässt die Pipeline scheitern.
]

== Der HPA misst nicht

Ein HorizontalPodAutoscaler mit dem Ziel `averageUtilization: 50` rechnet so: aktueller CPU-Verbrauch geteilt durch den CPU-Request, gemittelt über alle Pods. Dafür braucht er zwei Dinge: Messwerte aus der Resource-Metrics-API (`metrics.k8s.io`, geliefert vom metrics-server) und einen Request in jedem Container.

#datei("szenarien/15-rollouts/kaputt-hpa.yaml (Ausschnitt)", ```yaml
      containers:
        - name: rechner
          image: busybox:1.37
          resources:
            limits:
              memory: 32Mi
---
kind: HorizontalPodAutoscaler
spec:
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```, erklaerung: [Kein CPU-Request im Container. 50 Prozent von nichts lassen sich nicht berechnen.])

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/kaputt-hpa.yaml
kubectl --context talos apply -f szenarien/15-rollouts/kaputt-hpa.yaml
```][Dasselbe Manifest auf beiden Clustern.]

#symptom[
```text
$ kubectl --context rke2 get hpa -n dbg-15
NAME      REFERENCE            TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
rechner   Deployment/rechner   cpu: <unknown>/50%   1         4         1          2m
```
Auf beiden Clustern dasselbe Bild. Die Ursachen sind aber verschieden.
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 describe hpa rechner -n dbg-15 | sed -n '/^Conditions/,$p'
kubectl --context talos describe hpa rechner -n dbg-15 | sed -n '/^Events/,$p'
```][Conditions und Events des HPA auf beiden Clustern.]

Auf RKE2 steht in der Condition `ScalingActive False` mit dem Reason `FailedGetResourceMetric`, das Event lautet:

```text
failed to get cpu utilization: missing request for cpu in container rechner
of Pod rechner-7b9c6d8f5-l2kxn
```

Auf Talos scheitert es schon einen Schritt früher:

```text
failed to get cpu utilization: unable to get metrics for resource cpu: unable
to fetch metrics from resource metrics API: the server could not find the
requested resource (get pods.metrics.k8s.io)
```

#cmd("Mac")[```bash
kubectl --context talos top pods -n dbg-15
kubectl --context talos get apiservice v1beta1.metrics.k8s.io
```][Auf Talos meldet `top` `error: Metrics API not available`, die APIService gibt es nicht (`NotFound`). Auf RKE2 liefert beides Werte, dort läuft `rke2-metrics-server`.]

In k9s zeigt `:hpa dbg-15` die HPAs, `d` die Describe-Ansicht mit den Events. Fehlt die Metrics-API, bleiben in k9s auch die Spalten für CPU und Speicher in der Pod-Ansicht leer.

#ursache[
  Auf RKE2 fehlt der CPU-Request: Der HPA bekommt Messwerte, kann sie aber nicht in Prozent umrechnen. Auf Talos fehlt zusätzlich die Messquelle, weil Talos keinen metrics-server mitbringt. In beiden Fällen setzt der HPA `ScalingActive=False` und ändert die Replikazahl nicht, weder nach oben noch nach unten.
]

=== Beheben auf Talos: metrics-server installieren

metrics-server holt seine Werte über HTTPS vom Kubelet jedes Knotens. Das Kubelet von Talos signiert sein Serving-Zertifikat standardmäßig selbst, metrics-server würde es ablehnen. Die Talos-Doku beschreibt deshalb drei Schritte: Das Kubelet beantragt sein Zertifikat bei der Cluster-CA, ein Approver genehmigt diese Anträge, dann kommt der metrics-server.

#datei("labor/talos/patch-kubelet-serving-certs.yaml (Ausschnitt)", ```yaml
apiVersion: v1alpha1
kind: KubeletConfig
extraArgs:
  rotate-server-certificates: "true"
```, erklaerung: [Das Kubelet stellt dann einen CertificateSigningRequest mit dem Signer `kubernetes.io/kubelet-serving`.])

#cmd("Mac")[```bash
talosctl -n 172.16.0.170,172.16.0.171 patch mc \
  --patch @labor/talos/patch-kubelet-serving-certs.yaml
kubectl --context talos apply -f https://raw.githubusercontent.com/\
alex1989hu/kubelet-serving-cert-approver/v0.12.1/deploy/standalone-install.yaml
kubectl --context talos get csr
```][Patch auf beiden Knoten, dann der Approver in der festen Version 0.12.1. Die CSRs mit Signer `kubernetes.io/kubelet-serving` stehen nach kurzer Zeit auf `Approved,Issued`.]

#falle[
  Solange die Serving-CSRs auf `Pending` stehen, hat das Kubelet kein Zertifikat. Dann scheitern auch `kubectl logs` und `kubectl exec` auf diesem Knoten mit einem TLS-Fehler. Installiere den Approver deshalb direkt nach dem Patch. Ohne den Patch meldet metrics-server dagegen sinngemäß `x509: cannot validate certificate for 172.16.0.171 because it doesn't contain any IP SANs`. Die Abkürzung `--kubelet-insecure-tls` schaltet die Prüfung ab, die Talos-Doku geht bewusst den sicheren Weg.
]

#datei("werkzeuge/metrics-server-values-talos.yaml (Ausschnitt)", ```yaml
replicas: 1
args: []
resources:
  requests:
    cpu: 50m
    memory: 64Mi
```, erklaerung: [Kein `--kubelet-insecure-tls`. Die Standard-Argumente des Charts fragen das Kubelet über die `InternalIP` und den Port aus dem Node-Status.])

#cmd("Mac")[```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm --kube-context talos upgrade --install metrics-server \
  metrics-server/metrics-server --version 3.14.0 \
  -n kube-system -f werkzeuge/metrics-server-values-talos.yaml --wait
kubectl --context talos top nodes
```][Installiert metrics-server 0.9.0 nach `kube-system`. Nach etwa einer Minute liefert `top nodes` CPU und Speicher beider Knoten.]

Jetzt zeigt auch der Talos-HPA dieselbe Meldung wie RKE2: `missing request for cpu`. Den Request setzt der Fix für beide:

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/fix-hpa.yaml
kubectl --context talos apply -f szenarien/15-rollouts/fix-hpa.yaml
```][Der Container fordert jetzt `cpu: 50m` an.]

#pruefe[
  Nach ein bis zwei Minuten zeigt `kubectl get hpa -n dbg-15` auf beiden Clustern `cpu: 0%/50%` oder einen kleinen Prozentwert. `describe hpa` meldet `ScalingActive True`.
]

#distro(
  [metrics-server ist als `rke2-metrics-server` dabei und wird über den Helm-Controller von RKE2 verwaltet. Anpassungen gehen über eine `HelmChartConfig` in `/var/lib/rancher/rke2/server/manifests/`.],
  [Kein metrics-server, keine Metrics-API. Du installierst ihn selbst, nach dem Muster der Talos-Doku mit Serving-Zertifikaten aus der Cluster-CA. Damit hast du ihn auch selbst zu aktualisieren.],
)

== Das Helm-Release hängt

Helm speichert jede Revision eines Release als Secret im Namespace. Vor einem Upgrade legt es die neue Revision mit dem Status `pending-upgrade` an, am Ende setzt es `deployed` oder `failed`. Wird Helm dazwischen hart beendet, bleibt `pending-upgrade` stehen. Das ist zugleich die Sperre gegen parallele Upgrades. Typischer Auslöser in der Praxis: Ein CI-Runner bricht einen Job wegen Zeitüberschreitung ab, während `helm upgrade --wait` noch wartet.

#datei("szenarien/15-rollouts/haenger.sh (Ausschnitt)", ```bash
helm --kube-context "$CTX" upgrade demo "$CHART" \
  -n dbg-15 --set readinessPort=9999 --wait --timeout 5m &
HELM_PID=$!
sleep 15
kill -9 "$HELM_PID"
```, erklaerung: [Revision 2 wird nie ready, `helm` wartet. Nach 15 Sekunden kommt `SIGKILL`. Auf `Ctrl-C` oder `SIGTERM` würde Helm noch reagieren und das Release als `failed` markieren, auf `SIGKILL` nicht.])

#cmd("Mac")[```bash
szenarien/15-rollouts/haenger.sh rke2
helm --kube-context rke2 upgrade demo \
  szenarien/15-rollouts/demo-chart -n dbg-15
```][Das Skript installiert Revision 1 aus dem Mini-Chart `demo-chart` und bricht das Upgrade auf Revision 2 ab. Danach der Versuch, normal weiterzuarbeiten.]

#symptom[
```text
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```
Dabei läuft gar keine andere Operation. Jeder weitere Versuch endet genauso.
]

=== Untersuchen

#cmd("Mac")[```bash
helm --kube-context rke2 history demo -n dbg-15
kubectl --context rke2 get secrets -n dbg-15 -l owner=helm --show-labels
```][Die Revisionen des Release, dann die Secrets, in denen Helm sie speichert. Das Label `status` jedes Secrets entspricht der Spalte `STATUS`.]

```text
REVISION  UPDATED                   STATUS           CHART       ... DESCRIPTION
1         Mon Nov  9 22:41:03 2026  deployed         demo-0.1.0  ... Install complete
2         Mon Nov  9 22:41:20 2026  pending-upgrade  demo-0.1.0  ... Preparing upgrade
```

In k9s öffnest du mit `:helm` die Releases, `r` zeigt die Historie des gewählten Release. Auch `helm list -n dbg-15` zeigt das Release, denn Helm 4 listet standardmäßig alle Zustände. Mit `--pending` filterst du gezielt.

#ursache[
  Die letzte Revision steht auf `pending-upgrade`. Helm prüft vor jedem Upgrade, ob die jüngste Revision in einem `pending`-Zustand ist, und bricht dann mit `another operation ... is in progress` ab. Der Prozess, der die Revision abschließen sollte, wurde mit `SIGKILL` beendet und konnte nichts mehr aufräumen.
]

=== Beheben

#cmd("Mac")[```bash
helm --kube-context rke2 rollback demo 1 -n dbg-15
helm --kube-context rke2 upgrade demo szenarien/15-rollouts/demo-chart \
  -n dbg-15 --wait
```][Der Rollback prüft die Sperre nicht und legt Revision 3 als Kopie von Revision 1 an. Danach ist ein normales Upgrade wieder möglich. In der k9s-Historie geht der Rollback mit `r` auf der gewünschten Revision.]

#pruefe[
  `helm history demo -n dbg-15` endet mit einer Revision im Status `deployed`. Revision 3 trägt die Beschreibung `Rollback to 1`.
]

Hilft der Rollback nicht, etwa weil schon die erste Installation hängt (`pending-install`), bleibt das Löschen des Secrets der hängenden Revision: `kubectl delete secret sh.helm.release.v1.demo.v2 -n dbg-15`. Danach gilt wieder die vorherige Revision. Mach das nur, wenn du sicher bist, dass wirklich kein Helm-Prozess mehr läuft.

#distro(
  [RKE2 installiert seine mitgelieferten Charts (`rke2-traefik`, `rke2-coredns` ...) über den eingebauten Helm-Controller, sichtbar an den Jobs `helm-install-rke2-...` in `kube-system`. Diese Releases änderst du nicht mit `helm upgrade`, sondern über `HelmChartConfig`.],
  [Talos hat keinen Helm-Controller. Alles, was du mit Helm installierst, auch metrics-server und Traefik, verwaltest du selbst mit der Helm-CLI.],
)

== Der Job gibt auf

Ein Job startet bei Fehlern neue Pods, bis `backoffLimit` erreicht ist. Die Wartezeit zwischen den Versuchen wächst dabei: 10 Sekunden, 20, 40 und so weiter. `activeDeadlineSeconds` begrenzt zusätzlich die Gesamtlaufzeit.

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/kaputt-job.yaml
```][Der Job `import` erwartet `/daten/import.csv`, die Datei gibt es nicht. `backoffLimit: 2` erlaubt zwei Wiederholungen.]

#symptom[
```text
$ kubectl --context rke2 get jobs,pods -n dbg-15 -l app=import
NAME               STATUS   COMPLETIONS   DURATION   AGE
job.batch/import   Failed   0/1           52s        52s

NAME               READY   STATUS   RESTARTS   AGE
pod/import-7xq9d   0/1     Error    0          52s
pod/import-bk2mw   0/1     Error    0          41s
pod/import-zr4pt   0/1     Error    0          20s
```
]

=== Untersuchen

#cmd("Mac")[```bash
kubectl --context rke2 describe job import -n dbg-15 | sed -n '/^Events/,$p'
kubectl --context rke2 logs -n dbg-15 job/import
```][Die Events des Jobs, dann das Log eines seiner Pods. `logs job/...` sucht sich selbst einen Pod aus.]

```text
  Warning  BackoffLimitExceeded  2s  job-controller  Job has reached the specified
                                                    backoff limit
FEHLER: /daten/import.csv fehlt
```

In k9s zeigt `:jobs dbg-15` die Jobs. `Enter` führt zu den Pods, `l` zu den Logs und `p` zu den Logs des vorherigen Containers, falls einer neu gestartet wurde.

#ursache[
  Jeder Versuch endet mit Exit-Code 1. Nach drei Pods (ein Versuch plus zwei Wiederholungen) setzt der Job-Controller die Condition `Failed` mit dem Reason `BackoffLimitExceeded` und startet nichts mehr. Wäre stattdessen `activeDeadlineSeconds` abgelaufen, stünde dort `DeadlineExceeded` mit `Job was active longer than specified deadline`.
]

=== Beheben

Das Pod-Template eines Jobs ist unveränderlich. Ein `apply` mit geändertem Befehl scheitert mit `field is immutable`. Du löschst den Job und legst ihn neu an.

#cmd("Mac")[```bash
kubectl --context rke2 delete job import -n dbg-15
kubectl --context rke2 apply -f szenarien/15-rollouts/fix-job.yaml
kubectl --context rke2 wait --for=condition=Complete job/import \
  -n dbg-15 --timeout=60s
```][Der korrigierte Job legt seine Eingabedatei selbst an. `wait` kehrt zurück, sobald der Job fertig ist.]

#pruefe[
  `job.batch/import condition met`, `kubectl get jobs -n dbg-15` zeigt `Complete` und `1/1`.
]

#falle[
  `ttlSecondsAfterFinished: 3600` löscht den Job eine Stunde nach dem Ende, mitsamt Pods und Logs. Bei CronJobs räumen zusätzlich `successfulJobsHistoryLimit` und `failedJobsHistoryLimit` auf. Untersuche gescheiterte Jobs zeitnah. Einen CronJob testest du gezielt mit `kubectl create job --from=cronjob/<name> test-1`.
]

== Die ConfigMap-Änderung kommt nicht an

#cmd("Mac")[```bash
kubectl --context rke2 apply -f szenarien/15-rollouts/kaputt-configmap.yaml
kubectl --context rke2 patch configmap begruessung -n dbg-15 \
  --type=merge -p '{"data":{"GRUSS":"Hallo v2"}}'
```][Das Deployment `gruss` liest `GRUSS` per `envFrom` aus der ConfigMap und gibt den Wert alle zehn Sekunden aus. Danach änderst du die ConfigMap.]

#symptom[
  `kubectl --context rke2 logs -n dbg-15 deploy/gruss --tail 3` zeigt auch Minuten später nur `Hallo v1`.
]

#ursache[
  Umgebungsvariablen setzt das Kubelet einmal beim Start des Containers. Eine spätere Änderung der ConfigMap erreicht den laufenden Prozess nie. Als Volume eingebundene ConfigMaps aktualisiert das Kubelet mit Verzögerung (Sync-Periode plus Cache, zusammen oft ein bis zwei Minuten), außer bei `subPath`-Mounts. Ob die Anwendung die geänderte Datei dann neu liest, ist ihre Sache.
]

#cmd("Mac")[```bash
kubectl --context rke2 rollout restart deploy/gruss -n dbg-15
```][Startet die Pods neu, sie lesen die ConfigMap beim Start. In k9s geht das in der Deployment-Ansicht mit `r`.]

#pruefe[
  Nach dem Neustart zeigt `kubectl --context rke2 logs -n dbg-15 deploy/gruss --tail 1` den Text `Hallo v2`.
]

In Helm-Charts löst du das dauerhaft mit einer Annotation am Pod-Template, die eine Prüfsumme der ConfigMap enthält, etwa `checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}`. Ändert sich die ConfigMap, ändert sich das Template, und Kubernetes rollt neu aus.

== Aufräumen

#cmd("Mac")[```bash
helm --kube-context rke2 uninstall demo -n dbg-15
kubectl --context rke2 delete ns dbg-15
kubectl --context talos delete ns dbg-15
```][Entfernt das Helm-Release und beide Namespaces. Der metrics-server auf Talos bleibt, du brauchst ihn in den weiteren Übungen und für k9s.]

#aufgabe[
  Setze in einer Kopie von `fix-rollout.yaml` das Image auf `busybox:1.37-gibtesnicht`, `progressDeadlineSeconds` auf `30` und die `change-cause` auf `v3: neues Image`. Wende sie an. Welche Condition hat das Deployment nach einer Minute, welchen Status der neue Pod, und welche Revision stellst du mit `rollout undo --to-revision` wieder her, damit `v2` mit korrigierter Probe läuft?

  Hinweis: Wieder `Progressing False` mit `ProgressDeadlineExceeded`, diesmal steht der neue Pod auf `ImagePullBackOff` (Kapitel 5). `rollout history` zeigt dir, welche Revision die `change-cause` „Probe korrigiert“ trägt.
]

#gelernt(
  [Ein hängender Rollout zeigt `Progressing=False` mit `ProgressDeadlineExceeded`. Kubernetes rollt nicht von selbst zurück, das machst du mit `rollout undo`.],
  [`<unknown>` beim HPA hat zwei häufige Gründe: keine Metrics-API (Talos ohne metrics-server) oder kein Request im Container. Die Events des HPA unterscheiden beides.],
  [metrics-server auf Talos braucht Kubelet-Serving-Zertifikate aus der Cluster-CA: `rotate-server-certificates`, ein Approver für die CSRs, dann das Chart.],
  [`another operation (install/upgrade/rollback) is in progress` heißt: Die letzte Revision steht auf `pending-*`. `helm history` zeigt sie, `helm rollback` löst die Sperre.],
  [Jobs geben nach `backoffLimit` mit `BackoffLimitExceeded` auf. Ihr Template ist unveränderlich, also löschen und neu anlegen.],
  [ConfigMaps als Umgebungsvariablen wirken erst nach einem Neustart: `rollout restart` oder eine Prüfsummen-Annotation.],
)
