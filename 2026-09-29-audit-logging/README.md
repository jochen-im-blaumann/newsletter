# Kubernetes Audit-Log: wer hat wann was im Cluster gemacht

Getestet gegen Kubernetes 1.36 (kind, lokal).

Folge 7 der Serie **Kubernetes Sicherheit**. In dieser Übung aktivierst du das Audit-Log des `kube-apiserver`, schreibst eine Policy, die steuert, was geloggt wird, tappst dabei in eine typische Falle mit der `events`-Ressource — und siehst live, wie sich Secret-Zugriffe (nur Metadaten) und Pod-Änderungen (komplette Objekte) unterschiedlich im Log niederschlagen.

**Wichtig, bevor du anfängst:** Diese Übung braucht echten Zugriff auf die Control Plane — `--audit-log-path` und `--audit-policy-file` sind Flags des `kube-apiserver`. Auf einem **managed** Cluster wie DOKS, EKS oder GKE kommst du an diese Flags nicht ran, weil dort DigitalOcean/AWS/Google den Control-Plane-Prozess betreiben, nicht du (bei DOKS gibt es dafür bis heute nicht mal ein natives Feature — siehe der [offene Feature-Request](https://ideas.digitalocean.com/kubernetes/p/audit-logs-support-for-managed-kubernetes)). Deshalb läuft diese Übung gegen `kind` — einen lokalen Cluster, bei dem du selbst der Control-Plane-Admin bist. Genauso gut geeignet: `minikube` oder ein eigener `kubeadm`-Cluster.

## Voraussetzungen

- Docker
- [`kind`](https://kind.sigs.k8s.io/) installiert
- `kubectl`
- `jq` (zum Lesbarmachen der Log-Zeilen)

## Überblick

```
Schritt 1: kind-Cluster mit Audit-Log-Flags anlegen
Schritt 2: Secret anlegen — Metadata-Level, kein Klartext im Log
Schritt 3: Pod anlegen/löschen — RequestResponse-Level, volle Objekte
Schritt 4: Der Blindflug-Fehler — events.k8s.io flutet das Log trotz Exclude-Regel
Schritt 5: Fix — Policy korrigieren, API-Server neu starten
Schritt 6: Verifizieren — vorher/nachher
Schritt 7: Aufräumen
```

---

## Schritt 1: kind-Cluster mit Audit-Log-Flags anlegen

Zuerst die Policy, die festlegt, was wie detailliert geloggt wird:

```yaml
# audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: None
    resources:
      - group: ""
        resources: ["events"]
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["pods"]
  - level: Request
    verbs: ["create", "update", "patch", "delete"]
  - level: Metadata
```

Vier Stufen, von grob nach fein: `None` (nicht loggen), `Metadata` (nur wer/was/wann, kein Inhalt), `Request` (zusätzlich der gesendete Request-Body) und `RequestResponse` (zusätzlich auch die Antwort vom API-Server). Secrets und ConfigMaps landen bewusst nur auf `Metadata` — sonst stünde jeder Secret-Wert im Klartext im Log.

Die `kind`-Cluster-Config reicht die Policy als Datei in den Control-Plane-Node durch und setzt die passenden `kube-apiserver`-Flags:

```yaml
# kind-audit-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ./audit-policy.yaml
        containerPath: /etc/kubernetes/policies/audit-policy.yaml
        readOnly: true
      - hostPath: ./audit-logs
        containerPath: /var/log/kubernetes
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-policy-file: /etc/kubernetes/policies/audit-policy.yaml
            audit-log-path: /var/log/kubernetes/audit.log
            audit-log-maxage: "7"
            audit-log-maxbackup: "3"
          extraVolumes:
            - name: audit-policy
              hostPath: /etc/kubernetes/policies/audit-policy.yaml
              mountPath: /etc/kubernetes/policies/audit-policy.yaml
              readOnly: true
              pathType: File
            - name: audit-log
              hostPath: /var/log/kubernetes
              mountPath: /var/log/kubernetes
              pathType: DirectoryOrCreate
```

```bash
mkdir -p audit-logs
kind create cluster --name audit-demo --image kindest/node:v1.36.1 --config kind-audit-config.yaml
```

**Erwartete Ausgabe (gekürzt):**

```
Creating cluster "audit-demo" ...
 ✓ Ensuring node image (kindest/node:v1.36.1) 🖼️
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-audit-demo"
```

Das Audit-Log selbst liegt als Datei im Control-Plane-Node — bei `kind` ist der Node ein Docker-Container, deshalb per `docker exec` statt SSH:

```bash
kubectl create namespace audit-demo
docker exec audit-demo-control-plane wc -l /var/log/kubernetes/audit.log
```

Schon jetzt stehen dort ein paar tausend Zeilen — allein der Cluster-Start und die internen Controller erzeugen laufend API-Requests.

**Wichtig: Kein Default, wenn die Policy-Datei fehlt**

`audit-log-path` allein reicht nicht. Ohne `audit-policy-file` bleibt das Log leer — es gibt kein eingebautes "logge wenigstens Metadata für alles" als Fallback. Zum Beleg ein Testlauf mit einem zweiten Cluster, bei dem nur `audit-log-path` gesetzt ist, ganz ohne `audit-policy-file`:

```bash
docker exec audit-nopolicy-control-plane ls -la /var/log/kubernetes/
```

**Tatsächliche Ausgabe:**

```
-rw------- 1 root root 0 Sep 29 06:14 audit.log
```

Die Datei wird angelegt — der API-Server startet ohne Fehler, `audit-log-path` allein reicht also, um überhaupt eine Datei zu erzeugen. Aber selbst nach `kubectl create namespace` und `kubectl create configmap` bleibt sie bei 0 Bytes:

```bash
kubectl create namespace test-ns
kubectl create configmap test-cm --from-literal=foo=bar -n test-ns
docker exec audit-nopolicy-control-plane wc -l /var/log/kubernetes/audit.log
```

**Tatsächliche Ausgabe:**

```
0 /var/log/kubernetes/audit.log
```

Ohne Policy-Datei ist Auditing faktisch aus — nicht "minimal", sondern komplett stumm. Genau das ist der Grund, warum `audit-policy-file` in der `kind-audit-config.yaml` oben von Anfang an mitgesetzt ist.

## Schritt 2: Secret anlegen — Metadata-Level, kein Klartext im Log

```bash
kubectl create secret generic demo-secret --from-literal=key=wert -n audit-demo
```

```bash
docker exec audit-demo-control-plane sh -c \
  "grep '\"resource\":\"secrets\",\"namespace\":\"audit-demo\",\"name\":\"demo-secret\"' /var/log/kubernetes/audit.log | grep ResponseComplete" | jq .
```

**Tatsächliche Ausgabe (gekürzt):**

```json
{
  "level": "Metadata",
  "verb": "create",
  "user": { "username": "kubernetes-admin" },
  "objectRef": {
    "resource": "secrets",
    "namespace": "audit-demo",
    "name": "demo-secret"
  },
  "responseStatus": { "code": 201 }
}
```

Kein `requestObject`, kein `responseObject` — der Wert `wert` taucht im Log nicht auf. Du siehst: wer, wann, welches Secret, welche Aktion, welcher HTTP-Status. Nicht: den Inhalt. Genau das Verhalten, das du für Secrets willst.

## Schritt 3: Pod anlegen/löschen — RequestResponse-Level, volle Objekte

```bash
kubectl run nginx-test --image=nginx --restart=Never -n audit-demo
kubectl delete pod nginx-test -n audit-demo
```

```bash
docker exec audit-demo-control-plane sh -c \
  "grep '\"resource\":\"pods\",\"namespace\":\"audit-demo\",\"name\":\"nginx-test\"' /var/log/kubernetes/audit.log | grep '\"verb\":\"delete\"' | grep ResponseComplete" | jq '.level, .verb, .user.username'
```

**Tatsächliche Ausgabe:**

```
"RequestResponse"
"delete"
"kubernetes-admin"
```

Für Pods hast du `RequestResponse` konfiguriert — hier steht das komplette Objekt im Log, inklusive Spec. Nützlich für Debugging und Forensik ("welche Image-Version lief da wirklich"), aber auch deutlich mehr Speicher pro Zeile. Deshalb ist die Policy pro Ressourcentyp einzeln abgestuft, nicht pauschal auf `RequestResponse` für alles.

## Schritt 4: Der Blindflug-Fehler — events.k8s.io flutet das Log

Die Policy aus Schritt 1 schließt `events` explizit aus (`level: None`) — die sollen ja nicht jede Sekunde das Log fluten. Trotzdem:

```bash
docker exec audit-demo-control-plane sh -c \
  "grep -c '\"apiGroup\":\"events.k8s.io\"' /var/log/kubernetes/audit.log"
```

**Tatsächliche Ausgabe:**

```
54
```

(Deine Zahl wird abweichen — sie hängt davon ab, wie lange der Cluster bis zu diesem Zeitpunkt schon läuft. Entscheidend ist nur: größer als 0.)

Die Exclude-Regel greift nicht. Der Grund: Sie schließt nur `group: ""` aus — die alte Core-API für Events. Seit einigen Kubernetes-Versionen läuft die Events-API aber standardmäßig über die eigene API-Gruppe `events.k8s.io`, und `kube-proxy`, `kubelet` & Co. nutzen genau die. Die Regel greift also ins Leere, und jeder Node-Heartbeat-Event landet über die letzte Catch-all-Regel (`level: Request` für alle Schreib-Verben) trotzdem im Log.

## Schritt 5: Fix — Policy korrigieren, API-Server neu starten

```bash
sed -i 's/resources: \["events"\]/resources: ["events"]\n      - group: "events.k8s.io"\n        resources: ["events"]/' audit-policy.yaml
```

`audit-policy.yaml` sieht danach so aus:

```yaml
  - level: None
    resources:
      - group: ""
        resources: ["events"]
      - group: "events.k8s.io"
        resources: ["events"]
```

Die Policy-Datei liegt nur read-only im Node gemountet — Änderungen an der Host-Datei kommen sofort im Container an. Der `kube-apiserver` liest die Policy aber nur beim Start ein, deshalb muss der Static Pod neu starten:

```bash
kubectl delete pod -n kube-system -l component=kube-apiserver
kubectl wait --for=condition=Ready node/audit-demo-control-plane --timeout=60s
```

`kubeadm` betreibt den API-Server als Static Pod — `kubelet` erkennt das Löschen und startet ihn anhand des Manifests in `/etc/kubernetes/manifests/` sofort neu, diesmal mit der korrigierten Policy.

## Schritt 6: Verifizieren — vorher/nachher

```bash
VORHER=$(docker exec audit-demo-control-plane sh -c "wc -l < /var/log/kubernetes/audit.log")
kubectl create configmap trigger --from-literal=foo=bar -n audit-demo
sleep 8
docker exec audit-demo-control-plane sh -c \
  "tail -n +$((VORHER+1)) /var/log/kubernetes/audit.log | grep -c 'events.k8s.io'"
```

**Tatsächliche Ausgabe:**

```
0
```

Seit dem Neustart mit korrigierter Policy taucht `events.k8s.io` nicht mehr auf — während der `configmap`-Create weiterhin sauber protokolliert wird. Die Catch-all-Regel am Ende der Policy ist dabei Absicht, nicht Notlösung: Sie sorgt dafür, dass neue Ressourcentypen, an die du beim Schreiben der Policy nicht gedacht hast, trotzdem mit einem Mindest-Level (`Metadata`) erfasst werden, statt komplett durchzurutschen.

## Schritt 7: Aufräumen

```bash
kind delete cluster --name audit-demo
rm -rf audit-logs
```

| Fehler | Folge |
|---|---|
| Kein Audit-Log aktiv | 💥 Nach einem Vorfall keine Spur, wer was im Cluster geändert hat |
| Alles auf `RequestResponse` | ⚠️ Log wächst explosionsartig, Secrets im Klartext protokolliert |
| Exclude-Regel nur für `group: ""` | ⚠️ `events.k8s.io` flutet das Log trotzdem |
| Abgestufte Policy + Exclude für beide Event-Gruppen | ✅ Secrets nur als Metadaten, Pods vollständig, Rauschen draußen |

Der Unterschied zu den letzten Ausgaben: Bei RBAC, PSA, Gatekeeper und Kyverno hast du entschieden, was im Cluster erlaubt ist. Heute geht es nicht um Verhindern, sondern ums Nachvollziehen — die Grundlage für jede Forensik, wenn doch mal etwas durchrutscht.
