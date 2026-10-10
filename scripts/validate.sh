#!/usr/bin/env bash
# Validate everything Argo CD would apply: render every Kustomize overlay and check the output,
# plus the plain manifests, against Kubernetes + CRD JSON schemas. Run by CI on every push/PR
# (required check on main) and locally: ./scripts/validate.sh
# (needs kubectl, kubeconform, helm, kyverno CLI, docker, python3 + PyYAML)
set -euo pipefail
cd "$(dirname "$0")/.."

K8S_VERSION="${K8S_VERSION:-1.35.0}"   # EKS version (idp-infra/30-cluster)
CRD_CATALOG_REF="${CRD_CATALOG_REF:-f1e7f6bc0537bf0622ffe6e47dbaa85914fabbec}"   # datreeio/CRDs-catalog, 2026-10 before #988
# CRDs that a kustomization installs itself (Image Updater) are turned into schemas here, so
# its custom resources are checked against the pinned version, not the public catalog's copy.
LOCAL_SCHEMAS="$(mktemp -d)"
trap 'rm -rf "$LOCAL_SCHEMAS"' EXIT
KC=(kubeconform -strict -summary -output text -kubernetes-version "$K8S_VERSION"
    # kubeconform has no schema for the CRD kind itself; the API server validates those.
    -skip CustomResourceDefinition
    -schema-location default
    -schema-location "$LOCAL_SCHEMAS/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
    # CRDs (Argo CD Application, ExternalSecret, ClusterSecretStore, Kyverno ...). The catalog
    # is pinned by commit: its 2026-10-08 update of the external-secrets.io schemas cannot be
    # loaded by kubeconform v0.8.0 ("could not find schema for ClusterSecretStore"), which
    # turned this check red with no change in this repo. Bump the pin deliberately.
    -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CRD_CATALOG_REF}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")

fail=0
rendered="$(mktemp)"
# Helm charts that an Application installs (platform controllers). Rendered first: their CRDs
# become the schemas for the custom resources that apps declare.
while read -r release namespace repo chart version values; do
  echo "==> helm chart $chart $version (Application $release)"
  if ! helm template "$release" "$chart" --repo "$repo" --version "$version" \
        --namespace "$namespace" --include-crds --values "$values" > "$rendered"; then fail=1; continue; fi
  ./scripts/crd-schemas.py "$LOCAL_SCHEMAS" < "$rendered"
  "${KC[@]}" - < "$rendered" || fail=1
done < <(./scripts/helm-sources.py platform/argocd-apps)
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
for f in platform/argocd-apps/*.yaml; do
  echo "==> $f"
  "${KC[@]}" "$f" || fail=1
done
# Admission policies: everything deployed passes them, and each one rejects its bad example.
./scripts/policy-test.sh || fail=1
# Alert rules: promtool syntax check and unit tests.
./scripts/rules-test.sh || fail=1
exit $fail
