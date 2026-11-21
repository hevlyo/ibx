# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The version is the one `ibx --version` prints.
Plugin manifests carry the same version as `ibx --version`.

## 0.4.0 - 2026-11-21

Adapts ibx to instabox's terms of 2026-11-06 and the free-plan change of 2026-12-01, and to
the API as read on 2026-11-21. Research and decisions are in
docs/research/2026-11-06-instabox-changes.md and docs/research/2026-11-21-instabox-changes.md.

### Added

- `402 early_allowance_ended` is the new error code `free_limit`, no longer `account_blocked`:
  the free plan runs only `limits.freeSandboxes` boxes at a time. The refusal applies only to
  free boxes: after one, claim skips the other free boxes that are not running (and any the
  server marks `Machine.earlyAllowanceEnded`), still tries paid ones, and exits 75 when none
  is left. Commands that wake a box fail without retry; keepalive skips the box. Doctor shows
  `earlyAllowanceEnded` and `freeSandboxes`.
- Abuse locks (`cooldownReason` starting with `abuse_`, or `reason` on a wake's
  `409 machine_cooldown`) fail at once with error code `abuse_lock`, printing the lock's
  explanation and appeal, instead of waiting out a lock of up to 24 hours. This covers exec,
  put, get, `ibx run` and `ibx job`, and `exec --json` keeps the code whatever the server's
  text says. Claim skips such boxes, ls shows an abuse lock, keepalive prints `abuse lock until
  TIME, skipped`, `ls --json` rows carry `cooldownReason`, and doctor prints the lock's `what`,
  `explanation` and `appeal`.
- Plain `ibx exec` prints one warning line on stderr when the server reports `oomKilled`,
  naming the process and PID when given; nothing when it is false or absent.
- `ls --json` rows carry `free` (`Machine.free`: a free-plan box).
- `500 restore_failed` (a resume could not restore the box's memory; its processes are lost and
  it is stopped with its files kept). When ibx itself starts, resumes or wakes the box (claim,
  get, ssh, run, job, exec after `machine_not_running`), it warns and starts the box from its
  disks once; a wake that comes back as `409 machine_not_running` with the box's `lastError`
  restore_failed counts the same. An exec (buffered or `--stream`), put, get, `ibx run` or
  `ibx job` whose own request got it says it did not run, never "may or may not have run"; the
  next command starts the box.
- `ibx run` and `ibx job` bring a stopped or paused box up before their single exec, as exec,
  put and get do (run still sends its start once). A `409 machine_not_running` on that exec
  says nothing started.
- `403 account_disabled` is `account_blocked`: claim stops at the first refusal instead of
  trying every box. Exec says it did not run for every account-wide refusal (`account_blocked`,
  `free_limit`, `running_limit`), in plain output as in `--json`.
- New error code `running_limit`: a `429 concurrency_limit` that is not retryable (the plan
  allows no more sandboxes running at once). It is account-wide: claim stops at the first
  refusal and exits 75; exec, put, get, run and job say nothing started (125); keepalive skips
  the box. A retryable `concurrency_limit` (too many execs at once) on exec and file transfers
  is handled like `quota_exceeded`.
- curl no longer repeats a start, resume, wake or lease PUT after a 429 or 500 reply (each
  repeat counted against `limits.startsPerMinute`, and a repeated wake hid a
  `500 restore_failed`); ibx repeats those requests only after a lost connection or a
  transient gateway answer (408, 502, 503, 504, 522, 524), at most three times.

### Changed

- Free boxes (`Machine.free`) get no activity lease. The terms of 2026-11-06, §2(e), forbid
  "activity leases renewed from outside the Sandbox" that keep a free box from pausing.
  `ibx keepalive`, with or without `--all`, prints a free-plan skip line for such a box and
  exits 0; `ibx claim` sets no lease there (`leaseUntil: null`, no lease warning). Paid boxes
  keep the lease. Release still deletes it. `tests/live.sh` expects the skip line and no
  lease on free boxes, and skips its two-box run when the free plan can run only one free box
  at a time.
- `ibx doctor` fails when a keepalive timer, launchd agent or cron entry is installed and any
  pool box is free, and names how to remove it. Without a timer it no longer recommends one
  for free boxes.
- `install.sh --keepalive` and `--keepalive=all` still install the timer, and warn that it is
  for paid plans only and against the free plan's terms.
- A start, resume or wake refused with `429 rate_limited` waits `retryAfterSeconds` (or
  `Retry-After`, default 20 s) within the existing budget, then retries. Exec itself is never
  retried.
- Every exec ibx composes for itself (job polls, status and kill, sweeps, release and claim
  checks, `~/.ibx` maintenance, directory archive helpers, the single-file put and get
  fallbacks) sends `noHistory`. `ibx run` and `ibx exec --tail N` send `historyCommand` set to
  the user's command, so the box's exec history shows what the user ran. A plain `ibx exec`
  sends neither.
- An exec, put or get refused with `409 operation_conflict` (nothing started: the 45-second
  wake hold ran out, or another operation such as a snapshot or resize is active) waits for the
  operation the error names, then until the box runs, and sends the request again, at most
  three times, instead of failing with "may or may not have run". `ibx run` and `ibx job` fail
  and say nothing started.
- The fresh-boot warning (`runtime.processesPreserved: false`) also follows a start or resume
  that ibx waited for but did not send: the server's wake named by an exec's or a file
  transfer's `409 operation_conflict`, ibx's own wake that outlived the 45-second hold, and a
  resume already running when ibx looked.
- Free runs start with a 120-minute max-run limit that use extends, up to 480 minutes (the
  instabox rule since mid-November; leases and wakes do not count). On a free box, claim's
  "under 60 minutes left" warning says use extends the run, `ls` shows `pausesAt` as "TIME or
  later", and doctor's run budget calls it the current limit. Docs no longer say "480 by
  default, dynamic runtime when enabled".
- The `free_limit` message says a released free box keeps its slot until it pauses after 30
  idle minutes. Doctor's network hint and the skill point to https://status.instabox.sh.
- Docs: trust-model.md adds Latitude.sh bare-metal hosting in the United States, that the SOC 2
  Type II audit does not cover InstaBox yet, and the ban on health data without a BAA. The
  skill lists the abuse workloads the terms ban, including brute force searches for crypto
  keys, seeds or vanity addresses and resource farming (stopped without notice since
  2026-11-16), says §2(e) is unchanged through that revision, and tells agents to stream or
  detach a quiet command longer than about 4 minutes (a quiet buffered exec can be cut at about
  270 s).
- Docs: the README, the skill, keepalive.md, api-notes.md, field-notes.md, trust-model.md and
  recipes.md describe the free plan's idle definition, wake on use, dynamic runtime, the
  escalating max-run cooldowns, abuse locks, the 2026-12-01 one-box limit, server-side exec
  history, declared monitoring and the preinstalled instabox toolkit. Agents are told never to
  keep a free box awake, never to give a box an instabox key, and never to ask the user to
  approve an `instabox login --agent` code from a box. Links to the CLI and SDK docs point at
  `/docs/reference/*`.

### Fixed

Also includes the fixes once listed as 0.3.1 (2026-10-29), which was never tagged:

- `ibx run` still starts the job in a new session when `setsid` is not installed.
  Debian sandboxes keep `setsid -f`. Otherwise `python3` calls `setsid(2)`, which is
  what the offline mock needs on macOS, where that script runs on the CI machine.
  If both are missing, the start fails with the setsid message.
- `ibx get` of a directory reads each member's name and type from the tar headers
  before extracting. `tar -t` can print a rewritten name and exit 0, so a `..` member
  was copied. Absolute names, a `..` component, and anything other than a regular
  file or directory are refused. The check uses python3.
- The offline check for temporary files during a slow exec waits for that exec.
  It was counting an earlier exec in the same group, so a busy runner looked too soon.
- Directory get writes its archive check to a program file and refuses the copy
  unless that check finishes. Feeding the check on standard input can be skipped,
  and the copy then succeeds.

## 0.3.0 - 2026-10-28

### Added

- Ownership-aware commands refuse another agent's live reservation with `held_by_other`;
  unreserved work warns to claim first, renew requires a live owned reservation (`not_held`),
  and release stays idempotent. An unreadable date is a live hold for that same agent.
  `release` and `renew` re-check the holder on a fresh read before writing; there is still no
  compare-and-swap. The user-only IBX_ALLOW_ANY bypasses pool and holder checks.
- `ls --mine [--json]` finds your live pool reservations and reports agent identity/source.
  `release --mine [--json]` releases all yours, reports individual failures and exits 125 on
  partial failure. A signal stops further boxes and names any box already released. It refuses
  a shared per-host fallback with `ambiguous_identity`.
- Human claim output hints on stderr to use the literal name, release it and find it with
  `ls --mine`; stdout remains only the box name.

- Opt-in `ibx exec --stream` SSE output, uncapped and incremental. Stream errors retain partial
  output, kill the command on disconnect, and never repeat partly-run work. Buffered exec stays
  the default and the 600-second timeout still applies.
- Fail-closed Org Secret selection, application-state and guest-residue checks in claim,
  pool add and doctor. The user-only IBX_ALLOW_SECRETS permits proxy Secrets selected by name
  and scoped to named hosts, never the `all` selection or env Secrets.
- Claim and list output include pausesAt and cooldownUntil. Claim prefers larger run budgets.
- Private `ibx forward` localhost tunnels share SSH host pinning and one-hour token cleanup.
- Doctor shows the concrete org plan, free-hour usage and limits, run budgets, unsafe Secrets,
  public ports on unreserved boxes, and long-lived SSH tokens.
- JSON errors distinguish auth and account_blocked, with cleaned server hints and scopes.
- `ls --json` rows include the API's `runtime` (`ready`, `processesPreserved`), so agents can
  check whether processes survived a wake. Every doctor FAIL line is followed by its next step,
  and a failed audit shows the API's reason, even after curl diagnostics, or cleaned raw text
  for a gateway error. A sandbox list doctor cannot read is reported as
  such, never as an empty pool.
- README tables of exit codes and environment variables, updated for 0.3.0.
- Dated platform research and decisions in docs/research/2026-10-27-instabox-changes.md.
- `ibx run` and `ibx job` for named detached jobs. A start is never retried; if it may have
  run, one read-only status check says whether it started. `release` stops running ibx jobs.
  `claim` stops leftover jobs from a previous holder and clears `~/.ibx`.
- `ibx exec --json` prints one object with `ran` of `yes`, `no` or `partial`. `--tail N` keeps
  the full merged output on the box and prints the last lines. `--json` and `--stream` cannot
  be combined.
- `ibx put` copies a directory (git tracked files, or `find` outside a work tree), refuses
  credential-looking paths and symlinks that resolve outside it, and extracts through the file
  API. `ibx get` of a remote directory checks the archive before extracting it.
- `release` warns about guest processes and listeners still running after the job sweep.
  `--no-check` skips that report. An exec failure is a warning, not a failed release.
- `doctor` checks GitHub for a newer release (cached 24 hours, `IBX_UPDATE_CHECK=0` disables it)
  and warns when more than one ibx skill, or a different `ibx` on `PATH`, is visible.

### Changed

- Keepalive skips known or raced max-run cooldowns successfully while renewing other boxes.
  It preserves --all semantics. Leases do not prevent the free 480-minute max-run pause.
  `409 max_run_disabled` is a skip too, and so is a billing block (402, from the wake of an
  idle-paused box): one line for that box, the other boxes still get their leases, and on its
  own it leaves the status at 0, so the timer unit's Restart=on-failure does not repeat it. A
  cooldown ibx cannot read is left to the server.
- Dates from the API are read as RFC 3339 with any offset. A date ibx cannot read is unknown,
  never a reason to drop a row: claim skips a box whose cooldown it cannot read, ls and claim
  report an unknown pause as null, doctor still lists such SSH tokens.
- Claim exits 125 (an API failure), not 75, when it cannot inspect a box's Org Secrets; pool
  add and doctor tell "could not inspect" apart from "Secrets are selected".
- IBX_ALLOW_SECRETS accepts only proxy Secrets selected by name and scoped to named hosts,
  in claim and pool add; `all` remains refused because it includes future Secrets, even when
  today's effective items are empty or scoped. An unknown delivery kind, `*` or omitted or empty hosts (every host) fail closed. Doctor
  fails for such a proxy Org Secret, and accepts a 404 from the org Secrets route when usage
  says the server has no Org Secrets.
- `ibx.claim.start` holds the server's time of the claim (the `updatedAt` of the claim's PATCH
  reply, when the PATCH moved it), so release's port cleanup does not depend on the local clock.
- An interrupt says whether the remote command had started or had finished. In `--stream`
  mode only a 4xx reply with an error envelope means the command did not run. Every 503,
  including retryable host_unavailable, and other replies without a stream (2xx cut off, 500,
  a gateway's page) say it may have run: an API restart can kill partly-run work and return 503.
- User exec never retries host_unavailable, even when retryable. Cooldown and quota refusals
  remain safe to wait out. New and older credential codes are recognized.
- Official streaming file routes replace base64 exec for put/get. Put accepts up to 5 GiB and
  verifies SHA-256; get stages output with IBX_GET_MAX, default 2G. Only route-not-found on an
  older server enables the previous 750 KB transport, with a warning. Upload follows symlinks.
  File names reach curl literally (`-g`, `./` prefix): `{a,b}` and `[...]` are not expanded,
  and a file named `-` is a file, not stdin. Put verifies that its physical path names the
  same file, refusing paths that lose trailing newlines. The helper and installer ignore
  exported CDPATH. Put refuses `/dev/stdin`, fd names and physical paths under `/proc`,
  `/sys` or `/dev`, even with --force, and hands curl the file's physical path.
- Release removes all ports created during the reservation, whatever their names, using stable
  ibx.claim.start. Renew changes only the activity timestamp. Older non-ibx ports remain warned.
- Billing blocks stop claim after the first affected candidate. Interrupts promptly close exec
  connections; the message explains partly-run work and surviving setsid children.
- Exec reports invalidUtf8, actual signals and diskWarning without changing the remote status.
- Key-bearing shell variables explicitly clear inherited export attributes before starting any
  child process, including streaming curl.
- Vault file residue is unsafe; an uninspectable Vault stays refused with clearer 403 advice.
- Docs cover independent Vault and Org Secrets, 32 shared concurrent requests, eight-hour
  checkpoints, plan-specific idle settings, current CLI/SDK features and org key boundaries.
  The obsolete ignored-idle-setting bug reports are removed. Public-URL wake behavior remains
  explicitly unverified because the prose docs and spec conflict.
- Offline mock and live-test definitions track the current API. Live tests select enough run
  budget, verify leases for their own boxes and check keepalive's exit status. The mock answers
  exec on an idle-paused box with `409 machine_not_running`, as the spec says, so the wake path
  ibx takes then stays tested.

## 0.2.0 - 2026-10-17

### Added

- An atomic mkdir lock on every OS. Processes sharing a safe, user-owned state directory
  serialize reservation writes and cap checks. A reaper guard protects stale-lock recovery,
  and owner records include the host and PID namespace. Stale locks are reclaimed by atomic rename;
  unsafe or unavailable state directories warn and leave the settle checks in place.
- `IBX_MAX_CLAIMS`, default 3, limits live pool reservations per agent; 0 disables the cap.
- Per-session default agent names in Claude Code (`CLAUDE_CODE_SESSION_ID`) and Codex
  (`CODEX_THREAD_ID`), with the previous per-host name as fallback.
- `--json` anywhere after `claim`, `renew` and `release`, including warnings and structured
  errors. `interrupted` errors exit 130 for SIGINT or 143 for SIGTERM, and name any sandbox
  already kept by the claim. Other error codes are `no_free_sandbox`, `claim_limit`, `lock_busy`
  and `failed`. `lock_busy` exits 75 after waiting up to five minutes for a usable local lock.
  `failed` usually exits 125, but an unexpected command failure keeps its own status. It can
  include `held` when a claim already kept a sandbox; the caller must release that sandbox.
- The installer follows `CLAUDE_CONFIG_DIR` for Claude Code skills. `doctor` warns when that
  config directory cannot see ibx through a skill or installed plugin.
- Exit 75 lists holders, reservation times and purposes when no sandbox is free, and the
  agent's reservations when its cap is reached.
- `doctor` reports the agent name, its source and cap, and warns about an unwritable state
  directory.
- Per-command `-h` and `--help` print usage before API access.
- A field note describes the sandbox's `NODE_OPTIONS` preload.

### Changed

- The skill tells agents to use a sandbox on their own, without being asked, for unvetted code,
  builds, tests, benchmarks and Docker of public code, headless browsers and video rendering,
  large public datasets, and long jobs. Public code is explicitly fine; private code still
  needs the user's request. Recreate-the-sandbox advice is limited to code with a reason for
  distrust.
- README rewritten.
- Claims wait up to five minutes for a busy local lock, then exit 75 with `lock_busy` and make
  no reservation. Only unusable state directories fall back to the settle checks. Signals
  during lock-directory creation clean up empty directories, and dead guard owners are
  reclaimed immediately when host and PID namespace match.
- Diagnostic writes tolerate a closed stderr. Exec retry sleeps are reaped during cleanup.
- Remote `exec` arguments stay untouched after `--` or the remote command, and remote `ssh`
  arguments after the box. Claim purposes starting with `-` are rejected.
- Config roots in `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `XDG_CONFIG_HOME` expand a leading
  tilde, require an absolute path and strip trailing slashes. Installs deduplicate shared roots;
  uninstall also checks the default Claude root when a custom root is set.
- Claim waits respond promptly to SIGINT and SIGTERM. JSON output is emitted once at cleanup,
  including dependency and temporary-directory failures. Failed public-port listings return
  `publicPorts: null` with a warning.
- `claim` rechecks that a sandbox is free in the same GET used to build its reservation PATCH.
- A claim's purpose must be one quoted argument; extra arguments are now rejected.
- The default agent name is now per session, so reservations from 0.1.0 show a different holder
  name.

## 0.1.0 - 2026-10-15

First public release. instabox is in beta; everything below was checked against its API on
2026-10-15.

### Added

- `ibx`, a single bash script (bash 4.4+, curl 7.71+, jq 1.6+, ssh) that talks to the instabox
  API directly. On macOS it re-runs itself with Homebrew's bash when the system bash 3.2 starts
  it.
  - `claim`, `renew`, `release` and `ls [--all] [--json]` for a shared pool of sandboxes. A
    reservation is sandbox metadata (`ibx.claim.by`, `ibx.claim.at`, `ibx.claim.purpose`,
    `ibx.claim.token`). `claim` waits out concurrent writers and checks its token twice before
    it hands a sandbox out; its API calls during the reservation are capped at 8 s, curl's
    retries included. A reservation older than `IBX_STALE_SECS` (24 h) counts as abandoned.
    Exit 75 when no sandbox is free. `ls --json` gives one object per sandbox, with a boolean
    `vault`.
  - `claim` sets the `ibx-keepalive` activity lease (1 hour) on the sandbox it hands out, and
    `release` deletes it.
  - `exec`, `put`, `get` and `ssh` to work in a sandbox. `claim`, `ssh`, and an `exec` that gets
    `409 machine_not_running` wake an idle-paused sandbox, resume a paused one or start a
    stopped one, and warn when it came back from a fresh boot. When the server itself wakes an
    idle-paused sandbox for an exec, ibx cannot tell, and the skill says so.
  - `exec -t SECS` (1-600, default 300) and `exec -i`, which sends local stdin (up to 1 MiB) to
    the command; both go before `--`, in any order. An exec is never retried once the command
    may have started. It is retried only on errors that mean it did not run: the account's exec
    quota (up to 10 minutes, every 5-9 s, then "exec did not run: 4 other execs kept the
    account busy for 10 minutes"), a sandbox that is not running (up to 3 starts), and host
    errors the API marks retryable. `api_key_expired` and `api_key_revoked` count as rejected.
  - `put [--force] <box> <local> <remote>` and `get <box> <remote> [local]` copy files up to
    750 KB, text or binary. A leading `~/` in the remote path is stripped.
  - `ssh` uses a 1-hour token kept out of argv and error output, in a 0600 ssh config, and
    revoked on exit, with `revokedAt` confirmed; it pins the host certificate authority the API
    returns.
  - `port` and `unport` publish ports under `ibx:` names, with a warning that the URL has no
    authentication. `release` unpublishes them and refuses to finish while one is still
    public. A 404 on unpublishing counts as already unpublished, so `unport` of a port that is
    not published succeeds.
  - `pool add [--allow-vault]` and `pool rm` choose which sandboxes agents may claim
    (`ibx.pool` metadata).
  - `keepalive [--all]` renews the activity lease on reserved pool sandboxes (or every pool
    sandbox), because the server ignores the idle-pause setting today. It exits 1 when a lease
    could not be renewed.
  - `doctor` checks dependencies, the API key, API access, the pool, the Vault of pool
    sandboxes and the keepalive timer.
  - Exit codes: the remote command's for `exec` and `ssh`; 124 exec timed out; 75 no free
    sandbox; 125 ibx failed; 255 ssh could not connect; 143 when the remote command was killed
    by SIGTERM, and also when ibx itself gets SIGTERM, which it reports as "interrupted by
    SIGTERM: a remote command it started may still be running".
- Safety measures in the helper:
  - The API key comes from `INSTABOX_API_KEY` or a file (`IBX_KEY_FILE`, default
    `${XDG_CONFIG_HOME:-~/.config}/instabox/api-key`; ibx warns when others can read it). It
    stays in an unexported shell variable, is removed from the environment of every program
    ibx starts, and reaches curl through a pipe (`-H @-`): never in argv or on disk. Every curl
    runs with `-q`, so `~/.curlrc` is ignored. All temporary files are made under `umask 077`.
  - `INSTABOX_API_URL` must be `https://api.instabox.sh` unless `IBX_ALLOW_CUSTOM_API=1`;
    plain http is accepted only for `127.0.0.1` and `localhost` (tests).
  - Agent commands (`exec`, `put`, `get`, `ssh`, `port`, `unport`, `renew`, `release`) work only
    on pool sandboxes unless `IBX_ALLOW_ANY=1` ("is not in the pool", exit 125).
  - Vault: `claim` skips pool sandboxes that the Vault writes one or more items into, unless
    `IBX_ALLOW_VAULT=1`; `pool add` refuses them unless `--allow-vault`, and warns when the
    Vault is on but empty; `doctor` reports a FAIL for the first and a warning for the second.
  - `put` refuses files that look like credentials unless `--force`: `.env`, `.env.*`,
    `*.env`, key stores and private keys (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`,
    `*.keystore`, `*.kdbx`, `id_rsa*`, `id_dsa*`, `id_ecdsa*`, `id_ed25519*`), `*.tfstate`,
    `*.tfvars`, `.netrc`, `.npmrc`, `.pypirc`, `.pgpass`, `.git-credentials`, `credentials*`,
    `*secret*`, `*token*`, `api-key`, `*.ovpn`, `.docker/config.json`, and anything under
    `.ssh/`, `.aws/`, `.gnupg/`, `.kube/`, `gcloud/`, `.claude/`, `.codex/` or `instabox/`.
    Symlinks are followed, so a link with a harmless name to a credential is refused too.
  - The default agent name in reservations is pseudonymous, `agent-<checksum of user@host>`.
    `IBX_AGENT_NAME` replaces it, limited to `A-Za-z0-9@._:-` and 64 characters. Control
    characters are removed from the claim purpose.
  - Sandbox IDs from the API are validated, and names, purposes and URLs from the API are
    printed without control characters.
- The agent skill `skills/ibx/SKILL.md`, with references on the trust model, the API, observed
  behaviour, the keepalive timer and recipes. It covers tool timeouts (`-t` + 120 s; `-t` at
  most 480 where a tool call stops at 10 minutes), detached long jobs polled with separate
  calls, the Vault check before running untrusted code, the credentials guard and
  `git archive`, the privacy of the claim purpose, and asking the user to recreate a sandbox
  after untrusted code ran.
- `install.sh`: links or copies the skill into Claude Code, `~/.agents/skills`, Codex or
  OpenCode, puts `ibx` on PATH, and installs the keepalive timer (systemd user timer on Linux,
  launchd agent on macOS). Idempotent, with `--dry-run` and `--uninstall`; it never replaces a
  directory or file it did not create.
- A Claude Code plugin marketplace (`/plugin marketplace add hevlyo/ibx`).
- `tests/offline.sh`: runs the helper and `install.sh` against a local mock of the API
  (`tests/mock_api.py`) in a scratch HOME, with no account and no network. With
  `MOCK_EXEC=real` the mock also runs the commands, so `put` and `get` are tested.
- `tests/live.sh`: opt-in (`IBX_LIVE=1`) checks against a real account. It claims two pool
  sandboxes, runs commands, copies files, opens SSH sessions, publishes a port for a few
  seconds, runs `ibx keepalive`, and releases both, also after a failure.
- CI (GitHub Actions): `bash -n`, shellcheck (a pinned, checksum-verified release) and a syntax
  check of the mock; then the offline suite on Ubuntu (with `MOCK_EXEC=real`) and on macOS
  (Homebrew bash), plus checks that the system bash 3.2 is refused with a clear message or
  re-runs ibx with Homebrew's bash.
- `SECURITY.md`: how to report a vulnerability privately, and what is in scope.
