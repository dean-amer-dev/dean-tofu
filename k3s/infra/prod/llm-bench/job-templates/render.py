#!/usr/bin/env python3
"""Reference builder for llm-bench stage/serve Jobs and the serve Service.

Reads the runner config (ConfigMap llm-bench-runners, key runners.yaml) and renders plain
Kubernetes objects. The Phase 3 MCP reuses these builders; Phase 2 uses the CLI to produce the
Tofu-managed test Jobs. Requires PyYAML.

  render.py --runners runners.yaml stage  --engine llamacpp --repo R [--revision V] [--file GLOB] [--ctx N] --run-id ID
  render.py --runners runners.yaml serve  --engine llamacpp --path /weights/R/SHA/file.gguf --run-id ID [--lease-minutes 30]
                                          [--startup-minutes 10] [--arg X ...] [--env K=V ...] [--ctx N]
  render.py --runners runners.yaml service
Add --ttl to set ttlSecondsAfterFinished (MCP-created Jobs; never for Tofu/ArgoCD-managed ones).
"""
import argparse
import hashlib
import re
import sys

import yaml


class NoAlias(yaml.SafeDumper):
    def ignore_aliases(self, data):
        return True

GROUP = "llm-bench"
FETCH_BASE = {"WEIGHTS_ROOT": "/weights"}


def labels(runner, engine, run_id, kind):
    return {GROUP + "/runner": runner, GROUP + "/engine": engine, GROUP + "/run-id": run_id, GROUP + "/kind": kind}


def tolerations():
    return [
        {"key": "gpu-worker", "operator": "Equal", "value": "true", "effect": "NoSchedule"},
        {"key": "nvidia.com/gpu", "operator": "Equal", "value": "present", "effect": "NoSchedule"},
    ]


def slug(repo):
    return re.sub(r"[^a-z0-9]+", "-", repo.lower()).strip("-")[:24].strip("-")


def ollama_name(path):
    return "m-" + hashlib.sha256(path.encode()).hexdigest()[:12]


def build_stage(runner_name, r, engine, repo, revision, file_glob, ctx, run_id, ttl=None, fit_check="strict"):
    st = r["stage"]
    lab = labels(runner_name, engine, run_id, "stage")
    env = [
        {"name": "ENGINE", "value": engine}, {"name": "HF_REPO", "value": repo},
        {"name": "HF_REVISION", "value": revision or "main"}, {"name": "HF_FILE", "value": file_glob or ""},
        {"name": "CTX", "value": str(ctx)}, {"name": "VRAM_BYTES", "value": str(r["vramBytes"])},
        {"name": "VRAM_RESERVE_BYTES", "value": str(r["vramReserveBytes"])},
        {"name": "NINFER_VERSIONS", "value": ",".join(str(v) for v in r["engines"].get("ninfer", {}).get("supportedContainerVersions", [2]))},
        {"name": "FIT_CHECK", "value": fit_check}, {"name": "WEIGHTS_ROOT", "value": "/weights"},
        {"name": "HF_TOKEN", "valueFrom": {"secretKeyRef": {"name": st["hfTokenSecret"], "key": "token", "optional": True}}},
    ]
    mounts = [{"name": "weights", "mountPath": "/weights"}, {"name": "script", "mountPath": "/script"}]
    fetch = {
        "name": "fetch", "image": st["image"], "imagePullPolicy": "IfNotPresent",
        "command": ["python3", "-I", "/script/stage.py"], "env": env, "volumeMounts": mounts,
        "resources": {"requests": {"cpu": "500m", "memory": "512Mi"}, "limits": {"memory": st["memory"]}},
    }
    volumes = [
        {"name": "weights", "persistentVolumeClaim": {"claimName": r["weightsPvc"]}},
        {"name": "script", "configMap": {"name": st["scriptConfigMap"], "defaultMode": 0o555}},
    ]
    pod = {
        "restartPolicy": "Never", "nodeSelector": {"kubernetes.io/hostname": r["node"]}, "tolerations": tolerations(),
        "volumes": volumes,
    }
    if engine == "ollama":
        fetch["env"].append({"name": "RESULT_FILE", "value": "/shared/result.json"})
        fetch["volumeMounts"] = mounts + [{"name": "shared", "mountPath": "/shared"}]
        volumes.append({"name": "shared", "emptyDir": {}})
        script = (
            "set -eu\n"
            "P=$(grep -o '\"path\": *\"[^\"]*\"' /shared/result.json | head -1 | cut -d'\"' -f4)\n"
            "N=m-$(printf %s \"$P\" | sha256sum | cut -c1-12)\n"
            "export OLLAMA_HOST=127.0.0.1:11999 OLLAMA_MODELS=/weights/ollama\n"
            "ollama serve >/tmp/serve.log 2>&1 &\n"
            "until ollama list >/dev/null 2>&1; do sleep 1; done\n"
            "printf 'FROM %s\\n' \"$P\" > /tmp/Modelfile\n"
            "ollama create \"$N\" -f /tmp/Modelfile\n"
            "ollama list\n"
        )
        pod["initContainers"] = [fetch]
        pod["containers"] = [{
            "name": "import", "image": r["engines"]["ollama"]["image"], "imagePullPolicy": "IfNotPresent",
            "command": ["sh", "-c", script],
            "volumeMounts": [{"name": "weights", "mountPath": "/weights"}, {"name": "shared", "mountPath": "/shared"}],
            "resources": {"requests": {"cpu": "500m", "memory": "512Mi"}, "limits": {"memory": "4Gi"}},
        }]
    else:
        pod["containers"] = [fetch]
    spec = {"backoffLimit": 0, "activeDeadlineSeconds": st["deadlineMinutes"] * 60,
            "template": {"metadata": {"labels": lab}, "spec": pod}}
    if ttl:
        spec["ttlSecondsAfterFinished"] = ttl
    return {"apiVersion": "batch/v1", "kind": "Job",
            "metadata": {"name": "stage-%s-%s-%s" % (runner_name, slug(repo), run_id), "namespace": r["namespace"], "labels": lab},
            "spec": spec}


def build_serve(runner_name, r, engine, path, run_id, lease_minutes=None, startup_minutes=None, args=(), env=None, ctx=4096, ttl=None):
    eng = r["engines"][engine]
    lease = min(lease_minutes or r["lease"]["defaultMinutes"], r["lease"]["maxMinutes"])
    startup = min(startup_minutes or r["startup"]["defaultMinutes"], r["startup"]["maxMinutes"])
    lab = labels(runner_name, engine, run_id, "serve")
    e = dict(eng.get("env", {}))
    e.update(env or {})
    ro = engine != "ollama"
    container = {
        "name": "engine", "image": eng["image"], "imagePullPolicy": "IfNotPresent",
        "ports": [{"containerPort": 8080, "name": "http"}],
        "volumeMounts": [{"name": "weights", "mountPath": "/weights", "readOnly": ro}],
        "resources": {"requests": {"cpu": r["serve"]["cpu"], "memory": r["serve"]["memory"], r["gpuResource"]: "1"},
                      "limits": {"memory": r["serve"]["memory"], r["gpuResource"]: "1"}},
    }
    hp = {"path": eng["health"]["path"], "port": eng["health"]["port"]}
    startup_probe = {"httpGet": hp, "periodSeconds": 10, "failureThreshold": startup * 6, "timeoutSeconds": 5}
    ready = {"httpGet": hp, "periodSeconds": 10, "failureThreshold": 3, "timeoutSeconds": 5}
    live = {"httpGet": hp, "periodSeconds": 15, "failureThreshold": 4, "timeoutSeconds": 5}
    if engine == "ninfer":
        container["args"] = [path] + list(eng["fixedArgs"]) + ["--model-id", "bench"] + list(args)
    elif engine == "llamacpp":
        container["command"] = list(eng["command"])
        container["args"] = ["-m", path] + list(eng["fixedArgs"]) + ["--alias", "bench", "-c", str(ctx)] + list(args)
    elif engine == "ollama":
        name = ollama_name(path)
        e.setdefault("OLLAMA_CONTEXT_LENGTH", str(ctx))
        c = "OLLAMA_HOST=127.0.0.1:8080 ollama"
        container["command"] = ["sh", "-c", (
            "set -e\n"
            "ollama serve & pid=$!\n"
            "until %s list >/dev/null 2>&1; do sleep 1; done\n"
            "%s cp %s bench\n"
            "%s run bench '' </dev/null >/dev/null\n"
            "wait $pid\n") % (c, c, name, c)]
        probe = {"exec": {"command": ["sh", "-c", "%s ps | grep -q bench" % c]}, "periodSeconds": 10}
        startup_probe = dict(probe, failureThreshold=startup * 6, timeoutSeconds=10)
        ready = dict(probe, failureThreshold=3, timeoutSeconds=10)
    container["startupProbe"], container["readinessProbe"], container["livenessProbe"] = startup_probe, ready, live
    container["env"] = [{"name": "NVIDIA_VISIBLE_DEVICES", "value": "all"},
                        {"name": "NVIDIA_DRIVER_CAPABILITIES", "value": "compute,utility"}] + \
                       [{"name": k, "value": str(v)} for k, v in e.items()]
    pod = {
        "restartPolicy": "Never", "priorityClassName": r["priorityClassName"], "runtimeClassName": r["runtimeClassName"],
        "nodeSelector": {"kubernetes.io/hostname": r["node"]}, "tolerations": tolerations(),
        "terminationGracePeriodSeconds": 30,
        "volumes": [{"name": "weights", "persistentVolumeClaim": {"claimName": r["weightsPvc"]}}],
        "containers": [container],
    }
    spec = {"backoffLimit": 0, "activeDeadlineSeconds": lease * 60,
            "template": {"metadata": {"labels": lab}, "spec": pod}}
    if ttl:
        spec["ttlSecondsAfterFinished"] = ttl
    return {"apiVersion": "batch/v1", "kind": "Job",
            "metadata": {"name": "bench-%s-%s-%s" % (runner_name, engine, run_id), "namespace": r["namespace"], "labels": lab},
            "spec": spec}


def build_service(runner_name, r):
    return {"apiVersion": "v1", "kind": "Service",
            "metadata": {"name": "bench-" + runner_name, "namespace": r["namespace"]},
            "spec": {"selector": {GROUP + "/runner": runner_name, GROUP + "/kind": "serve"},
                     "ports": [{"name": "http", "port": 8080, "targetPort": 8080}]}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runners", required=True)
    ap.add_argument("--runner", default="murderbot")
    ap.add_argument("--indent", type=int, default=0, help="indent output as list items of a raw-chart resources list")
    sub = ap.add_subparsers(dest="what", required=True)
    s = sub.add_parser("stage")
    s.add_argument("--engine", required=True)
    s.add_argument("--repo", required=True)
    s.add_argument("--revision", default="")
    s.add_argument("--file", default="")
    s.add_argument("--ctx", type=int, default=4096)
    s.add_argument("--run-id", required=True)
    s.add_argument("--ttl", type=int)
    v = sub.add_parser("serve")
    v.add_argument("--engine", required=True)
    v.add_argument("--path", required=True)
    v.add_argument("--run-id", required=True)
    v.add_argument("--lease-minutes", type=int)
    v.add_argument("--startup-minutes", type=int)
    v.add_argument("--ctx", type=int, default=4096)
    v.add_argument("--arg", action="append", default=[])
    v.add_argument("--env", action="append", default=[])
    v.add_argument("--ttl", type=int)
    sub.add_parser("service")
    a = ap.parse_args()
    r = yaml.safe_load(open(a.runners))["runners"][a.runner]
    if a.what == "stage":
        obj = build_stage(a.runner, r, a.engine, a.repo, a.revision, a.file, a.ctx, a.run_id, a.ttl)
    elif a.what == "serve":
        obj = build_serve(a.runner, r, a.engine, a.path, a.run_id, a.lease_minutes, a.startup_minutes, a.arg,
                          dict(x.split("=", 1) for x in a.env), a.ctx, a.ttl)
    else:
        obj = build_service(a.runner, r)
    text = yaml.dump(obj, Dumper=NoAlias, default_flow_style=False, sort_keys=False, width=1000)
    if a.indent:
        lines = text.splitlines()
        text = "\n".join([" " * a.indent + "- " + lines[0]] + [" " * (a.indent + 2) + l for l in lines[1:]]) + "\n"
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
