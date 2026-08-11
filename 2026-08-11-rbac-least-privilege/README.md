# RBAC: Overprivilegierte ServiceAccounts finden und Least Privilege umsetzen

Getestet gegen Kubernetes 1.36 (DOKS, DigitalOcean fra1).

Folge 1 der Serie **Kubernetes Sicherheit**. In dieser Übung findest du ServiceAccounts mit `cluster-admin`-Rechten, siehst live, was so ein ServiceAccount alles darf, und baust anschließend einen sauber eingeschränkten ServiceAccount nach dem Least-Privilege-Prinzip.

## Voraussetzungen

- Laufender Kubernetes-Cluster (DOKS oder jeder andere) mit `kubectl`-Zugriff
- `jq` installiert

## Überblick

```
Schritt 1: Absichtlich overprivilegierten ServiceAccount anlegen
Schritt 2: Finden mit einer kubectl/jq-Query
Schritt 3: Zeigen, was der ServiceAccount alles darf
Schritt 4: Aufräumen der unsicheren Bindung
Schritt 5: Least-Privilege-ServiceAccount korrekt aufbauen
Schritt 6: Rechte gezielt mit kubectl auth can-i testen
Schritt 7: Token-Automount abschalten und verifizieren
Schritt 8: Aufräumen
```

---

## Schritt 1: Einen overprivilegierten ServiceAccount anlegen

Zur Demonstration bauen wir das Problem erst bewusst nach — ein ServiceAccount, der `cluster-admin` bekommt, obwohl er nur eine einzelne App betreiben soll:

```bash
kubectl create namespace rbac-demo
kubectl create serviceaccount overprivileged-app -n rbac-demo
kubectl create clusterrolebinding overprivileged-app-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=rbac-demo:overprivileged-app
```

## Schritt 2: Overprivilegierte ServiceAccounts finden

```bash
kubectl get clusterrolebindings -o json | jq -r '
  .items[] |
  select(.roleRef.name == "cluster-admin") |
  select(.subjects != null) |
  .subjects[] |
  select(.kind == "ServiceAccount") |
  "\(.namespace)/\(.name) -> cluster-admin"
'
```

**Erwartete Ausgabe:**

```
rbac-demo/overprivileged-app -> cluster-admin
```

Jeder ServiceAccount, der hier auftaucht, kann bei einer Kompromittierung den kompletten Cluster übernehmen — nicht nur seinen eigenen Namespace.

## Schritt 3: Zeigen, was das in der Praxis bedeutet

```bash
kubectl auth can-i --list --as=system:serviceaccount:rbac-demo:overprivileged-app
```

**Erwartete Ausgabe (Auszug):**

```
Resources   Non-Resource URLs   Resource Names   Verbs
*.*         []                  []               [*]
            [*]                 []               [*]
```

`*.*` mit Verb `[*]` heißt: alle Ressourcen, alle Aktionen, cluster-weit. Ein Pod mit diesem ServiceAccount ist im Ernstfall gleichbedeutend mit vollem `kubectl`-Zugriff als Cluster-Admin.

## Schritt 4: Unsichere Bindung entfernen

```bash
kubectl delete clusterrolebinding overprivileged-app-admin
kubectl delete namespace rbac-demo
```

---

## Schritt 5: Least-Privilege-ServiceAccount korrekt aufbauen

Jetzt der Gegenentwurf: ein ServiceAccount, der wirklich nur das darf, was er braucht.

```bash
kubectl create namespace rbac-leastpriv
```

```yaml
# 01-serviceaccount.yml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dev-readonly
  namespace: rbac-leastpriv
automountServiceAccountToken: false
```

```bash
kubectl apply -f 01-serviceaccount.yml -n rbac-leastpriv
```

```yaml
# 02-role.yml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: rbac-leastpriv
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

```bash
kubectl apply -f 02-role.yml -n rbac-leastpriv
```

```yaml
# 03-rolebinding.yml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-readonly-binding
  namespace: rbac-leastpriv
subjects:
- kind: ServiceAccount
  name: dev-readonly
  namespace: rbac-leastpriv
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f 03-rolebinding.yml -n rbac-leastpriv
```

**Bewusste Einschränkung:**
- `Role` statt `ClusterRole` — Zugriff nur im eigenen Namespace
- Nur `get`, `list`, `watch` auf `pods` — kein `create`, `update`, `delete`
- Keine Secrets, ConfigMaps oder Deployments in den Rules
- Kein Wildcard (`*`) bei Verbs oder Resources

## Schritt 6: Rechte gezielt testen

```bash
# Darf er Pods lesen? (sollte ja)
kubectl auth can-i get pods \
  --as=system:serviceaccount:rbac-leastpriv:dev-readonly \
  -n rbac-leastpriv
```

**Erwartet: yes**

```bash
# Darf er Secrets lesen? (sollte nicht!)
kubectl auth can-i get secrets \
  --as=system:serviceaccount:rbac-leastpriv:dev-readonly \
  -n rbac-leastpriv
```

**Erwartet: no**

```bash
# Darf er Pods in kube-system sehen? (sollte nicht!)
kubectl auth can-i list pods \
  --as=system:serviceaccount:rbac-leastpriv:dev-readonly \
  -n kube-system
```

**Erwartet: no**

## Schritt 7: Token-Automount abschalten und verifizieren

```yaml
# 04-pod.yml
apiVersion: v1
kind: Pod
metadata:
  name: dev-app
  namespace: rbac-leastpriv
spec:
  serviceAccountName: dev-readonly
  automountServiceAccountToken: false
  containers:
  - name: app
    image: nginx:alpine
    resources:
      requests:
        cpu: "50m"
        memory: "64Mi"
      limits:
        cpu: "100m"
        memory: "128Mi"
```

```bash
kubectl apply -f 04-pod.yml
kubectl wait --for=condition=Ready pod/dev-app -n rbac-leastpriv --timeout=60s
kubectl exec -n rbac-leastpriv dev-app -- \
  ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>/dev/null || echo "Kein Token gemountet - korrekt!"
```

**Erwartete Ausgabe:**

```
Kein Token gemountet - korrekt!
```

Ohne `automountServiceAccountToken: false` würde jeder Pod automatisch ein API-Token gemountet bekommen — selbst wenn die Anwendung die Kubernetes-API gar nicht anspricht.

---

## Aufräumen

```bash
kubectl delete namespace rbac-leastpriv
```

---

## Zusammenfassung

| Situation | Ergebnis |
|---|---|
| ServiceAccount mit `cluster-admin` | 💥 Voller Cluster-Zugriff bei Kompromittierung |
| `Role` (nicht `ClusterRole`) mit spezifischen Verbs | ✅ Zugriff auf Namespace und Ressource begrenzt |
| `automountServiceAccountToken: true` (Default) | ⚠️ Token gemountet, auch wenn nie gebraucht |
| `automountServiceAccountToken: false` | ✅ Kein Token, keine Angriffsfläche über die API |

## Referenzen

- https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- https://www.cisecurity.org/benchmark/kubernetes (Sektion 5.1)
