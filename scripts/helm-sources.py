#!/usr/bin/env python3
"""Print one line per Helm chart that an Argo CD Application in this repo installs:

    <app name> <namespace> <repo URL> <chart> <version> <values file>

validate.sh renders each with `helm template`, so charts are checked like everything else
and the CRDs they bring become schemas for the custom resources in apps/.
"""
import json
import pathlib
import sys
import tempfile

import yamlsafe

out_dir = pathlib.Path(tempfile.mkdtemp(prefix="helm-values-"))
for path in sorted(pathlib.Path(sys.argv[1]).glob("*.yaml")):
    for doc in yamlsafe.load_all(path.read_text()):
        if not doc or doc.get("kind") != "Application":
            continue
        spec = doc["spec"]
        for source in spec.get("sources") or [spec.get("source") or {}]:
            if "chart" not in source:
                continue
            helm = source.get("helm") or {}
            values = out_dir / f"{doc['metadata']['name']}.json"
            values.write_text(json.dumps(helm.get("valuesObject") or {}))
            print(
                helm.get("releaseName") or doc["metadata"]["name"],
                spec["destination"].get("namespace", "default"),
                source["repoURL"],
                source["chart"],
                source["targetRevision"],
                values,
            )
