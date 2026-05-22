# Schritt für Schritt: Velero auf DOKS installieren und testen

Getestet gegen einen DigitalOcean Kubernetes Cluster (DOKS) — Kubernetes 1.36.0 (1.36.0-do.0),
Velero v1.17, Plugin velero-plugin-for-aws v1.13. Ablage: DigitalOcean Spaces
(S3-kompatibel). Die Volume-Inhalte sichern wir per File-System-Backup in
denselben Bucket — ein Backend für alles, portabel.

Alle Schritte sind zum Kopieren gehalten. Anpassen musst du nur die Variablen
in Schritt 0.

## Voraussetzungen

- DOKS-Cluster, kubectl darauf gesetzt
- DigitalOcean API-Token (für doctl)
- Ein DigitalOcean Space angelegt (Region z. B. fra1)
- Spaces-Zugangsschlüssel: Dashboard → API → Spaces Keys

## 0 — Variablen setzen

Einmal setzen, dann laufen alle folgenden Befehle ohne Anpassung durch:

```bash
export CLUSTER_NAME="mein-cluster"          # doctl kubernetes cluster list
export SPACES_KEY="DO00XXXXXXXXXXXX"        # Spaces Access Key
export SPACES_SECRET="xxxxxxxxxxxxxxxx"     # Spaces Secret Key
export SPACES_REGION="fra1"                 # Spaces-Region
export SPACES_BUCKET="velero-backups"       # Bucket-Name
export VELERO_VERSION="v1.17.0"
```

## 1 — kubectl auf den Cluster zeigen

```bash
doctl kubernetes cluster kubeconfig save $CLUSTER_NAME
kubectl get nodes
```

## 2 — Velero-CLI installieren

```bash
wget https://github.com/velero-io/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz
tar -xf velero-${VELERO_VERSION}-linux-amd64.tar.gz
sudo mv velero-${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/
velero version --client-only
```

## 3 — Spaces-Credentials anlegen

Datei `credentials-velero` im AWS-Format (es wird die S3-API verwendet):

```bash
cat > credentials-velero << EOF
[default]
aws_access_key_id=${SPACES_KEY}
aws_secret_access_key=${SPACES_SECRET}
EOF
```

## 4 — Velero in den Cluster installieren

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.13.0 \
  --bucket ${SPACES_BUCKET} \
  --backup-location-config region=${SPACES_REGION},s3Url=https://${SPACES_REGION}.digitaloceanspaces.com,checksumAlgorithm="" \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --use-volume-snapshots=false \
  --secret-file ./credentials-velero
```

Die Flags kurz:

- `--provider aws` + Plugin — der S3-API-Treiber. Kein Amazon: er spricht hier den Spaces-Endpunkt an.
- `--use-node-agent` — startet das node-agent-DaemonSet für File-System-Backup.
- `--default-volumes-to-fs-backup` — sichert alle Volumes per Kopia in den Bucket.
- `--use-volume-snapshots=false` — keine Block-Storage-Snapshots; alles geht nach Spaces.
- `checksumAlgorithm=""` — Pflicht für DigitalOcean Spaces; neuere Plugin-Versionen (aws-sdk-go-v2) werfen sonst XAmzContentSHA256Mismatch.

Angelegt werden: Namespace `velero`, Deployment `velero`, DaemonSet `node-agent`,
Secret `cloud-credentials`, die Velero-CRDs sowie eine BackupStorageLocation
namens `default`.

## 5 — Installation prüfen

```bash
kubectl get pods -n velero      # velero-... und node-agent-... → Running
velero backup-location get      # PHASE → Available
```

Erwartete Ausgabe:

```
NAME      PROVIDER   BUCKET/PREFIX    PHASE       ACCESS MODE   DEFAULT
default   aws        velero-backups   Available   ReadWrite     true
```

## 6 — Demo-Anwendung deployen

Eine kleine Shop-Anwendung — sie deckt die typischen Ressourcentypen ab, die
Velero sichern soll: ConfigMap, Secret, PersistentVolumeClaim,
eingebettet in Deployment und Service.

```bash
kubectl apply -f - << 'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo-shop
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-config
  namespace: demo-shop
data:
  APP_ENV: "production"
  APP_NAME: "Demo Shop"
  DB_HOST: "postgres"
  DB_PORT: "5432"
---
apiVersion: v1
kind: Secret
metadata:
  name: shop-secrets
  namespace: demo-shop
type: Opaque
stringData:
  DB_PASSWORD: "s3cur3p@ssw0rd"
  API_KEY: "sk-demo-1234567890abcdef"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shop-data
  namespace: demo-shop
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-web
  namespace: demo-shop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: shop-web
  template:
    metadata:
      labels:
        app: shop-web
    spec:
      containers:
      - name: web
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
        envFrom:
        - configMapRef:
            name: shop-config
        - secretRef:
            name: shop-secrets
        volumeMounts:
        - name: shop-data
          mountPath: /data
      volumes:
      - name: shop-data
        persistentVolumeClaim:
          claimName: shop-data
---
apiVersion: v1
kind: Service
metadata:
  name: shop-web
  namespace: demo-shop
spec:
  selector:
    app: shop-web
  ports:
  - port: 80
    targetPort: 80
EOF
```

Warten, bis der Pod läuft:

```bash
kubectl wait --for=condition=ready pod -l app=shop-web -n demo-shop --timeout=120s
```

Testdaten ins PersistentVolume schreiben:

```bash
POD=$(kubectl get pod -n demo-shop -l app=shop-web -o name)

kubectl exec -n demo-shop $POD -- sh -c '
  echo "Bestellung #1001: Laptop, 999 EUR"   > /data/orders.txt
  echo "Bestellung #1002: Maus, 29 EUR"     >> /data/orders.txt
  echo "Backup-Zeitstempel: '"$(date)"'"    >> /data/orders.txt
'

# Prüfen
kubectl exec -n demo-shop $POD -- cat /data/orders.txt
```

Erwartete Ausgabe:

```
Bestellung #1001: Laptop, 999 EUR
Bestellung #1002: Maus, 29 EUR
Backup-Zeitstempel: Fri May 22 10:44:56 UTC 2026
```

## 7 — Backup erstellen

```bash
velero backup create demo-shop-backup \
  --include-namespaces demo-shop \
  --wait
```

## 8 — Status prüfen

```bash
velero backup get
velero backup describe demo-shop-backup --details
```

Relevante Ausgabe (gekürzt):

```
Phase:  Completed

Namespaces:
  Included:  demo-shop

Backup Volumes:
  Pod Volume Backups - kopia:
    Completed:
      demo-shop/shop-web-...: shop-data
```

Der Eintrag `Pod Volume Backups - kopia` bestätigt: Der Inhalt des PersistentVolume liegt im Bucket.

## 9 — Disaster simulieren

```bash
kubectl delete namespace demo-shop --wait
kubectl get ns demo-shop   # → NotFound
```

## 10 — Wiederherstellen

```bash
velero restore create \
  --from-backup demo-shop-backup \
  --include-namespaces demo-shop \
  --wait
```

Restore-Status prüfen:

```bash
velero restore get
velero restore describe <restore-name> --details
```

## 11 — Restore verifizieren

```bash
kubectl wait --for=condition=ready pod -l app=shop-web -n demo-shop --timeout=120s

# PVC-Inhalt — muss die ursprünglichen Bestellungen enthalten
POD=$(kubectl get pod -n demo-shop -l app=shop-web -o name)
kubectl exec -n demo-shop $POD -- cat /data/orders.txt

# Secret
kubectl get secret shop-secrets -n demo-shop \
  -o jsonpath='{.data.DB_PASSWORD}' | base64 -d

# ConfigMap
kubectl get configmap shop-config -n demo-shop \
  -o jsonpath='{.data.APP_NAME}'
```

Erwartetes Ergebnis:

```
# PVC-Inhalt (Zeitstempel vom Backup, nicht von jetzt):
Bestellung #1001: Laptop, 999 EUR
Bestellung #1002: Maus, 29 EUR
Backup-Zeitstempel: Fri May 22 10:44:56 UTC 2026

# Secret:
s3cur3p@ssw0rd

# ConfigMap:
Demo Shop
```

> **Wichtig:** Velero überschreibt vorhandene Objekte standardmäßig nicht —
> existierende Ressourcen bleiben unverändert und werden im Restore als
> `skipped` gemeldet. Für einen aussagekräftigen Test den Namespace vorher
> löschen (Schritt 9).

## Optional: Automatisches Backup per Schedule

```bash
# Täglich um 02:00 Uhr, 30 Tage aufbewahren
velero schedule create daily-demo-shop \
  --schedule="0 2 * * *" \
  --include-namespaces demo-shop \
  --ttl 720h

velero schedule get
```

## Aufräumen

```bash
# Demo-Anwendung löschen
kubectl delete namespace demo-shop

# Velero deinstallieren
velero uninstall --force

# (Optional) Spaces-Bucket manuell leeren und löschen
```

## Hinweis zur Übung

Getestet gegen einen DOKS-Cluster (Kubernetes 1.36.0) mit Velero v1.17 und dem Plugin
velero-plugin-for-aws v1.13 — mit Ausnahme des vollständigen Cluster-Restores.
Ein kompletter Restore (`velero restore create --from-backup cluster-backup-…`)
ergibt nur Sinn in einen leeren/neuen Cluster; ein Restore in den laufenden
Quellcluster ist kein aussagekräftiger Test. Wer das üben will: neuen
DOKS-Cluster anlegen, Velero identisch installieren (gleiche Version, gleicher
Bucket) und dann den Restore fahren.
