# NetworkPolicy: Default-Deny durchsetzen und den DNS-Egress-Fallstrick fixen

Getestet gegen Kubernetes 1.36 (DOKS, DigitalOcean fra1, CNI: Cilium).

Folge 5 der Serie **Kubernetes Sicherheit**. In dieser Übung siehst du, dass Pods in Kubernetes standardmäßig uneingeschränkt miteinander reden dürfen — auch über Namespace-Grenzen hinweg. Danach sperrst du erst per Default-Deny alles zu, gibst gezielt nur Frontend-zu-Backend-Traffic frei, und läufst anschließend in den klassischen Egress-Fallstrick: Default-Deny auf Egress killt DNS, bevor du überhaupt merkst, warum die Verbindung abbricht.

## Voraussetzungen

- Laufender Kubernetes-Cluster (DOKS oder jeder andere) mit `kubectl`-Zugriff
- CNI mit NetworkPolicy-Support (Cilium, Calico — **nicht** das alte Flannel ohne Zusatz)

## Überblick

```
Schritt 1: Namespace + Backend, Frontend, Other anlegen
Schritt 2: Verbindung ohne Policy testen — beide kommen durch
Schritt 3: Default-Deny (Ingress) setzen — beide blockiert
Schritt 4: Nur Frontend freigeben — Frontend kommt durch, Other nicht
Schritt 5: Default-Deny (Egress) auf Frontend — DNS bricht
Schritt 6: DNS-Egress freigeben — DNS funktioniert, curl trotzdem noch blockiert
Schritt 7: Egress zum Backend freigeben — curl funktioniert wieder
Schritt 8: Aufräumen
```

---

## Schritt 1: Namespace + Pods anlegen

```bash
kubectl create namespace netpol-demo
kubectl apply -f 01-backend.yml
kubectl apply -f 02-frontend-pod.yml
kubectl apply -f 03-other-pod.yml
kubectl wait --for=condition=Available deployment/backend -n netpol-demo --timeout=90s
kubectl wait --for=condition=Ready pod/frontend -n netpol-demo --timeout=90s
kubectl wait --for=condition=Ready pod/other -n netpol-demo --timeout=90s
```

`backend` ist ein einfacher Python-HTTP-Server auf Port 8080, `frontend` und `other` sind zwei `curl`-Pods — `other` steht stellvertretend für jeden beliebigen weiteren Pod im Cluster, der mit dem Backend eigentlich nichts zu tun haben soll.

## Schritt 2: Verbindung ohne Policy testen

```bash
kubectl exec -n netpol-demo frontend -- curl -s -m 8 -o /dev/null -w "HTTP %{http_code}\n" http://backend-service:8080
kubectl exec -n netpol-demo other -- curl -s -m 8 -o /dev/null -w "HTTP %{http_code}\n" http://backend-service:8080
```

**Tatsächliche Ausgabe:**

```
HTTP 200
HTTP 200
```

Beide kommen durch — auch `other`, der mit dem Backend nichts zu tun haben sollte. Das ist der Ausgangszustand jedes Kubernetes-Namespace ohne NetworkPolicy: flaches Netz, offene Türen überall.

## Schritt 3: Default-Deny (Ingress) setzen

```bash
kubectl apply -f 04-default-deny-all.yml
```

```bash
kubectl exec -n netpol-demo frontend -- curl -s -m 8 -o /dev/null -w "HTTP %{http_code}\n" http://backend-service:8080
kubectl exec -n netpol-demo other -- curl -s -m 8 -o /dev/null -w "HTTP %{http_code}\n" http://backend-service:8080
```

**Tatsächliche Ausgabe:**

```
command terminated with exit code 28
HTTP 000
command terminated with exit code 28
HTTP 000
```

Exit Code 28 = Timeout. Beide Verbindungen laufen ins Leere — `podSelector: {}` ohne `ingress`-Regeln heißt: nichts kommt mehr rein, für keinen Pod im Namespace.

## Schritt 4: Nur Frontend freigeben

```bash
kubectl apply -f 05-allow-frontend-to-backend.yml
```

```bash
kubectl exec -n netpol-demo frontend -- curl -s -m 8 -o /dev/null -w "HTTP %{http_code}\n" http://backend-service:8080
kubectl exec -n netpol-demo other -- curl -s -m 8 -o /dev/null -w "HTTP %{http_code}\n" http://backend-service:8080
```

**Tatsächliche Ausgabe:**

```
HTTP 200
command terminated with exit code 28
HTTP 000
```

`frontend` kommt durch, `other` bleibt blockiert — die Regel greift exakt nach Label-Selektor, nicht nach "irgendein Pod im selben Namespace".

## Schritt 5: Default-Deny (Egress) auf Frontend

```bash
kubectl apply -f 06-default-deny-egress-frontend.yml
kubectl exec -n netpol-demo frontend -- nslookup backend-service
```

**Tatsächliche Ausgabe:**

```
;; connection timed out; no servers could be reached
command terminated with exit code 1
```

Nicht mal mehr die DNS-Anfrage an CoreDNS kommt raus. `frontend` darf zwar laut Schritt 4 weiterhin *reinkommender* Traffic vom Backend empfangen — aber jede eigene ausgehende Verbindung, auch DNS, ist jetzt dicht.

## Schritt 6: DNS-Egress freigeben

```bash
kubectl apply -f 07-allow-dns-egress-frontend.yml
kubectl exec -n netpol-demo frontend -- nslookup backend-service
kubectl exec -n netpol-demo frontend -- curl -s -m 8 -o /dev/null -w "HTTP %{http_code}\n" http://backend-service:8080
```

**Tatsächliche Ausgabe:**

```
Server:		10.115.0.10
Address:	10.115.0.10:53

Name:	backend-service.netpol-demo.svc.cluster.local
Address: 10.115.3.129

command terminated with exit code 28
HTTP 000
```

DNS löst wieder auf — aber `curl` scheitert trotzdem. Der Name wird gefunden, die eigentliche Verbindung zum Backend auf Port 8080 ist aber weiterhin nicht freigegeben. Genau der Fallstrick: DNS-Freigabe allein reicht nicht, sie behebt nur den DNS-Teil.

## Schritt 7: Egress zum Backend freigeben

```bash
kubectl apply -f 08-allow-egress-frontend-to-backend.yml
kubectl exec -n netpol-demo frontend -- curl -s -m 8 -o /dev/null -w "HTTP %{http_code}\n" http://backend-service:8080
```

**Tatsächliche Ausgabe:**

```
HTTP 200
```

Jetzt komplett: Ingress auf dem Backend erlaubt nur Frontend, Egress auf dem Frontend erlaubt nur DNS und das Backend selbst. Alles andere bleibt dicht — in beide Richtungen.

## Schritt 8: Aufräumen

```bash
kubectl delete namespace netpol-demo
```

---

## Zusammenfassung

| Situation | Ergebnis |
|---|---|
| Keine NetworkPolicy im Namespace | 💥 Jeder Pod darf mit jedem sprechen |
| Default-Deny Ingress | ✅ Nichts kommt mehr rein — inkl. gewünschtem Traffic |
| Default-Deny Ingress + gezielte Allow-Regel | ✅ Nur der erlaubte Absender kommt durch |
| Default-Deny Egress ohne DNS-Ausnahme | 💥 CoreDNS-Anfragen blockiert, Namensauflösung tot |
| Default-Deny Egress + DNS-Freigabe, aber keine Ziel-Freigabe | ⚠️ DNS funktioniert, Verbindung selbst bleibt blockiert |
| Default-Deny Egress + DNS-Freigabe + Ziel-Freigabe | ✅ Round-Trip funktioniert, alles andere bleibt zu |

## Referenzen

- https://kubernetes.io/docs/concepts/services-networking/network-policies/
- https://docs.cilium.io/en/stable/network/kubernetes/policy/
