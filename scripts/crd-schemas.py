#!/usr/bin/env python3
"""Write a strict JSON schema for every CRD found in the YAML on stdin.

    kubectl kustomize platform/image-updater | scripts/crd-schemas.py <out-dir>

validate.sh uses it so that a custom resource is checked against the CRD version this repo
actually installs (the public CRD catalog can lag behind a release). Output layout matches the
kubeconform schema location <out-dir>/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json.
"""
import json
import pathlib
import sys

import yamlsafe


def strict(node):
    """Reject unknown fields wherever the CRD lists its properties (kubeconform -strict)."""
    if isinstance(node, dict):
        if "properties" in node and "additionalProperties" not in node \
                and not node.get("x-kubernetes-preserve-unknown-fields"):
            node["additionalProperties"] = False
        for value in node.values():
            strict(value)
    elif isinstance(node, list):
        for value in node:
            strict(value)


out = pathlib.Path(sys.argv[1])
for doc in yamlsafe.load_all(sys.stdin):
    if not doc or doc.get("kind") != "CustomResourceDefinition":
        continue
    group, kind = doc["spec"]["group"], doc["spec"]["names"]["kind"].lower()
    for version in doc["spec"]["versions"]:
        schema = version.get("schema", {}).get("openAPIV3Schema")
        if not schema:
            continue
        strict(schema)
        path = out / group / f"{kind}_{version['name']}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(schema))
        print(f"    schema from CRD: {group}/{path.name}", file=sys.stderr)
