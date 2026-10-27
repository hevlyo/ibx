# ibx

Borrow a disposable [instabox.sh](https://instabox.sh) sandbox from a shared pool, use it, and
give it back clean. ibx is an MIT agent skill and one bash script. It tells agents to move
unvetted tools, public builds and tests, Docker, headless browsers, video rendering, large
public datasets and long jobs off your computer on their own. Secrets and logged-in sessions
stay local. Private code needs your explicit request.

```sh
ibx claim "run public project tests"
ibx exec box-2 -t 480 -- 'git clone --depth 1 https://github.com/expressjs/express && cd express && npm ci && npm test'
ibx release box-2
```

Use the literal box name returned by claim in later calls. The example name above is only an
example. Other holders may be using it.

ibx is independent of InsForge. The official CLI and SDK administer your org and its
sandboxes. ibx adds shared reservations, a per-agent cap, activity leases, credential guards
and exec retry rules for coding agents. It does not create or delete boxes, keys or snapshots.

## Install

> [!NOTE]
> ibx needs bash 4.4+, curl 7.71+ and jq 1.6+, plus ssh for `ibx ssh`. On macOS, run
> `brew install bash jq`. The system bash 3.2 is too old, and ibx re-runs itself with Homebrew's
> bash when it finds it. You also need an instabox.sh account with a few sandboxes and an API
> key, which [Setup](#setup) walks through.

Pick one way per agent. Each installs the same skill, named `ibx`.

### Any agent, with the skills CLI

```sh
npx skills add hevlyo/ibx                              # asks where to install
npx skills add hevlyo/ibx -g -a claude-code -a codex   # global, for the agents you name
```

The agent runs the script from the skill's directory as `bash <skill-dir>/scripts/ibx`. To have
`ibx` on your own PATH as well, clone the repository and run `./install.sh --agents none`.

### Claude Code plugin

```text
/plugin marketplace add hevlyo/ibx
/plugin install ibx@ibx
```

The skill shows up as `/ibx:ibx`. The plugin manifests carry no version number, so plugin
updates follow the repository's commits. Do not also link the skill into `~/.claude/skills`, or
Claude Code loads it twice.

> [!TIP]
> Claude Code started with `CLAUDE_CONFIG_DIR` reads skills from `$CLAUDE_CONFIG_DIR/skills`, not
> `~/.claude/skills`. Harnesses that run one config dir per account do this, and then the agent
> never sees the skill and never reaches for a sandbox. `ibx doctor` warns about it, and
> install.sh follows the variable, so run it once per config dir:
> `CLAUDE_CONFIG_DIR=~/.claude-work ./install.sh --agents claude --no-bin`.

### From a clone, with install.sh

```sh
git clone https://github.com/hevlyo/ibx
cd ibx
./install.sh --dry-run    # print every change, touch nothing
./install.sh              # skill into ~/.claude/skills and ~/.agents/skills, ibx into ~/.local/bin
```

install.sh links the skill, so `git pull` updates it. install.sh needs no sudo and no network,
and running it again changes nothing that is already in place. The only things it replaces are
its own files and symlinks that point at an ibx skill or helper (or at nothing). If anything else
is in the way, it stops before changing anything and names it.

| Option | Effect |
|---|---|
| `--agents LIST` | Skills roots, comma-separated. `claude` is `$CLAUDE_CONFIG_DIR/skills` (default `~/.claude/skills`), `agents` is `~/.agents/skills` (read by Codex and other agents), `codex` is `$CODEX_HOME/skills` (default `~/.codex/skills`), `opencode` is `${XDG_CONFIG_HOME:-~/.config}/opencode/skills`. `all` is every root above, and `none` installs no skill (useful with the bin link alone). Default `claude,agents`. |
| `--copy` | Copy the skill instead of linking it. Run it again after a `git pull`. |
| `--bin DIR`, `--no-bin` | Where the `ibx` command is linked (default `~/.local/bin`), or not at all. |
| `--keepalive`, `--keepalive=all` | Install the keepalive timer (step 3 of [Setup](#setup)). |
| `--uninstall` | Remove what install.sh installed. |
| `--dry-run` | Print every change, including the timer files, and change nothing. |

### Next to the official instabox skills

`npx instabox@latest` installs InsForge's skills (`instabox`, `instabox-basic-setup`,
`instabox-move-repo`, `instabox-snapshots`) into `~/.claude/skills` and `~/.agents/skills`. ibx
keeps to its own skill directory (`ibx`), metadata keys (`ibx.*`), lease ID (`ibx-keepalive`)
and port names (`ibx:...`), and it does not need the instabox CLI. Install both if you like.

## Setup

1. Create an org-scoped key with `machines:write`, which includes `machines:read`, and an
   expiry of 30-90 days. Leave out delete and image scopes. With the official CLI signed in,
   create the key, then paste only the printed secret into a private file with an editor.

   ```sh
   umask 077
   mkdir -p ~/.config/instabox
   instabox keys create --name ibx-agents --scope machines:write --expires-in-days 90
   ${EDITOR:-vi} ~/.config/instabox/api-key
   chmod 600 ~/.config/instabox/api-key
   ```

   The CLI prints the new secret once, among other output. Paste only the `ibk_...` secret
   into the file, and keep it out of command arguments, shell history and logs. Neither ibx
   nor the key can read its expiry date; note it yourself. Expiry stops keepalive.
   `IBX_KEY_FILE` selects another file. `INSTABOX_API_KEY` also works, but exported variables
   reach every child your shell starts. ibx removes it before launching its own children.

2. Keep the pool in an org with no Org Secrets and create boxes with both credential stores
   disabled. New free orgs normally get one box; some older orgs have a higher limit. Read
   `ibx doctor` before creating more.

   ```sh
   instabox create --name box-1 --no-vault --secrets none
   ibx pool add box-1
   ibx doctor
   ```

   Never run `instabox-basic-setup` or the setup of `npx instabox` in the pool org. Dashboard
   boxes select all current and future proxy Secrets by default. Turning off the Vault does
   not turn off Org Secrets. Clear both proxy and env selections when repairing an old box.
   Claim fails closed when it cannot inspect selections, application state or residue.

3. If you want automatic idle protection, install the optional timer yourself.

   ```sh
   ./install.sh --keepalive
   ```

   ibx never changes your installed timer on its own. See [keepalive](skills/ibx/references/keepalive.md).

## Commands

| Command | Behavior |
|---|---|
| `ibx claim [--json] "purpose"` | Reserve a free box, at most 3 live claims per agent by default |
| `ibx ls [--all] [--json]` | State, holder, next pause and cooldown; `--json` adds Vault/Secrets risk and `runtime` |
| `ibx exec BOX [--stream] [-t SECS] [-i] -- CMD...` | Run up to 600 seconds; default 300, text stdin up to 1 MiB |
| `ibx put [--force] BOX LOCAL REMOTE` | Atomic upload up to 5 GiB, credential guard and SHA-256 check |
| `ibx get BOX REMOTE [LOCAL]` | Staged binary download, default cap 2G through `IBX_GET_MAX` |
| `ibx ssh BOX [--] [CMD...]` | Stream over SSH with a 1-hour token revoked on exit |
| `ibx forward BOX [LOCAL:]REMOTE...` | Private localhost tunnel, held in the foreground |
| `ibx port BOX PORT [NAME]` | Public unauthenticated URL, only when the user needs sharing |
| `ibx unport BOX PORT` | Unpublish a port |
| `ibx renew [--json] BOX` | Renew reservation age without changing its start time |
| `ibx release [--json] BOX` | Remove ibx ports and ports created during the reservation, drop lease and claim |
| `ibx keepalive [--all]` | Renew reserved boxes, or every pool box with --all; cooldown, disabled max-run and billing refusals are skips |
| `ibx pool add|rm BOX...` | User chooses pool membership |
| `ibx doctor` | Dependencies, key, org plan and usage, run budgets, Secrets, ports and token audit; each FAIL names a next step |

Relative file paths live under `/data/home`; absolute paths pass through. Quote a leading
`~/`. Upload follows a symlink at the destination. An older server with no file routes uses
the previous exec transport, warns, and keeps its 750 KB limit. A file-not-found response
never triggers fallback. Use `git archive` or tar through SSH for directories after checking
tracked files for secrets; never transfer `.git`, local config or credentials.

For a private preview, run `ibx forward BOX 18080:8080` and visit `http://127.0.0.1:18080`.
Forwarding binds only to loopback. Its token lasts one hour, and its open-tunnel behavior after
expiry is unverified. The tunnel relies on the reservation's activity lease.

## Reservations and parallel work

Hold one box per active parallel job and release each when its part is done. `IBX_MAX_CLAIMS`
defaults to 3; 0 disables it, for the user only. Agents must never raise it or change
`IBX_AGENT_NAME` or `IBX_STATE_DIR` to evade it. The default name hashes user, host and a known
session ID (`CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID`), with a per-host fallback.

An atomic mkdir lock serializes writes and cap checks for one user sharing a state directory.
A usable busy lock waits up to five minutes, then returns `lock_busy` without a write. An
unusable directory warns and leaves the settle wait and double token check in place. Other
computers still depend on those checks. Metadata reservations are advisory and provide no
access boundary against other API clients.

SDK `setMetadata` and a raw metadata PATCH replace the whole metadata map. They can silently
drop `ibx.pool` and `ibx.claim.*`. Other tools must preserve those keys. Renew updates
`ibx.claim.at`; `ibx.claim.start` stays fixed for port cleanup. It holds the server's time of
the claim (the `updatedAt` the claim's PATCH returned), so a local clock that is off does not
matter; ibx uses its own clock only when that PATCH left `updatedAt` unchanged.

## Lifecycle and long jobs

The free plan fixes idle pause at 1800 seconds. Other values return 403 `permission_denied`.
Paid plans allow 300-1800 in steps of 300, or 0 with always-on; the 120-86400 range is for
admin-granted manual lifecycle accounts. ibx changes none of these settings.

Claim sets a one-hour activity lease. A timer renews it every 15 minutes. Leases prevent idle
pauses, but free boxes still pause after 480 continuous minutes. All wake paths refuse until
`cooldownUntil`; the spec default is 10 minutes, and observed cooldowns were 5-17 minutes.
Plan checkpoints near eight hours; a refused poll is not a dead job. After a wake, check the
job PID and `runtime.processesPreserved` in `ibx ls --json`. A fresh boot loses processes.

Use detached jobs for work longer than a tool call. Redirect every stream and record status.

```sh
ibx exec BOX -- 'mkdir -p jobs/build; cd jobs/build; setsid -f bash -c "echo \$\$ >pid; make >log 2>&1; echo \$? >rc" </dev/null >/dev/null 2>&1'
ibx exec BOX -- 'tail -n 30 jobs/build/log; cat jobs/build/rc 2>/dev/null'
```

Exec returns after the parent exits; background writers can lose later output or get broken
pipes. Closing an exec connection kills its process group, even when the command partly ran.
Children started in a new session with `setsid` can survive. A dropped SSH command may still
be running. Never retry user exec after `host_unavailable`, even if the API says retryable.

Opt into `ibx exec BOX --stream -- CMD` for SSE output as it arrives, without the buffered
1 MiB cap. It keeps partial output after an error, but a dropped stream kills the command.
A stream error never retries partly-run work. The same 600-second limit applies; use detached
jobs for longer work. Buffered exec remains the default.

The shared limit is 32 concurrent requests per user, including files, desktop, forwarding and
Secret refresh. Buffered exec caps stdout and stderr at 1 MiB each. Invalid UTF-8 is replaced
and reported, not preserved as binary. Use get for binary output.

With `keepalive --all`, free boxes cycle through eight hours running, cooldown, then up to 15
minutes before the timer wakes them. Free hours may have an org cap; 0 means no cap. An
included-usage suspension occurred on 2026-10-18. A paid 4 vCPU/8 GiB box costs about $0.034
per running hour, plus storage (about $0.0022 an hour for 20 GiB, also while paused); the Pro
plan adds a $20 monthly fee that includes $20 of usage. The user decides the timer mode.

## Safety and cleanup

The provider controls each VM. Anyone with the org's `machines:write` key can execute on every
box in that org and become root through sudo. A key cannot be restricted to one box. Public
code is fine; private code requires the user's request. Secrets, logged-in browser profiles,
SSH keys, cloud sessions and third-party personal data stay off the pool.

Vault delivery and Org Secrets are separate. Proxy Secrets can inject credentials against
their allowed hosts; env Secrets expose values in the VM. Wildcard hosts are unsafe, and no
hosts means every host. Claim, pool add and doctor inspect selections and residue, failing
closed. `IBX_ALLOW_SECRETS` is a user-only override for proxy Secrets scoped to named hosts;
wildcard and env Secrets remain refused. All `IBX_ALLOW_*` variables
are user decisions. See the [trust model](skills/ibx/references/trust-model.md).

A preinstalled port agent (`instabox-port`, with a guest-readable credential) was found on
box-5 on 2026-10-27, so guest code there can publish ports; assume other boxes may have it.
Release removes every port created during the reservation, whatever its name, plus all
ibx-prefixed ports. Older non-ibx ports remain with a warning. Stop your processes before
release; a leftover process can publish again. The prose docs say public visits wake an
idle-paused box; the spec still says 503. That behavior remains unverified on this account.
Manual pauses and stops return 503.

If code had a reason for distrust, ask the user to recreate that sandbox from a clean source.
Routine builds of well-known public projects do not need that warning. Do not use `fork` for
pool recreation because it cannot pass `--no-vault --secrets none`. Keep deletion interactive.

## JSON and exit codes

Claim, renew and release accept `--json` anywhere after the command and emit exactly one
object with warnings. Error codes are `no_free_sandbox`, `claim_limit` and `lock_busy` (75),
`auth` and `account_blocked` (125), `failed` (normally 125, or an unexpected command status),
and `interrupted` (130/143). Check `error.held` and release any box it names. `ls --json`
rows carry `secrets` (true when Org Secrets are selected or could not be inspected), `vault`,
`pausesAt`, `cooldownUntil` and the API's `runtime` (`ready`, `processesPreserved`). API
strings in diagnostics are cleaned before printing.

| Exit | Meaning |
|---|---|
| The remote command's own | `exec` and `ssh` pass it through. |
| 0 | Success. `keepalive` also exits 0 when it skips a box in cooldown, with max-run disabled, or blocked by billing (402). |
| 1 | `keepalive` could not renew at least one lease for another reason (the lease request was refused or cut off). A bad key or an unreachable API exits 125. |
| 75 | No free sandbox, the agent already holds `IBX_MAX_CLAIMS` sandboxes, or another claim on this computer held the lock for 5 minutes. |
| 124 | `exec` timed out. |
| 125 | ibx failed: API, network, usage, a guard (credential file, Vault, Org Secrets), or a sandbox outside the pool. A claim that could not inspect a box's Secrets exits 125, not 75. |
| 130 / 143 | ibx got SIGINT / SIGTERM. The message says whether the remote command had started. |
| 255 | `ssh` could not connect (or the remote command exited 255). |

## Environment variables

| Variable | Meaning |
|---|---|
| `INSTABOX_API_KEY` | The API key. Without it, ibx reads `IBX_KEY_FILE`. |
| `IBX_KEY_FILE` | Default `${XDG_CONFIG_HOME:-~/.config}/instabox/api-key`. |
| `INSTABOX_API_URL` | Default `https://api.instabox.sh`. Plain http works only for `127.0.0.1` and `localhost`, for tests. |
| `IBX_ALLOW_CUSTOM_API=1` | The key may go to a host other than `api.instabox.sh`. |
| `IBX_AGENT_NAME` | The name in reservations. Default `agent-<number>`, per session in Claude Code and Codex, and per user and host when ibx finds no session ID it knows. Characters outside `A-Za-z0-9@._:-` become `_`, 64 at most. |
| `IBX_MAX_CLAIMS` | Live reservations one agent may hold. Default 3, 0 for no cap. |
| `IBX_STALE_SECS` | Age at which a reservation counts as abandoned. Default 86400. |
| `IBX_STATE_DIR` | Where the claim lock lives. Default `${XDG_STATE_HOME:-~/.local/state}/ibx`. |
| `IBX_GET_MAX` | Largest download `ibx get` accepts: bytes, or a number with K, M or G. Default 2G. |
| `IBX_ALLOW_ANY=1` | Let agent commands use sandboxes outside the pool. |
| `IBX_ALLOW_VAULT=1` | Let `claim` hand out sandboxes that the Vault writes secrets into. |
| `IBX_ALLOW_SECRETS=1` | Let `claim` hand out sandboxes with proxy Org Secrets scoped to named hosts. Proxy Secrets for every host (`*`, or no hosts), env Secrets, unknown delivery kinds, pending states and guest residue stay refused. |

The `IBX_ALLOW_*` variables switch off safety checks. They are yours to set, and the skill tells
agents never to set them.

## How it compares

Checked against the 2026-10-27 docs, CLI 0.7.1 and SDK 0.5.3.

| Feature | ibx | Official CLI / SDK / skills |
|---|---|---|
| Reservations, cap and pool guard | Yes | No |
| Exec retry rules | Never repeats a user command once it may have started | Caller must apply the API's partly-run rules |
| Command tools | exec, SSH | CLI exec --stream, --background, jobs, --json, argv and run; SDK command API |
| Files | Guarded put up to 5 GiB, bounded get | CLI push, pull, cp; SDK files |
| Credentials | Reads Vault and Org Secret state, fails closed | Manages Org Secrets and legacy Vault; basic setup enrolls credentials |
| Lifecycle | Wake/resume/start existing pool boxes, leases | Create, delete, snapshots, restart, fork and auto-suspend settings; max-run through the API (`maxRunMinutes`) |
| Access | Private forward and public port cleanup | port-forward, ports, desktop |
| Diagnostics | Org usage, run budgets, ports and SSH tokens | usage, logs, ps, metrics |

Activity leases are documented only in the OpenAPI spec, so ibx tracks that contract.
Official CLI jobs hold no activity lease and bypass ibx's reservations and guards.

## References and development

- [Agent skill](skills/ibx/SKILL.md)
- [Recipes](skills/ibx/references/recipes.md)
- [API notes](skills/ibx/references/api-notes.md)
- [Field notes](skills/ibx/references/field-notes.md)
- [Keepalive](skills/ibx/references/keepalive.md)
- [2026-10-27 research and decisions](docs/research/2026-10-27-instabox-changes.md)
- [Changelog](CHANGELOG.md) and [security reporting](SECURITY.md)

Offline tests use a local mock and scratch HOME, without a real account. Run `tests/offline.sh`
and `MOCK_EXEC=real tests/offline.sh`; the latter executes commands in the mock too.
`tests/live.sh` is opt-in and changes real boxes. Run it only when explicitly authorized.

MIT licensed. See [LICENSE](LICENSE).
