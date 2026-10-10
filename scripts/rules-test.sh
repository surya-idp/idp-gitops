#!/usr/bin/env bash
# Check the alert rules (platform/monitoring/rules.yaml) with promtool: syntax, then the unit
# tests in tests/prometheus. Called by validate.sh; needs docker and python3 + PyYAML.
#
# promtool wants plain rule groups, not the Kubernetes PrometheusRule that wraps them, so the
# groups are extracted first.
set -euo pipefail
cd "$(dirname "$0")/.."

# Same promtool as the Prometheus line the stack runs; pinned by digest.
PROM_IMAGE="prom/prometheus:v3.5.0@sha256:63805ebb8d2b3920190daf1cb14a60871b16fd38bed42b857a3182bc621f4996"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 755 "$work"
python3 -c "
import sys, yaml
doc = yaml.safe_load(open('platform/monitoring/rules.yaml'))
assert doc['kind'] == 'PrometheusRule'
yaml.safe_dump({'groups': doc['spec']['groups']}, open(sys.argv[1], 'w'))
" "$work/rules.yaml"
cp tests/prometheus/rules_test.yaml "$work/"
chmod 644 "$work"/*

echo "==> alert rules: promtool check + unit tests"
docker run --rm --entrypoint promtool -v "$work:/rules:ro,z" -w /rules "$PROM_IMAGE" check rules rules.yaml
docker run --rm --entrypoint promtool -v "$work:/rules:ro,z" -w /rules "$PROM_IMAGE" test rules rules_test.yaml
