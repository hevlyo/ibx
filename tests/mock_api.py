#!/usr/bin/env python3
"""In-memory fake of the part of the instabox.sh API that ibx uses, for offline tests.

Python 3 standard library only. It follows the published OpenAPI document where ibx depends on
it: the error envelope, Bearer auth, Idempotency-Key on PATCH /v1/machines/{id} and on
resume/start, 202 Operations for resume/start and long polls on GET /v1/operations/{id}?wait=,
POST /wake answering 200 with the Machine, PUT activity-leases waking an idle-paused sandbox,
metadata replaced (not merged) by PATCH, exec answering 409 machine_not_running on a sandbox that
does not run, DELETE of a port that is not public answering 404 not_found.

Vault: every Machine has "vault" (false by default: the Vault is off for it). With the Vault on,
GET /v1/machines/{id or name}/vault answers {enabled, items: [{name, kind, ...}], applied}; on a
sandbox whose Machine has no "vault" field (set "vault": null) that route answers 404, as a
server without the Vault would. resume/start with {"vault": false} turn it off for good.

Exec: with --exec real (or MOCK_EXEC=real) the command runs with `bash -c` in a per-sandbox
temporary HOME (also its working directory), with the request's stdin and timeout. Otherwise a
canned result: `exit N` exits N, `sleep N` longer than the timeout times out, anything else
exits 0 and echoes the command on stdout. Queued results (control "execResults") win over both.

Test endpoints (no auth):
  GET    /_calls    every /v1 request: method, path, query, idempotencyKey, status, dropped, body
                     (an exec's stdin is replaced by stdinLength and stdinSha256)
  DELETE /_calls    forget them
  GET    /_state    sandboxes with their ports, leases, SSH tokens and HOME directory
  POST   /_control  JSON object; keys are applied in this order:
    reset: true                       default sandboxes; no faults, calls or queued results
    seed: {count, states, pool, metadata, idle, vault}   replace the sandboxes (box-1..N);
        vault: {"box-2": 3, "box-3": 0} or "box-2:3,box-3:0" = the Vault on with N items
    set: {"box-1": {state, metadata, mergeMetadata, deleteMetadata, ports, leases, freshBoot,
                    ready, vault, name, id, rawPorts}}   change one sandbox; state "idle" = paused when
        idle; ports: [{port, name, url}]; vault: N (on, N items), false (off) or null (no
        "vault" field and no Vault route); name/id rename it (id: any string, even an invalid one).
        rawPorts overrides GET /ports verbatim, for malformed provider responses.
    clockSkew: SECONDS                seconds the mock's clock runs ahead of the client's (negative:
        behind); applies to every timestamp it makes, before the reset's seed; reset restores 0
    metadataKeepsUpdatedAt: true      PATCH leaves updatedAt as it was (reset: false)
    clearFaults: true
    opDelay: SECONDS                   delay for new operations (reset restores --op-delay)
    faults: [{kind, method, match, count, status, code, message, retryable, operationId,
              before, seconds, skip}]
        kind "drop": the reply is cut off mid-body (before: true closes the connection
        without a reply; the request is not processed then; plain: true answers an exec that
        asks for a stream with a plain JSON result instead, as a buffering proxy would; with a
        queued or canned result);
        "error": answer status/code instead (body: TEXT sends that text/html page instead of
        an error envelope, as a gateway in front of the API would); "delay": wait `seconds`
        before handling the request; "conflict": resume/start answer 409 operation_conflict
        naming an operation that is already in progress; "failop": the next operation fails.
        skip: leave the first N matching requests alone. match is a regular expression
        searched in the path.
    dropGets K, quotaExecs K, dropExecs K, conflictResumes K, failOps K   shortcuts
    execResults: [{stdout, stderr, exitCode, timedOut, truncated, signal, delay}]
        delay: seconds the exec takes before it answers (a slow command, in both exec modes)
    resetCalls: true

Start: mock_api.py --port 0 prints the chosen port on stdout, then serves until SIGTERM.
  --vault box-2:3 --vault box-3:0 (or box-2:3,box-3:0) seeds the Vault; --help for the rest.
"""

from pathlib import Path
import codecs
import selectors
import argparse
import copy
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from base64 import b64encode
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

B32 = "abcdefghijklmnopqrstuvwxyz234567"
MIB = 1 << 20
DEFAULT_KEY = "ibk_" + "mock" * 13
STATES = {"creating", "starting", "running", "stopping", "stopped", "suspending",
          "suspended", "resuming", "deleting", "deleted", "error"}
TRANSITIONS = {  # transitional state -> (operation type, final state)
    "creating": ("create", "running"), "starting": ("start", "running"),
    "resuming": ("resume", "running"), "stopping": ("stop", "stopped"),
    "suspending": ("suspend", "suspended"),
}
META_KEY = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
MACHINE_ID = re.compile(r"^m_[a-z2-7]{26}$")


def rid(prefix, n=26):
    return prefix + "".join(secrets.choice(B32) for _ in range(n))


CLOCK_SKEW = 0.0  # seconds the server clock runs ahead of the client (control "clockSkew")


def now():
    return datetime.now(timezone.utc) + timedelta(seconds=CLOCK_SKEW)


def iso(dt=None):
    dt = dt or now()
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%06dZ" % dt.microsecond


def fake_ca_key():
    blob = struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32) + \
        hashlib.sha256(b"ibx mock host CA").digest()
    return "ssh-ed25519 " + b64encode(blob).decode()


class ApiError(Exception):
    def __init__(self, status, code, message, retryable=False, operation_id=None, **details):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message
        self.retryable, self.operation_id = retryable, operation_id
        self.details = details

    def body(self):
        return {"error": {"code": self.code, "message": self.message,
                          "requestId": rid("req_", 16), "retryable": self.retryable,
                          "operationId": self.operation_id, **self.details}}


def not_found(what="no such resource"):
    return ApiError(404, "not_found", what)


def bad_request(message):
    return ApiError(400, "bad_request", message)


def truthy(v):
    return v in (True, 1, "1", "true", "yes", "on")


class State:
    def __init__(self, args):
        self.lock = threading.RLock()
        self.cond = threading.Condition(self.lock)
        self.key = args.key
        self.default_op_delay = self.op_delay = args.op_delay
        self.exec_real = args.exec == "real"
        self.max_execs = args.max_execs
        self.ssh_port = args.ssh_port or closed_port()
        self.verbose = args.verbose
        self.defaults = dict(count=args.machines, states=split(args.states),
                             pool=split(args.pool), idle=args.idle, vault=",".join(args.vault))
        self.home_root = tempfile.mkdtemp(prefix="ibx-mock-")
        self.ca_key = fake_ca_key()
        self.machines = {}  # id -> internal machine (public fields + "_" private ones)
        self.ops = {}
        self.faults = []
        self.exec_results = []
        self.calls = []
        self.idem = {}
        self.running_execs = 0
        self.org_secrets = []
        self.org_secrets_enabled = True
        self.files_enabled = True
        self.file_bad_hash = False
        self.metadata_keeps_updated_at = False
        self.org = {"id": "org_mock", "tier": "free", "limits": {"freeSandboxHours": 0, "startsPerMinute": 3}, "usage": {"freeSandboxHours": 12}}
        startup = {"dropGets": args.drop_gets, "quotaExecs": args.quota_execs,
                   "dropExecs": args.drop_execs, "conflictResumes": args.conflict_resumes,
                   "failOps": args.fail_ops}
        with self.lock:
            self.seed(**self.defaults)
            self.control({k: v for k, v in startup.items() if v})

    # ---- sandboxes -------------------------------------------------------------------------
    def seed(self, count=3, states=None, pool=None, metadata=None, idle=None, vault=None):
        for m in self.machines.values():
            shutil.rmtree(m["_home"], ignore_errors=True)
        self.machines, self.ops = {}, {}
        states, pool, vault = states or [], pool or [], parse_vault(vault)
        for i in range(1, int(count) + 1):
            name = "box-%d" % i
            st = states[i - 1] if i - 1 < len(states) else "running"
            inpool = truthy(pool[i - 1]) if i - 1 < len(pool) else not pool
            md = dict(metadata or {})
            if inpool:
                md["ibx.pool"] = "1"
            now = iso()
            mid = rid("m_")
            home = os.path.join(self.home_root, mid)
            os.makedirs(home)
            m = {"id": mid, "name": name, "desiredState": "running", "state": "running",
                 "revision": 1, "operationId": None,
                 "template": {"id": "tpl_base", "version": "1", "digest": "sha256:" + "0" * 64},
                 "spec": {"vcpus": 4, "memMiB": 8192, "persistentDiskGiB": 20},
                 "storage": {"sizeGiB": 20, "mountPath": "/data", "persistent": True,
                             "synced": True},
                 "runtime": {"ready": True}, "free": True, "maxRunMinutes": 480,
                 "runStartedAt": now, "cooldownUntil": None, "orgId": "org_mock",
                 "autoSuspendAfterSeconds": 1800, "metadata": md, "vault": False,
                 "guestUser": "user", "createdAt": now, "updatedAt": now,
                 "_home": home, "_ports": {}, "_leases": {}, "_tokens": {}, "_fresh": False,
                 "_vault": [], "_secrets": {"secrets": [], "envSecrets": [], "items": [], "version": 0}}
            if name in vault:
                self.set_vault(m, vault[name])
            self.machines[mid] = m
            self.set_state(m, "idle" if name in (idle or []) else st)

    def set_state(self, m, st):
        m.pop("autoSuspendedAt", None)
        m["operationId"] = None
        if st == "idle":
            st = "suspended"
            m["autoSuspendedAt"] = iso(now() - timedelta(minutes=5))
        if st not in STATES:
            raise bad_request("unknown state %s" % st)
        m["state"] = st
        m["desiredState"] = st if st in ("running", "stopped", "suspended") else "running"
        m["runtime"] = {"ready": st == "running"}
        if st in TRANSITIONS:
            typ, final = TRANSITIONS[st]
            self.start_op(m, typ, final, transitional=st)

    @staticmethod
    def set_vault(m, v):
        """v: number of items (the Vault on), False (off), None (no "vault" field at all)."""
        if v is None:
            m.pop("vault", None)
            m["_vault"] = []
        elif v is False:
            m["vault"], m["_vault"] = False, []
        else:
            if isinstance(v, bool) or not isinstance(v, int) or v < 0:
                raise bad_request("vault: a number of items, false or null")
            m["vault"] = True
            m["_vault"] = ["MOCK_SECRET_%d" % (i + 1) for i in range(v)]

    def find(self, ref, by_name=True):
        for m in self.machines.values():
            if m["id"] == ref or (by_name and m["name"] == ref):
                return m
        raise not_found("sandbox %s not found" % ref)

    @staticmethod
    def public(m):
        return {k: copy.deepcopy(v) for k, v in m.items() if not k.startswith("_")}

    def touch(self, m):
        m["revision"] += 1
        m["updatedAt"] = iso()

    # ---- operations ------------------------------------------------------------------------
    def start_op(self, m, typ, final, transitional=None, trigger=None):
        now = iso()
        op = {"id": rid("op_"), "machineId": m["id"], "type": typ, "state": "running",
              "phase": "booting" if final == "running" else "saving", "error": None,
              "createdAt": now, "updatedAt": now,
              "_done": time.monotonic() + self.op_delay, "_final": final,
              "_from": m["state"],
              "_fail": self.take_fault("POST", "", kinds=("failop",)) is not None}
        if trigger:
            op["trigger"] = trigger
        self.ops[op["id"]] = op
        m["state"] = transitional or {"running": "starting" if typ == "start" else "resuming",
                                      "stopped": "stopping", "suspended": "suspending"}[final]
        m["desiredState"] = final
        if typ in ("start", "resume") and trigger is None:
            m["_leases"] = {}
        m["operationId"] = op["id"]
        m["runtime"] = {"ready": False}
        self.touch(m)
        self.cond.notify_all()
        return op

    def tick(self):
        now, changed = time.monotonic(), False
        for op in self.ops.values():
            if op["state"] not in ("queued", "running") or now < op["_done"]:
                continue
            changed = True
            op["updatedAt"] = iso()
            m = self.machines.get(op["machineId"])
            if op["_fail"]:
                op["state"], op["phase"] = "failed", "failed"
                op["error"] = ApiError(500, "internal",
                                       "mock: injected operation failure").body()["error"]
                if m and m["operationId"] == op["id"]:
                    m["operationId"] = None
                    m["state"] = op["_from"] if op["_from"] not in TRANSITIONS else "error"
                    m["desiredState"] = m["state"]
                    m["lastError"] = op["error"]
                    self.touch(m)
                continue
            op["state"], op["phase"] = "succeeded", "done"
            if m and m["operationId"] == op["id"]:
                m["operationId"] = None
                m["state"] = m["desiredState"] = op["_final"]
                m.pop("autoSuspendedAt", None)
                m["runtime"] = {"ready": op["_final"] == "running"}
                if op["_final"] == "running":
                    m["runStartedAt"] = iso()
                    m["cooldownUntil"] = None
                if op["type"] in ("start", "resume") and op["_from"] in ("suspended", "suspending"):
                    m["runtime"]["processesPreserved"] = not m["_fresh"]
                    m["_fresh"] = False
                self.touch(m)
        if changed:
            self.cond.notify_all()

    def wait_op(self, op, seconds):
        """Waits (lock held, released while waiting) until op ends or its state/phase changes."""
        end = time.monotonic() + seconds
        first = (op["state"], op["phase"])
        while True:
            self.tick()
            if op["state"] in ("succeeded", "failed") or (op["state"], op["phase"]) != first:
                return
            left = min(end, op["_done"]) - time.monotonic()
            if end - time.monotonic() <= 0:
                return
            self.cond.wait(max(0.01, left))

    def public_op(self, op):
        out = {k: copy.deepcopy(v) for k, v in op.items() if not k.startswith("_")}
        m = self.machines.get(op["machineId"])
        if op["state"] == "succeeded" and m:
            out["machine"] = self.public(m)
        return out

    # ---- faults ----------------------------------------------------------------------------
    def take_fault(self, method, path, kinds=("drop", "error", "delay")):
        for f in self.faults:
            if f["kind"] not in kinds or f["count"] <= 0:
                continue
            if f.get("method") and f["method"] != method:
                continue
            if f.get("match") and not re.search(f["match"], path):
                continue
            if f.get("skip", 0) > 0:
                f["skip"] -= 1
                continue
            f["count"] -= 1
            return dict(f)
        return None

    def control(self, c):
        global CLOCK_SKEW
        if c.get("reset"):
            CLOCK_SKEW = 0.0
        if "clockSkew" in c:  # before seeding, so every timestamp of the reset uses it
            CLOCK_SKEW = float(c["clockSkew"])
        if c.get("reset"):
            self.op_delay = self.default_op_delay
            self.org_secrets = []
            self.org_secrets_enabled = True
            self.files_enabled = True
            self.file_bad_hash = False
            self.metadata_keeps_updated_at = False
            self.seed(**self.defaults)
            self.faults, self.exec_results, self.calls, self.idem = [], [], [], {}
        if "orgSecrets" in c:
            self.org_secrets = c["orgSecrets"]
        if "orgSecretsEnabled" in c:
            self.org_secrets_enabled = c["orgSecretsEnabled"]
        if "fileBadHash" in c:
            self.file_bad_hash = c["fileBadHash"]
        if "metadataKeepsUpdatedAt" in c:
            self.metadata_keeps_updated_at = truthy(c["metadataKeepsUpdatedAt"])
        if "filesEnabled" in c:
            self.files_enabled = c["filesEnabled"]
        if "org" in c:
            self.org.update(c["org"])
        if "opDelay" in c:
            self.op_delay = float(c["opDelay"])
        if "seed" in c:
            s = c["seed"]
            self.seed(count=s.get("count", 3), states=s.get("states"), pool=s.get("pool"),
                      metadata=s.get("metadata"), idle=s.get("idle"), vault=s.get("vault"))
        for ref, ch in (c.get("set") or {}).items():
            m = self.find(ref)
            if "state" in ch:
                self.set_state(m, ch["state"])
            for key in ("maxRunMinutes", "runStartedAt", "cooldownUntil", "free"):
                if key in ch:
                    m[key] = ch[key]
            if "secrets" in ch:
                m["_secrets"] = ch["secrets"]
            if "rawVault" in ch:
                m["_raw_vault"] = ch["rawVault"]
            if "applied" in ch:
                m["_applied"] = ch["applied"]
            if "tokens" in ch:
                m["_tokens"] = {t["id"]: dict(t, _revoked=bool(t.get("revokedAt"))) for t in ch["tokens"]}
            if "metadata" in ch:
                m["metadata"] = dict(ch["metadata"])
            m["metadata"].update(ch.get("mergeMetadata") or {})
            for k in ch.get("deleteMetadata") or []:
                m["metadata"].pop(k, None)
            for p in ch.get("ports") or []:
                self.publish(m, int(p["port"]), p.get("name"), p.get("url"))
            if "rawPorts" in ch:
                m["_raw_ports"] = copy.deepcopy(ch["rawPorts"])
            for lease in ch.get("leases") or []:
                self.put_lease(m, lease, 3600)
            if "freshBoot" in ch:
                m["_fresh"] = truthy(ch["freshBoot"])
            if "ready" in ch:
                m["runtime"]["ready"] = truthy(ch["ready"])
            if "vault" in ch:
                self.set_vault(m, ch["vault"])
            if "name" in ch:
                m["name"] = str(ch["name"])
            if "id" in ch:  # any string: tests give it an invalid one
                del self.machines[m["id"]]
                m["id"] = str(ch["id"])
                self.machines[m["id"]] = m
            self.touch(m)
        if c.get("clearFaults"):
            self.faults = []
        for f in c.get("faults") or []:
            f = dict(f)
            f.setdefault("count", 1)
            if f.get("kind") not in ("drop", "error", "delay", "conflict", "failop"):
                raise bad_request("unknown fault kind %r" % f.get("kind"))
            self.faults.append(f)
        shortcuts = {
            "dropGets": {"kind": "drop", "method": "GET"},
            "quotaExecs": {"kind": "error", "method": "POST", "match": "/exec$", "status": 429,
                           "code": "quota_exceeded", "retryable": True,
                           "message": "concurrent-request limit reached"},
            "dropExecs": {"kind": "drop", "method": "POST", "match": "/exec$"},
            "conflictResumes": {"kind": "conflict", "method": "POST", "match": "/(resume|start)$"},
            "failOps": {"kind": "failop"},
        }
        for name, f in shortcuts.items():
            if c.get(name):
                self.faults.append(dict(f, count=int(c[name])))
        self.exec_results.extend(c.get("execResults") or [])
        if c.get("resetCalls"):
            self.calls = []
        self.cond.notify_all()

    def dump(self):
        out = []
        for m in self.machines.values():
            d = self.public(m)
            d["ports"] = sorted(m["_ports"].values(), key=lambda p: p["port"])
            d["leases"] = sorted(m["_leases"].values(), key=lambda l: l["id"])
            d["tokens"] = [{"id": t["id"], "name": t["name"], "revoked": t["_revoked"]}
                           for t in m["_tokens"].values()]
            d["home"] = m["_home"]
            d["vaultItems"] = list(m["_vault"])
            out.append(d)
        return {"machines": out, "faults": self.faults,
                "operations": [self.public_op(o) for o in self.ops.values()]}

    # ---- resources -------------------------------------------------------------------------
    def publish(self, m, port, name, url=None):
        if port < 1024 or port > 65535 or port in (5901, 6768):
            raise bad_request("port must be 1024-65535 and not reserved (5901, 6768)")
        if name is not None and (not isinstance(name, str) or len(name) > 100):
            raise bad_request("name: at most 100 characters")
        existing = m["_ports"].get(port)
        if existing:
            if name is not None:
                existing["name"] = name
            if url is not None:
                existing["url"] = url
            return 200, existing
        if len(m["_ports"]) >= 16:
            raise ApiError(429, "quota_exceeded", "the sandbox already has 16 public ports")
        p = {"id": rid("pp_"), "machineId": m["id"], "port": port,
             "name": name if name is not None else "Port %d" % port,
             "url": url or "https://%s.ports.mock.invalid" % rid("p", 12), "createdAt": iso(),
             "expiresAt": None}
        m["_ports"][port] = p
        return 201, p

    def put_lease(self, m, lease, ttl):
        if len(m["_leases"]) >= 128 and lease not in m["_leases"]:
            raise ApiError(429, "quota_exceeded", "at most 128 active task leases per machine")
        exp = iso(now() + timedelta(seconds=ttl))
        m["_leases"][lease] = {"id": lease, "machineId": m["id"], "expiresAt": exp}
        return m["_leases"][lease]

    def record(self, method, path, query, headers, body):
        call = {"seq": len(self.calls) + 1, "t": time.time(), "method": method, "path": path,
                "query": query, "idempotencyKey": headers.get("Idempotency-Key"), "accept": headers.get("Accept"),
                "status": None, "dropped": False, "body": None}
        if body:
            try:
                b = json.loads(body)
                if isinstance(b, dict) and isinstance(b.get("stdin"), str):
                    data = b["stdin"].encode("utf-8", "surrogatepass")
                    b = dict(b, stdin=None, stdinLength=len(data),
                             stdinSha256=hashlib.sha256(data).hexdigest())
                call["body"] = b
            except ValueError:
                call["body"] = {"unparsed": len(body)}
        self.calls.append(call)
        return call


def split(v):
    if v is None or v == "":
        return []
    if v == "none":
        return ["0"] * 64
    return [x.strip() for x in v.split(",")]


def parse_vault(v):
    """{"box-2": 3} or "box-2:3,box-3:0" (or a list of such terms) -> {name: items}."""
    if not v:
        return {}
    if isinstance(v, dict):
        return dict(v)
    out = {}
    for term in v if isinstance(v, list) else str(v).split(","):
        name, _, n = str(term).strip().partition(":")
        if name:
            out[name] = int(n or 0)
    return out


def closed_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def parse_wait(v):
    if not v:
        return 0.0
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(ms|s)?", v)
    if not m:
        raise bad_request("wait: a duration such as 25s or 500ms")
    x = float(m.group(1))
    return min(x / 1000 if m.group(2) == "ms" else x, 30.0)


def json_body(raw, required=False):
    if not raw:
        if required:
            raise bad_request("a JSON body is required")
        return {}
    try:
        b = json.loads(raw)
    except ValueError:
        raise bad_request("the body is not JSON")
    if not isinstance(b, dict):
        raise bad_request("the body must be a JSON object")
    return b


def run_real(home, cmd, stdin, timeout, cwd, envs, streamed=False):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home, "USER": "dev",
           "LOGNAME": "dev", "SHELL": "/bin/bash", "LANG": "C.UTF-8"}
    env.update(envs)
    wd = os.path.join(home, cwd) if cwd else home
    if not os.path.isdir(wd):
        return {"stdout": "", "stderr": "cwd %s: no such directory\n" % cwd, "exitCode": 1,
                "timedOut": False, "truncated": False}
    p = subprocess.Popen(["bash", "-c", cmd], cwd=wd, env=env, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    timed_out = False
    try:
        out, err = p.communicate(stdin.encode(), timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            out, err = p.communicate(timeout=5)
        except subprocess.TimeoutExpired:  # something detached still holds the pipes
            p.kill()
            out, err = b"", b""
    limit = None if streamed else MIB
    r = {"stdout": out[:limit].decode("utf-8", "replace"),
         "stderr": err[:limit].decode("utf-8", "replace"),
         "truncated": not streamed and (len(out) > MIB or len(err) > MIB), "timedOut": timed_out}
    try:
        out[:limit].decode("utf-8")
        err[:limit].decode("utf-8")
    except UnicodeDecodeError:
        r["invalidUtf8"] = True
    if timed_out:
        r["exitCode"] = 124
    elif p.returncode < 0:
        r["exitCode"] = 128 - p.returncode
        try:
            r["signal"] = signal.Signals(-p.returncode).name.removeprefix("SIG")
        except ValueError:
            pass
    else:
        r["exitCode"] = p.returncode
    return r


def run_canned(cmd, timeout):
    s = cmd.strip()
    r = {"stdout": "", "stderr": "", "exitCode": 0, "timedOut": False, "truncated": False}
    m = re.fullmatch(r"exit (\d+)", s)
    if m:
        r["exitCode"] = int(m.group(1)) & 255
        return r
    m = re.fullmatch(r"sleep (\d+(?:\.\d+)?)", s)
    if m:
        if float(m.group(1)) > timeout:
            r.update(timedOut=True, exitCode=124)
        return r
    r["stdout"] = cmd + "\n"
    return r


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ibx-mock/1"
    S = None  # State, set in main()

    def log_message(self, fmt, *args):
        if self.S.verbose:
            sys.stderr.write("mock: %s\n" % (fmt % args))

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def do_PUT(self):
        self.dispatch("PUT")

    def do_PATCH(self):
        self.dispatch("PATCH")

    def do_DELETE(self):
        self.dispatch("DELETE")

    def reply(self, status, obj, drop=False, content_type=None):
        data = obj if isinstance(obj, bytes) else (b"" if obj is None else (json.dumps(obj) + "\n").encode())
        self.send_response(status)
        if obj is not None:
            self.send_header("Content-Type", content_type or ("application/octet-stream" if isinstance(obj, bytes) else "application/json"))
            if isinstance(obj, dict) and (obj.get("error") or {}).get("retryAfterSeconds"):
                self.send_header("Retry-After", str(obj["error"]["retryAfterSeconds"]))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        if drop:
            data = data[: len(data) // 2]
        self.wfile.write(data)
        self.wfile.flush()
        if drop:
            self.cut()
        self.close_connection = True

    def cut(self):
        try:
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.close_connection = True

    def dispatch(self, method):
        S = self.S
        u = urlsplit(self.path)
        path = u.path
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n > 0 else b""
        if path.startswith("/_"):
            return self.test_endpoint(method, path, raw)
        with S.lock:
            call = S.record(method, path, u.query, self.headers, raw)
        status, obj, fault = 500, None, None
        try:
            with S.lock:
                S.tick()
                auth = self.headers.get("Authorization", "")
                port_auth = auth == "Port mock-port" and re.fullmatch(r"/v1/machines/" + next(iter(S.machines), "none") + r"/ports(?:/[0-9]+)?", path)
                if auth != "Bearer " + S.key and not port_auth:
                    code = "missing_key" if not auth else ("malformed_key" if not auth.startswith("Bearer ibk_") else "invalid_key")
                    raise ApiError(401, code, "API key refused", reason=code, hint="ask the user for a valid key", docs="https://docs.mock.invalid/auth")
                fault = S.take_fault(method, path)
            if fault and fault["kind"] == "delay":
                time.sleep(float(fault.get("seconds", 1)))
            if fault and fault["kind"] == "drop" and fault.get("before"):
                with S.lock:
                    call["status"], call["dropped"] = 0, True
                return self.cut()
            if fault and fault["kind"] == "error" and "body" in fault:
                with S.lock:
                    call["status"] = int(fault.get("status", 502))
                return self.reply(call["status"], fault["body"].encode(), content_type="text/html; charset=utf-8")
            if fault and fault["kind"] == "error":
                raise ApiError(int(fault.get("status", 500)), fault.get("code", "internal"),
                               fault.get("message", "mock: injected error"),
                               truthy(fault.get("retryable", False)), fault.get("operationId"),
                               **{k: fault[k] for k in ("retryAfterSeconds", "hint", "requiredScopes", "reason") if k in fault})
            status, obj = self.route(method, path, parse_qs(u.query), raw, call)
        except ApiError as e:
            status, obj = e.status, e.body()
        except Exception as e:  # a bug in the mock: say so instead of hanging the client
            status, obj = 500, ApiError(500, "internal", "mock bug: %r" % e).body()
        if status == 0:  # real SSE already wrote the response and owns its process lifecycle
            with S.lock:
                call["status"] = 200
            return
        drop = bool(fault and fault["kind"] == "drop")
        with S.lock:
            call["status"], call["dropped"] = status, drop
        if drop and obj is None:
            return self.cut()
        if status == 200 and method == "POST" and path.endswith("/exec") and "text/event-stream" in self.headers.get("Accept", "") \
                and not (drop and fault.get("plain")):
            return self.reply_sse(obj, drop)
        self.reply(status, obj, drop)

    def sse_headers(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Connection", "close")
        self.end_headers()

    def sse_event(self, name, value):
        self.wfile.write(("event: " + name + "\ndata: " + json.dumps(value, ensure_ascii=False) + "\n\n").encode())
        self.wfile.flush()

    def reply_sse(self, result, drop=False):
        self.sse_headers()
        self.wfile.write(b": ping\n\n")
        for name in ("stdout", "stderr"):
            text = result.get(name, "")
            for start in range(0, len(text), 65536):
                self.sse_event(name, {"data": text[start:start + 65536]})
        time.sleep(float(result.get("streamDelay", 0)))
        if result.get("streamError"):
            self.sse_event("error", {"error": {"code": "host_unavailable", "message": "mock stream disconnected", "retryable": True}})
        elif not (drop or result.get("streamDrop")):
            self.sse_event("exit", dict(result, stdout="", stderr="", truncated=False))
        self.close_connection = True

    def reply_real_stream(self, home, cmd, stdin, timeout, cwd, envs):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home, "USER": "dev",
               "LOGNAME": "dev", "SHELL": "/bin/bash", "LANG": "C.UTF-8"}
        env.update(envs)
        wd = os.path.join(home, cwd) if cwd else home
        self.sse_headers()
        if not os.path.isdir(wd):
            self.sse_event("stderr", {"data": "cwd does not exist\n"})
            self.sse_event("exit", {"stdout": "", "stderr": "", "exitCode": 1, "timedOut": False, "truncated": False})
            self.close_connection = True
            return
        proc = subprocess.Popen(["bash", "-c", cmd], cwd=wd, env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        pending = stdin.encode()
        offset = 0
        selector = selectors.DefaultSelector()
        for name, stream in (("stdout", proc.stdout), ("stderr", proc.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        if pending:
            os.set_blocking(proc.stdin.fileno(), False)
            selector.register(proc.stdin, selectors.EVENT_WRITE, "stdin")
        else:
            proc.stdin.close()
        # Watch the socket even while the command is silent, so disconnect kills promptly.
        selector.register(self.connection, selectors.EVENT_READ, "connection")
        decoders = {name: codecs.getincrementaldecoder("utf-8")("replace") for name in ("stdout", "stderr")}
        validators = {name: codecs.getincrementaldecoder("utf-8")("strict") for name in decoders}
        exited_at = None
        invalid = finished = False
        timed_out = threading.Event()
        def kill_group():
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        def expire():
            if proc.poll() is None:
                timed_out.set()
                kill_group()
        # A blocked network writer must never postpone the command deadline.
        watchdog = threading.Timer(timeout, expire)
        watchdog.daemon = True
        try:
            watchdog.start()
            self.connection.settimeout(timeout + 1)
            while True:
                now = time.monotonic()
                if proc.poll() is not None:
                    exited_at = exited_at or now
                    outputs = [key for key in selector.get_map().values() if key.data in ("stdout", "stderr")]
                    if not outputs or now - exited_at >= 1:
                        break
                for key, _ in selector.select(timeout=0.05):
                    name, stream = key.data, key.fileobj
                    if name == "connection":
                        if not self.connection.recv(1, socket.MSG_PEEK):
                            return
                        continue
                    if name == "stdin":
                        try:
                            offset += os.write(stream.fileno(), pending[offset:offset + 65536])
                        except BrokenPipeError:
                            offset = len(pending)
                        if offset >= len(pending):
                            selector.unregister(stream)
                            stream.close()
                        continue
                    try:
                        data = os.read(stream.fileno(), 65536)
                    except BlockingIOError:
                        continue
                    try:
                        validators[name].decode(data, final=not data)
                    except UnicodeDecodeError:
                        invalid = True
                        validators[name].reset()
                    text = decoders[name].decode(data, final=not data)
                    if text:
                        self.sse_event(name, {"data": text})
                    if not data:
                        selector.unregister(stream)
                        stream.close()
            result = {"stdout": "", "stderr": "", "timedOut": timed_out.is_set(), "truncated": False,
                      "exitCode": 124 if timed_out.is_set() else (128 - proc.returncode if proc.returncode < 0 else proc.returncode)}
            if invalid:
                result["invalidUtf8"] = True
            if proc.returncode < 0 and not timed_out.is_set():
                result["signal"] = signal.Signals(-proc.returncode).name.removeprefix("SIG")
            self.sse_event("exit", result)
            finished = True
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        finally:
            watchdog.cancel()
            # Disconnect/timeout kills the group; normal parent exit preserves background work.
            if not finished:
                kill_group()
            proc.wait(timeout=5)
            selector.close()
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                stream.close()
            self.close_connection = True

    def test_endpoint(self, method, path, raw):
        S = self.S
        try:
            with S.lock:
                S.tick()
                if path == "/_calls" and method == "GET":
                    return self.reply(200, {"calls": S.calls})
                if path == "/_calls" and method == "DELETE":
                    S.calls = []
                    return self.reply(204, None)
                if path == "/_state" and method == "GET":
                    return self.reply(200, S.dump())
                if path == "/_control" and method == "POST":
                    S.control(json_body(raw, required=True))
                    return self.reply(200, {"ok": True, "machines": [
                        {"name": m["name"], "id": m["id"], "state": m["state"]}
                        for m in S.machines.values()]})
                if path == "/_health":
                    return self.reply(200, {"ok": True})
            raise not_found()
        except ApiError as e:
            self.reply(e.status, e.body())

    # ---- routes ----------------------------------------------------------------------------
    def route(self, method, path, query, raw, call):
        S = self.S
        parts = [unquote(p) for p in path.strip("/").split("/")]
        if parts[:1] != ["v1"]:
            raise not_found()
        parts = parts[1:]
        with S.lock:
            if parts == ["me"] and method == "GET":
                return 200, {"userId": 1, "login": "mock-user", "name": "Mock User",
                             "activated": True, "admin": False, "orgId": "org_mock"}
            if parts == ["orgs", "org_mock"] and method == "GET":
                return 200, S.org
            if parts == ["orgs", "org_mock", "secrets"] and method == "GET":
                if not S.org_secrets_enabled:
                    raise not_found("route not found")
                return 200, {"items": S.org_secrets}
            if parts == ["ports"] and method == "GET":
                return 200, {"ports": [dict(p, machineId=m["id"]) for m in S.machines.values() for p in m["_ports"].values()]}
            if parts == ["usage"] and method == "GET":
                return 200, {"computedAt": iso(), "logicalBytes": 0, "storedBytes": 0,
                             "exclusiveBytes": 0, "machines": len(S.machines), "snapshots": 0,
                             "images": 0,
                             "limits": {"maxMachines": 5, "maxSnapshots": 5, "maxStoredGiB": 200,
                                        "maxImages": 10, "orgSecrets": S.org_secrets_enabled,
                                        "machineSpec": {"vcpus": 4, "memMiB": 8192,
                                                        "persistentDiskGiB": 20}}}
            if parts == ["machines"] and method == "GET":
                return 200, self.list_machines(query)
            if len(parts) == 2 and parts[0] == "operations" and method == "GET":
                op = S.ops.get(parts[1])
                if not op:
                    raise not_found("operation %s not found" % parts[1])
                S.wait_op(op, parse_wait((query.get("wait") or [""])[0]))
                return 200, S.public_op(op)
            if len(parts) < 2 or parts[0] != "machines":
                raise not_found()
        mref, rest = parts[1], parts[2:]
        by_name = rest in ([], ["exec"], ["vault"]) and method in ("GET", "POST")  # MachineRef
        if not by_name and not MACHINE_ID.match(mref):
            raise not_found("sandbox %s not found (this route takes the sandbox ID)" % mref)
        if rest == ["exec"] and method == "POST":
            return self.exec_(mref, raw, call)
        with S.lock:
            m = S.find(mref, by_name)
            if rest == [] and method == "GET":
                return 200, S.public(m)
            if rest == [] and method == "PATCH":
                return self.idempotent(method, path, raw, lambda: self.patch(m, raw))
            if len(rest) == 1 and rest[0] in ("resume", "start") and method == "POST":
                return self.idempotent(method, path, raw,
                                       lambda: self.lifecycle(m, rest[0], path, raw))
            if rest == ["wake"] and method == "POST":
                return self.wake(m)
            if rest == ["secrets"] and method in ("GET", "PATCH"):
                if not S.org_secrets_enabled:
                    raise not_found("route not found")
                if method == "PATCH":
                    m["_secrets"].update(json_body(raw, required=True))
                return 200, m["_secrets"]
            if rest in (["files"], ["files", "content"]):
                if not S.files_enabled:
                    raise not_found("route not found")
                return self.files(m, method, query, raw)
            if rest == ["vault"] and method == "GET":
                return self.vault(m)
            if rest == ["ports"] and method == "GET":
                return 200, {"enabled": True,
                             "ports": m.get("_raw_ports", sorted(m["_ports"].values(), key=lambda p: p["port"]))}
            if rest == ["ports"] and method == "POST":
                b = json_body(raw, required=True)
                if not isinstance(b.get("port"), int) or isinstance(b.get("port"), bool):
                    raise bad_request("port: an integer is required")
                return S.publish(m, b["port"], b.get("name"))
            if len(rest) == 2 and rest[0] == "ports" and method == "DELETE":
                if not re.fullmatch(r"\d+", rest[1]):
                    raise bad_request("port must be an integer")
                if m["_ports"].pop(int(rest[1]), None) is None:
                    raise not_found("port %s is not public" % rest[1])
                return 204, None
            if len(rest) == 2 and rest[0] == "activity-leases":
                if not re.fullmatch(r"[A-Za-z0-9_-]+", rest[1]):
                    raise bad_request("bad lease id")
                if method == "PUT":
                    return self.lease(m, rest[1], raw)
                if method == "DELETE":
                    m["_leases"].pop(rest[1], None)
                    return 204, None
            if rest == ["connection-info"] and method == "GET":
                return 200, {"machineId": m["id"], "transport": "ssh", "host": "127.0.0.1",
                             "port": S.ssh_port, "username": m["id"],
                             "hostTrust": {"type": "ca", "publicKey": S.ca_key,
                                           "principals": [m["id"]]},
                             "capabilities": ["pty", "exec", "port-forwarding"]}
            if rest == ["ssh-tokens"] and method == "GET":
                return 200, {"tokens": [{k: v for k, v in t.items() if k in ("id", "name", "createdAt", "expiresAt", "revokedAt")} for t in m["_tokens"].values()]}
            if rest == ["ssh-tokens"] and method == "POST":
                return self.ssh_token(m, raw)
            if len(rest) == 2 and rest[0] == "ssh-tokens" and method == "DELETE":
                t = m["_tokens"].get(rest[1])
                if not t:
                    raise not_found("token %s not found" % rest[1])
                t["_revoked"] = True
                t["revokedAt"] = iso()
                return 204, None
        raise ApiError(405, "method_not_allowed", "%s is not allowed on %s" % (method, path))

    def list_machines(self, query):
        ms = [self.S.public(m) for m in self.S.machines.values()]
        for term in query.get("metadata", []):
            k, _, v = term.partition(":")
            ms = [m for m in ms if m["metadata"].get(k) == v]
        start = int((query.get("cursor") or ["0"])[0] or 0)
        limit = int((query.get("limit") or ["0"])[0] or 0)
        page = ms[start:start + limit] if limit else ms[start:]
        nxt = str(start + limit) if limit and start + limit < len(ms) else None
        return {"machines": page, "nextCursor": nxt}

    def idempotent(self, method, path, raw, fn):
        key = self.headers.get("Idempotency-Key")
        if not key:
            raise bad_request("missing Idempotency-Key")
        if not re.fullmatch(r"[\x21-\x7e]{1,200}", key):
            raise bad_request("bad Idempotency-Key")
        fp = hashlib.sha256(method.encode() + b" " + path.encode() + b"\n" + raw).hexdigest()
        seen = self.S.idem.get(key)
        if seen:
            if seen[0] != fp:
                raise ApiError(409, "idempotency_conflict", "key reused for a different request")
            return seen[1], copy.deepcopy(seen[2])
        status, obj = fn()
        self.S.idem[key] = (fp, status, copy.deepcopy(obj))
        return status, obj

    def patch(self, m, raw):
        b = json_body(raw, required=True)
        for k in b:
            if k in ("rootDiskGiB", "persistentDiskGiB"):
                raise ApiError(400, "spec_not_allowed", "sandbox sizes are fixed")

        md = b.get("metadata")
        if md is not None:
            if not isinstance(md, dict):
                raise bad_request("metadata must be an object")
            if len(md) > 32:
                raise bad_request("metadata: at most 32 keys")
            for k, v in md.items():
                if not META_KEY.match(k):
                    raise bad_request("metadata key %r: 1-64 characters [A-Za-z0-9_.-]" % k)
                if not isinstance(v, str) or len(v) > 512:
                    raise bad_request("metadata %s: a string of at most 512 characters" % k)
            if len(json.dumps(md, separators=(",", ":")).encode()) > 8192:
                raise bad_request("metadata: at most 8 KiB as JSON")
            m["metadata"] = dict(md)  # replaces: {} clears it
        if "autoSuspendAfterSeconds" in b:
            m["autoSuspendAfterSeconds"] = b["autoSuspendAfterSeconds"]

        if not self.S.metadata_keeps_updated_at:  # the spec does not say whether PATCH bumps it
            m["updatedAt"] = iso()  # metadata changes do not bump revision
        return 200, self.S.public(m)

    def check_cooldown(self, m):
        if m.get("maxRunMinutes") == 0:
            raise ApiError(409, "max_run_disabled", "max-run is disabled")
        until = m.get("cooldownUntil")
        if until:
            try:
                seconds = (datetime.fromisoformat(until.replace("Z", "+00:00")) - now()).total_seconds()
            except ValueError:  # a deadline the client may not parse: the server still enforces it
                seconds = 60
            if seconds > 0:
                raise ApiError(409, "machine_cooldown", "max-run cooldown", retryAfterSeconds=max(1, int(seconds + 1)))

    def files(self, m, method, query, raw):
        self.check_cooldown(m)
        if m["state"] != "running":
            raise ApiError(409, "machine_not_running", "not running")
        path = (query.get("path") or [""])[0]
        if not path.startswith("/"):
            raise bad_request("absolute path required")
        relative = path.removeprefix("/data/home/") if path.startswith("/data/home/") else path.lstrip("/")
        target = os.path.realpath(os.path.join(m["_home"], relative))
        if not target.startswith(m["_home"] + os.sep):
            raise ApiError(403, "permission_denied", "outside mock home")
        if os.path.isdir(target):
            raise ApiError(409, "not_a_file", "destination is a directory")
        if method == "PUT":
            if len(raw) > 5 * 1024**3:
                raise ApiError(413, "too_large", "file exceeds 5 GiB")
            if not os.path.isdir(os.path.dirname(target)):
                if query.get("parents") != ["true"]:
                    raise ApiError(404, "missing_parent", "parent missing")
                os.makedirs(os.path.dirname(target), exist_ok=True)
            created = not os.path.exists(target)
            with open(target + ".upload", "wb") as stream:
                stream.write(raw)
            os.replace(target + ".upload", target)
            return (201 if created else 200), {"path": path, "size": len(raw), "created": created,
                    "mode": "0644", "sha256": "0" * 64 if self.S.file_bad_hash else hashlib.sha256(raw).hexdigest()}
        if method == "GET":
            try:
                return 200, Path(target).read_bytes()
            except FileNotFoundError:
                raise not_found("file not found")
        raise bad_request("unsupported file request")

    def lifecycle(self, m, action, path, raw=b""):
        S = self.S
        b = json_body(raw)
        self.check_cooldown(m)
        if m["operationId"]:
            raise ApiError(409, "operation_conflict", "another operation is in progress",
                           operation_id=m["operationId"])
        allowed = {"resume": ("suspended",), "start": ("stopped", "suspended")}[action]
        if m["state"] not in allowed:
            raise ApiError(409, "operation_conflict",
                           "cannot %s a sandbox that is %s" % (action, m["state"]))
        if S.take_fault("POST", path, kinds=("conflict",)):
            other = S.start_op(m, action, "running")  # as if another client got there first
            raise ApiError(409, "operation_conflict", "another operation is in progress",
                           operation_id=other["id"])
        if b.get("vault") is False:  # permanent: the Vault never reaches it again
            S.set_vault(m, False)
        op = S.start_op(m, action, "running")
        return 202, S.public_op(op)

    def vault(self, m):
        """GET /vault: what the Vault writes into this sandbox (404: a server without Vault)."""
        if "_raw_vault" in m:
            return 200, m["_raw_vault"]
        if "vault" not in m:
            raise not_found("this server has no Vault")
        on = m["vault"] is not False
        items = [{"name": n, "kind": "env", "path": None}
                 for n in m["_vault"]] if on else []
        return 200, {"machineId": m["id"], "enabled": on, "items": items,
                     "applied": m.get("_applied", {"at": iso(), "env": [], "files": []} if on else None)}

    def wake(self, m):
        """POST /wake: 200 with the running Machine, after waking an idle-paused one."""
        S = self.S
        self.check_cooldown(m)
        if m["state"] == "running" and not m["operationId"]:
            return 200, S.public(m)
        if m["state"] == "suspended" and m.get("autoSuspendedAt") and not m["operationId"]:
            S.start_op(m, "resume", "running", trigger="request")
        op = S.ops.get(m["operationId"]) if m["operationId"] else None
        if op is None:
            raise ApiError(409, "machine_not_running",
                           "the sandbox is %s (paused or stopped by hand: resume or start it)"
                           % m["state"])
        end = time.monotonic() + 45
        while op["state"] not in ("succeeded", "failed") and time.monotonic() < end:
            S.wait_op(op, end - time.monotonic())
        if op["state"] == "succeeded" and m["state"] == "running":
            return 200, S.public(m)
        if op["state"] == "failed":
            raise ApiError(409, "machine_not_running", "the sandbox could not be resumed")
        raise ApiError(409, "operation_conflict", "still resuming", operation_id=op["id"])

    def lease(self, m, lease, raw):
        self.check_cooldown(m)
        b = json_body(raw)
        ttl = b.get("ttlSeconds") or 300
        if not isinstance(ttl, int) or not 30 <= ttl <= 3600:
            raise bad_request("ttlSeconds: 30-3600")
        if m["state"] != "running" or m["operationId"]:
            if m["state"] == "suspended" and m.get("autoSuspendedAt"):
                self.wake(m)  # PUT wakes an idle-paused sandbox first
            elif m["operationId"]:
                raise ApiError(409, "operation_conflict", "an operation is in progress",
                               operation_id=m["operationId"])
            else:
                raise ApiError(409, "machine_not_running", "the sandbox is %s" % m["state"])
        return 200, self.S.put_lease(m, lease, ttl)

    def ssh_token(self, m, raw):
        b = json_body(raw)
        ttl = b.get("ttlSeconds", 604800)
        if not isinstance(ttl, int) or not 1 <= ttl <= 2592000:
            raise bad_request("ttlSeconds: 1-2592000")
        name = (b.get("name") or "").strip()
        if len(name.encode()) > 100:
            raise bad_request("name: at most 100 bytes")
        tok = "ibssh_" + "".join(secrets.choice(B32) for _ in range(40))
        t = {"id": rid("cn_"), "name": name, "machineId": m["id"], "host": "127.0.0.1",
             "port": self.S.ssh_port, "token": tok,
             "command": "ssh -p %d %s@127.0.0.1" % (self.S.ssh_port, tok),
             "createdAt": iso(), "expiresAt": iso(now() + timedelta(seconds=ttl)),
             "hostKeyFingerprint": "SHA256:" + b64encode(hashlib.sha256(
                 self.S.ca_key.encode()).digest()).decode().rstrip("="),
             "_revoked": False}
        m["_tokens"][t["id"]] = t
        return 201, {k: v for k, v in t.items() if not k.startswith("_")}

    def exec_(self, mref, raw, call):
        S = self.S
        b = json_body(raw, required=True)
        cmd = b.get("cmd")
        if not isinstance(cmd, str) or not cmd or len(cmd) > 65536 or "\0" in cmd:
            raise bad_request("cmd: 1-65536 characters, no NUL")
        t = b.get("timeoutSeconds", 60)
        if not isinstance(t, int) or isinstance(t, bool) or not 1 <= t <= 600:
            raise bad_request("timeoutSeconds: 1-600")
        stdin = b.get("stdin", "")
        if not isinstance(stdin, str) or len(stdin.encode("utf-8", "surrogatepass")) > MIB:
            raise bad_request("stdin: at most 1 MiB")
        cwd = b.get("cwd") or ""
        envs = b.get("envs") or {}
        if not isinstance(envs, dict) or not all(
                re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k) and isinstance(v, str)
                for k, v in envs.items()):
            raise bad_request("envs: names [A-Za-z_][A-Za-z0-9_]*, string values")
        with S.lock:
            m = S.find(mref)
            self.check_cooldown(m)
            if m["state"] != "running" or m["operationId"]:
                raise ApiError(409, "machine_not_running", "the sandbox is %s" % m["state"])
            if S.running_execs >= S.max_execs:
                raise ApiError(429, "quota_exceeded", "too many execs at once (%d of %d)"
                               % (S.running_execs, S.max_execs), retryable=True)
            S.running_execs += 1
            queued = S.exec_results.pop(0) if S.exec_results else None
            home = m["_home"]
        try:
            if queued is not None:
                queued = dict(queued)
                time.sleep(float(queued.pop("delay", 0) or 0))
                r = {"stdout": "", "stderr": "", "exitCode": 0, "timedOut": False,
                     "truncated": False}
                r.update(queued)
            elif S.exec_real:
                if "text/event-stream" in self.headers.get("Accept", ""):
                    self.reply_real_stream(home, cmd, stdin, t, cwd, envs)
                    return 0, None
                r = run_real(home, cmd, stdin, t, cwd, envs, "text/event-stream" in self.headers.get("Accept", ""))
            else:
                r = run_canned(cmd, t)
        finally:
            with S.lock:
                S.running_execs -= 1
        return 200, r


def main():
    ap = argparse.ArgumentParser(description="Fake instabox.sh API for the ibx offline tests.")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=0, help="0: pick one and print it on stdout")
    ap.add_argument("--key", default=os.environ.get("MOCK_API_KEY", DEFAULT_KEY),
                    help="the API key clients must send as Bearer")
    ap.add_argument("--machines", type=int, default=3, help="sandboxes box-1..N (default 3)")
    ap.add_argument("--states", default="", help="comma-separated states (running, suspended, "
                    "idle = paused when idle, stopped, error, starting, ...); default running")
    ap.add_argument("--pool", default="", help="comma-separated 1/0 per sandbox, or none; "
                    "default: all in the pool")
    ap.add_argument("--idle", action="append", default=[], metavar="NAME",
                    help="this sandbox is paused when idle (autoSuspendedAt set)")
    ap.add_argument("--vault", action="append", default=[], metavar="NAME:N",
                    help="the Vault is on for this sandbox and writes N items into it "
                    "(box-3:0 = on but empty); comma-separated or repeated")
    ap.add_argument("--op-delay", type=float, default=0.3, help="seconds an operation takes")
    ap.add_argument("--exec", choices=("real", "canned"),
                    default="real" if os.environ.get("MOCK_EXEC") == "real" else "canned")
    ap.add_argument("--max-execs", type=int, default=32, help="concurrent execs (429 beyond)")
    ap.add_argument("--ssh-port", type=int, default=0, help="port in connection-info "
                    "(default: a closed local port, so ssh fails fast)")
    ap.add_argument("--drop-gets", type=int, default=0, metavar="K")
    ap.add_argument("--quota-execs", type=int, default=0, metavar="K")
    ap.add_argument("--drop-execs", type=int, default=0, metavar="K")
    ap.add_argument("--conflict-resumes", type=int, default=0, metavar="K")
    ap.add_argument("--fail-ops", type=int, default=0, metavar="K")
    ap.add_argument("--verbose", action="store_true", help="log requests on stderr")
    args = ap.parse_args()

    state = State(args)
    Handler.S = state
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    if args.port == 0:
        print(server.server_address[1], flush=True)

    def stop(*_):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        shutil.rmtree(state.home_root, ignore_errors=True)


if __name__ == "__main__":
    main()
