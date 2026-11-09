# Kapitel 14: Control Plane, etcd und Webhooks
rke2-config-kaputt.yaml ist kein Kubernetes-Manifest, sondern eine RKE2-Drop-in-Datei für /etc/rancher/rke2/config.yaml.d/ (Talos: labor/talos/patch-apiserver-featuregate.yaml).
kurzlebiges-zertifikat.sh legt Schlüssel und kubeconfig unter tmp-<kontext>/ ab (von Git ausgenommen).
