#!/usr/bin/env python3
"""Check every Alertmanager configuration in a rendered manifest stream (stdin).

A chart merges our `alertmanager.config` values over its own defaults. Lists replace, maps merge,
so a default route can end up naming a receiver that our receiver list no longer has. The
operator then refuses the whole configuration and never starts Alertmanager (seen on the cluster
on 2026-10-11: `undefined receiver "null" used in route`). This catches it before the merge.
"""
import base64
import sys

import yamlsafe


def receivers_used(route):
    if route.get("receiver"):
        yield route["receiver"]
    for child in route.get("routes") or []:
        yield from receivers_used(child)


fail = 0
for doc in yamlsafe.load_all(sys.stdin.read()):
    if not doc or doc.get("kind") != "Secret":
        continue
    raw = (doc.get("stringData") or {}).get("alertmanager.yaml")
    if raw is None and "alertmanager.yaml" in (doc.get("data") or {}):
        raw = base64.b64decode(doc["data"]["alertmanager.yaml"]).decode()
    if raw is None:
        continue
    name = doc["metadata"]["name"]
    config = yamlsafe.load_all(raw)
    config = next(iter(config)) or {}
    defined = {r["name"] for r in config.get("receivers") or []}
    route = config.get("route") or {}
    if not route.get("receiver"):
        print(f"FAIL alertmanager config {name}: the top route has no receiver")
        fail = 1
    missing = sorted(set(receivers_used(route)) - defined)
    if missing:
        print(f"FAIL alertmanager config {name}: route uses undefined receiver(s) {missing}")
        fail = 1
    if not fail:
        print(f"ok   alertmanager config {name}: {len(defined)} receiver(s), every route resolves")
sys.exit(fail)
