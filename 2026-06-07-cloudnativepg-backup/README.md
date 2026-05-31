# CloudNativePG: Backup und Point-in-Time Recovery

Getestet gegen Kubernetes 1.33.12 (DOKS, DigitalOcean fra1).

In dieser Übung installierst du den CloudNativePG Operator, legst einen PostgreSQL-Cluster mit zwei Replicas an, richtest WAL-Archivierung zu einem S3-kompatiblen Object Store ein, und führst eine Point-in-Time Recovery durch.

## Voraussetzungen

- `kubectl` konfiguriert gegen einen laufenden Kubernetes-Cluster
- Zugang zu einem S3-kompatiblen Object Store — entweder DigitalOcean Spaces oder MinIO lokal im Cluster (Option A unten)

## Option A: MinIO im Cluster (ohne externen Storage)

MinIO deployen und Bucket anlegen:

```bash
kubectl create namespace minio

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args: ["server", "/data"]
        env:
        - name: MINIO_ROOT_USER
          value: minioadmin
        - name: MINIO_ROOT_PASSWORD
          value: minioadmin
        ports:
        - containerPort: 9000
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  selector:
    app: minio
  ports:
  - port: 9000
EOF

cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-init
  namespace: minio
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: mc
        image: minio/mc:latest
        command: ["sh", "-c", "mc alias set local http://minio.minio.svc.cluster.local:9000 minioadmin minioadmin && mc mb local/cnpg-backups --ignore-existing"]
EOF

kubectl -n minio wait --for=condition=complete job/minio-init --timeout=60s
```

Verwende dann in Schritt 2 und 3:
- `ACCESS_KEY_ID` / `SECRET_ACCESS_KEY`: `minioadmin`
- `endpointURL`: `http://minio.minio.svc.cluster.local:9000`
- `destinationPath`: `s3://cnpg-backups/postgres-prod`

## Schritt 1: CloudNativePG Operator installieren

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.0.yaml

kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager
```

## Schritt 2: Namespace und Credentials anlegen

```bash
kubectl create namespace production

kubectl -n production create secret generic backup-creds \
  --from-literal=ACCESS_KEY_ID=<ACCESS_KEY> \
  --from-literal=SECRET_ACCESS_KEY=<SECRET_KEY>
```

## Schritt 3: PostgreSQL-Cluster mit Backup anlegen

Passe `destinationPath` und `endpointURL` auf deinen Object Store an. Für DigitalOcean Spaces in `fra1`: `endpointURL: https://fra1.digitaloceanspaces.com`.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-prod
  namespace: production
spec:
  instances: 3
  storage:
    size: 2Gi
  backup:
    barmanObjectStore:
      destinationPath: s3://dein-bucket/postgres-prod
      endpointURL: https://fra1.digitaloceanspaces.com
      s3Credentials:
        accessKeyId:
          name: backup-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: backup-creds
          key: SECRET_ACCESS_KEY
      wal:
        compression: gzip
    retentionPolicy: "7d"
EOF
```

Warten bis der Cluster healthy ist:

```bash
kubectl -n production get cluster postgres-prod -w
# Fertig wenn: STATUS "Cluster in healthy state", READY 3/3
```

## Schritt 4: Testdaten einfügen

```bash
PRIMARY=$(kubectl -n production get cluster postgres-prod \
  -o jsonpath='{.status.currentPrimary}')

kubectl -n production exec -it $PRIMARY -- psql -U postgres
```

In psql:

```bash
CREATE TABLE orders (id serial PRIMARY KEY, product text, ts timestamptz DEFAULT now());
INSERT INTO orders (product) VALUES ('Widget'), ('Gadget'), ('Gizmo');
SELECT * FROM orders;
\q
```

## Schritt 5: WAL wechseln und Backup erstellen

Der WAL-Switch sorgt dafür, dass alle bisherigen Änderungen sofort archiviert werden:

```bash
kubectl -n production exec $PRIMARY -- psql -U postgres -c "SELECT pg_switch_wal();"

cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: backup-uebung
  namespace: production
spec:
  cluster:
    name: postgres-prod
  method: barmanObjectStore
EOF

kubectl -n production get backup backup-uebung -w
# Warten bis PHASE "completed"
```

## Schritt 6: PITR-Zeitpunkt notieren und Post-Backup-Daten einfügen

```bash
# Aktuellen Zeitpunkt (UTC) als RESTORE_TIME merken
kubectl -n production exec $PRIMARY -- psql -U postgres -t -c \
  "SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SS');"

# Daten einfügen, die nach dem Restore NICHT vorhanden sein sollen
kubectl -n production exec $PRIMARY -- psql -U postgres -c \
  "INSERT INTO orders (product) VALUES ('Nach-Backup-Artikel');"

# WAL wechseln damit der neue Insert archiviert wird vor dem Löschen
kubectl -n production exec $PRIMARY -- psql -U postgres -c "SELECT pg_switch_wal();"
```

## Schritt 7: Cluster löschen (Disaster simulieren)

```bash
kubectl -n production delete cluster postgres-prod
```

Alle Pods und PVCs werden gelöscht. Die Daten im Object Store bleiben.

## Schritt 8: Point-in-Time Recovery

Ersetze `YYYY-MM-DD HH:MM:SS` mit dem `RESTORE_TIME` aus Schritt 6:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-restored
  namespace: production
spec:
  instances: 3
  storage:
    size: 2Gi
  bootstrap:
    recovery:
      source: postgres-prod
      recoveryTarget:
        targetTime: "YYYY-MM-DD HH:MM:SS"
  externalClusters:
    - name: postgres-prod
      barmanObjectStore:
        destinationPath: s3://dein-bucket/postgres-prod
        endpointURL: https://fra1.digitaloceanspaces.com
        s3Credentials:
          accessKeyId:
            name: backup-creds
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: backup-creds
            key: SECRET_ACCESS_KEY
EOF

kubectl -n production get cluster postgres-restored -w
# Warten bis STATUS "Cluster in healthy state", READY 3/3
```

## Schritt 9: Daten prüfen

```bash
RESTORED=$(kubectl -n production get cluster postgres-restored \
  -o jsonpath='{.status.currentPrimary}')

kubectl -n production exec -it $RESTORED -- psql -U postgres -c \
  "SELECT * FROM orders;"
```

Erwartetes Ergebnis: `Widget`, `Gadget`, `Gizmo` sind vorhanden. `Nach-Backup-Artikel` fehlt — der Restore endete exakt bei `RESTORE_TIME`.

## Aufräumen

```bash
kubectl delete namespace production
kubectl delete namespace minio   # nur bei Option A
kubectl delete -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.0.yaml
```
