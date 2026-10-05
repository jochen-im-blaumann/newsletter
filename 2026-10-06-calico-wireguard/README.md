# Pod-Traffic zwischen Nodes verschlüsseln: Calico mit WireGuard

Getestet gegen Kubernetes 1.36 (kind, lokal) mit Calico 3.33.

Folge 8 der Serie **Kubernetes Sicherheit**. In dieser Übung schneidest du den Traffic zwischen zwei Pods auf verschiedenen Nodes mit `tcpdump` mit und liest ein "geheimes" Token im Klartext mit. Dann schaltest du WireGuard in Calico ein, schneidest erneut mit und siehst: Auf der Leitung zwischen den Nodes steht nur noch verschlüsselter UDP-Verkehr.

**Wichtig, bevor du anfängst:** `kind`-Nodes sind Docker-Container und teilen sich den Kernel mit deinem Rechner. WireGuard muss deshalb in **deinem** Host-Kernel verfügbar sein (Linux ab 5.6, bei WSL2 als Modul). Prüfen:

```bash
sudo modprobe wireguard && lsmod | grep wireguard
```

Kommt eine Zeile mit `wireguard` zurück, kann es losgehen.

## Voraussetzungen

- Docker
- [`kind`](https://kind.sigs.k8s.io/) installiert
- `kubectl`
- `jq` (nur für den optionalen Schritt 7)

## Überblick

```
Schritt 1: kind-Cluster ohne CNI anlegen (1 Control Plane, 2 Worker)
Schritt 2: Calico installieren
Schritt 3: Server-Pod, Client-Pod und Sniffer auf verschiedene Nodes setzen
Schritt 4: Mitschneiden ohne WireGuard — das Token liegt im Klartext
Schritt 5: WireGuard einschalten
Schritt 6: Mitschneiden mit WireGuard — nur noch UDP-Rauschen
Schritt 7: Optional — was kostet es? (iperf3)
Schritt 8: Aufräumen
```

---

## Schritt 1: kind-Cluster ohne CNI anlegen

`kind` bringt von Haus aus ein eigenes Netzwerk-Plugin mit. Das schalten wir ab, damit Calico übernehmen kann:

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```bash
kind create cluster --name wg-demo --image kindest/node:v1.36.1 --config kind-config.yaml
```

Die Nodes bleiben jetzt `NotReady`, bis ein Netzwerk-Plugin da ist. Das ist so gewollt.

## Schritt 2: Calico installieren

Calico wird über den Tigera-Operator installiert:

```bash
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/operator-crds.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.0/manifests/tigera-operator.yaml
```

Dazu die Konfiguration. Wir nehmen nur den Teil, den wir brauchen:

```yaml
# calico-installation.yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: 192.168.0.0/16
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
```

`VXLANCrossSubnet` heißt: Zwischen Nodes im selben Subnetz wird nicht gekapselt. Genau wie in einem normalen Rechenzentrum-Netz, deshalb siehst du gleich die Pod-IPs direkt auf der Leitung.

```bash
kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=60s
kubectl apply -f calico-installation.yaml
kubectl wait --for=condition=Ready nodes --all --timeout=300s
```

Das dauert ein, zwei Minuten. Danach:

```bash
kubectl get nodes
```

**Tatsächliche Ausgabe:**

```
NAME                    STATUS   ROLES           AGE     VERSION
wg-demo-control-plane   Ready    control-plane   2m47s   v1.36.1
wg-demo-worker          Ready    <none>          2m32s   v1.36.1
wg-demo-worker2         Ready    <none>          2m32s   v1.36.1
```

## Schritt 3: Server, Client und Sniffer auf verschiedene Nodes setzen

Damit der Traffic wirklich über die Node-Grenze geht, pinnen wir die Pods per `nodeName`. Der Server läuft auf `wg-demo-worker`, der Client auf `wg-demo-worker2`:

```yaml
# 01-server.yaml
apiVersion: v1
kind: Pod
metadata:
  name: server
  labels:
    app: server
spec:
  nodeName: wg-demo-worker
  containers:
    - name: nginx
      image: nginx:1.29
      ports:
        - containerPort: 80
```

```yaml
# 02-client.yaml
apiVersion: v1
kind: Pod
metadata:
  name: client
spec:
  nodeName: wg-demo-worker2
  containers:
    - name: curl
      image: curlimages/curl:8.16.0
      command: ["sleep", "infinity"]
```

Der dritte Pod ist unser Mitleser. Er läuft mit `hostNetwork: true` auf dem Server-Node und sieht damit die echte Netzwerkkarte des Nodes (`eth0`), also genau das, was auch ein Angreifer im Rechenzentrum am Kabel sehen würde:

```yaml
# 03-sniffer.yaml
apiVersion: v1
kind: Pod
metadata:
  name: sniffer
spec:
  nodeName: wg-demo-worker
  hostNetwork: true
  containers:
    - name: tcpdump
      image: nicolaka/netshoot:latest
      command: ["sleep", "infinity"]
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW"]
```

```bash
kubectl apply -f 01-server.yaml -f 02-client.yaml -f 03-sniffer.yaml
kubectl wait --for=condition=Ready pod --all --timeout=240s
kubectl get pods -o wide
```

**Tatsächliche Ausgabe:**

```
NAME      READY   STATUS    RESTARTS   AGE   IP               NODE
client    1/1     Running   0          56s   192.168.51.194   wg-demo-worker2
server    1/1     Running   0          56s   192.168.69.70    wg-demo-worker
sniffer   1/1     Running   0          56s   172.20.0.2       wg-demo-worker
```

Deine IPs weichen ab. Wichtig ist nur: Server und Client stehen auf verschiedenen Nodes.

## Schritt 4: Mitschneiden ohne WireGuard

Erst die Server-IP merken, dann den Mitschnitt im Hintergrund starten und währenddessen vom Client aus einen Request mit "geheimem" Token schicken:

```bash
SERVER_IP=$(kubectl get pod server -o jsonpath='{.status.podIP}')

kubectl exec sniffer -- timeout 8 tcpdump -i eth0 -nn -A 'tcp port 80' > dump-vorher.txt &
sleep 3
kubectl exec client -- curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer geheim-4711" http://$SERVER_IP
wait
```

```bash
grep -a -E "Authorization|GET /" dump-vorher.txt
```

**Tatsächliche Ausgabe:**

```
c..&I5..GET / HTTP/1.1
Authorization: Bearer geheim-4711
```

Da steht es: Pfad, Header, Token, alles im Klartext. Und `tcpdump` lief nicht im Pod des Clients oder des Servers, sondern auf der Netzwerkkarte des Nodes dazwischen. Genau dort sitzt im Rechenzentrum jemand, der "nur" am Netzwerk ist.

Auch die Pod-IPs sind direkt sichtbar:

```bash
grep -a -E "IP .* > .*\.80:" dump-vorher.txt | head -3
```

```
08:29:36.597689 IP 192.168.51.194.54202 > 192.168.69.70.80: Flags [S], ...
```

Eine NetworkPolicy (Folge 5) hätte diesen Request erlaubt oder verboten. Verschlüsselt hätte sie ihn nicht.

## Schritt 5: WireGuard einschalten

Ein Befehl, im laufenden Betrieb, ohne Cluster-Neubau:

```bash
kubectl patch felixconfiguration default --type='merge' \
  -p '{"spec":{"wireguardEnabled":true}}'
```

Calico erzeugt jetzt pro Node einen Schlüssel, verteilt die Public Keys und baut die Verbindungen auf. Nach ein paar Sekunden:

```bash
kubectl get nodes -o yaml | grep -i wireguard
```

**Tatsächliche Ausgabe (gekürzt):**

```
      projectcalico.org/IPv4WireguardInterfaceAddr: 192.168.51.195
      projectcalico.org/WireguardPublicKey: VZ4xUa4jNDUg9xXSkjjLnK9g5NmL1i1svwrKVhVrp0I=
      ...
```

Und auf dem Node gibt es ein neues Interface:

```bash
docker exec wg-demo-worker ip -br link show wireguard.cali
```

```
wireguard.cali   UNKNOWN        <POINTOPOINT,NOARP,UP,LOWER_UP>
```

Ein `wg show` gibt es auf den Nodes nicht, das Tool ist dort nicht installiert. Ob der Tunnel steht, siehst du am Interface `wireguard.cali`.

## Schritt 6: Mitschneiden mit WireGuard

Dasselbe Spiel wie in Schritt 4. Diesmal schneiden wir auf `eth0` sowohl `tcp port 80` als auch `udp port 51820` mit (51820 ist der WireGuard-Port):

```bash
kubectl exec sniffer -- timeout 8 tcpdump -i eth0 -nn -A 'udp port 51820 or tcp port 80' > dump-nachher.txt &
sleep 3
kubectl exec client -- curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer geheim-4711" http://$SERVER_IP
wait
```

Zuerst: Taucht das Token noch auf?

```bash
grep -a -c "Authorization" dump-nachher.txt
```

**Tatsächliche Ausgabe:**

```
0
```

Null Treffer. Und was steht stattdessen auf der Leitung?

```bash
grep -a -E "^[0-9:.]+ IP " dump-nachher.txt | head -4
```

**Tatsächliche Ausgabe:**

```
08:30:25.825751 IP 172.20.0.4.51820 > 172.20.0.2.51820: UDP, length 148
08:30:25.826044 IP 172.20.0.2.51820 > 172.20.0.4.51820: UDP, length 92
08:30:25.826250 IP 172.20.0.4.51820 > 172.20.0.2.51820: UDP, length 96
08:30:25.826449 IP 172.20.0.2.51820 > 172.20.0.4.51820: UDP, length 96
```

Nur noch UDP zwischen den **Node**-IPs (`172.20.0.x`) auf Port 51820. Keine Pod-IPs mehr, kein HTTP, kein Token. Die Pod-IPs sieht der Mitleser auf der Leitung nicht mal mehr.

Zur Gegenprobe schneiden wir auf dem WireGuard-Interface selbst mit, also **vor** der Verschlüsselung:

```bash
kubectl exec sniffer -- timeout 6 tcpdump -i wireguard.cali -nn -A 'tcp port 80' > dump-wg.txt &
sleep 2
kubectl exec client -- curl -s -o /dev/null -H "Authorization: Bearer geheim-4711" http://$SERVER_IP
wait
grep -a "Authorization" dump-wg.txt
```

**Tatsächliche Ausgabe:**

```
Authorization: Bearer geheim-4711
```

Auf `wireguard.cali` steht das Token wieder im Klartext, auf `eth0` ist es weg. Das ist die Grenze der Maßnahme: WireGuard schützt die Strecke **zwischen** den Nodes. Wer root auf einem Node hat, sieht den Traffic davor und danach weiterhin. Gegen den Mitleser im Netzwerk hilft es, gegen den Admin auf dem Node nicht.

Wie viel Traffic wirklich durch den Tunnel ging, zeigt der Zähler:

```bash
docker exec wg-demo-worker cat /sys/class/net/wireguard.cali/statistics/rx_bytes
```

```
1716
```

## Schritt 7 (optional): Was kostet es? Messen mit iperf3

```yaml
# 04-iperf.yaml
apiVersion: v1
kind: Pod
metadata:
  name: iperf-server
spec:
  nodeName: wg-demo-worker
  containers:
    - name: iperf3
      image: networkstatic/iperf3
      args: ["-s"]
---
apiVersion: v1
kind: Pod
metadata:
  name: iperf-client
spec:
  nodeName: wg-demo-worker2
  containers:
    - name: iperf3
      image: networkstatic/iperf3
      command: ["sleep", "infinity"]
```

```bash
kubectl apply -f 04-iperf.yaml
kubectl wait --for=condition=Ready pod/iperf-server pod/iperf-client --timeout=240s
IP=$(kubectl get pod iperf-server -o jsonpath='{.status.podIP}')

# Mit WireGuard (ist ja noch an), drei Läufe à 5 Sekunden
for i in 1 2 3; do
  kubectl exec iperf-client -- iperf3 -c $IP -t 5 -J | jq '.end.sum_received.bits_per_second/1e9'
done

# WireGuard aus, dieselben Läufe
kubectl patch felixconfiguration default --type=merge -p '{"spec":{"wireguardEnabled":false}}'
sleep 15
for i in 1 2 3; do
  kubectl exec iperf-client -- iperf3 -c $IP -t 5 -J | jq '.end.sum_received.bits_per_second/1e9'
done
```

**Meine Werte (Gbit/s, WSL2-Laptop, kind):**

| | Gbit/s |
|---|---|
| mit WireGuard | 0,39 / 0,38 / 0,38 |
| ohne WireGuard | 11,3 / 11,4 / 11,0 |

**Nimm diese Zahlen nicht als Maßstab.** Bei `kind` laufen alle Nodes als Container auf einem Rechner, ohne echte Netzwerkkarte dazwischen. Ohne WireGuard ist das Netz deshalb unrealistisch schnell, und mit WireGuard rechnet die CPU des Laptops die komplette Verschlüsselung allein. Der Abstand ist hier viel größer als in der Praxis: Auf zwei DigitalOcean-Droplets (`s-2vcpu-4gb`, Frankfurt, Kubernetes 1.37.1, Calico 3.31.2) lag der Pod-zu-Pod-Durchsatz mit WireGuard bei rund 40 bis 45 Prozent des Wertes ohne WireGuard. Die Übung zeigt dir, **wie** du misst. Für belastbare Zahlen wiederholst du den Test auf der Hardware, auf der dein Cluster wirklich läuft.

## Schritt 8: Aufräumen

```bash
kind delete cluster --name wg-demo
rm -f dump-vorher.txt dump-nachher.txt dump-wg.txt
```

| Situation | Ergebnis |
|---|---|
| Standard-Cluster, Calico ohne WireGuard | 💥 Pod-Traffic zwischen Nodes im Klartext, Mitleser am Netzwerk liest Header und Tokens |
| NetworkPolicy allein | ⚠️ Regelt, wer reden darf, verschlüsselt nichts |
| Calico mit `wireguardEnabled: true` | ✅ Auf der Leitung nur UDP 51820 zwischen den Nodes |
| WireGuard an, Angreifer hat root auf dem Node | ⚠️ Sieht den Traffic vor dem Tunnel weiterhin |
| `hostNetwork`-Pods | ⚠️ Gehen nicht automatisch durch den Tunnel |

Der Unterschied zu den letzten Ausgaben: Bei RBAC, PSA, Gatekeeper und Kyverno ging es darum, was im Cluster erlaubt ist, bei NetworkPolicy darum, wer mit wem reden darf. Heute geht es um das, was auf dem Weg dazwischen passiert, nämlich ob jemand mitliest.
