#!/usr/bin/env python3
"""Stage and validate Hugging Face model weights on the llm-bench weights volume.

Runs in a CPU-only Job (no GPU request) so a download never holds the GPU. Standard library
only. Modes (env MODE): stage (default), list, delete, evict.

Layout: <WEIGHTS_ROOT>/<hf-repo>/<revision-sha>/<file>, plus <file>.stage.json per staged model.

Exit codes: 0 ok, 2 validation failed (bad selection/header/version/size/fit), 3 network or
download failure, 4 repo not found or gated without access. The last stdout line is a JSON
object; it is also written to /dev/termination-log (stage mode) so a Job reader gets it from
the pod status.
"""
import fnmatch
import hashlib
import json
import os
import re
import shutil
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.environ.get("WEIGHTS_ROOT", "/weights")
HF = "https://huggingface.co"
MIB = 1024 * 1024
GIB = 1024 * MIB
SPLIT_RE = re.compile(r"-(\d{5})-of-(\d{5})\.gguf$")


class Fail(Exception):
    def __init__(self, code, error, **detail):
        super().__init__(error)
        self.code = code
        self.error = error
        self.detail = detail


def env_int(name, default):
    return int(os.environ.get(name) or default)


def emit(obj, termination=True):
    line = json.dumps(obj, separators=(",", ":"))
    print(line, flush=True)
    if termination:
        try:
            with open("/dev/termination-log", "w") as f:
                f.write(line[:4000])
        except OSError:
            pass


class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    """Do not forward the Hugging Face token to the CDN host after a redirect."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urllib.parse.urlparse(newurl).netloc != urllib.parse.urlparse(req.full_url).netloc:
            new.headers.pop("Authorization", None)
            new.unredirected_hdrs.pop("Authorization", None)
        return new


OPENER = urllib.request.build_opener(NoAuthRedirect)


def http(url, token, headers=None, timeout=60):
    req = urllib.request.Request(url, headers=dict(headers or {}))
    if token:
        req.add_header("Authorization", "Bearer " + token)
    return OPENER.open(req, timeout=timeout)


def model_info(repo, revision, token):
    url = "%s/api/models/%s/revision/%s?blobs=true" % (HF, repo, urllib.parse.quote(revision, safe=""))
    try:
        with http(url, token) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise Fail(4, "gated_or_unauthorized", repo=repo, http=e.code, token_set=bool(token))
        if e.code == 404:
            raise Fail(4, "repo_or_revision_not_found", repo=repo, revision=revision)
        raise Fail(3, "hf_api_error", http=e.code)
    except (urllib.error.URLError, TimeoutError) as e:
        raise Fail(3, "hf_api_unreachable", reason=str(e))


def pick_files(siblings, engine, pattern):
    ext = ".ninfer" if engine == "ninfer" else ".gguf"
    sizes = {s["rfilename"]: s for s in siblings}
    if pattern:
        names = [n for n in sizes if fnmatch.fnmatch(n, pattern)]
    else:
        names = [n for n in sizes if n.endswith(ext) and "mmproj" not in n.lower()]
    if not names:
        raise Fail(2, "no_matching_file", engine=engine, pattern=pattern,
                   available=sorted(n for n in sizes if n.endswith(ext))[:12])
    groups = {}
    for n in names:
        groups.setdefault(SPLIT_RE.sub(".gguf", n), []).append(n)
    if len(groups) > 1:
        raise Fail(2, "ambiguous_file", hint="set a file pattern that selects one model", candidates=sorted(groups)[:12])
    key, found = next(iter(groups.items()))
    m = SPLIT_RE.search(found[0])
    if m:
        total = int(m.group(2))
        want = [SPLIT_RE.sub("-%05d-of-%05d.gguf" % (i, total), found[0]) for i in range(1, total + 1)]
        missing = [w for w in want if w not in sizes]
        if missing:
            raise Fail(2, "split_parts_missing", missing=missing)
        found = want
    if len(found) == 1 and not found[0].endswith(ext):
        raise Fail(2, "wrong_extension", file=found[0], expected=ext)
    files = []
    for n in sorted(found):
        s = sizes[n]
        files.append({"name": n, "size": s.get("size"), "sha256": (s.get("lfs") or {}).get("sha256")})
    return files


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 * MIB), b""):
            h.update(chunk)
    return h.hexdigest()


def download(repo, sha, item, dest, token):
    name, size, want = item["name"], item["size"], item["sha256"]
    marker = dest + ".ok"
    part = dest + ".part"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.isfile(dest) and os.path.isfile(marker) and os.path.getsize(dest) == size:
        if open(marker).read().strip() == "%s %d" % (want or "-", size):
            print("already staged: " + name, flush=True)
            return
    for stale in (marker,):
        if os.path.exists(stale):
            os.remove(stale)
    url = "%s/%s/resolve/%s/%s" % (HF, repo, sha, urllib.parse.quote(name))
    attempt = 0
    while True:
        have = os.path.getsize(part) if os.path.exists(part) else 0
        if have == size:
            break
        try:
            hdr = {"Range": "bytes=%d-" % have} if have else {}
            with http(url, token, hdr, timeout=120) as r, open(part, "ab" if have else "wb") as out:
                if have and r.status != 206:
                    out.truncate(0)
                    out.seek(0)
                while True:
                    chunk = r.read(4 * MIB)
                    if not chunk:
                        break
                    out.write(chunk)
        except urllib.error.HTTPError as e:
            if e.code in (401, 403, 404):
                raise Fail(4, "download_denied", file=name, http=e.code)
            attempt += 1
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError):
            attempt += 1
        else:
            if os.path.getsize(part) >= size:
                break
            attempt += 1
        if attempt > 8:
            raise Fail(3, "download_failed", file=name, have=os.path.getsize(part) if os.path.exists(part) else 0, size=size)
        time.sleep(min(60, 5 * attempt))
    got_size = os.path.getsize(part)
    if got_size != size:
        os.remove(part)
        raise Fail(2, "size_mismatch", file=name, expected=size, got=got_size)
    got = sha256_file(part)
    if want and got != want:
        os.remove(part)
        raise Fail(2, "sha256_mismatch", file=name, expected=want, got=got)
    os.replace(part, dest)
    with open(marker, "w") as f:
        f.write("%s %d\n" % (want or "-", size))
    item["sha256_verified"] = got


def read_gguf(path):
    """Header and metadata of a GGUF file (first part of a split set is enough)."""

    def rd(f, fmt):
        return struct.unpack("<" + fmt, f.read(struct.calcsize(fmt)))[0]

    def rstr(f):
        return f.read(rd(f, "Q")).decode("utf-8", "replace")

    scalar = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}

    def rval(f, t):
        if t in scalar:
            return rd(f, scalar[t])
        if t == 8:
            return rstr(f)
        if t == 9:
            et, n = rd(f, "I"), rd(f, "Q")
            return [rval(f, et) for _ in range(n)]
        raise Fail(2, "bad_gguf_value_type", type=t)

    with open(path, "rb") as f:
        if f.read(4) != b"GGUF":
            raise Fail(2, "bad_magic", file=os.path.basename(path), expected="GGUF")
        version = rd(f, "I")
        if version not in (2, 3):
            raise Fail(2, "unsupported_gguf_version", version=version)
        n_tensors, n_kv = rd(f, "Q"), rd(f, "Q")
        kv = {}
        for _ in range(n_kv):
            key = rstr(f)
            kv[key] = rval(f, rd(f, "I"))
    arch = kv.get("general.architecture", "")
    return {"version": version, "tensors": n_tensors, "arch": arch, "kv": kv}


def kv_bytes_per_token(g, elem_bytes):
    """Upper-bound KV cache bytes per token from GGUF metadata (all layers counted as attention)."""
    kv, a = g["kv"], g["arch"]
    layers = kv.get(a + ".block_count")
    heads = kv.get(a + ".attention.head_count")
    heads_kv = kv.get(a + ".attention.head_count_kv", heads)
    emb = kv.get(a + ".embedding_length")
    if isinstance(heads_kv, list):
        heads_kv = max(heads_kv or [0])
    if isinstance(heads, list):
        heads = max(heads or [0])
    if not (layers and heads and heads_kv):
        return None
    head_dim = kv.get(a + ".attention.key_length") or (emb // heads if emb else None)
    if not head_dim:
        return None
    return 2 * layers * heads_kv * head_dim * elem_bytes


def check_ninfer(path, supported):
    with open(path, "rb") as f:
        head = f.read(8)
    if head[:7] != b"NINFER\x00":
        raise Fail(2, "bad_magic", file=os.path.basename(path), expected="NINFER")
    ver = head[7]
    if ver not in supported:
        raise Fail(2, "unsupported_ninfer_container", version=ver, supported=sorted(supported),
                   hint="the pinned NInfer runtime cannot load this container version")
    return ver


def stage():
    engine = os.environ["ENGINE"]
    repo = os.environ["HF_REPO"]
    revision = os.environ.get("HF_REVISION") or "main"
    pattern = os.environ.get("HF_FILE") or ""
    token = os.environ.get("HF_TOKEN") or ""
    ctx = env_int("CTX", 4096)
    vram = env_int("VRAM_BYTES", 24467 * MIB)
    reserve = env_int("VRAM_RESERVE_BYTES", 1536 * MIB)
    kv_elem = env_int("KV_ELEM_BYTES", 2)
    supported = {int(v) for v in os.environ.get("NINFER_VERSIONS", "2").split(",") if v}
    fit_mode = os.environ.get("FIT_CHECK", "strict")
    if engine not in ("ninfer", "llamacpp", "ollama"):
        raise Fail(2, "unknown_engine", engine=engine)

    info = model_info(repo, revision, token)
    sha = info["sha"]
    files = pick_files(info["siblings"], engine, pattern)
    weights = sum(f["size"] or 0 for f in files)
    budget = vram - reserve
    if weights > budget:
        raise Fail(2, "too_large", weights_bytes=weights, budget_bytes=budget,
                   hint="weights alone exceed GPU memory minus reserve")

    outdir = os.path.join(ROOT, repo, sha)
    os.makedirs(outdir, exist_ok=True)
    for f in files:
        download(repo, sha, f, os.path.join(outdir, f["name"]), token)
    primary = os.path.join(outdir, files[0]["name"])

    facts = {}
    if engine == "ninfer":
        facts["ninfer_container_version"] = check_ninfer(primary, supported)
        # KV size depends on the engine flags; weights plus reserve is the only hard check.
    else:
        g = read_gguf(primary)
        per_tok = kv_bytes_per_token(g, kv_elem)
        facts.update({"gguf_version": g["version"], "arch": g["arch"], "tensors": g["tensors"],
                      "native_context": g["kv"].get(g["arch"] + ".context_length"),
                      "kv_bytes_per_token_upper_bound": per_tok})
        if per_tok:
            need = weights + per_tok * ctx
            facts["estimated_total_bytes"] = need
            if need > budget:
                if fit_mode == "strict":
                    raise Fail(2, "does_not_fit", weights_bytes=weights, kv_bytes=per_tok * ctx, ctx=ctx,
                               budget_bytes=budget, hint="lower the context or set FIT_CHECK=warn")
                facts["fit_warning"] = True

    mpath = manifest_path(primary)
    prev = {}
    if os.path.isfile(mpath):
        try:
            prev = json.load(open(mpath))
        except (OSError, ValueError):
            prev = {}
    now = int(time.time())
    manifest = {"engines": sorted(set(prev.get("engines", [])) | {engine}), "repo": repo, "revision": sha,
                "requested_revision": revision, "primary_file": files[0]["name"], "files": files,
                "weights_bytes": weights, "ctx_checked": ctx, "staged_at": prev.get("staged_at", now),
                "last_used": now, **facts}
    with open(mpath, "w") as f:
        json.dump(manifest, f, indent=1)
    return {"ok": True, "engine": engine, "repo": repo, "revision": sha, "primary_file": files[0]["name"],
            "path": primary, "weights_bytes": weights, **facts}


def manifest_path(primary):
    return primary + ".stage.json"


def entries():
    out = []
    for dirpath, _dirs, names in os.walk(ROOT):
        for n in names:
            if not n.endswith(".stage.json"):
                continue
            try:
                m = json.load(open(os.path.join(dirpath, n)))
            except (OSError, ValueError):
                continue
            primary = os.path.join(ROOT, m["repo"], m["revision"], m["primary_file"])
            m["path"] = primary
            m["ollama_imported"] = os.path.isfile(primary + ".ollama-imported")
            out.append(m)
    return out


def entry_key(m):
    return "%s@%s#%s" % (m["repo"], m["revision"], m["primary_file"])


def remove_entry(m):
    base = os.path.join(ROOT, m["repo"], m["revision"])
    for f in m["files"]:
        for suffix in ("", ".ok", ".part"):
            p = os.path.join(base, f["name"] + suffix)
            if os.path.isfile(p):
                os.remove(p)
    for suffix in (".stage.json", ".ollama-imported"):
        p = m["path"] + suffix
        if os.path.isfile(p):
            os.remove(p)
    cur = os.path.dirname(m["path"])
    root = os.path.realpath(ROOT)
    while os.path.realpath(cur).startswith(root + os.sep):
        try:
            os.rmdir(cur)
        except OSError:
            break
        cur = os.path.dirname(cur)


def run_list():
    es = [{k: e.get(k) for k in ("repo", "revision", "requested_revision", "primary_file", "path", "engines",
                                  "ollama_imported", "weights_bytes", "last_used", "staged_at")} for e in entries()]
    used = shutil.disk_usage(ROOT)
    return {"ok": True, "entries": es, "volume_total": used.total, "volume_free": used.free}


def run_delete():
    repo, rev, primary = os.environ["HF_REPO"], os.environ["HF_REVISION"], os.environ["PRIMARY_FILE"]
    for m in entries():
        if (m["repo"], m["revision"], m["primary_file"]) == (repo, rev, primary):
            remove_entry(m)
            return {"ok": True, "deleted": entry_key(m)}
    raise Fail(2, "not_a_staged_entry", repo=repo, revision=rev, primary_file=primary)


def run_evict():
    """Delete least recently used entries until staged weights are below LIMIT_GIB, skipping IN_USE keys."""
    limit = env_int("LIMIT_GIB", 300) * GIB
    in_use = set(filter(None, os.environ.get("IN_USE", "").split(",")))
    es = sorted(entries(), key=lambda e: e.get("last_used", 0))
    total = sum(e.get("weights_bytes", 0) for e in es)
    deleted = []
    for e in es:
        if total <= limit:
            break
        if entry_key(e) in in_use:
            continue
        remove_entry(e)
        total -= e.get("weights_bytes", 0)
        deleted.append(entry_key(e))
    return {"ok": True, "deleted": deleted, "remaining_bytes": total}


def main():
    mode = os.environ.get("MODE", "stage")
    try:
        result = {"stage": stage, "list": run_list, "delete": run_delete, "evict": run_evict}[mode]()
        emit(result, termination=(mode == "stage"))
        if os.environ.get("RESULT_FILE"):
            with open(os.environ["RESULT_FILE"], "w") as f:
                json.dump(result, f, separators=(",", ":"))
        return 0
    except Fail as e:
        emit({"ok": False, "error": e.error, **e.detail})
        return e.code
    except KeyError as e:
        emit({"ok": False, "error": "missing_parameter", "name": str(e)})
        return 2


if __name__ == "__main__":
    sys.exit(main())
