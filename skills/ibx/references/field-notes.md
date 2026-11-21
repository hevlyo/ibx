# Field notes: instabox behaviour seen in practice

These notes record observations from 2026-10-15 through 2026-10-27, including details that the
docs omit or contradict, plus documentation and terms changes read on 2026-11-06 (marked as
such; none of those was tested live). The initial image was `agent-browser` version 2026-10-15.4 in
us-west-2. instabox is in beta and changes fast. When a note here and
the live spec disagree, read `GET https://api.instabox.sh/v1/openapi.json` (public, no key),
and trust what you observe over both. Each note gives the symptom and what to do.

This file is about behaviour. Routes, scopes, Idempotency-Key rules, error codes, limits and
curl patterns are in [api-notes.md](api-notes.md); this file links there instead of repeating
them.

Spec citations look like `spec: POST /v1/machines/{id}/exec` (a route) or
`spec: schemas.Metadata` (a component schema). Read them with
`jq '.paths["/v1/machines/{id}/exec"].post.description' openapi.json`.

## Contents

1. [Idle pause and plan rules](#1-idle-pause-and-plan-rules)
2. [Activity leases](#2-activity-leases)
3. [What wakes a paused sandbox](#3-what-wakes-a-paused-sandbox)
4. [Pause, stop and start: what survives](#4-pause-stop-and-start-what-survives)
5. [exec quirks](#5-exec-quirks)
6. [TLS drops and slow replies](#6-tls-drops-and-slow-replies)
7. [Process killing](#7-process-killing)
8. [The guest user](#8-the-guest-user)
9. [Public ports](#9-public-ports)
10. [SSH tokens and certificates](#10-ssh-tokens-and-certificates)
11. [Desktop and computer use](#11-desktop-and-computer-use)
12. [Spec drift](#12-spec-drift)
13. [Hardware, network and software](#13-hardware-network-and-software)
14. [Timings](#14-timings)
15. [Reporting provider bugs](#15-reporting-provider-bugs)

## 1. Idle pause and plan rules

On 2026-10-15 and 2026-10-16, PATCH with `autoSuspendAfterSeconds: 0` returned 200 and the
setting stayed 1800. SDK 0.5.0 sent the same PATCH. The server changed on 2026-10-25 according
to the docs. On 2026-10-27, non-1800 values returned 403 `permission_denied` on the free plan;
PATCH 1800 was a successful no-op. This is now a plan restriction, not an ignored-setting bug.

Free boxes have a fixed 1800-second idle pause. Paid plans allow 300-1800 in whole minutes,
or 0 when always-on is allowed. The 120-86400 range belongs to admin-granted manual lifecycle
accounts. ibx never changes these settings. On paid boxes it holds an activity lease while a
box is claimed. On free boxes it holds none: since 2026-11-06 the terms (§2(e)) forbid leases
renewed from outside the sandbox, scheduled pings and busy loops that keep a free box from
pausing ([keepalive.md](keepalive.md)).

Free boxes also pause at their max-run limit. Leases cannot prevent this. Live probes on
2026-10-27 found runs of exactly 8 hours and cooldowns of 5-17 minutes. The docs read on
2026-11-06 give 5-20 minutes for the first max-run pause, 60-75 for a second back-to-back one
and 120-135 from the third on, and describe a dynamic runtime "when enabled". The OpenAPI and
auto-pause docs read on 2026-11-21 make it the rule for every free box: each run starts at 120
minutes and grows with use up to 480; leases and wake calls do not count. The change landed
between 2026-11-08 and 2026-11-13 without an announcement
([research note](../../../docs/research/2026-11-21-instabox-changes.md)). `runtime.processesPreserved` was true in the observed resumptions. Check job PIDs
and `runtime.processesPreserved` (in `ibx ls --json`) after waking, keep checkpoints, and do not interpret a refused poll as a dead job.

The 2026-11-06 docs define idle as "no coding agent working, no terminal or SSH traffic, and no
CPU load"; an exec, a file read, a public port request or a lease keeps a box busy, and a
missing signal counts as busy. A job that waits silently can therefore be paused. A resume normally
brings its memory and processes back, but it can fall back to a fresh boot
(`runtime.processesPreserved: false`) and open network connections can drop, so check the PID
and `processesPreserved` after any wake, not only after a max-run pause.

The prose docs say public visits wake idle-paused boxes and wait; the spec still says 503.
This behavior was not verified on the pool. Manual pauses and stops still return 503.

## 2. Activity leases

Leases prevent idle pauses, not max-run pauses. An idle sandbox stayed up for more than
60 minutes with a lease renewed every 15 minutes. How they
behave (a PUT wakes an idle-paused sandbox, a lifecycle operation drops every lease, a full
idle period starts at expiry, a DELETE starts the idle clock without waking) is in
[keepalive.md](keepalive.md#4-how-activity-leases-work); the route and its limits are in
[api-notes.md](api-notes.md#2-routes).

ibx uses the lease ID `ibx-keepalive` with a TTL of 3600 s. On a paid box `ibx claim` sets it
once the sandbox is reserved and `ibx keepalive` renews it. On a free box (`Machine.free`) neither
does, because the free plan's terms forbid it. `ibx release` deletes it either way.

## 3. What wakes a paused sandbox

| Request | Sandbox paused for idleness | Paused or stopped by hand, or archived |
|---|---|---|
| exec | wakes it, then runs (`trigger: request`), per the spec's lifecycle text and the prose docs; the request waits up to 45 s, then gets a retryable `409 operation_conflict`. The exec route itself says `409 machine_not_running`. ibx handles both, since neither means the command started: on `machine_not_running` it wakes the sandbox and sends the exec again; on `operation_conflict` it waits for the operation `error.operationId` names (the wake, or a snapshot or resize on a running sandbox), then until the sandbox runs, and sends it again, at most three times. `ibx run` and `ibx job` send once and report that nothing started | `409 machine_not_running` |
| `GET /files`, `PUT /files`, terminal | wakes it, then runs (`trigger: request`) | `409 machine_not_running` |
| `GET /files/content` | the route says `409 machine_not_running`; ibx wakes it and retries | `409 machine_not_running` |
| `POST /connections` (SSH certificate) | wakes it | `409 machine_not_running` |
| `POST /wake` | wakes it, waits up to 45 s | not undone |
| `PUT` activity lease | wakes it; ibx sends none to free boxes | do not rely on it |
| SSH login with a token | the client is told to start the sandbox; it is not woken | same |
| Public URL | prose docs say wake and wait; spec says 503, unverified here | 503 |
| Max-run cooldown | every wake path refuses until cooldownUntil | same |
| Abuse lock (`cooldownReason` `abuse_*`) | every wake path refuses, for up to 24 h | same |
| Second free box after 2026-12-01 | start, resume and wake refused with `402 early_allowance_ended` | same |
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
  prints "WARNING: ... came back with a fresh boot" after a start, resume or wake it made
  itself (`claim`, `ssh`, or an exec that got `409 machine_not_running`) and after a start or
  resume it waited for: one already running when it looked, or the one a
  `409 operation_conflict` names (a wake, the server's or its own, that outlived its 45-second
  hold). When the server's wake for an exec or a file request (`trigger: request`) finishes
  within the hold, the request just runs; ibx never sees the resume and cannot warn. Check that
  your processes are still there.
- After a pause, `storage.synced` stays `false` for about 16 s. A snapshot of a stopped or
  paused sandbox waits for it (spec: schemas.Storage).
- After stop/start, files persist on `/data` and on the system disk (packages installed with
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
- The limit is 32 requests per user, shared with files, desktop, forwarding and Secret refresh.
  `/v1/usage` does not expose this limit. A 429 `quota_exceeded` means nothing started.
- A restarting API kills an active command and may return retryable `host_unavailable`.
  Repeating it runs it again. ibx never retries a user command after that response.
- Current credential codes are `missing_key`, `malformed_key`, `invalid_key`, `expired_key`,
  `revoked_key`, `session_expired` and `missing_scope`; older names remain supported.
- The API supports SSE output. `ibx exec --stream` opts in; default exec collects output and
  caps each stream at 1 MiB. Closing a stream kills its command; an error never retries it.
- `invalidUtf8` reports replacement of bad bytes with U+FFFD. Use put/get for binary data.
  `signal` names the terminating signal; `diskWarning.message` reports filesystem pressure.
- Newer servers set `oomKilled: true` (and `oomKill` with the process name and PID) when the
  kernel OOM killer killed the command or a child. ibx prints one warning line for it. Boxes
  whose host or template predates the feature report `oomKilled: false` and `oomKills: 0`, so
  false proves nothing; exit 137 and `sudo dmesg` remain the check.
- Every exec that reaches the box is recorded server-side: the command text and the first
  64 KiB of each output stream, newest 200 per box, until the box is deleted (spec: GET
  /v1/machines/{id}/history, read on 2026-11-06). ibx leaves its own housekeeping execs out with
  `noHistory`; user commands stay in.
- Live on 2026-10-27, exec returned about one second after its parent command exited. Later
  writes from a background child were lost and failed with a broken pipe. The writer died,
  while its loop survived. Use `setsid -f CMD </dev/null >LOG 2>&1` for detached work.
- One slow exec took 71 s at the gateway while the command took 4 s in the VM. Keep
  the client timeout well above `timeoutSeconds`. ibx waits `-t` + 90 s, so an agent's tool
  call needs `-t` + 120 s, plus any wait before the command starts (request slot, cooldown,
  box start; see [recipes.md](recipes.md)).

## 6. TLS drops and slow replies

**Symptom.** curl exits with 55 (send failure) or 56 (receive failure) in the middle of a
reply. This happened intermittently and many times on 2026-10-15, on every kind of route.

**What to do.**
- Retry only calls that are safe to repeat (the Retry column in
  [api-notes.md](api-notes.md#2-routes)). Never retry exec or `POST /ssh-tokens` blindly. An
  exec may run twice, and a token POST leaves a second live token behind.
- A `DELETE /v1/machines/{id}/ssh-tokens/{tokenID}` that failed this way did **not** revoke the
  token. Check `revokedAt` in `GET /v1/machines/{id}/ssh-tokens`, and DELETE again if it is
  missing.
- Write the body to a file, so a retried download replaces the partial body. The patterns are
  in [api-notes.md](api-notes.md#9-curl-patterns-that-survive-tls-drops).

## 7. Process killing

The exec self-match reported on 2026-10-15 was not reproduced on 2026-10-27. The command now
runs through `eval "$INSTABOX_EXEC_CMD"`; its full text is absent from argv. This applies to
exec, not SSH, where the change was not verified. Recorded PIDs remain the safest way to stop
only your own processes. Keep bracket patterns in SSH commands. Never kill provider processes.

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
- Manual pauses and stops answer 503. For idle pauses, the prose docs say wake and wait,
  while the spec still says 503; this remains unverified here. After an unpublish, the URL answers 404 immediately.
- Publishing the same port again keeps its URL. Port ranges and the per-sandbox cap are in
  [api-notes.md](api-notes.md#7-limits).
- A DELETE of a port that is not published returns 404. `ibx unport` and `ibx release` treat
  that as already unpublished.
- `/usr/local/bin/instabox-port` and the guest-readable 0600 credential
  `/run/instabox-port/agent.json`, refreshed on resume, were found on box-5 on 2026-10-27
  (agent-browser image); assume other boxes may have them. Guest code there can publish an
  unauthenticated URL. Release removes ibx ports and ports created during
  the reservation; a process left running can publish again afterward.

## 10. SSH tokens and certificates

- An SSH token (`ibssh_...`) **is the SSH user name**, and the server accepts it with auth
  method `none`. It is a bearer secret. Anyone who has it gets a shell (and so root through
  sudo) until it expires or is revoked. Used naively, it ends up in process lists (argv), shell
  history, and any file a tool writes the login into. Its default lifetime is long (7 days, with `noExpiry` also available; see
  [api-notes.md](api-notes.md#7-limits)).
- `ibx ssh` asks for 1 h, keeps the token in a 0600 ssh config inside a private temp directory
  (ibx runs under `umask 077`), redacts it from stderr, and revokes it on exit
  ([trust-model.md](trust-model.md#7-what-ibx-enforces)). If ibx prints
  "WARNING: SSH token ... may NOT be revoked; it expires within 1 hour", check `revokedAt`
  (section 6).
- A login with a token to a sandbox that is not running tells the client to start it; the
  sandbox is not woken. `ibx ssh` starts or wakes the sandbox first.
- Certificates (`POST /v1/machines/{id}/connections`) bind access to a key pair, which is
  safer. No single certificate can be revoked. The admin "close connection" route says it
  is not a revocation. Revoking or expiring the API key that issued a certificate ends it
  (spec: info.description, "API keys").
- SSH supports pty, shell, exec, subsystem, env, signals and local port forwarding. It does
  not support agent forwarding, X11 or remote forwarding (spec: info.description, "SSH").
  `mosh-server` is installed and works through a relay.

## 11. Desktop and computer use

- The `agent-browser` template has XFCE and **Xvnc (TigerVNC) on 127.0.0.1:5901**. The spec
  says Xvfb (spec: POST /v1/machines/{id}/desktop). Chromium is not started automatically.
- The VNC server has no password and listens only on loopback; `GET /v1/machines/{id}/vnc` is
  the way in (spec: same route). Any process in the sandbox can drive the display.
- An MCP server, `instabox-computer-use` (open-computer-use), offers 9 tools, including `click`, `drag`,
  `get_app_state`, `list_apps`, `perform_secondary_action`, `press_key`, `scroll`, `set_value`,
  `type_text`.
- Human takeover (`{"action": "takeover"}`) makes the MCP refuse its input tools until
  `handback`, or until 30 s pass without a call from the holder. The lock is advisory, so tools
  that drive the display directly (xdotool) ignore it (spec: POST /v1/machines/{id}/desktop).
- The server enforces view-only desktop links. Viewer input was dropped. Links work
  without signing in until they expire, and `DELETE /v1/machines/{id}/desktop/stream` revokes
  all of them.
- Login shells get `NODE_OPTIONS=--require /usr/local/lib/instabox/headed-browser.cjs`, set by
  `/etc/profile.d/instabox-display.sh` (seen 2026-10-17 on `agent-browser`). Every Node process
  that `ibx exec` starts preloads that script, which is there for headed browsers on the desktop.
  For benchmarks, test runs that should match CI, or a browser that must stay headless, run with
  `env -u NODE_OPTIONS` or `NODE_OPTIONS= node ...`.

## 12. Spec drift

Checked through 2026-10-27, with items from 2026-11-06 marked by date:

- The fork route was removed on 2026-10-15. CLI fork now exists, but cannot pass the two
  credential-disabling flags required for pool recreation. Use a clean snapshot and explicit create.
- The exec description says the user is `dev`; new sandboxes use their `guestUser` (section 8).
- The desktop description says Xvfb; it is Xvnc, and Chromium is not auto-started (section 11).
- The idempotency prose says every mutating POST and DELETE needs an `Idempotency-Key`; the
  per-route parameters disagree, and they are what the server enforces
  ([api-notes.md](api-notes.md#3-idempotency)).
- The ignored-setting behavior above is historical. Since 2026-10-25 the free plan rejects
  non-1800 values. `machine_cooldown` and `max_run_disabled` were missing from Error.code
  through 2026-10-27; the spec read on 2026-11-06 lists them.
- The scope list in the prose leaves out ports, leases, files, wake and desktop; the
  per-route descriptions give their scopes.
- Some schema descriptions are split into stray keys with `null` values (for example
  `schemas.Files.properties.path`, `schemas.Connection.properties.id`). Read the text around
  them.
- The docs moved to Mintlify on 2026-11-06 and now have Markdown versions (for example
  [auto-pause.md](https://instabox.sh/docs/machines/auto-pause.md)); old paths such as
  `/docs/cli` and `/docs/sdk` redirect to `/docs/reference/*`. The legal pages still render
  only with JavaScript. `GET /v1/openapi.json` is public and remains the most complete source.
- Found on 2026-11-06: the auto-pause docs still suggest holding a lease for a silent task,
  with no free-plan caveat, while the terms forbid leases renewed from outside the box on the
  free plan. `Machine.cooldownReason` and `Error.reason` list three abuse reasons;
  errors.md and `Operation.trigger` add `abuse_proxy`.

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

Boxes created or rebuilt after 2026-11-01 also ship the instabox CLI
(`/usr/local/bin/instabox`), provider skills in `~/.claude/skills` and `~/.agents/skills`, and an
instabox MCP config, per the 2026-11-01 changelog. Whether the existing pool boxes have them was
not checked. Treat them as data; no key goes into a box for them ([trust-model.md](trust-model.md)).

The preinstalled tools in `agent-browser` 2026-10-15.4 include `claude`, `codex`, node 22, python 3.13, `uv`,
`go`, rust, `gh`, `git`, docker with compose, chromium 154, `mosh-server`. `bun` was missing then
and is in the image as of 2026-10-27. Missing tools include `tmux`, `ripgrep`, `opencode`,
`strace`, `tcpdump`, `/usr/bin/time`. Install the Debian ones
with `sudo apt-get install -y tmux ripgrep strace tcpdump time`. Packages persist across
stop/start, so the next holder of a pool sandbox sees them too. The preinstalled agent CLIs are
not signed in; leave them that way ([trust-model.md](trust-model.md)).

The shared egress IP means per-IP rate limits (for example anonymous container registry pulls)
can run out sooner than you would expect. Account limits are in
[api-notes.md](api-notes.md#7-limits): a free org normally gets one sandbox; this account's
five sandboxes are an early-account allowance that ends on 2026-12-01 00:00 UTC. After that
only one free sandbox runs at a time, the service pauses the others, and starting another
fails with `402 early_allowance_ended` (`free_limit` in ibx). The free plan also allows 3
starts a minute, wakes included; above that a retryable `429 rate_limited`.

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
not to ibx. The user's instabox CLI sends them with `instabox feedback --type bug --component
api --title ... --detail ... --expected ...`, which redacts emails, keys, tokens, home paths and
public IPv4 addresses before sending. Agents draft the report and let the user send it.
Include no keys, tokens, sandbox IDs or personal data. The idle-setting refusal on the free
plan is expected and is not a bug.

Current documentation discrepancies, found on 2026-11-06: the lease advice in the auto-pause
docs against the free-plan terms, and `abuse_proxy` missing from two enums (section 12). The public-URL
wake behavior also differs between the prose docs and spec; it needs an authorized probe.
Problems with ibx belong in its repository; security reports follow [the security policy](https://github.com/hevlyo/ibx/security/policy).
