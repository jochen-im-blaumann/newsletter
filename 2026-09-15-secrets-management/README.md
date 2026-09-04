# Kubernetes Secrets: vom base64-Irrtum zum Sealed Secret

Getestet gegen Kubernetes 1.36 (DOKS, DigitalOcean fra1).

Folge 6 der Serie **Kubernetes Sicherheit**. In dieser Übung legst du zuerst ein normales Kubernetes-Secret an und dekodierst es selbst, um zu sehen, dass `data` nur base64-kodiert ist, nicht verschlüsselt. Danach installierst du den Sealed-Secrets-Controller, versiegelst denselben Wert git-safe, und lässt den Controller ihn im Cluster automatisch zu einem echten Secret zurückverwandeln.

## Voraussetzungen

- Laufender Kubernetes-Cluster (DOKS oder jeder andere) mit `kubectl`-Zugriff
- `kubeseal`-CLI ([Download](https://github.com/bitnami/sealed-secrets/releases))

## Überblick

```
Schritt 1: Secret anlegen
Schritt 2: data-Feld dekodieren — base64, keine Verschlüsselung
Schritt 3: Sealed-Secrets-Controller installieren
Schritt 4: Secret versiegeln (kubeseal)
Schritt 5: Original löschen, SealedSecret anwenden
Schritt 6: Controller hat das Secret automatisch neu erzeugt
Schritt 7: Aufräumen
```

---

## Schritt 1: Secret anlegen

```bash
kubectl create namespace secrets-demo
kubectl create secret generic db-password \
  --from-literal=password='SuperSicher123' \
  -n secrets-demo
```

**Tatsächliche Ausgabe:**

```
namespace/secrets-demo created
secret/db-password created
```

## Schritt 2: data-Feld dekodieren

```bash
kubectl get secret db-password -n secrets-demo -o jsonpath='{.data.password}'
```

Ausgabe: ein kryptisch aussehender String — base64-kodiert. Zur Kontrolle, dass base64 keine Einbahnstraße ist, lässt sich derselbe Wert auch lokal nachvollziehen:

```bash
printf '%s' 'SuperSicher123' | base64
```

**Ausgabe:**

```
U3VwZXJTaWNoZXIxMjM=
```

Exakt der String, der im `data`-Feld des Secrets steht. Und der Rückweg ist genauso trivial:

```bash
echo 'U3VwZXJTaWNoZXIxMjM=' | base64 -d
```

**Ausgabe:**

```
SuperSicher123
```

Zwei Befehle, Klartext-Passwort auf dem Bildschirm. Kein Schlüssel nötig — base64 ist eine Kodierung, keine Verschlüsselung.

## Schritt 3: Sealed-Secrets-Controller installieren

```bash
kubectl apply -f https://github.com/bitnami/sealed-secrets/releases/download/v0.39.1/controller.yaml
kubectl wait --for=condition=Available deployment/sealed-secrets-controller -n kube-system --timeout=120s
```

**Tatsächliche Ausgabe:**

```
serviceaccount/sealed-secrets-controller created
service/sealed-secrets-controller created
role.rbac.authorization.k8s.io/sealed-secrets-service-proxier created
rolebinding.rbac.authorization.k8s.io/sealed-secrets-controller created
role.rbac.authorization.k8s.io/sealed-secrets-key-admin created
clusterrolebinding.rbac.authorization.k8s.io/sealed-secrets-controller created
clusterrole.rbac.authorization.k8s.io/secrets-unsealer created
deployment.apps/sealed-secrets-controller created
customresourcedefinition.apiextensions.k8s.io/sealedsecrets.bitnami.com created
rolebinding.rbac.authorization.k8s.io/sealed-secrets-service-proxier created
service/sealed-secrets-controller-metrics created
deployment.apps/sealed-secrets-controller condition met
```

Der Controller landet standardmäßig im `kube-system`-Namespace und generiert sich beim ersten Start sein eigenes Schlüsselpaar — der private Schlüssel verlässt den Cluster nie.

## Schritt 4: Secret versiegeln

`secret-plain.yaml` enthält denselben Wert wie in Schritt 1, diesmal als Manifest:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-password
  namespace: secrets-demo
type: Opaque
stringData:
  password: SuperSicher123
```

```bash
kubeseal --format yaml --controller-namespace kube-system < secret-plain.yaml > sealed-secret.yaml
cat sealed-secret.yaml
```

**Tatsächliche Ausgabe (gekürzt):**

```
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: db-password
  namespace: secrets-demo
spec:
  encryptedData:
    password: AgB3k9s... (mehrere hundert Zeichen Chiffretext)
```

Kein `data`-Feld mehr, sondern `encryptedData` — mit dem öffentlichen Schlüssel des Controllers verschlüsselt. Dieser Chiffretext ist git-safe: Ohne den privaten Schlüssel des Controllers lässt er sich nicht zurückrechnen, auch nicht mit `base64 -d`.

## Schritt 5: Original löschen, SealedSecret anwenden

```bash
kubectl delete secret db-password -n secrets-demo
kubectl apply -f sealed-secret.yaml
```

**Tatsächliche Ausgabe:**

```
secret "db-password" deleted from secrets-demo namespace
sealedsecret.bitnami.com/db-password created
```

## Schritt 6: Controller hat das Secret automatisch neu erzeugt

```bash
kubectl get sealedsecret db-password -n secrets-demo
kubectl get secret db-password -n secrets-demo
```

**Tatsächliche Ausgabe:**

```
NAME          AGE
db-password   3s

NAME          TYPE     DATA   AGE
db-password   Opaque   1      3s
```

Der Controller beobachtet `SealedSecret`-Objekte, entschlüsselt `encryptedData` mit seinem privaten Schlüssel und erzeugt daraus automatisch ein ganz normales `Secret` — mit demselben `data`-Feld wie in Schritt 1. Der Unterschied: In Git liegt nur der Chiffretext aus Schritt 4, nie der Klartext.

## Schritt 7: Aufräumen

```bash
kubectl delete namespace secrets-demo
kubectl delete -f https://github.com/bitnami/sealed-secrets/releases/download/v0.39.1/controller.yaml
```

---

## Zusammenfassung

| Situation | Ergebnis |
|---|---|
| `kubectl get secret -o jsonpath` + `base64 -d` | 💥 Zwei Befehle, Klartext auf dem Bildschirm |
| Secret-Manifest im Klartext in Git | 💥 Für jeden mit Repo-Zugriff sofort lesbar |
| SealedSecret (`encryptedData`) in Git | ✅ Ohne privaten Schlüssel des Controllers nicht entschlüsselbar |
| SealedSecret im Cluster angewendet | ✅ Controller erzeugt automatisch das echte Secret |

## Referenzen

- https://kubernetes.io/docs/concepts/configuration/secret/
- https://github.com/bitnami/sealed-secrets
