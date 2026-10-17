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
    clearFaults: true
    opDelay: SECONDS                   delay for new operations (reset restores --op-delay)
    faults: [{kind, method, match, count, status, code, message, retryable, operationId,
              before, seconds, skip}]
        kind "drop": the reply is cut off mid-body (before: true closes the connection
        without a reply; the request is not processed then); "error": answer status/code
        instead; "delay": wait `seconds` before handling the request; "conflict": resume/start
        answer 409 operation_conflict naming an operation that is already in progress;
        "failop": the next operation fails. skip: leave the first N matching requests alone.
        match is a regular expression searched in the path.
    dropGets K, quotaExecs K, dropExecs K, conflictResumes K, failOps K   shortcuts
    execResults: [{stdout, stderr, exitCode, timedOut, truncated, signal, delay}]
        delay: seconds the exec takes before it answers (a slow command, in both exec modes)
    resetCalls: true

Start: mock_api.py --port 0 prints the chosen port on stdout, then serves until SIGTERM.
  --vault box-2:3 --vault box-3:0 (or box-2:3,box-3:0) seeds the Vault; --help for the rest.
"""

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


def iso(dt=None):
    dt = dt or datetime.now(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%06dZ" % dt.microsecond


def fake_ca_key():
    blob = struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32) + \
        hashlib.sha256(b"ibx mock host CA").digest()
    return "ssh-ed25519 " + b64encode(blob).decode()


class ApiError(Exception):
    def __init__(self, status, code, message, retryable=False, operation_id=None):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message
        self.retryable, self.operation_id = retryable, operation_id

    def body(self):
        return {"error": {"code": self.code, "message": self.message,
                          "requestId": rid("req_", 16), "retryable": self.retryable,
                          "operationId": self.operation_id}}


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
                 "runtime": {"ready": True}, "timeoutAt": None, "onTimeout": "pause",
                 "autoSuspendAfterSeconds": 1800, "metadata": md, "vault": False,
                 "guestUser": "dev", "createdAt": now, "updatedAt": now,
                 "_home": home, "_ports": {}, "_leases": {}, "_tokens": {}, "_fresh": False,
                 "_vault": []}
            if name in vault:
                self.set_vault(m, vault[name])
            self.machines[mid] = m
            self.set_state(m, "idle" if name in (idle or []) else st)

    def set_state(self, m, st):
        m.pop("autoSuspendedAt", None)
        m["operationId"] = None
        if st == "idle":
            st = "suspended"
            m["autoSuspendedAt"] = iso(datetime.now(timezone.utc) - timedelta(minutes=5))
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
        if c.get("reset"):
            self.op_delay = self.default_op_delay
            self.seed(**self.defaults)
            self.faults, self.exec_results, self.calls, self.idem = [], [], [], {}
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
                           "message": "too many execs at once (4 of 4)"},
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
        exp = iso(datetime.now(timezone.utc) + timedelta(seconds=ttl))
        m["_leases"][lease] = {"id": lease, "machineId": m["id"], "expiresAt": exp}
        return m["_leases"][lease]

    def record(self, method, path, query, headers, body):
        call = {"seq": len(self.calls) + 1, "t": time.time(), "method": method, "path": path,
                "query": query, "idempotencyKey": headers.get("Idempotency-Key"),
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


def run_real(home, cmd, stdin, timeout, cwd, envs):
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
    r = {"stdout": out[:MIB].decode("utf-8", "replace"),
         "stderr": err[:MIB].decode("utf-8", "replace"),
         "truncated": len(out) > MIB or len(err) > MIB, "timedOut": timed_out}
    if timed_out:
        r["exitCode"] = 124
    elif p.returncode < 0:
        r["exitCode"] = 128 - p.returncode
        try:
            r["signal"] = signal.Signals(-p.returncode).name
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

    def reply(self, status, obj, drop=False):
        data = b"" if obj is None else (json.dumps(obj) + "\n").encode()
        self.send_response(status)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
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
                if auth != "Bearer " + S.key:
                    raise ApiError(401, "unauthenticated", "missing or unknown API key")
                fault = S.take_fault(method, path)
            if fault and fault["kind"] == "delay":
                time.sleep(float(fault.get("seconds", 1)))
            if fault and fault["kind"] == "drop" and fault.get("before"):
                with S.lock:
                    call["status"], call["dropped"] = 0, True
                return self.cut()
            if fault and fault["kind"] == "error":
                raise ApiError(int(fault.get("status", 500)), fault.get("code", "internal"),
                               fault.get("message", "mock: injected error"),
                               truthy(fault.get("retryable", False)), fault.get("operationId"))
            status, obj = self.route(method, path, parse_qs(u.query), raw, call)
        except ApiError as e:
            status, obj = e.status, e.body()
        except Exception as e:  # a bug in the mock: say so instead of hanging the client
            status, obj = 500, ApiError(500, "internal", "mock bug: %r" % e).body()
        drop = bool(fault and fault["kind"] == "drop")
        with S.lock:
            call["status"], call["dropped"] = status, drop
        if drop and obj is None:
            return self.cut()
        self.reply(status, obj, drop)

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
                             "activated": True, "admin": False}
            if parts == ["usage"] and method == "GET":
                return 200, {"computedAt": iso(), "logicalBytes": 0, "storedBytes": 0,
                             "exclusiveBytes": 0, "machines": len(S.machines), "snapshots": 0,
                             "images": 0,
                             "limits": {"maxMachines": 5, "maxSnapshots": 10, "maxStoredGiB": 200,
                                        "maxImages": 10,
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
            if rest == ["ssh-tokens"] and method == "POST":
                return self.ssh_token(m, raw)
            if len(rest) == 2 and rest[0] == "ssh-tokens" and method == "DELETE":
                t = m["_tokens"].get(rest[1])
                if not t:
                    raise not_found("token %s not found" % rest[1])
                t["_revoked"] = True
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
            if k not in ("metadata", "timeoutSeconds", "onTimeout", "autoSuspendAfterSeconds",
                         "vault"):
                raise bad_request("unknown field %s" % k)
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
        if "onTimeout" in b:
            m["onTimeout"] = b["onTimeout"]
        m["updatedAt"] = iso()  # metadata changes do not bump revision
        return 200, self.S.public(m)

    def lifecycle(self, m, action, path, raw=b""):
        S = self.S
        b = json_body(raw)
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
        if "vault" not in m:
            raise not_found("this server has no Vault")
        on = m["vault"] is not False
        items = [{"name": n, "kind": "env", "selector": "", "updatedAt": m["createdAt"]}
                 for n in m["_vault"]] if on else []
        return 200, {"machineId": m["id"], "enabled": on, "items": items,
                     "applied": on and m["state"] == "running"}

    def wake(self, m):
        """POST /wake: 200 with the running Machine, after waking an idle-paused one."""
        S = self.S
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
             "expiresAt": iso(datetime.now(timezone.utc) + timedelta(seconds=ttl)),
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
                r = run_real(home, cmd, stdin, t, cwd, envs)
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
    ap.add_argument("--max-execs", type=int, default=4, help="concurrent execs (429 beyond)")
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
