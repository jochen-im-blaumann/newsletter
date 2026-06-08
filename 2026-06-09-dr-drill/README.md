# Disaster Recovery Drill: etcd + CloudNativePG auf kubeadm

Getestet gegen Kubernetes 1.35 (kubeadm, DigitalOcean fra1).

In dieser Übung baust du einen kubeadm-Cluster von Grund auf, richtest zwei Backup-Ebenen ein (etcd-Snapshot + CloudNativePG WAL-Archivierung), simulierst einen echten Datenverlust und stellst alles wieder her. Das ist kein Trockenübung — du wirst Daten löschen und sie wiederholen.

## Voraussetzungen

- DigitalOcean-Account mit API-Token (ca. $0.50 für diese Übung)
- `terraform` >= 1.5 installiert
- `ansible` installiert (`pip install ansible`)
- `kubectl` installiert

## Überblick

```
Schritt 1-3:  Cluster aufsetzen (kubeadm, 1 CP + 1 Worker)
Schritt 4-5:  MinIO + CloudNativePG deployen
Schritt 6:    Testdaten einfügen
Schritt 7:    etcd-Snapshot + WAL-Archivierung einrichten
Schritt 8:    Datenverlust simulieren (DROP TABLE)
Schritt 9:    CloudNativePG PITR — Wiederherstellung
Schritt 10:   Aufräumen
```

---

## Schritt 1: Cluster-VMs hochziehen

```bash
cd terraform
```

Erstelle eine `terraform.tfvars` mit deinem DO-Token:

```bash
cat <<EOF > terraform.tfvars
do_token = "dop_v1_..."
EOF
```

Cluster starten:

```bash
terraform init
terraform apply
```

Nach ca. 3 Minuten gibt Terraform zwei IPs aus:

```bash
# Outputs:
# control_plane_ip = "X.X.X.X"
# worker_ip        = "Y.Y.Y.Y"
# ssh_command      = "ssh -i ./id_rsa_dr_drill root@X.X.X.X"
```

Warte 2-3 Minuten bis cloud-init auf beiden Nodes fertig ist:

```bash
ssh -i terraform/id_rsa_dr_drill root@<CP_IP> \
  "tail -1 /var/log/cloud-init-k8s.log"
# kubeadm v1.35 + etcdctl v3.5.14 ready on dr-drill-cp
```

---

## Schritt 2: kubeadm init auf dem Control Plane

SSH auf den Control Plane:

```bash
ssh -i terraform/id_rsa_dr_drill root@<CP_IP>
```

Cluster initialisieren:

```bash
kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --apiserver-cert-extra-sans=<CP_IP>
```

kubeconfig für root einrichten:

```bash
mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config
```

Calico als CNI installieren:

```bash
kubectl create -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.31.2/manifests/tigera-operator.yaml

kubectl create -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.31.2/manifests/custom-resources.yaml
```

Warten bis Calico läuft:

```bash
kubectl -n calico-system rollout status deployment/calico-kube-controllers
```

---

## Schritt 3: Worker joinen

Auf dem Control Plane den Join-Command holen:

```bash
kubeadm token create --print-join-command
```

In einem neuen Terminal auf dem Worker ausführen:

```bash
ssh -i terraform/id_rsa_dr_drill root@<WORKER_IP>
# dann den kubeadm join ... Befehl einfügen
```

Zurück auf dem Control Plane prüfen:

```bash
kubectl get nodes
# NAME             STATUS   ROLES           AGE   VERSION
# dr-drill-cp      Ready    control-plane   3m    v1.35.x
# dr-drill-worker  Ready    <none>          60s   v1.35.x
```

---

## Schritt 4: StorageClass + MinIO deployen (WAL-Storage im Cluster)

Kubeadm hat keine Default-StorageClass. Zuerst den Local-Path-Provisioner installieren:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml

kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

kubectl get storageclass
# NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

MinIO als In-Cluster-Object-Store deployen — kein externer S3-Bucket nötig:

```bash
kubectl create namespace minio

kubectl -n minio apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
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
        image: quay.io/minio/minio:latest
        args: ["server", "/data", "--console-address", ":9001"]
        env:
        - name: MINIO_ROOT_USER
          value: minioadmin
        - name: MINIO_ROOT_PASSWORD
          value: minioadmin
        ports:
        - containerPort: 9000
        - containerPort: 9001
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 5Gi
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
  - name: api
    port: 9000
  - name: console
    port: 9001
EOF
```

Warte bis MinIO läuft:

```bash
kubectl -n minio rollout status deployment/minio
```

MinIO-Buckets anlegen (`mc`-Container hat kein Shell-Entrypoint — Job mit init-Container verwenden):

```bash
MINIO_IP=$(kubectl -n minio get svc minio -o jsonpath='{.spec.clusterIP}')

kubectl -n minio apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-setup
  namespace: minio
spec:
  template:
    spec:
      restartPolicy: Never
      initContainers:
      - name: get-mc
        image: quay.io/minio/mc:latest
        command: ["cp", "/usr/bin/mc", "/shared/mc"]
        volumeMounts:
        - name: shared
          mountPath: /shared
      containers:
      - name: setup
        image: alpine:latest
        command: ["/bin/sh", "-c", "/shared/mc alias set local http://${MINIO_IP}:9000 minioadmin minioadmin && /shared/mc mb local/postgres-wal && /shared/mc mb local/etcd-backups && echo done"]
        volumeMounts:
        - name: shared
          mountPath: /shared
      volumes:
      - name: shared
        emptyDir: {}
EOF

kubectl -n minio wait --for=condition=Complete job/minio-setup --timeout=60s
kubectl -n minio logs job/minio-setup
# Added 'local' successfully.
# Bucket created successfully 'local/postgres-wal'.
# Bucket created successfully 'local/etcd-backups'.
# done
kubectl -n minio delete job minio-setup
```

---

## Schritt 5: CloudNativePG Operator + PostgreSQL-Cluster

Operator installieren:

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.0.yaml

kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager
```

S3-Credentials für MinIO (kein HTTPS, daher `endpointCA` nicht nötig):

```bash
kubectl create namespace production

kubectl -n production create secret generic minio-creds \
  --from-literal=ACCESS_KEY_ID=minioadmin \
  --from-literal=SECRET_ACCESS_KEY=minioadmin
```

PostgreSQL-Cluster mit WAL-Archivierung zu MinIO:

```bash
MINIO_IP=$(kubectl -n minio get svc minio -o jsonpath='{.spec.clusterIP}')

kubectl -n production apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-prod
spec:
  instances: 2
  storage:
    size: 2Gi
  backup:
    barmanObjectStore:
      destinationPath: s3://postgres-wal/postgres-prod
      endpointURL: http://${MINIO_IP}:9000
      s3Credentials:
        accessKeyId:
          name: minio-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: minio-creds
          key: SECRET_ACCESS_KEY
      wal:
        compression: gzip
    retentionPolicy: "7d"
EOF
```

Warte bis der Cluster healthy ist:

```bash
kubectl -n production get cluster postgres-prod -w
# NAME            AGE   INSTANCES   READY   STATUS                     PRIMARY
# postgres-prod   2m    2           2       Cluster in healthy state    postgres-prod-1
```

---

## Schritt 6: Testdaten einfügen

Primary-Pod ermitteln und Daten anlegen:

```bash
PRIMARY=$(kubectl -n production get cluster postgres-prod \
  -o jsonpath='{.status.currentPrimary}')

kubectl -n production exec -it $PRIMARY -- psql -U postgres <<'SQL'
CREATE TABLE orders (
  id      serial PRIMARY KEY,
  product text,
  menge   int,
  ts      timestamptz DEFAULT now()
);
INSERT INTO orders (product, menge) VALUES
  ('Widget',  100),
  ('Gadget',   50),
  ('Gizmo',   200);
SELECT * FROM orders;
SQL
```

Erwartete Ausgabe:

```
 id | product | menge |             ts
----+---------+-------+----------------------------
  1 | Widget  |   100 | 2026-06-09 10:15:00+00
  2 | Gadget  |    50 | 2026-06-09 10:15:01+00
  3 | Gizmo   |   200 | 2026-06-09 10:15:02+00
```

---

## Schritt 7: Backups sicherstellen

### 7a: etcd-Snapshot

Das etcd-Container-Image hat kein `tar` — `kubectl cp` schlägt fehl. Stattdessen direkt `etcdctl` auf dem Host nutzen (wird von cloud-init installiert):

```bash
SNAP_FILE="/tmp/etcd-snap-$(date +%F-%H%M).db"

ETCDCTL_API=3 etcdctl snapshot save $SNAP_FILE \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

etcdutl snapshot status $SNAP_FILE --write-out=table
# +----------+----------+------------+------------+
# |   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
# +----------+----------+------------+------------+
# | d86382aa |     3416 |       2231 |      13 MB |
# +----------+----------+------------+------------+
```

### 7b: CloudNativePG On-Demand-Backup

Merke dir die aktuelle Uhrzeit — sie wird für die PITR gebraucht:

```bash
date -u "+%Y-%m-%d %H:%M:%S"
# z.B. 2026-06-09 10:20:00
```

```bash
kubectl -n production apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: backup-vor-drill
spec:
  cluster:
    name: postgres-prod
  method: barmanObjectStore
EOF
```

```bash
kubectl -n production get backup backup-vor-drill -w
# NAME              AGE   CLUSTER        METHOD              PHASE
# backup-vor-drill  45s   postgres-prod  barmanObjectStore   completed
```

---

## Schritt 8: Datenverlust simulieren

Jetzt kommt der Teil, der Herzrasen macht. Merke dir die Uhrzeit direkt vor dem Delete:

```bash
date -u "+%Y-%m-%d %H:%M:%S"
# RESTORE_TIME = dieser Wert minus 30 Sekunden
```

```bash
kubectl -n production exec -it $PRIMARY -- psql -U postgres -c \
  "DROP TABLE orders;"
```

Verify — die Tabelle ist weg:

```bash
kubectl -n production exec -it $PRIMARY -- psql -U postgres -c \
  "\dt"
# Did not find any relations.
```

---

## Schritt 9: Point-in-Time Recovery

**Wichtig:** Zuerst einen WAL-Switch erzwingen, damit das aktuelle WAL-Segment (das den DROP TABLE enthält) ins Archiv kommt. Ohne diesen Schritt schlägt die Recovery mit "recovery ended before configured recovery target was reached" fehl:

```bash
kubectl -n production exec -it $PRIMARY -- psql -U postgres -c \
  'CHECKPOINT; SELECT pg_switch_wal();'
```

Warte 30 Sekunden, bis das WAL-Segment in MinIO archiviert ist.

Ersetze `YYYY-MM-DD HH:MM:SS` mit dem Zeitstempel aus Schritt 7b (kurz nach dem On-Demand-Backup, kurz vor dem DROP TABLE):

```bash
MINIO_IP=$(kubectl -n minio get svc minio -o jsonpath='{.spec.clusterIP}')

kubectl -n production apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-restored
spec:
  instances: 2
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
        destinationPath: s3://postgres-wal/postgres-prod
        endpointURL: http://${MINIO_IP}:9000
        s3Credentials:
          accessKeyId:
            name: minio-creds
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: minio-creds
            key: SECRET_ACCESS_KEY
EOF
```

Recovery-Fortschritt beobachten:

```bash
kubectl -n production get cluster postgres-restored -w
```

Sobald `Cluster in healthy state`:

```bash
RESTORED=$(kubectl -n production get cluster postgres-restored \
  -o jsonpath='{.status.currentPrimary}')

kubectl -n production exec -it $RESTORED -- psql -U postgres -c \
  "SELECT * FROM orders;"
```

Erwartetes Ergebnis: alle drei Zeilen (Widget, Gadget, Gizmo) sind zurück.

---

## Schritt 10: Aufräumen

**Kubernetes-Ressourcen:**

```bash
kubectl delete namespace production minio
kubectl delete -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.0.yaml
```

**Droplets löschen (Kosten stoppen):**

```bash
cd terraform
terraform destroy
```

---

## Was du gelernt hast

Du hast zwei unabhängige Backup-Ebenen aufgesetzt und getestet:

| Ebene | Tool | Was wird gesichert | Getestet mit |
|---|---|---|---|
| Cluster-State | etcd snapshot | Alle K8s-Objekte (Deployments, Secrets, CRDs) | Snapshot erstellt + geprüft |
| Datenbankdaten | CloudNativePG PITR | Transaktionskonsistente Postgres-Daten | DROP TABLE → Wiederherstellung |

Der entscheidende Unterschied zu "Backup vorhanden": Du hast den Restore durchgezogen und die Daten verifiziert.
