# CloudNativePG: Backup und Point-in-Time Recovery

Getestet gegen Kubernetes 1.32 (DOKS, DigitalOcean fra1).

In dieser Übung installierst du den CloudNativePG Operator, legst einen PostgreSQL-Cluster mit zwei Replicas an, richtest WAL-Archivierung zu einem S3-kompatiblen Object Store ein, und führst eine Point-in-Time Recovery durch.

## Voraussetzungen

- `kubectl` konfiguriert gegen einen laufenden DOKS-Cluster
- `helm` installiert
- Zugang zu einem S3-kompatiblen Object Store (DigitalOcean Spaces oder lokales MinIO)
- `kubectl cnpg` Plugin (optional, vereinfacht Diagnose)

Plugin installieren:

```bash
curl -sSfL \
  https://github.com/cloudnative-pg/cloudnative-pg/releases/latest/download/kubectl-cnpg_linux_amd64.tar.gz \
  | tar -xz -C /usr/local/bin kubectl-cnpg
```

## Schritt 1: CloudNativePG Operator installieren

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.0.yaml
```

Warten bis der Controller läuft:

```bash
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager
```

Verfügbare CRDs prüfen:

```bash
kubectl get crds | grep cnpg
```

## Schritt 2: Credentials für Object Store anlegen

Ersetze `<ACCESS_KEY>` und `<SECRET_KEY>` mit deinen Spaces- oder MinIO-Credentials:

```bash
kubectl create namespace production

kubectl -n production create secret generic backup-creds \
  --from-literal=ACCESS_KEY_ID=<ACCESS_KEY> \
  --from-literal=SECRET_ACCESS_KEY=<SECRET_KEY>
```

## Schritt 3: PostgreSQL-Cluster mit Backup anlegen

Passe `destinationPath` und `endpointURL` auf deinen Object Store an. Für DigitalOcean Spaces in `fra1` wäre `endpointURL: https://fra1.digitaloceanspaces.com`.

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

Cluster-Status beobachten:

```bash
kubectl -n production get cluster postgres-prod -w
```

Sobald `STATUS` auf `Cluster in healthy state` wechselt und `READY` auf `3/3` steht, läuft der Cluster.

## Schritt 4: Testdaten einfügen

Primary-Pod ermitteln und einloggen:

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

## Schritt 5: On-Demand-Backup erstellen

Merke dir die aktuelle Uhrzeit — du wirst sie für PITR brauchen.

```bash
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
```

Backup-Status prüfen:

```bash
kubectl -n production get backup backup-uebung
```

Warte bis `PHASE` auf `completed` steht. WAL-Archivierung läuft kontinuierlich im Hintergrund.

## Schritt 6: Weitere Daten einfügen (nach dem Backup)

```bash
kubectl -n production exec -it $PRIMARY -- psql -U postgres -c \
  "INSERT INTO orders (product) VALUES ('Nach-Backup-Artikel');"
```

Merke dir erneut die aktuelle Uhrzeit als `RESTORE_TIME` — du willst später **vor** diesem Insert wiederherstellen.

## Schritt 7: Cluster löschen (Disaster simulieren)

```bash
kubectl -n production delete cluster postgres-prod
```

Alle Pods und PVCs werden gelöscht. Die Daten im Object Store bleiben.

## Schritt 8: Point-in-Time Recovery

Ersetze `YYYY-MM-DD HH:MM:SS` mit der Zeit aus Schritt 5 (nach dem Backup, vor Schritt 6):

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
```

Recovery-Fortschritt beobachten:

```bash
kubectl -n production get cluster postgres-restored -w
```

## Schritt 9: Daten prüfen

```bash
RESTORED=$(kubectl -n production get cluster postgres-restored \
  -o jsonpath='{.status.currentPrimary}')

kubectl -n production exec -it $RESTORED -- psql -U postgres -c \
  "SELECT * FROM orders;"
```

Erwartetes Ergebnis: Die drei ursprünglichen Artikel (`Widget`, `Gadget`, `Gizmo`) sind vorhanden. Der `Nach-Backup-Artikel` aus Schritt 6 fehlt — du hast exakt bis `targetTime` zurückgestellt.

## Aufräumen

```bash
kubectl delete namespace production
kubectl delete -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.0.yaml
```
