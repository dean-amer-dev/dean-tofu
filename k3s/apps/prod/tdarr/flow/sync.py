#!/usr/bin/env python3
"""Push the version-controlled Tdarr flow and libraries into Tdarr's DB.

Tdarr keeps flows and libraries in its own DB, so git is the source of truth and
this script applies it. Idempotent. Docs are matched by NAME, never by _id:
Tdarr's cruddb insert ignores any supplied _id and assigns its own.

Env: TDARR_URL (default in-cluster service), FLOW_DIR.
Flag: --dry-run  compare only, never write.
"""
import json
import os
import re
import sys
import time
import urllib.request

URL = os.environ.get("TDARR_URL", "http://tdarr-server.tdarr.svc.cluster.local:8265").rstrip("/")
FLOW_DIR = os.environ.get("FLOW_DIR", os.path.dirname(os.path.abspath(__file__)))
FLOW_KEYS = ("name", "description", "tags", "flowPlugins", "flowEdges")
LIB_SKIP = ("createdAt", "totalHealthCheckCount", "totalTranscodeCount", "scanFound", "navItemSelected")
DRY = "--dry-run" in sys.argv


def cruddb(data):
    req = urllib.request.Request(
        URL + "/api/v2/cruddb",
        data=json.dumps({"data": data}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read().decode()
    return json.loads(body) if body.strip() else None


def get_all(collection):
    return cruddb({"collection": collection, "mode": "getAll"}) or []


def by_name(docs, name):
    matches = [d for d in docs if d.get("name") == name]
    if len(matches) > 1:
        sys.exit(f"{len(matches)} docs named {name!r}; refusing to guess")
    return matches[0] if matches else None


def build_flow():
    flow = json.load(open(os.path.join(FLOW_DIR, "flow.json")))
    pat = re.compile(r"^@@file:([\w.-]+)@@$")
    for node in flow["flowPlugins"]:
        code = node.get("inputsDB", {}).get("code")
        m = pat.match(code) if isinstance(code, str) else None
        if m:
            node["inputsDB"]["code"] = open(os.path.join(FLOW_DIR, m.group(1))).read()
    return {k: flow[k] for k in FLOW_KEYS}


def wait_for_tdarr():
    for _ in range(60):
        try:
            return get_all("FlowsJSONDB")
        except Exception as e:  # server still starting / mid-rollout
            print(f"waiting for Tdarr ({e})", flush=True)
            time.sleep(10)
    sys.exit("Tdarr never became reachable")


def sync_doc(collection, desired, existing, label):
    """Insert or update by name. Returns the live doc's _id."""
    if existing is None:
        print(f"{label}: missing, inserting", flush=True)
        if DRY:
            return None
        cruddb({"collection": collection, "mode": "insert", "obj": desired})
        existing = by_name(get_all(collection), desired["name"])
        if not existing:
            sys.exit(f"{label}: not found after insert")
    keys = [k for k in desired if existing.get(k) != desired[k]]
    if not keys:
        print(f"{label}: already in sync", flush=True)
        return existing["_id"]
    print(f"{label}: differs in {keys}", flush=True)
    if DRY:
        return existing["_id"]
    cruddb({"collection": collection, "mode": "update", "docID": existing["_id"], "obj": {k: desired[k] for k in keys}})
    after = cruddb({"collection": collection, "mode": "getById", "docID": existing["_id"]})
    bad = [k for k in desired if not after or after.get(k) != desired[k]]
    if bad:
        sys.exit(f"{label}: read-back mismatch in {bad}")
    print(f"{label}: updated and verified", flush=True)
    return existing["_id"]


def main():
    flows = wait_for_tdarr()
    flow = build_flow()
    flow_id = sync_doc("FlowsJSONDB", flow, by_name(flows, flow["name"]), f"flow {flow['name']!r}")

    libs = get_all("LibrarySettingsJSONDB")
    for lib in json.load(open(os.path.join(FLOW_DIR, "libraries.json"))):
        desired = {k: v for k, v in lib.items() if k not in LIB_SKIP}
        desired["flowId"] = flow_id
        existing = by_name(libs, lib["name"])
        if existing is None:
            desired.update({k: lib[k] for k in ("createdAt",) if k in lib})
        sync_doc("LibrarySettingsJSONDB", desired, existing, f"library {lib['name']!r}")


if __name__ == "__main__":
    main()
