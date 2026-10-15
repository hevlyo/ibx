# Field notes: instabox behaviour seen in practice

These notes record what a real account showed on 2026-10-15 (region us-west-2, template
`agent-browser` version 2026-10-15.4) in places where the docs say nothing, say something
different, or are easy to miss. instabox is in beta and changes fast. When a note here and
the live spec disagree, read `GET https://api.instabox.sh/v1/openapi.json` (public, no key),
and trust what you observe over both. Each note gives the symptom and what to do.

This file is about behaviour. Routes, scopes, Idempotency-Key rules, error codes, limits and
curl patterns are in [api-notes.md](api-notes.md); this file links there instead of repeating
them.

Spec citations look like `spec: POST /v1/machines/{id}/exec` (a route) or
`spec: schemas.Metadata` (a component schema). Read them with
`jq '.paths["/v1/machines/{id}/exec"].post.description' openapi.json`.

## Contents

1. [Idle pause and the ignored autoSuspendAfterSeconds](#1-idle-pause-and-the-ignored-autosuspendafterseconds)
2. [Activity leases](#2-activity-leases)
3. [What wakes a paused sandbox](#3-what-wakes-a-paused-sandbox)
4. [Pause, stop and start: what survives](#4-pause-stop-and-start-what-survives)
5. [exec quirks](#5-exec-quirks)
6. [TLS drops and slow replies](#6-tls-drops-and-slow-replies)
7. [pkill -f kills its own exec](#7-pkill--f-kills-its-own-exec)
8. [The guest user](#8-the-guest-user)
9. [Public ports](#9-public-ports)
10. [SSH tokens and certificates](#10-ssh-tokens-and-certificates)
11. [Desktop and computer use](#11-desktop-and-computer-use)
12. [Spec drift](#12-spec-drift)
13. [Hardware, network and software](#13-hardware-network-and-software)
14. [Timings](#14-timings)
15. [Reporting provider bugs](#15-reporting-provider-bugs)

## 1. Idle pause and the ignored autoSuspendAfterSeconds

**Symptom.** A sandbox running a quiet job (a download, a `sleep` loop, a server that nobody
calls) goes `suspended` with `autoSuspendedAt` set about 30 minutes after the last exec or
terminal use. Its public URLs start answering 503.

**Facts (verified 2026-10-15).**
- New sandboxes pause after 1800 s without activity (spec: schemas.AutoSuspendAfterSeconds).
- The setting is ignored today. `PATCH /v1/machines/{id}` and `POST /v1/machines` with
  `autoSuspendAfterSeconds` of 0, 7200 or even 5 all return 200, and the value stays 1800.
  The field is parsed (a string gives a Go unmarshal error), then dropped. 5 is outside the
  documented 120-86400 range and still gets 200.
- Light CPU does not count as activity. A 5-second CPU burst every minute did not keep a
  sandbox awake: it paused at 30.5 minutes. The spec says a sandbox is idle with "little CPU"
  (spec: schemas.Machine, `autoSuspendAfterSeconds`). The exact threshold is not known.
- According to the spec, exec, files, terminal traffic, preview (public URL) requests and
  activity leases count as activity. Status reads and keepalives do not (spec: info.description,
  "Sandbox lifecycle").

**What to do.**
- Do not rely on the setting or on CPU load. Use an activity lease. `ibx keepalive` run from a
  timer renews one (see [keepalive.md](keepalive.md)). Otherwise, touch the sandbox with an exec
  at least every 25 minutes.
- An idle pause keeps processes (section 4), so a detached job only freezes, and it carries on
  when the sandbox wakes. The things that do break are public URLs and work that depends on the
  outside world while paused.
- To check whether the bug is fixed, PATCH a value and GET the sandbox again. If the server
  starts keeping the value, the timer becomes optional.

## 2. Activity leases

Leases work as documented, and they are the one reliable way to keep a sandbox awake: an idle
sandbox stayed up for more than 60 minutes with a lease renewed every 15 minutes. How they
behave (a PUT wakes an idle-paused sandbox, a lifecycle operation drops every lease, a full
idle period starts at expiry, a DELETE starts the idle clock without waking) is in
[keepalive.md](keepalive.md#2-how-activity-leases-work); the route and its limits are in
[api-notes.md](api-notes.md#2-routes).

ibx uses the lease ID `ibx-keepalive` with a TTL of 3600 s. `ibx claim` sets it once the
sandbox is reserved, `ibx keepalive` renews it, and `ibx release` deletes it.

## 3. What wakes a paused sandbox

| Request | Sandbox paused for idleness | Paused or stopped by hand, timeout, archive |
|---|---|---|
| exec, `GET /files`, terminal | wakes it, then runs (`trigger: request`) | `409 machine_not_running` |
| `POST /connections` (SSH certificate) | wakes it | `409 machine_not_running` |
| `POST /wake` | wakes it, waits up to 45 s | not undone |
| `PUT` activity lease | wakes it | do not rely on it |
| SSH login with a token | the client is told to start the sandbox; it is not woken | same |
| Public URL | **never wakes it**: 503 while paused | 503 |
| `GET /v1/machines/{id}`, lists | no effect | no effect |

Sources: spec info.description ("Sandbox lifecycle"), the per-route descriptions, and
observation. Nothing undoes a manual pause or stop automatically. `ibx claim` and `ibx ssh`
make sure the sandbox runs before they use it, and `ibx exec` (also behind `put` and `get`)
starts or resumes it after a `409 machine_not_running`, so with ibx a sandbox someone paused
by hand gets resumed.

## 4. Pause, stop and start: what survives

- **Pause** (`suspend`) keeps RAM and processes. A counter loop kept counting from where it
  stopped. While the sandbox is paused, the guest's monotonic clock is frozen (so `sleep` and
  monotonic timeouts do not advance). The wall clock is corrected on resume and jumps forward,
  so programs that compare wall-clock times see a gap.
- After a resume, `runtime.processesPreserved: false` means the programs could not be brought
  back and the sandbox booted fresh; the files are still there (spec: schemas.Runtime). ibx
  prints "WARNING: ... came back with a fresh boot" only after a start, resume or wake it made
  itself (`claim`, `ssh`, or an exec that got `409 machine_not_running`). When the server wakes
  an idle-paused sandbox for an exec (`trigger: request`), ibx never sees the resume and cannot
  warn: check that your processes are still there.
- After a pause, `storage.synced` stays `false` for about 16 s. A snapshot of a stopped or
  paused sandbox waits for it (spec: schemas.Storage).
- **Stop/start**: files persist on `/data` and on the system disk (packages installed with
  apt survive). Processes and `/dev/shm` do not.
- SSH connections close when the sandbox pauses or stops (spec: info.description, "SSH").
- `stop` on a paused sandbox returns `409 operation_conflict`. Start it first, or delete it
  (spec: POST /v1/machines/{id}/stop).

## 5. exec quirks

Limits (timeout, `cmd`, stdin and output sizes, concurrency) are in
[api-notes.md](api-notes.md#7-limits). What they mean in practice:

- It runs `bash -lc <cmd>` as the guest user (section 8), with HOME and the working directory
  at `/data/home`.
- When the timeout runs out, the process group gets SIGKILL and the result has
  `timedOut: true` and `exitCode: 124`. The exit code is in the body, and the HTTP status is
  200 even for exit 1. A command killed by signal N exits with 128+N (143 = SIGTERM, 137 =
  SIGKILL, often the OOM killer).
- **The concurrency limit (4) covers the whole account**, so every agent sharing the pool
  shares it, and `GET /files` counts too. Going over it returns `429 quota_exceeded`. ibx
  waits 5-9 s (jittered) between tries for up to 10 minutes, then stops with "exec did not
  run: 4 other execs kept the account busy for 10 minutes".
- **Not idempotent**: a retry runs the command again. ibx retries only errors that mean the
  command did not run (the quota, `machine_not_running` up to 3 times, retryable
  `host_unavailable`). It treats `api_key_expired` and `api_key_revoked` as rejected (did not
  run), and stops on anything else with "the command may or may not have run". Write commands
  that are safe to repeat (`mkdir -p`, marker files, check-then-act).
- Output is collected, not streamed: you see nothing until the command ends.
- `stdin` is a JSON string, so `ibx exec -i` carries text: bytes that are not valid UTF-8
  arrive as U+FFFD. Binary files go through `ibx put` or `ibx ssh`.
- A background process that keeps stdout or stderr open makes the exec wait for it (standard
  SSH behaviour), and a timeout then kills it. To start something that must outlive the exec,
  use `setsid -f CMD </dev/null >LOG 2>&1` (see [recipes.md](recipes.md#5-long-jobs-detached)).
- Slow outlier: one exec took 71 s at the gateway while the command took 4 s in the VM. Keep
  the client timeout well above `timeoutSeconds`: ibx waits `-t` + 90 s, so an agent's tool
  call needs `-t` + 120 s.

## 6. TLS drops and slow replies

**Symptom.** curl exits with 55 (send failure) or 56 (receive failure) in the middle of a
reply. This happened intermittently and many times on 2026-10-15, on every kind of route.

**What to do.**
- Retry only calls that are safe to repeat (the Retry column in
  [api-notes.md](api-notes.md#2-routes)). Never retry exec or `POST /ssh-tokens` blindly: an
  exec may run twice, and a token POST leaves a second live token behind.
- A `DELETE /v1/machines/{id}/ssh-tokens/{tokenID}` that failed this way did **not** revoke the
  token. Check `revokedAt` in `GET /v1/machines/{id}/ssh-tokens`, and DELETE again if it is
  missing.
- Write the body to a file, so a retried download replaces the partial body. The patterns are
  in [api-notes.md](api-notes.md#9-curl-patterns-that-survive-tls-drops).

## 7. pkill -f kills its own exec

**Symptom.** `ibx exec BOX -- 'pkill -f my-server; echo done'` exits 143 and prints nothing.
ibx warns "the remote command was killed by SIGTERM".

**Cause.** The pattern appears in the exec's own `bash -lc` command line, so pkill matches that
shell and kills it. The same thing happens with `ibx ssh BOX 'pkill -f ...'`.

**What to do.**
- Look before you kill, and do the kill in a separate exec, with a bracket pattern that matches
  the target but not its own text:
  `ibx exec BOX -- "pgrep -af '[m]y-server'"`, then `ibx exec BOX -- "pkill -f '[m]y-server' || true"`.
- Better still, record PIDs or process groups when you start something and kill those
  ([recipes.md](recipes.md#8-safe-process-killing)).
- Never kill the provider's processes: `instabox-guest-agent`, `sshd`, `Xvnc`,
  `instabox-computer-use`.

## 8. The guest user

- Every sandbox has a guest user, fixed at create (spec: schemas.Machine, `guestUser`). It is
  `user` by default. The instabox CLI sends the creator's local user name, so sandboxes made
  with it often log in as that name (spec: schemas.CreateMachineRequest, `guestUser`). Older
  sandboxes, and templates without the `guest-user` capability, use `dev`; a sandbox created
  from a snapshot keeps the snapshot's user. The exec description in the spec still says `dev`.
- HOME is `/data/home` whatever the name. Use `$HOME` and `$(id -un)`. Never hard-code `dev`,
  `user`, `/home/dev` or any other name.
- The guest user has passwordless `sudo` and is in the `docker` group.
- exec and SSH sessions arrive as SSH sessions from `172.16.0.1` (the gateway). The gateway
  terminates SSH. `instabox-guest-agent` runs as root and talks to the host over vsock. A fixed
  control-plane key sits in `/etc/instabox/authorized_keys/<uid>`. Do not edit or remove these;
  see [trust-model.md](trust-model.md) for what they mean.

## 9. Public ports

- URL: `https://<port>-<sandbox id without the m_ prefix>.instabox.tech`, served with a Let's
  Encrypt wildcard certificate through a transparent proxy.
- **There is no authentication option** (spec: schemas.PublishPortRequest has only `port` and
  `name`). Anyone with the URL reaches the whole service on that port. The URL is built from
  the sandbox ID and the port, so it is not a random secret.
- While the sandbox is paused or stopped, the URL answers 503, and a request never wakes the
  sandbox. After an unpublish, the URL answers 404 immediately.
- Publishing the same port again keeps its URL. Port ranges and the per-sandbox cap are in
  [api-notes.md](api-notes.md#7-limits).
- A DELETE of a port that is not published returns 404. `ibx unport` and `ibx release` treat
  that as already unpublished.
- Software inside a sandbox that holds the sandbox-local port credential (`instabox-port`,
  installed by `POST /v1/machines/{id}/port-agent`) can publish ports itself. `ibx release`
  removes only ports whose name starts with `ibx:` and warns about the others.

## 10. SSH tokens and certificates

- An SSH token (`ibssh_...`) **is the SSH user name**, and the server accepts it with auth
  method `none`. It is a bearer secret: anyone who has it gets a shell (and so root through
  sudo) until it expires or is revoked. Used naively, it ends up in process lists (argv), shell
  history, and any file a tool writes the login into. Its default lifetime is long (7 days; see
  [api-notes.md](api-notes.md#7-limits)).
- `ibx ssh` asks for 1 h, keeps the token in a 0600 ssh config inside a private temp directory
  (ibx runs under `umask 077`), redacts it from stderr, and revokes it on exit
  ([trust-model.md](trust-model.md#7-what-ibx-enforces)). If ibx prints
  "WARNING: SSH token ... may NOT be revoked; it expires within 1 hour", check `revokedAt`
  (section 6).
- A login with a token to a sandbox that is not running tells the client to start it; the
  sandbox is not woken. `ibx ssh` starts or wakes the sandbox first.
- Certificates (`POST /v1/machines/{id}/connections`) bind access to a key pair, which is
  safer. **No single certificate can be revoked**: the admin "close connection" route says it
  is not a revocation. Revoking or expiring the API key that issued a certificate ends it
  (spec: info.description, "API keys").
- Supported over SSH: pty, shell, exec, subsystem, env, signals, local port forwarding. Not
  supported: agent forwarding, X11, remote forwarding (spec: info.description, "SSH").
  `mosh-server` is installed and works through a relay.

## 11. Desktop and computer use

- The `agent-browser` template has XFCE and **Xvnc (TigerVNC) on 127.0.0.1:5901**. The spec
  says Xvfb (spec: POST /v1/machines/{id}/desktop). Chromium is not started automatically.
- The VNC server has no password and listens only on loopback; `GET /v1/machines/{id}/vnc` is
  the way in (spec: same route). Any process in the sandbox can drive the display.
- An MCP server, `instabox-computer-use` (open-computer-use), offers 9 tools: `click`, `drag`,
  `get_app_state`, `list_apps`, `perform_secondary_action`, `press_key`, `scroll`, `set_value`,
  `type_text`.
- Human takeover (`{"action": "takeover"}`) makes the MCP refuse its input tools until
  `handback`, or until 30 s pass without a call from the holder. The lock is advisory, so tools
  that drive the display directly (xdotool) ignore it (spec: POST /v1/machines/{id}/desktop).
- View-only desktop links are enforced on the server: viewer input was dropped. Links work
  without signing in until they expire, and `DELETE /v1/machines/{id}/desktop/stream` revokes
  all of them.

## 12. Spec drift

As of 2026-10-15:

- The fork route was removed from the spec on 2026-10-15. To copy a sandbox, take a snapshot
  and create from it.
- The exec description says the user is `dev`; new sandboxes use their `guestUser` (section 8).
- The desktop description says Xvfb; it is Xvnc, and Chromium is not auto-started (section 11).
- The idempotency prose says every mutating POST and DELETE needs an `Idempotency-Key`; the
  per-route parameters disagree, and they are what the server enforces
  ([api-notes.md](api-notes.md#3-idempotency)).
- `autoSuspendAfterSeconds` is documented but ignored (section 1).
- The scope list in the prose leaves out ports, leases, files, wake and desktop; the
  per-route descriptions give their scopes.
- Some schema descriptions are split into stray keys with `null` values (for example
  `schemas.Files.properties.path`, `schemas.Connection.properties.id`). Read the text around
  them.
- The docs site renders only with JavaScript. `GET /v1/openapi.json` is public and is the most
  complete source.

## 13. Hardware, network and software

| Item | Observed 2026-10-15 |
|---|---|
| VM | Firecracker microVM |
| OS / kernel | Debian 13, kernel 6.18, monolithic: no `modprobe`, no loadable modules, no `/dev/kvm` (no nested VMs or accelerated emulators) |
| CPU | 4 vCPU AMD EPYC (Zen 5); 4 processes scale 3.98x; steal about 0% with 5 sandboxes busy |
| Memory | 7964 MiB visible (about 7.8 GiB), **no swap** (out of memory means the OOM killer, exit 137) |
| Disks | 16 GiB system disk (`/`); 20 GiB storage at `/data` (HOME `/data/home`); 17 GiB of random data really written to `/data` |
| Egress | shared NAT IPv4; about 3.3 Gbit/s download from a nearby host, about 0.75 Gbit/s upload; outbound port 25 blocked |
| Ingress | none: not reachable from the internet, IPv6 included; only published ports (through the proxy) and SSH (through the gateway) |

Preinstalled in `agent-browser` 2026-10-15.4: `claude`, `codex`, node 22, python 3.13, `uv`,
`go`, rust, `gh`, `git`, docker with compose, chromium 154, `mosh-server`. Missing: `tmux`,
`ripgrep`, `opencode`, `bun`, `strace`, `tcpdump`, `/usr/bin/time`. Install the Debian ones
with `sudo apt-get install -y tmux ripgrep strace tcpdump time`. Packages persist across
stop/start, so the next holder of a pool sandbox sees them too. The preinstalled agent CLIs are
not signed in; leave them that way ([trust-model.md](trust-model.md)).

The shared egress IP means per-IP rate limits (for example anonymous container registry pulls)
can run out sooner than you would expect. Account limits (5 sandboxes in any state, one fixed
size, snapshots, keys) are in [api-notes.md](api-notes.md#7-limits).

## 14. Timings

| Action | Observed 2026-10-15 |
|---|---|
| Create from a preboot template | 0.3-0.4 s server-side |
| Resume after a pause | about 0.2 s server-side, about 0.9 s as the client sees it |
| `storage.synced` after a pause | `false` for about 16 s |
| Stop / start | about 1 s / about 2.6 s |
| Live snapshot of a running sandbox | ready in 4-7 s; processes undisturbed |
| Idle pause | 30 min without activity (paused at 30.5 min with light CPU bursts) |
| exec outlier | 71 s at the gateway for a command that took 4 s |

## 15. Reporting provider bugs

Problems with instabox itself (the API, sandboxes, the CLI, the docs) go to the instabox team,
not to ibx. The user's instabox CLI has a command for it; it redacts emails, keys, tokens, home
paths and public IPv4 addresses before sending:

```bash
instabox feedback --type bug --component api --title "autoSuspendAfterSeconds is accepted but ignored" \
  --detail "PATCH /v1/machines/{id} with autoSuspendAfterSeconds 7200 returns 200; GET still shows 1800." \
  --expected "the value from the spec range 120-86400 is kept"
```

Good candidates from these notes: the ignored `autoSuspendAfterSeconds` (section 1), the token
DELETE lost to a TLS drop (section 6), and the spec drift (section 12). Agents draft the report
and let the user send it; never include API keys, tokens, sandbox IDs or personal data.
Problems with ibx itself go to its repository; security issues go through its private
reporting, as [SECURITY.md](https://github.com/hevlyo/ibx/blob/main/SECURITY.md) explains.
