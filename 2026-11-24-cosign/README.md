# Dein Scan sagt „sauber“. Aber ist es auch dein Image? Signieren mit cosign, durchsetzen mit Kyverno

Getestet gegen Kubernetes 1.37.0 (kind, lokal) mit cosign 3.1.4 und Kyverno 1.20.0 (Helm-Chart 3.10.0).

Folge 11 der Serie **Kubernetes Sicherheit**. Trivy hat dir in Folge 9 gesagt, was in einem Image steckt. Hier geht es um die andere Frage: Stammt das Image von dir, und ist es seit dem Bauen unverändert? Du signierst ein Image mit [cosign](https://github.com/sigstore/cosign) und lässt Kyverno im Cluster jeden Pod ablehnen, dessen Image keine passende Signatur hat.

## Voraussetzungen

- Docker
- [`kind`](https://kind.sigs.k8s.io/), `kubectl`, `helm`
- `cosign` (Release-Binary von [github.com/sigstore/cosign/releases](https://github.com/sigstore/cosign/releases) oder über deinen Paketmanager)

## Überblick

```
Schritt 1: Lokale Registry und kind-Cluster anlegen
Schritt 2: Zwei Images bauen, eines davon signieren
Schritt 3: Kyverno installieren und die Regel anlegen
Schritt 4: Signiertes und unsigniertes Image deployen
Schritt 5: Gegenprobe: das Tag wird umgebogen
Schritt 6: Aufräumen
```

---

## Schritt 1: Lokale Registry und kind-Cluster anlegen

Eine kleine Registry im Docker-Netz von kind, damit du nichts ins Internet pushen musst:

```bash
docker network inspect kind >/dev/null 2>&1 || docker network create kind
docker run -d --restart=always --name kind-registry --network kind \
  -p 127.0.0.1:5001:5000 registry:2
```

Der Cluster bekommt eine eigene Kubeconfig-Datei, damit deine `~/.kube/config` unangetastet bleibt. Die Nodes lernen, die Registry per HTTP anzusprechen:

```bash
kind create cluster --config kind-config.yaml --image kindest/node:v1.37.0 \
  --kubeconfig ~/.kube/config.cosign-demo
export KUBECONFIG=~/.kube/config.cosign-demo

for n in $(kind get nodes --name cosign-demo); do
  docker exec "$n" mkdir -p /etc/containerd/certs.d/kind-registry:5000
  printf 'server = "http://kind-registry:5000"\n[host."http://kind-registry:5000"]\n' \
    | docker exec -i "$n" tee /etc/containerd/certs.d/kind-registry:5000/hosts.toml >/dev/null
done
kubectl get nodes
```

## Schritt 2: Zwei Images bauen, eines davon signieren

```bash
docker build -t localhost:5001/shop:1.0 shop/
docker build -t localhost:5001/intruder:1.0 intruder/
docker push localhost:5001/shop:1.0
docker push localhost:5001/intruder:1.0
```

Die zwei Images unterscheiden sich im Inhalt. Das ist wichtig: Eine Signatur gehört zu einer **Digest** (dem Hash des Image-Manifests), nicht zum Namen.

Schlüsselpaar erzeugen. Für die Übung mit leerer Passphrase, im echten Betrieb mit Passphrase oder KMS:

```bash
export COSIGN_PASSWORD=""
cosign generate-key-pair
```

Das legt `cosign.key` (privat, nie weitergeben) und `cosign.pub` an. Dann `shop` signieren, und zwar über die Digest, nicht über das Tag:

```bash
DIGEST=$(docker inspect --format '{{index .RepoDigests 0}}' localhost:5001/shop:1.0)
echo "$DIGEST"
cosign sign --key cosign.key --tlog-upload=false --use-signing-config=false \
  --new-bundle-format=false --yes "$DIGEST"
```

- `--tlog-upload=false` und `--use-signing-config=false`: nichts an das öffentliche Transparenzlog von Sigstore schicken, die Übung läuft ohne Internet-Dienst.
- `--new-bundle-format=false`: legt die Signatur im klassischen Format ab (als Tag mit Endung `.sig`). In meinem Test hat Kyverno 1.20.0 die Signatur im neuen Standardformat von cosign 3 nicht gefunden (`no signatures found`). cosign meldet für das Flag „deprecated“. Prüf bei neueren Versionen, ob du es noch brauchst.

Prüfen von Hand:

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog=true localhost:5001/shop:1.0
```

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog=true localhost:5001/intruder:1.0
```

Das erste liefert die Signatur samt Digest, das zweite endet mit `Error: no signatures found`.

## Schritt 3: Kyverno installieren und die Regel anlegen

Ab Kyverno 1.20 nimmt der Cluster keine alten `ClusterPolicy`-Objekte mehr an (Lesen und Löschen geht noch). Für Signaturen gibt es die `ImageValidatingPolicy` in der API-Gruppe `policies.kyverno.io`.

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --set admissionController.container.extraArgs.allowInsecureRegistry=true
kubectl -n kyverno wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=admission-controller --timeout=180s
```

`allowInsecureRegistry` brauchst du nur, weil unsere Übungs-Registry kein TLS spricht. Im echten Cluster lässt du das weg.

Die Regel steckt in `01-verify-images.yaml.tpl`. Dein öffentlicher Schlüssel kommt per `envsubst` hinein:

```bash
kubectl create namespace shop
export PUBKEY="$(sed 's/^/            /' cosign.pub)"
envsubst < 01-verify-images.yaml.tpl | kubectl apply -f -
kubectl get imagevalidatingpolicy
```

Gelesen heißt die Regel: Für Pods im Namespace `shop` gilt jedes Image aus `kind-registry:5000/*` nur, wenn es mit dem Schlüssel in `cosign.pub` signiert ist. Warte, bis die Spalte `READY` auf `true` steht.

## Schritt 4: Signiertes und unsigniertes Image deployen

```bash
kubectl apply -f 02-pods.yaml
```

```bash
kubectl -n shop get pods
kubectl -n shop get pod shop-signed -o jsonpath='{.spec.containers[0].image}{"\n"}'
```

`shop-signed` läuft. Kyverno hat das Tag `1.0` im Pod durch die Digest ersetzt, damit später niemand das Tag umbiegen kann, ohne dass der Pod es merkt. `shop-unsigned` wird abgelehnt, die Meldung beginnt so:

```
admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-verify-image-signature" denied the request:
Policy verify-image-signature failed: Image ist nicht mit unserem Schlüssel signiert; verification details: image "kind-registry:5000/intruder:1.0@sha256:...", attestor "unserkey": failed to verify cosign signatures: no signatures found
```

## Schritt 5: Gegenprobe: das Tag wird umgebogen

Jemand baut ein anderes Image und pusht es unter dasselbe Tag `shop:1.0`:

```bash
mkdir -p manipuliert
printf 'FROM busybox:1.37\nLABEL app=manipuliert\nCMD ["sh", "-c", "echo manipuliert; sleep 3600"]\n' > manipuliert/Dockerfile
docker build -t localhost:5001/shop:1.0 manipuliert/
docker push localhost:5001/shop:1.0
kubectl -n shop delete pod shop-signed
kubectl -n shop run shop-neu --image=kind-registry:5000/shop:1.0
```

Der Name ist derselbe, der Hash nicht: Die Signatur gehört zur alten Digest, der Pod wird mit `no signatures found` abgelehnt.

## Schritt 6: Aufräumen

```bash
kind delete cluster --name cosign-demo --kubeconfig ~/.kube/config.cosign-demo
docker rm -f kind-registry
rm -rf manipuliert cosign.key cosign.pub
```

## Was die Übung nicht zeigt

- **Keyless-Signieren** (Signatur an eine Identität wie ein GitHub-Konto oder einen CI-Job gebunden, ohne Schlüsseldatei): läuft über die öffentlichen Sigstore-Dienste und braucht Internet. Hier nicht getestet.
- Die Regel gilt nur für den Namespace `shop` und für Images aus der Test-Registry. Images anderer Herkunft prüft sie nicht.
- Eine Signatur sagt, **wer** das Image freigegeben hat, nicht, dass es **sicher** ist. Dafür bleibt Trivy zuständig.
