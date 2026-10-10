#!/usr/bin/env bash
# Validate everything Argo CD would apply: render every Kustomize overlay and check the output,
# plus the plain manifests, against Kubernetes + CRD JSON schemas. Run by CI on every push/PR
# (required check on main) and locally: ./scripts/validate.sh
# (needs kubectl, kubeconform, python3 + PyYAML)
set -euo pipefail
cd "$(dirname "$0")/.."

K8S_VERSION="${K8S_VERSION:-1.35.0}"   # EKS version (idp-infra/30-cluster)
# CRDs that a kustomization installs itself (Image Updater) are turned into schemas here, so
# its custom resources are checked against the pinned version, not the public catalog's copy.
LOCAL_SCHEMAS="$(mktemp -d)"
trap 'rm -rf "$LOCAL_SCHEMAS"' EXIT
KC=(kubeconform -strict -summary -output text -kubernetes-version "$K8S_VERSION"
    # kubeconform has no schema for the CRD kind itself; the API server validates those.
    -skip CustomResourceDefinition
    -schema-location default
    -schema-location "$LOCAL_SCHEMAS/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
    # CRDs (Argo CD Application, ExternalSecret, ClusterSecretStore, Kyverno ...)
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')

fail=0
rendered="$(mktemp)"
# Deployable roots: overlays and standalone kustomizations (bases are covered via overlays).
# tests/ holds a sample golden-path service, so a change to components/ is always exercised.
for dir in $(find apps platform tests -name kustomization.yaml -not -path '*/base/*' -printf '%h\n' | sort); do
  echo "==> $dir"
  if ! kubectl kustomize "$dir" > "$rendered"; then fail=1; continue; fi
  ./scripts/crd-schemas.py "$LOCAL_SCHEMAS" < "$rendered"
  "${KC[@]}" - < "$rendered" || fail=1
done
rm -f "$rendered"
# Plain manifests (not under a kustomization).
for f in platform/argocd-apps/*.yaml platform/kyverno/*.yaml; do
  echo "==> $f"
  "${KC[@]}" "$f" || fail=1
done
exit $fail
