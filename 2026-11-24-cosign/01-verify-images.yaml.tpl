apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: verify-image-signature
spec:
  validationActions: [Deny]
  webhookConfiguration:
    timeoutSeconds: 30
  matchConstraints:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: shop
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["pods"]
  matchImageReferences:
    - glob: "kind-registry:5000/*"
  attestors:
    - name: unserkey
      cosign:
        key:
          data: |
${PUBKEY}
        ctlog:
          insecureIgnoreTlog: true
          insecureIgnoreSCT: true
  validations:
    - expression: >-
        images.containers.map(image, verifyImageSignatures(image, [attestors.unserkey])).all(e, e > 0)
      message: "Image ist nicht mit unserem Schlüssel signiert"
