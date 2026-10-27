# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The version is the one `ibx --version` prints.
The Claude Code plugin manifests carry no version. Plugin users get every commit.

## 0.3.0 - 2026-10-27

### Added

- Opt-in `ibx exec --stream` SSE output, uncapped and incremental. Stream errors retain partial
  output, kill the command on disconnect, and never repeat partly-run work. Buffered exec stays
  the default and the 600-second timeout still applies.
- Fail-closed Org Secret selection, application-state and guest-residue checks in claim,
  pool add and doctor. The user-only IBX_ALLOW_SECRETS permits proxy Secrets, never env Secrets.
- Claim and list output include pausesAt and cooldownUntil. Claim prefers larger run budgets.
- Private `ibx forward` localhost tunnels share SSH host pinning and one-hour token cleanup.
- Doctor shows the concrete org plan, free-hour usage and limits, run budgets, unsafe Secrets,
  public ports on unreserved boxes, and long-lived SSH tokens.
- JSON errors distinguish auth and account_blocked, with cleaned server hints and scopes.
- Dated platform research and decisions in docs/research/2026-10-27-instabox-changes.md.

### Changed

- Keepalive skips known or raced max-run cooldowns successfully while renewing other boxes.
  It preserves --all semantics. Leases do not prevent the free 480-minute max-run pause.
- User exec never retries host_unavailable, even when retryable. Cooldown and quota refusals
  remain safe to wait out. New and older credential codes are recognized.
- Official streaming file routes replace base64 exec for put/get. Put accepts up to 5 GiB and
  verifies SHA-256; get stages output with IBX_GET_MAX, default 2G. Only route-not-found on an
  older server enables the previous 750 KB transport, with a warning. Upload follows symlinks.
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
  budget and verify leases only for their own boxes.

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
