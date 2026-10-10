#!/usr/bin/env bash
# Test the admission policies (platform/kyverno) offline with the Kyverno CLI. Called by
# validate.sh; needs the `kyverno` binary, helm, kubectl, python3 + PyYAML.
#
#   1. Everything we deploy must PASS every policy. Otherwise merging a policy would block the
#      next sync of an app that was fine yesterday.
#   2. Every policy must REJECT its bad example in tests/kyverno/<policy>/bad-*.yaml, and accept
#      good-*.yaml. A policy that has never been seen rejecting anything proves nothing.
#
# Not covered here: verify-image-provenance. It needs the real registry and the real
# attestations, so it is verified on the cluster.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/policies" "$work/crds"
for f in platform/kyverno/*.yaml; do
  case "$(basename "$f")" in kustomization.yaml|verify-image-provenance.yaml) continue ;; esac
  cp "$f" "$work/policies/"
done

# Custom resource kinds (the database resources) are unknown to the CLI unless it gets their
# CRDs: take them from the Helm charts the platform installs.
while read -r release namespace repo chart version values; do
  helm template "$release" "$chart" --repo "$repo" --version "$version" --namespace "$namespace" \
    --include-crds --values "$values" 2>/dev/null | python3 -c "
import sys, yaml
for i, doc in enumerate(d for d in yaml.safe_load_all(sys.stdin) if d and d.get('kind') == 'CustomResourceDefinition'):
    if doc['spec']['group'] == 'db.movetokube.com':
        open(f'$work/crds/{doc[\"metadata\"][\"name\"]}.yaml', 'w').write(yaml.safe_dump(doc))
"
done < <(./scripts/helm-sources.py platform/argocd-apps)

# apply <resource file> -> prints the CLI's result lines, returns the number of failures
apply() {
  # --crd-paths takes files, not a folder
  kyverno apply "$work/policies" --resource "$1" \
    --crd-paths "$(find "$work/crds" -name '*.yaml' | sort | paste -sd, -)" --remove-color 2>&1 || true
}
failures() { sed -n 's/.*fail: \([0-9]*\).*/\1/p' | tail -1; }

fail=0
echo "==> policies: everything we deploy must pass"
for dir in $(find apps tests -name kustomization.yaml -path '*/overlays/dev/*' -printf '%h\n' | sort); do
  kubectl kustomize "$dir" > "$work/rendered.yaml"
  out="$(apply "$work/rendered.yaml")"
  n="$(echo "$out" | failures)"
  passes="$(echo "$out" | sed -n 's/.*pass: \([0-9]*\).*/\1/p' | tail -1)"
  if [ "${n:-x}" = "0" ] && [ "${passes:-0}" != "0" ]; then
    echo "    ok    $dir ($passes checks passed)"
  else
    echo "    FAIL  $dir"; echo "$out" | grep -v '^$' | sed 's/^/          /'; fail=1
  fi
done

echo "==> policies: each one must reject its bad example and accept its good one"
for policy_dir in tests/kyverno/*/; do
  policy="$(basename "$policy_dir")"
  [ -f "$work/policies/$policy.yaml" ] || { echo "    FAIL  tests/kyverno/$policy has no policy platform/kyverno/$policy.yaml"; fail=1; continue; }
  for example in "$policy_dir"*.yaml; do
    out="$(apply "$example")"
    n="$(echo "$out" | failures)"
    case "$(basename "$example")" in
      bad-*)
        # rejected, and by THIS policy (not by accident through another one)
        if [ "${n:-0}" != "0" ] && echo "$out" | grep -q "policy $policy -> .* failed"; then
          echo "    ok    $example rejected by $policy"
        else
          echo "    FAIL  $example was not rejected by $policy"; echo "$out" | sed 's/^/          /'; fail=1
        fi ;;
      good-*)
        # accepted, and really evaluated: "0 failures" from a policy that did not match
        # the example at all would prove nothing
        passes="$(echo "$out" | sed -n 's/.*pass: \([0-9]*\).*/\1/p' | tail -1)"
        if [ "${n:-x}" = "0" ] && [ "${passes:-0}" != "0" ]; then echo "    ok    $example accepted"
        else echo "    FAIL  $example should pass every policy"; echo "$out" | sed 's/^/          /'; fail=1; fi ;;
    esac
  done
done
# every policy needs a bad example
for f in "$work"/policies/*.yaml; do
  policy="$(basename "$f" .yaml)"
  ls "tests/kyverno/$policy"/bad-*.yaml >/dev/null 2>&1 || { echo "    FAIL  no bad example for policy $policy (tests/kyverno/$policy/bad-*.yaml)"; fail=1; }
done
exit $fail
