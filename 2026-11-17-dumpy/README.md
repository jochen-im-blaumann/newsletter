# Mit wem redet dein Pod wirklich? Traffic mitschneiden mit dumpy

Getestet gegen Kubernetes 1.37.0 (kind, lokal) mit dumpy 0.2.1.

Folge 10 der Serie **Kubernetes Sicherheit**. Eine App läuft mit drei Replicas in einem Namespace, der per Pod Security Admission auf `restricted` steht. Du willst wissen, mit wem sie redet, bevor du ihr den Weg nach draußen per NetworkPolicy zumachst. `kubectl exec` und `kubectl debug` helfen dir hier nicht weiter. Mit dem kubectl-Plugin [dumpy](https://github.com/larryTheSlap/dumpy) schneidest du an allen drei Pods gleichzeitig mit, findest ein Ziel, von dem keiner wusste, schreibst die Regel und prüfst sie mit einem zweiten Mitschnitt.

## Voraussetzungen

- Docker
- [`kind`](https://kind.sigs.k8s.io/)
- `kubectl`
- `tcpdump` auf deinem Rechner (zum Lesen der Mitschnitte, Wireshark geht genauso)

## Überblick

```
Schritt 1: kind-Cluster anlegen (1 Control Plane, 2 Worker)
Schritt 2: dumpy installieren
Schritt 3: Die App ausrollen (Namespace mit "restricted")
Schritt 4: Die üblichen Wege scheitern
Schritt 5: Mit dumpy an allen Replicas mitschneiden
Schritt 6: Auswerten: mit wem redet die App?
Schritt 7: Egress-Regel schreiben und per Mitschnitt gegenprüfen
Schritt 8: Die Kehrseite: was der Sniffer darf
Schritt 9: Aufräumen
```

---

## Schritt 1: kind-Cluster anlegen

```bash
kind create cluster --config kind-config.yaml --image kindest/node:v1.37.0 \
  --kubeconfig ~/.kube/config.dumpy-demo
export KUBECONFIG=~/.kube/config.dumpy-demo
kubectl get nodes
```

Die eigene Kubeconfig-Datei sorgt dafür, dass deine `~/.kube/config` unangetastet bleibt.

## Schritt 2: dumpy installieren

**Weg A: mit krew.** [krew](https://krew.sigs.k8s.io/) ist der Plugin-Manager für kubectl. Falls du ihn noch nicht hast, installierst du ihn so (Linux und macOS, braucht `git`):

```bash
(
  set -x; cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" &&
  ./"${KREW}" install krew
)
```

krew legt seine Plugins unter `~/.krew/bin` ab. Dieses Verzeichnis muss in deinen `PATH`:

```bash
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
```

Damit das dauerhaft gilt, trag die Zeile in deine `~/.bashrc` oder `~/.zshrc` ein. Prüfen:

```bash
kubectl krew version
```

Dann dumpy installieren:

```bash
kubectl krew install dumpy
```

krew weist dich dabei darauf hin, dass Plugins aus dem Index nicht auf Sicherheit geprüft sind. Nimm das ernst: Ein kubectl-Plugin läuft mit deinen Cluster-Rechten.

**Weg B: von Hand**, ohne krew (Linux, x86_64):

```bash
curl -sLO https://github.com/larryTheSlap/dumpy/releases/download/v0.2.1/dumpy_Linux_x86_64.tar.gz
tar xzf dumpy_Linux_x86_64.tar.gz kubectl-dumpy
sudo mv kubectl-dumpy /usr/local/bin/
```

## Schritt 3: Die App ausrollen

```bash
kubectl apply -f 01-shop.yaml
kubectl -n shop rollout status deploy/shop
kubectl -n shop get pods -o wide
```

Im Namespace `shop` laufen eine `api` und drei Replicas von `shop`. Der Namespace hat das Label `pod-security.kubernetes.io/enforce: restricted`, die Pods laufen ohne root und ohne Capabilities.

## Schritt 4: Die üblichen Wege scheitern

Im Container selbst gibt es kein `tcpdump`:

```bash
kubectl -n shop exec deploy/shop -- tcpdump -i any -c 1
```

```
error: Internal error occurred: ... OCI runtime exec failed: exec failed: unable to start
container process: exec: "tcpdump": executable file not found in $PATH
```

Die Meldung ist lang, entscheidend ist das Ende: `tcpdump` gibt es im Container nicht.

Ein Debug-Container mit Werkzeugkasten wird vom Namespace abgelehnt:

```bash
POD=$(kubectl -n shop get pod -l app=shop -o name | head -1)
kubectl -n shop debug $POD --image=nicolaka/netshoot:v0.14 --target=shop -- tcpdump -i any -c 3
```

```
Error from server (Forbidden): ... violates PodSecurity "restricted:latest":
allowPrivilegeEscalation != false ..., unrestricted capabilities ...
```

Und mit dem passenden Profil startet er zwar, darf aber nicht mitschneiden:

```bash
kubectl -n shop debug $POD --image=nicolaka/netshoot:v0.14 --target=shop \
  --profile=restricted -c dbg -- tcpdump -i any -c 3
kubectl -n shop logs $POD -c dbg
```

Beim ersten Mal muss der Node das Debug-Image erst laden. Meldet `kubectl logs` noch `ContainerCreating`, warte eine Minute und wiederhole den Befehl. Dann steht dort:

```
tcpdump: any: You don't have permission to perform this capture on that device
(socket: Operation not permitted)
```

Das ist kein Fehler, sondern genau das, was `restricted` soll: Zum Mitschneiden braucht es die Capability `NET_RAW`, und die gibt es hier nicht.

## Schritt 5: Mit dumpy an allen Replicas mitschneiden

dumpy startet pro Ziel-Pod einen Sniffer-Pod auf demselben Node. Die Sniffer können in einem **anderen** Namespace laufen als das Ziel. Der Namespace `shop` bleibt also zu.

```bash
kubectl create namespace dumpy
kubectl dumpy capture deployment shop -t shop -n dumpy \
  -f "-i any port 53" --name shop-dns
```

- `-t shop`: Namespace des Ziels
- `-n dumpy`: Namespace für die Sniffer
- `-f`: der Filter, genau so, wie du ihn `tcpdump` mitgeben würdest (hier: nur DNS)

```bash
kubectl dumpy get -n dumpy
```
NAME      NAMESPACE  TARGET           TARGETNAMESPACE  TCPDUMPFILTERS  SNIFFERS
----      ---------  ------           ---------------  --------------  --------
shop-dns  dumpy      deployment/shop  shop             -i any port 53  3/3
```
NAME      NAMESPACE  TARGET           TARGETNAMESPACE  TCPDUMPFILTERS  SNIFFERS
shop-dns  dumpy      deployment/shop  shop             -i any port 53  3/3
```

Drei Replicas, drei Sniffer, ein Befehl. Lass das eine halbe Minute laufen.

## Schritt 6: Auswerten: mit wem redet die App?

Mitschnitte auf deinen Rechner holen, pro Pod eine Datei:

```bash
mkdir -p pcaps
kubectl dumpy export shop-dns ./pcaps -n dumpy
```

Eine `.pcap`-Datei ist das übliche Format für Netzwerk-Mitschnitte. Du kannst sie in [Wireshark](https://www.wireshark.org/) öffnen oder mit `tcpdump` lesen, `-r` steht für "aus Datei lesen":

```bash
f=$(ls pcaps/shop-dns-*.pcap | head -1)
tcpdump -nn -r $f | head -20
```

Jede Zeile ist ein Paket. Zwei Zeilen aus meinem Test:

```
14:12:26.334341 eth0  Out IP 10.244.2.3.41045 > 10.96.0.10.53: 45226+ A? api.shop.svc.cluster.local. (44)
14:12:26.395964 eth0  Out IP 10.244.2.3.49828 > 10.96.0.10.53: 43102+ A? example.com. (29)
```

Von links: Uhrzeit, Netzwerkkarte, Richtung (`Out` heißt: vom Pod weg), Absender, Empfänger (hier der DNS-Dienst des Clusters auf Port 53) und am Ende die Frage. `A? example.com.` bedeutet: "Welche IP-Adresse hat example.com?"

Für die Übersicht reichen die Namen. Welche fragt die App ab? `grep` filtert sie heraus, `sort` und `uniq -c` zählen:

```bash
for f in pcaps/shop-dns-*.pcap; do tcpdump -nn -r $f 2>/dev/null; done \
  | grep -oE ' A\? [^ ]+' | sort | uniq -c
```
     28  A? api.shop.svc.cluster.local.
     28  A? api.shop.svc.cluster.local.cluster.local.
     28  A? api.shop.svc.cluster.local.fritz.box.
     28  A? api.shop.svc.cluster.local.shop.svc.cluster.local.
     28  A? api.shop.svc.cluster.local.svc.cluster.local.
      9  A? example.com.
      9  A? example.com.cluster.local.
      9  A? example.com.fritz.box.
      9  A? example.com.shop.svc.cluster.local.
      9  A? example.com.svc.cluster.local.
```
28  A? api.shop.svc.cluster.local.
 9  A? example.com.
 9  A? example.com.cluster.local.
 9  A? example.com.shop.svc.cluster.local.
 9  A? example.com.svc.cluster.local.
```

Die Zeilen mit angehängter Endung sind die normale Namenssuche in Kubernetes: Der Pod probiert erst alle Suchdomänen durch. Die kannst du überlesen. `fritz.box` ist die Suchdomäne meines Rechners, bei dir steht dort etwas anderes oder nichts. Übrig bleiben zwei echte Ziele: `api.shop.svc.cluster.local.`, das war zu erwarten. Und `example.com.`, davon stand in keiner Doku etwas.

Jetzt der zweite Mitschnitt, diesmal alles außer DNS:

```bash
kubectl dumpy delete shop-dns -n dumpy
kubectl dumpy capture deployment shop -t shop -n dumpy \
  -f "-i any tcp and not port 53" --name shop-tcp
sleep 30
kubectl dumpy export shop-tcp ./pcaps -n dumpy
kubectl dumpy delete shop-tcp -n dumpy
```

```bash
f=$(ls pcaps/shop-tcp-*.pcap | head -1)
tcpdump -nn -A -r $f 2>/dev/null | grep -E 'Authorization|Host:' | sort | uniq -c
```

```
6 Authorization: Bearer geheim-4711
6 Host: api.shop.svc.cluster.local
2 Host: example.com
```

Zwei Erkenntnisse auf einmal: Die App telefoniert nach draußen. Und das Token für die interne API liegt im Mitschnitt im Klartext.

## Schritt 7: Egress-Regel schreiben und gegenprüfen

Jetzt weißt du, was die App braucht: DNS und die `api`. Mehr erlaubt die Regel nicht:

```bash
kubectl apply -f 02-egress-policy.yaml
```

Glauben ist gut, mitschneiden ist besser:

```bash
kubectl dumpy capture deployment shop -t shop -n dumpy \
  -f "-i any tcp and not port 53" --name shop-check
sleep 40
kubectl dumpy export shop-check ./pcaps -n dumpy
kubectl dumpy delete shop-check -n dumpy
f=$(ls pcaps/shop-check-*.pcap | head -1)
tcpdump -nn -r $f 2>/dev/null | grep -E 'Flags \[S' | cut -c1-90
```
14:14:31.022303 eth0  Out IP 10.244.2.3.38322 > 10.96.174.64.80: Flags [S], seq 2047157644
14:14:31.022722 eth0  In  IP 10.96.174.64.80 > 10.244.2.3.38322: Flags [S.], seq 932865433
14:14:31.082097 eth0  Out IP 10.244.2.3.37404 > 104.20.23.154.80: Flags [S], seq 261387785
14:14:31.522874 eth0  Out IP 10.244.2.3.51686 > 172.66.147.243.80: Flags [S], seq 30079282
14:14:32.097584 eth0  Out IP 10.244.2.3.37404 > 104.20.23.154.80: Flags [S], seq 261387785
14:14:32.545774 eth0  Out IP 10.244.2.3.51686 > 172.66.147.243.80: Flags [S], seq 30079282
...
```
eth0  Out IP 10.244.2.3.38322 > 10.96.174.64.80: Flags [S], ...
eth0  In  IP 10.96.174.64.80 > 10.244.2.3.38322: Flags [S.], ...
eth0  Out IP 10.244.2.3.37404 > 104.20.23.154.80: Flags [S], ...
eth0  Out IP 10.244.2.3.37404 > 104.20.23.154.80: Flags [S], ...
eth0  Out IP 10.244.2.3.37404 > 104.20.23.154.80: Flags [S], ...
```

Reihenfolge und Adressen sehen bei dir anders aus, das Muster bleibt: Die ersten beiden Zeilen sind hier die Anfrage an die `api` (10.96.174.64) und deren Antwort (`[S.]`). Danach gehen Anfragen an die beiden Adressen von `example.com` raus, jede Sekunde erneut, und es kommt nie eine Zeile mit `In` zurück. Die Regel greift, und du hast es gesehen statt gehofft.

## Schritt 8: Die Kehrseite: was der Sniffer darf

Starte noch einen Mitschnitt und sieh dir den Sniffer-Pod an:

```bash
kubectl dumpy capture deployment shop -t shop -n dumpy --name blick
kubectl -n dumpy get pod -l dumpy-capture=blick \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  hostPID="}{.spec.hostPID}{"  privileged="}{.spec.containers[0].securityContext.privileged}{"\n"}{end}'
kubectl dumpy delete blick -n dumpy
```
sniffer-blick-0013  hostPID=true  privileged=true
sniffer-blick-4522  hostPID=true  privileged=true
sniffer-blick-9350  hostPID=true  privileged=true
```
sniffer-blick-1234  hostPID=true  privileged=true
```

`privileged` plus `hostPID` heißt: Der Pod ist praktisch root auf dem Node. Deshalb kann er in den Netzwerk-Namespace eines fremden Pods greifen. Versuch es zum Vergleich im abgesicherten Namespace:

```bash
kubectl dumpy capture deployment shop -n shop --name versuch
```

```
Error: ... violates PodSecurity "restricted:latest": host namespaces (hostPID=true),
privileged (container "dumpy-container" must not set securityContext.privileged=true) ...
```

Merke dir daraus drei Dinge:

1. Wer in **irgendeinem** Namespace ohne Pod Security Admission Pods anlegen darf, kann den Traffic **jedes** Pods auf dem Node mitlesen, samt Tokens. Dafür braucht er dumpy nicht, das Plugin macht es nur bequem.
2. Gib dem Sniffer einen eigenen Namespace, auf den nur wenige Leute Zugriff haben, und lösch ihn nach der Fehlersuche wieder.
3. Das Sniffer-Image kommt standardmäßig als `larrytheslap/dumpy:latest` von Docker Hub und läuft privilegiert. Für echte Cluster: Image in die eigene Registry spiegeln, Version festnageln und mit `-i` angeben.

## Schritt 9: Aufräumen

```bash
kubectl delete namespace dumpy
kind delete cluster --name dumpy-demo --kubeconfig ~/.kube/config.dumpy-demo
rm -rf pcaps
unset KUBECONFIG
```
