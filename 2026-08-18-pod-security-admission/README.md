# Pod Security Admission: Namespaces mit dem `restricted`-Standard absichern

Getestet gegen Kubernetes 1.36 (DOKS, DigitalOcean fra1).

Folge 2 der Serie **Kubernetes Sicherheit**. In dieser Übung siehst du, dass ein Namespace ohne PSA-Label jeden Pod durchwinkt — auch als root, mit allen Capabilities. Danach aktivierst du erst `warn`/`audit`, um Verstöße sichtbar zu machen, dann `enforce=restricted`, um sie abzulehnen, und baust einen Pod, der den `restricted`-Standard erfüllt.

## Voraussetzungen

- Laufender Kubernetes-Cluster (DOKS oder jeder andere) mit `kubectl`-Zugriff, Version 1.25+
- `kubectl`-Kontext mit Rechten, Namespace-Labels zu setzen

## Überblick

```
Schritt 1: Namespace ohne PSA-Label anlegen
Schritt 2: Unsicheren Pod deployen — läuft klaglos durch
Schritt 3: warn + audit auf restricted setzen, Verstoß sichtbar machen
Schritt 4: enforce=restricted setzen
Schritt 5: Denselben unsicheren Pod erneut versuchen — abgelehnt
Schritt 6: Konformen Pod nach restricted-Standard bauen und deployen
Schritt 7: Aufräumen
```

---

## Schritt 1: Namespace ohne PSA-Label anlegen

```bash
kubectl create namespace psa-demo
```

Kein Label gesetzt — Standardverhalten ist `privileged`.

## Schritt 2: Unsicheren Pod deployen

```yaml
# 01-unsafe-pod.yml
apiVersion: v1
kind: Pod
metadata:
  name: unsafe-app
  namespace: psa-demo
spec:
  containers:
  - name: app
    image: nginx:alpine
    securityContext:
      runAsUser: 0
      allowPrivilegeEscalation: true
      capabilities:
        add: ["NET_RAW"]
    resources:
      requests:
        cpu: "50m"
        memory: "64Mi"
      limits:
        cpu: "100m"
        memory: "128Mi"
```

```bash
kubectl apply -f 01-unsafe-pod.yml
kubectl wait --for=condition=Ready pod/unsafe-app -n psa-demo --timeout=60s
```

**Erwartete Ausgabe:**

```
pod/unsafe-app created
pod/unsafe-app condition met
```

Läuft. Root, `allowPrivilegeEscalation: true`, zusätzliche Capability — der Namespace hat nichts dagegen, weil kein PSA-Label gesetzt ist.

## Schritt 3: warn + audit auf restricted setzen

```bash
kubectl label --overwrite ns psa-demo \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

Die Warnung erscheint nur bei einem echten Create/Update — ein `kubectl apply` auf einen bereits unveränderten Pod liefert keinen neuen Request an den API-Server und damit auch keine Warnung. Pod löschen und im Server-Side Dry-Run neu anlegen, um den Verstoß zu sehen, ohne wirklich etwas zu erzeugen:

```bash
kubectl delete pod unsafe-app -n psa-demo
kubectl apply -f 01-unsafe-pod.yml --dry-run=server
```

**Erwartete Ausgabe:**

```
pod "unsafe-app" deleted from psa-demo namespace
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]; container "app" must not include "NET_RAW" in securityContext.capabilities.add), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "app" must not set runAsUser=0), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/unsafe-app created (server dry run)
```

Der Pod wird noch nicht abgelehnt — `warn` und `audit` blockieren nichts, und der Dry-Run legt ohnehin nichts wirklich an. Aber jetzt weißt du genau, was bei `enforce` brechen würde.

## Schritt 4: enforce=restricted setzen

```bash
kubectl label --overwrite ns psa-demo \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest
```

Ein genereller Hinweis, unabhängig von dieser Übung: Bereits laufende Pods werden dadurch **nicht** nachträglich entfernt — PSA prüft nur bei Erstellung/Änderung. In unserem Fall existiert `unsafe-app` aktuell gar nicht mehr (in Schritt 3 für den Dry-Run gelöscht) — in einem echten Namespace mit laufenden Workloads würden diese also unangetastet weiterlaufen, bis sie das nächste Mal neu erstellt oder aktualisiert werden.

## Schritt 5: Den unsicheren Pod neu anlegen

```bash
kubectl apply -f 01-unsafe-pod.yml
```

**Erwartete Ausgabe:**

```
Error from server (Forbidden): error when creating "01-unsafe-pod.yml": pods "unsafe-app" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]; container "app" must not include "NET_RAW" in securityContext.capabilities.add), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "app" must not set runAsUser=0), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Abgelehnt, direkt beim API-Server — der Pod existiert zu keinem Zeitpunkt im Cluster.

## Schritt 6: Konformen Pod nach restricted-Standard bauen

```yaml
# 02-safe-pod.yml
apiVersion: v1
kind: Pod
metadata:
  name: safe-app
  namespace: psa-demo
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: nginx:alpine
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
    resources:
      requests:
        cpu: "50m"
        memory: "64Mi"
      limits:
        cpu: "100m"
        memory: "128Mi"
```

```bash
kubectl apply -f 02-safe-pod.yml
kubectl wait --for=condition=Ready pod/safe-app -n psa-demo --timeout=60s
```

**Erwartete Ausgabe:**

```
pod/safe-app created
pod/safe-app condition met
```

**Bewusste Einschränkung:**
- `runAsNonRoot: true` + `runAsUser: 1000` — kein root
- `allowPrivilegeEscalation: false` — Prozess kann sich keine zusätzlichen Rechte verschaffen
- `capabilities.drop: ["ALL"]` — keine der ~40 Default-Capabilities an Bord
- `seccompProfile.type: RuntimeDefault` — Syscall-Filter des Containerd/Docker-Runtime aktiv

## Schritt 7: Aufräumen

```bash
kubectl delete namespace psa-demo
```

---

## Zusammenfassung

| Situation | Ergebnis |
|---|---|
| Kein PSA-Label am Namespace | 💥 Standard `privileged` — jeder Pod erlaubt |
| `warn`/`audit=restricted`, kein `enforce` | ⚠️ Verstöße sichtbar, aber nichts verhindert |
| `enforce=restricted` | ✅ Nicht-konforme Pods werden beim `kubectl apply` abgelehnt |
| Pod mit `runAsNonRoot`, `drop: ALL`, `allowPrivilegeEscalation: false`, `seccompProfile` | ✅ Erfüllt `restricted` — läuft durch |

## Referenzen

- https://kubernetes.io/docs/concepts/security/pod-security-admission/
- https://kubernetes.io/docs/concepts/security/pod-security-standards/
- https://kubernetes.io/docs/tutorials/security/ns-level-pss/
