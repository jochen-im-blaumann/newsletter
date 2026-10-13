# Kubernetes 1.37: Upgrade-Check und die Neuerungen zum Anfassen

Getestet gegen Kubernetes 1.37.0 (kind, lokal).

Begleitübung zur Newsletter-Ausgabe "Zeit für ein Upgrade". In dieser Übung legst du einen lokalen Cluster mit Kubernetes 1.37 an, machst den Upgrade-Check, den du vor jedem echten Upgrade machen solltest (cgroup v2, kube-proxy-Modus), und fasst dann vier Neuerungen aus 1.37 an: KYAML, die `Unused`-Condition an PVCs, HPA Scale-to-Zero und das Ende der ConfigMap-Referenzen in Static Pods.

## Voraussetzungen

- Docker
- [`kind`](https://kind.sigs.k8s.io/) ab 0.33 (bringt das Node-Image für 1.37 mit)
- `kubectl` ab 1.36 (für `-o kyaml` und den Version-Skew)

## Überblick

```
Schritt 1: kind-Cluster mit Kubernetes 1.37 anlegen
Schritt 2: Upgrade-Check — cgroup v2, kube-proxy-Modus, kubelet-Config
Schritt 3: KYAML — kubectl get -o kyaml
Schritt 4: Verwaiste Volumes finden — die Unused-Condition an PVCs
Schritt 5: HPA auf null skalieren — minReplicas: 0
Schritt 6: Static Pods dürfen keine ConfigMaps mehr referenzieren
Schritt 7: Aufräumen
```

---

## Schritt 1: kind-Cluster mit Kubernetes 1.37 anlegen

Ein Control-Plane-Node und ein Worker reichen:

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
```

```bash
kind create cluster --name upgrade-demo --image kindest/node:v1.37.0 --config kind-config.yaml
kubectl get nodes
```

**Tatsächliche Ausgabe:**

```
NAME                         STATUS   ROLES           AGE   VERSION
upgrade-demo-control-plane   Ready    control-plane   39s   v1.37.0
upgrade-demo-worker          Ready    <none>          27s   v1.37.0
```

## Schritt 2: Upgrade-Check

Die drei Fragen, die du vor einem Upgrade auf 1.35 oder neuer an jeden Cluster stellen solltest. Hier übst du sie am kind-Cluster, bei dir zu Hause stellst du sie dem echten.

**Frage 1: Laufen die Nodes mit cgroup v2?**

Seit 1.35 startet das kubelet auf einem Node mit cgroup v1 nicht mehr (Einstellung `failCgroupV1: true`). Bei kind ist der Node ein Docker-Container, deshalb fragen wir den Container direkt. Auf einem echten Node läuft derselbe `stat`-Befehl per SSH:

```bash
docker exec upgrade-demo-worker stat -fc %T /sys/fs/cgroup/
```

**Tatsächliche Ausgabe:**

```
cgroup2fs
```

`cgroup2fs` heißt cgroup v2, alles gut. Steht da `tmpfs`, läuft der Node noch mit cgroup v1 und das Upgrade auf 1.35+ bleibt auf diesem Node hängen.

**Frage 2: Was sagt das kubelet dazu?**

Die laufende kubelet-Konfiguration kannst du über den API-Server abfragen. Interessant sind `failCgroupV1` und die neuen Memory-QoS-Felder:

```bash
kubectl get --raw "/api/v1/nodes/upgrade-demo-worker/proxy/configz" \
  | python3 -c 'import json,sys; c=json.load(sys.stdin)["kubeletconfig"]; print({k: c.get(k) for k in ["failCgroupV1","cgroupDriver","memoryThrottlingFactor","memoryReservationPolicy"]})'
```

**Tatsächliche Ausgabe:**

```
{'failCgroupV1': True, 'cgroupDriver': 'systemd', 'memoryThrottlingFactor': None, 'memoryReservationPolicy': 'None'}
```

Memory QoS ist in 1.37 zwar standardmäßig eingeschaltet, aber `memoryThrottlingFactor: None` und `memoryReservationPolicy: None` bedeuten: Es passiert nichts, solange du es nicht explizit konfigurierst. Ein Upgrade ändert das Laufzeitverhalten deiner Pods also nicht.

**Frage 3: In welchem Modus läuft kube-proxy?**

Der `ipvs`-Modus ist seit 1.37 deprecated und soll in 1.43 verschwinden. So findest du raus, was bei dir läuft:

```bash
kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' | grep 'mode:'
```

**Tatsächliche Ausgabe:**

```
mode: iptables
```

`iptables` oder `nftables` sind in Ordnung. Steht da `ipvs`, hast du bis 1.43 Zeit für die Umstellung auf `nftables`, aber ab 1.40 ist `ipvs` voraussichtlich standardmäßig abgeschaltet.

## Schritt 3: KYAML

KYAML ist in 1.37 stable. Es ist normales YAML, nur eindeutiger geschrieben: geschweifte Klammern statt Einrückung, Strings immer in Anführungszeichen. Jedes KYAML ist gültiges YAML, du kannst es mit jedem `kubectl apply` wieder einspielen.

```bash
kubectl get deploy coredns -n kube-system -o kyaml | head -40
```

**Tatsächliche Ausgabe (gekürzt):**

```
---
{
  apiVersion: "apps/v1",
  kind: "Deployment",
  metadata: {
    labels: {
      k8s-app: "kube-dns",
    },
    name: "coredns",
    namespace: "kube-system",
  },
  spec: {
    replicas: 2,
    strategy: {
      rollingUpdate: {
        maxSurge: "25%",
        maxUnavailable: 1,
      },
      type: "RollingUpdate",
    },
```

Schau dir `maxSurge: "25%"` und `maxUnavailable: 1` an: Im klassischen YAML sieht man den Unterschied zwischen String und Zahl nicht, in KYAML sofort. Genau dafür ist es gemacht.

## Schritt 4: Verwaiste Volumes finden

Neu in 1.37 (Beta, standardmäßig an): Der PVC-Controller schreibt an jede PVC eine Condition `Unused`, inklusive Zeitstempel, seit wann kein Pod mehr dranhängt.

Erst eine PVC anlegen:

```yaml
# 01-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: daten
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

Dann ein Pod, der sie benutzt:

```yaml
# 02-pod-mit-pvc.yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sleep", "infinity"]
      volumeMounts:
        - name: daten
          mountPath: /daten
  volumes:
    - name: daten
      persistentVolumeClaim:
        claimName: daten
```

```bash
kubectl apply -f 01-pvc.yaml -f 02-pod-mit-pvc.yaml
kubectl wait --for=condition=Ready pod/app --timeout=120s
kubectl get pvc daten -o jsonpath='{.status.conditions[?(@.type=="Unused")]}'
```

**Tatsächliche Ausgabe:**

```
{"lastProbeTime":null,"lastTransitionTime":"2026-10-13T06:17:52Z","message":"A pod is currently referencing this PVC","reason":"PodUsingPVC","status":"False","type":"Unused"}
```

`Unused: False`, die PVC ist in Benutzung. Jetzt den Pod löschen, so wie es im Alltag passiert, wenn jemand eine App abräumt und das Volume vergisst:

```bash
kubectl delete pod app
sleep 5
kubectl get pvc daten -o jsonpath='{.status.conditions[?(@.type=="Unused")]}'
```

**Tatsächliche Ausgabe:**

```
{"lastProbeTime":null,"lastTransitionTime":"2026-10-13T06:18:31Z","message":"No pods are currently referencing this PVC","reason":"NoPodsUsingPVC","status":"True","type":"Unused"}
```

`Unused: True`, und `lastTransitionTime` sagt dir, seit wann. Bisher musstest du dafür Pods und PVCs im ganzen Cluster gegeneinander abgleichen. Jetzt reicht eine Abfrage über alle Namespaces:

```bash
kubectl get pvc -A -o json | python3 -c '
import json,sys
for p in json.load(sys.stdin)["items"]:
    for c in p.get("status",{}).get("conditions",[]):
        if c["type"]=="Unused" and c["status"]=="True":
            print(p["metadata"]["namespace"], p["metadata"]["name"], "unbenutzt seit", c["lastTransitionTime"])'
```

**Tatsächliche Ausgabe:**

```
default daten unbenutzt seit 2026-10-13T06:18:31Z
```

Löschen tut Kubernetes nichts von selbst. Die Entscheidung bleibt bei dir, aber die Liste hast du jetzt.

## Schritt 5: HPA auf null skalieren

Bis 1.36 lehnte der API-Server einen HorizontalPodAutoscaler mit `minReplicas: 0` ab. In 1.37 ist Scale-to-Zero Beta und standardmäßig an, allerdings nur mit `Object`- oder `External`-Metriken. CPU und Memory gehen nicht, denn ohne Pod gibt es keine CPU-Werte, die wieder hochskalieren könnten.

```yaml
# 03-hpa-scale-to-zero.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: worker
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: worker
  minReplicas: 0
  maxReplicas: 10
  metrics:
    - type: External
      external:
        metric:
          name: queue_messages_ready
        target:
          type: AverageValue
          averageValue: "30"
```

```bash
kubectl apply -f 03-hpa-scale-to-zero.yaml
kubectl get hpa worker
```

**Tatsächliche Ausgabe:**

```
horizontalpodautoscaler.autoscaling/worker created
NAME     REFERENCE           TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
worker   Deployment/worker   <unknown>/30 (avg)   0         10        0          0s
```

`MINPODS 0` wird akzeptiert. Dass die Targets `<unknown>` sind, ist in dieser Übung erwartbar: Es gibt weder das Deployment noch einen Metrics-Adapter, der `queue_messages_ready` liefert. Im echten Cluster hängt da zum Beispiel ein Prometheus-Adapter oder KEDA dran, und der Queue-Worker schläft, bis Nachrichten anliegen.

## Schritt 6: Static Pods dürfen keine ConfigMaps mehr referenzieren

Static Pods werden vom kubelet direkt aus `/etc/kubernetes/manifests/` gestartet, ohne den API-Server. Trotzdem erlaubte ein Bug bisher, dass sie per `configMapRef` oder `secretRef` auf API-Objekte zeigen. Seit 1.37 ist das endgültig verboten, auch die Feature-Gate zum Ausschalten ist weg. Betrifft dich, wenn du Static Pods auf kubeadm-Nodes pflegst.

Wir probieren es aus: eine ConfigMap anlegen und einen Static Pod, der sie per `envFrom` einbinden will.

```yaml
# 04-static-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: static-app
  namespace: default
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sleep", "infinity"]
      envFrom:
        - configMapRef:
            name: app-config
```

Das Manifest kommt in das Static-Pod-Verzeichnis des Worker-Nodes. Bei kind geht das per `docker cp`, auf einem echten Node per `scp`:

```bash
kubectl create configmap app-config --from-literal=MODE=prod
docker cp 04-static-pod.yaml upgrade-demo-worker:/etc/kubernetes/manifests/static-pod.yaml
sleep 15
kubectl get pods -A | grep static
```

Die Ausgabe bleibt leer: Der Pod kommt nicht. Warum, steht im kubelet-Log des Nodes:

```bash
docker exec upgrade-demo-worker journalctl -u kubelet --no-pager | grep "static pods may not" | tail -2
```

**Tatsächliche Ausgabe:**

```
Oct 13 06:18:38 upgrade-demo-worker kubelet[248]: E1013 06:18:38.123812     248 file.go:107] "Unable to process watch event" err="can't process config file \"/etc/kubernetes/manifests/static-pod.yaml\": static pods may not reference configmaps"
Oct 13 06:18:53 upgrade-demo-worker kubelet[248]: E1013 06:18:53.455578     248 file.go:186] "Could not process manifest file" err="static pods may not reference configmaps" path="/etc/kubernetes/manifests/static-pod.yaml"
```

Klare Ansage: `static pods may not reference configmaps`. Wer das in einem eigenen Static Pod stehen hat, trägt die Werte nach dem Upgrade direkt ins Manifest ein, zum Beispiel als `env` oder als `hostPath`-Volume.

Manifest wieder entfernen:

```bash
docker exec upgrade-demo-worker rm /etc/kubernetes/manifests/static-pod.yaml
```

## Schritt 7: Aufräumen

```bash
kind delete cluster --name upgrade-demo
```

Das war's. Der Upgrade-Check aus Schritt 2 ist das, was du mitnehmen solltest: Dieselben drei Befehle gegen deinen echten Cluster, bevor du auf 1.35 oder neuer gehst.
