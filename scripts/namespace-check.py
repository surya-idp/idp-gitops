#!/usr/bin/env python3
"""Check the Namespace a deployable folder renders (stdin = rendered manifests, argv[1] = folder).

A golden-path service owns its namespace (components/golden-path/namespace.yaml), and project
`apps` therefore allows the cluster-wide kind Namespace. That must never become a way to take
over another namespace, so for apps/<name>/...: at most one Namespace, named <name>, and every
namespaced resource lives in it.
"""
import pathlib
import sys

import yamlsafe

parts = pathlib.Path(sys.argv[1]).parts
if parts[0] != "apps":
    sys.exit(0)
service = parts[1]
docs = [d for d in yamlsafe.load_all(sys.stdin.read()) if d]
names = [d["metadata"]["name"] for d in docs if d["kind"] == "Namespace"]
elsewhere = sorted(
    {f'{d["kind"]}/{d["metadata"]["name"]} in {d["metadata"]["namespace"]}'
     for d in docs if d["metadata"].get("namespace") not in (None, service)}
)
fail = 0
if names not in ([], [service]):
    print(f"FAIL {sys.argv[1]}: renders Namespace {names}; only '{service}' is allowed")
    fail = 1
# The two platform-owned apps deploy to namespaces with their own names (feature-flag-dev,
# backstage) and declare no Namespace; the rule below is for services that do.
if names and elsewhere:
    print(f"FAIL {sys.argv[1]}: resources outside namespace '{service}': {elsewhere}")
    fail = 1
sys.exit(fail)
