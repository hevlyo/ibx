# ibx

Borrow a disposable [instabox.sh](https://instabox.sh) sandbox from a shared pool, use it, and
give it back clean, from any coding agent.

ibx is an agent skill plus one bash script. It lets Claude Code, Codex, OpenCode and any other
agent that reads `SKILL.md` skills run risky or heavy work in a cloud Linux VM: untrusted
packages, browser jobs, Docker, long builds, large public datasets. The VM comes from a pool of
instabox sandboxes you set up. ibx keeps two agents off the same sandbox, handles the idle
pause, skips sandboxes that your instabox Vault writes secrets into, and refuses to copy files
that look like credentials. It is an independent project, not made by or affiliated with
InsForge, the company behind instabox.

```console
$ ibx claim "run the test suite of expressjs/express"
box-2
$ ibx exec box-2 -t 480 -- 'git clone -q --depth 1 https://github.com/expressjs/express && cd express && npm ci -s && npm test >test.log 2>&1 && echo tests passed'
tests passed
$ ibx release box-2
released box-2 (was: run the test suite of expressjs/express (agent-1904731562, since 2026-10-15T14:02:11Z))
```

## Why

instabox gives you a few sandboxes and an API that can do anything with them. An agent that
drives that API (or the CLI) directly tends to run into five problems:

- **Two agents grab the same box.** Both see a running, idle-looking sandbox and work on top of
  each other. `ibx claim` writes a reservation with a random token into the sandbox's metadata,
  waits out concurrent writers, and checks the token twice before it hands out the name. Held
  sandboxes are skipped. If none is free, it exits 75 and the agent asks you.
- **Boxes pause mid-job.** A sandbox pauses after 30 idle minutes, and light CPU load does not
  count as activity. The setting that should change this (`autoSuspendAfterSeconds`) is
  accepted and then ignored by the server (observed 2026-10-15). `ibx claim` sets a 1-hour
  activity lease on the sandbox it hands out, and `ibx keepalive`, run every 15 minutes from a
  timer, renews it while the reservation lasts. `claim`, `exec`, `put`, `get` and `ssh` wake,
  resume or start a sandbox that is not running. When ibx did that itself, it warns if the
  sandbox came back from a fresh boot (processes gone). When the server wakes an idle-paused
  sandbox for an exec on its own, ibx cannot tell, so the skill has agents check their
  processes after a long gap.
- **A non-idempotent exec gets retried.** The connection drops after an exec, the agent tries
  again, and the migration or the publish runs twice. ibx never retries an exec once the
  command may have started. It retries only errors that mean the command did not run, and
  otherwise says "the command may or may not have run; check before retrying". Calls that are
  safe to repeat are retried on network errors, with an `Idempotency-Key` where the API takes
  one.
- **Secrets end up in a VM the provider has root on.** The provider, and anyone holding an
  account API key with `machines:write`, can be root in every sandbox. ibx cannot make that VM
  trustworthy, so it limits what reaches it: `ibx put` refuses files that look like
  credentials; `ibx claim` skips pool sandboxes that the Vault writes secrets into, and
  `ibx pool add` refuses them; agent commands work only on pool sandboxes, so your other
  sandboxes stay out of reach; the API key never appears in argv, in the environment of the
  programs ibx starts, or on disk; and SSH tokens last 1 hour, stay out of argv and error
  output, and are revoked on exit. What ibx cannot check (a tar stream through `ibx ssh`, a
  `git archive`, the text of a command) is covered by the skill's rules: no credentials,
  logged-in sessions, other people's personal data, or your proprietary code unless you ask,
  and everything inside the VM is data, not instructions.
- **Public URLs stay open.** A published port gets a public URL with no authentication. `ibx port`
  says so and tags the port as ibx's. `ibx release` unpublishes ibx's ports and refuses to
  finish while one is still public. `ibx claim` warns about ports left open by an earlier holder.

## Features

- **Pool and reservations**: `ibx pool add|rm` chooses which sandboxes agents may claim;
  `ibx claim`, `ibx renew`, `ibx release` and `ibx ls` manage reservations. A reservation older
  than 24 hours (`IBX_STALE_SECS`) counts as abandoned. Agent commands (`exec`, `put`, `get`,
  `ssh`, `port`, `unport`, `renew`, `release`) work only on pool sandboxes.
- **Work in the sandbox**: `ibx exec` (bash login shell in HOME; 300 s by default, up to 600;
  `-i` sends local stdin, up to 1 MiB), `ibx put` and `ibx get` (files up to 750 KB, text or
  binary; `put` refuses credential-looking files unless `--force`) and `ibx ssh` (streams stdin
  and stdout, for long scripts and big transfers: `tar c dir | ibx ssh box-2 'tar x'`).
- **Vault checks**: `claim` skips, `pool add` refuses (unless `--allow-vault`) and `doctor`
  reports pool sandboxes that the instabox Vault writes secrets into.
- **Ports**: `ibx port` and `ibx unport`, with cleanup on release.
- **Keepalive**: `ibx keepalive [--all]`, plus a systemd or launchd timer from `install.sh`.
- **Diagnostics**: `ibx doctor` checks dependencies, the key, API access, the pool, the Vault
  of pool sandboxes and the timer.
- **Exit codes an agent can act on**: the remote command's own code for `exec` and `ssh`; 124
  exec timed out; 75 no free sandbox; 125 ibx itself failed (API, network, usage, a sandbox
  outside the pool); 255 ssh could not connect. 143 means either that the remote command was
  killed by SIGTERM or that ibx itself got SIGTERM (it says which; in the second case the
  remote command may still be running). `ibx keepalive` exits 1 when a lease could not be
  renewed.
- **One file**: bash, curl and jq against the HTTP API. No daemon, no SDK, no instabox CLI.
- **Agent guidance**: [SKILL.md](skills/ibx/SKILL.md) covers when to use a sandbox, what never
  goes there, the workflow, tool timeouts, long jobs and killing processes safely. Its
  [references](skills/ibx/references/) hold the trust model, API notes, observed behaviour,
  the keepalive setup and recipes.

## Requirements

- bash 4.4+, curl 7.71+, jq 1.6+, and ssh (only for `ibx ssh`).
- macOS: `brew install bash jq`. The system bash 3.2 is too old; ibx re-runs itself with
  Homebrew's bash when it finds it.
- An instabox.sh account with a few sandboxes, and an API key (see [Setup](#setup)).
- Python 3, only for the offline tests.

## Install

Pick one way per agent. Each installs the same skill, named `ibx`.

### 1. Any agent: the skills CLI

```sh
npx skills add hevlyo/ibx                                   # asks where to install
npx skills add hevlyo/ibx -g -a claude-code -a codex        # global, for the agents you name
```

The agent runs the helper from the skill's directory (`bash <skill-dir>/scripts/ibx`). To also
have `ibx` on your own PATH, clone the repository and run `./install.sh --agents none`.

### 2. Claude Code plugin

```text
/plugin marketplace add hevlyo/ibx
/plugin install ibx@ibx
```

The skill then appears as `/ibx:ibx`. The plugin manifests carry no version number, so plugin
updates follow the repository's commits. Do not also link the skill into `~/.claude/skills`, or
Claude Code loads it twice.

### 3. From a clone, with install.sh

```sh
git clone https://github.com/hevlyo/ibx
cd ibx
./install.sh --dry-run    # shows what it would do
./install.sh              # skill into ~/.claude/skills and ~/.agents/skills, ibx into ~/.local/bin
```

The skill is linked, so `git pull` updates it. Options:

| Option | Effect |
|---|---|
| `--agents LIST` | Skills roots, comma-separated: `claude` (`~/.claude/skills`), `agents` (`~/.agents/skills`, read by Codex and other agents), `codex` (`$CODEX_HOME/skills`), `opencode` (`~/.config/opencode/skills`), `all`, `none`. Default `claude,agents`. |
| `--copy` | Copy the skill instead of linking it. Run it again after a `git pull`. |
| `--bin DIR`, `--no-bin` | Where the `ibx` command is linked (default `~/.local/bin`), or not at all. |
| `--keepalive`, `--keepalive=all` | Install the keepalive timer (see [Setup](#setup)). |
| `--uninstall` | Remove what install.sh installed. |
| `--dry-run` | Print every change, including the timer files, and change nothing. |

install.sh needs no sudo and no network, and is safe to run again. It never replaces a
directory or file it did not create: if one is in the way, it stops before changing anything
and names it.

### Alongside the official instabox skills

`npx instabox@latest` installs InsForge's own skills (`instabox`, `instabox-basic-setup`,
`instabox-move-repo`, `instabox-snapshots`) into `~/.claude/skills` and `~/.agents/skills`.
ibx uses its own directory (`ibx`), its own metadata keys (`ibx.*`), its own lease ID
(`ibx-keepalive`) and its own port names (`ibx:...`), and does not need the instabox CLI. The
two work side by side: the CLI and its skills create and administer your sandboxes, and ibx
lends sandboxes from the pool to your agents.

## Setup

1. **Create an API key.** On the instabox dashboard's API Keys page, create a restricted key
   with only `machines:write`, which includes `machines:read`. Leave out `machines:delete` and
   `images:*`, and give it an expiry (30 to 90 days is reasonable). Scopes cover the whole
   account, not single sandboxes. So if you keep personal sandboxes with real data, use a
   separate instabox account for the pool.

2. **Store it** where ibx and the timer read it, readable only by you. The default is
   `${XDG_CONFIG_HOME:-~/.config}/instabox/api-key`:

   ```sh
   (umask 077 && mkdir -p ~/.config/instabox && cat >~/.config/instabox/api-key)
   # paste the key, press Enter, then Ctrl-D
   ```

   This keeps the key out of your shell history. `INSTABOX_API_KEY` also works, but environment
   variables leak into child processes more easily. `IBX_KEY_FILE` points ibx at another file.

3. **Fill the pool.** Agents claim only sandboxes you add. Create them with the Vault off, so
   your instabox secrets never reach code that agents run there:

   ```sh
   instabox create --name box-1 --no-vault
   instabox create --name box-2 --no-vault
   ibx pool add box-1 box-2     # names or IDs; ibx ls --all lists every sandbox
   ```

   `ibx pool add` refuses a sandbox that the Vault writes secrets into (`--allow-vault`
   overrides that), and warns when the Vault is on but still empty, because items you add later
   will reach it. For an existing sandbox that is stopped or paused,
   `instabox start box-1 --no-vault` (or `instabox resume box-1 --no-vault`) turns the Vault off
   for good.

4. **Check**: `ibx doctor` prints one line per check and exits 0 when everything is ready.

5. **Optional: keepalive.** Without it, a sandbox pauses after 30 idle minutes (the lease that
   `ibx claim` sets covers the first hour). Processes survive the pause and the next
   `ibx exec`, `ssh` or `claim` wakes it, but public URLs answer 503 until then.

   ```sh
   ./install.sh --keepalive        # keep reserved pool sandboxes awake (recommended)
   ./install.sh --keepalive=all    # keep every pool sandbox awake, around the clock
   ```

   On Linux this is a systemd user timer (`ibx-keepalive.timer`, every 15 minutes, catching up
   after sleep). On macOS it is a launchd agent (`local.ibx-keepalive`, every 900 s). For manual
   setup, cron, checks and costs, see
   [references/keepalive.md](skills/ibx/references/keepalive.md).

## Usage

### For humans

```sh
ibx ls                  # pool sandboxes, their state, and who holds each one and why
ibx ls --all --json     # every sandbox, machine-readable (with a boolean "vault" per sandbox)
ibx release box-2       # take back a sandbox an agent forgot (prints what it held)
ibx pool rm box-3       # stop agents from claiming it
ibx keepalive           # one keepalive run by hand
ibx --help
```

| Environment | Meaning |
|---|---|
| `INSTABOX_API_KEY` | The API key. Without it, ibx reads `IBX_KEY_FILE`. |
| `IBX_KEY_FILE` | Default `${XDG_CONFIG_HOME:-~/.config}/instabox/api-key`. |
| `INSTABOX_API_URL` | Default `https://api.instabox.sh`. Another host needs `IBX_ALLOW_CUSTOM_API=1`; plain http only to `127.0.0.1` or `localhost` (tests). |
| `IBX_AGENT_NAME` | The name shown in reservations. Default: the pseudonymous `agent-<checksum of user@host>`. Other characters than `A-Za-z0-9@._:-` become `_`; 64 at most. |
| `IBX_STALE_SECS` | Age at which a reservation counts as abandoned. Default 86400. |
| `IBX_ALLOW_ANY=1` | Let agent commands use sandboxes outside the pool. |
| `IBX_ALLOW_VAULT=1` | Let `claim` hand out sandboxes that the Vault writes secrets into. |

The `IBX_ALLOW_*` variables switch off safety checks. The skill tells agents never to set them.

The claim purpose and the agent name are stored in the sandbox's metadata, which the provider
and every API key of the account can read. Keep `IBX_AGENT_NAME` generic, and expect agents
to write generic purposes (the skill asks them to: no client or employer names, no secrets).

### For agents

You do not need to teach the agent the commands; the skill does. Ask for the outcome:

- "Try this npm package in an instabox sandbox before we add it."
- "Run the Playwright suite of this public repo in a sandbox and bring back the report."
- "Benchmark these two builds on the same sandbox."

The skill has the agent run `ibx doctor` once, `ibx claim` with a purpose, write the sandbox name
down, work with `exec`, `put`, `get` and `ssh`, clean up, and `ibx release`, also after errors. It
asks you before touching a sandbox someone else holds, publishes ports only when you ask, and
brings results back instead of leaving the only copy in the VM.

Tool timeouts: ibx waits up to `-t` + 90 s for an exec reply, so the agent's tool call needs at
least `-t` + 120 s (the default `-t 300` needs 420000 ms). Claude Code's Bash tool stops at
600000 ms, so there `-t` stays at 480 or less. `claim` and `ssh` may wait for a sandbox to
start: give them 600000 ms. Jobs longer than about 8 minutes run detached and are polled with
separate, quick `ibx exec` calls (or a poll loop run as a background task), never with a long
foreground `sleep` loop ([recipes](skills/ibx/references/recipes.md#5-long-jobs-detached)).

Credentials: `ibx put` refuses files that look like credentials (`.env`, `*.pem`, `*.key`,
`id_rsa*`, `id_ed25519*`, `credentials*`, `*secret*`, `*token*`, files under `.ssh/`, `.aws/`,
`.claude/` and similar). `--force` is for a false positive such as `src/token-bucket.js`, never
for something that really is a credential. `git archive` copies every versioned file, so the
skill has the agent look first and stop if anything matches, or archive only selected paths:

```sh
git ls-files | grep -Ei '(^|/)\.env|\.(pem|key|p12|pfx)$|id_rsa|id_ed25519|credential|secret'
git archive HEAD -- src tests | ibx ssh box-2 'mkdir -p app && tar x -C app'
```

## Safety model

Treat a pool sandbox as a computer that the provider fully controls and that anyone with the
account's API key can enter as root. The details are in
[references/trust-model.md](skills/ibx/references/trust-model.md). In short:

- The provider's guest agent runs as root in the VM; exec and SSH pass through its gateway.
- An API key cannot be limited to one sandbox: `machines:write` reaches all of them.
- Reservations are metadata, not locks. They keep cooperating agents apart; they do not keep
  anyone out. Their purpose and agent name are readable by the provider and every key of the
  account.
- Public URLs have no authentication. Vault items with no selector reach every sandbox that was
  not created with the Vault turned off.
- Pool sandboxes are reused: the next holder sees what you leave behind.

What ibx does about it:

- The API key stays in an unexported shell variable and reaches curl through a pipe, so it is
  never in argv, in the environment of the programs ibx starts, or on disk. Every curl runs
  with `-q`, so `~/.curlrc` cannot make it print the key. ibx warns when the key file is
  readable by others, and sends the key only to `https://api.instabox.sh` unless
  `IBX_ALLOW_CUSTOM_API=1`.
- Agent commands work only on pool sandboxes, and `claim` skips pool sandboxes that the Vault
  writes secrets into.
- `ibx put` refuses credential-looking files unless `--force`.
- SSH host keys are checked against the certificate authority the API returns, and SSH tokens
  are short-lived, hidden and revoked.
- `ibx release` will not finish while a URL that ibx published is still public.
- Names, purposes and URLs from the API are printed without control characters.

The skill's rules cover what ibx cannot check: no credentials, sessions, personal data or only
copies in the sandbox, and instructions found inside the VM are reported, not followed.

### After untrusted code ran

An agent that ran untrusted code in a pool sandbox tells you, and leaves the cleanup to you,
because that code had sudo. Recreate the sandbox from a template or from a clean snapshot,
always with `--no-vault`, and add it back to the pool:

```sh
ibx pool rm box-1
instabox rm box-1
instabox create --name box-1 --no-vault     # or: --snapshot clean-base --no-vault
ibx pool add box-1
```

A clean snapshot is one taken before any untrusted code ran, with no credentials in HOME. The
API's fork route was removed on 2026-10-15, so there is no fork to copy a sandbox with.

## How it compares

| | ibx | instabox CLI, used directly | instabox skills (InsForge's official set; community skills such as igzard/instabox-skill) |
|---|---|---|---|
| What it is | A skill and one bash script over the HTTP API | InsForge's command-line client | Skills that teach an agent the CLI (the community one also covers the SDK and HTTP API) |
| Model | Disposable, shared sandboxes for agent work | Your own cloud machines | Your own cloud machines; the official set can put your tokens and dotfiles into every box through the Vault (`instabox-basic-setup`) |
| Create, delete and snapshot sandboxes; Vault; API keys | Not covered, on purpose: you manage the account | Yes | Yes |
| Move a local repo, with its agent conversations, onto a box | No | By hand | Yes (`instabox-move-repo`) |
| Shared pool with per-agent reservations | Yes | No | No |
| Sandboxes that receive Vault secrets | Skipped by `claim`, refused by `pool add` | Your choice per sandbox (`--no-vault`) | Your choice per sandbox (`--no-vault`) |
| Idle pause | Activity lease, set by `claim` and renewed by a timer (`ibx keepalive`) | `auto-suspend` setting (the server ignored the underlying API field when tested on 2026-10-15) | The CLI's setting |
| Public ports cleaned up on hand-back | Yes (`ibx release`) | By hand (`instabox port unpublish`) | Through the CLI |
| Needs | bash, curl, jq, ssh, an API key | The instabox CLI; a sign-in or an API key | The CLI (or the SDK or HTTP API) |

They are not exclusive: many setups use the CLI to manage the account and ibx for agent work.

## Testing

```sh
tests/offline.sh                   # against a local mock of the API: no account, no network
MOCK_EXEC=real tests/offline.sh    # the mock also runs commands, so put/get are tested (Linux)
ONLY=claim tests/offline.sh        # only the groups whose name matches
IBX_LIVE=1 tests/live.sh           # opt-in, against a real account
```

The offline suite needs python3, curl and jq. The live suite needs the usual API key and at
least two free pool sandboxes that the Vault writes no secrets into. It claims both, runs
commands, copies files, opens SSH sessions, publishes a port at a public URL for a few seconds,
runs `ibx keepalive`, and releases both sandboxes at the end, also after a failure. CI runs
`bash -n` and shellcheck, then the offline suite on Linux (with `MOCK_EXEC=real`) and on macOS
(Homebrew bash, plus a check that the system bash 3.2 re-runs ibx with Homebrew's bash).

## Status and limitations

- Version 0.1.0. instabox is in beta and its API changes quickly. The behaviour described here
  was verified on 2026-10-15. When something disagrees, trust the live API
  (`https://api.instabox.sh/v1/openapi.json`), and please open an issue.
- Tested against the live API on Linux. macOS is covered by CI only (offline suite with
  Homebrew bash). Windows is not supported; WSL is untested.
- Reservations are advisory, and an API key cannot be limited to some sandboxes (see
  [Safety model](#safety-model)).
- One exec runs for at most 600 s, and an agent's tool call may stop sooner (Claude Code: 10
  minutes), so longer jobs run detached. At most 4 execs run at once per account, and
  `put`/`get` move files up to 750 KB (bigger ones go through `ibx ssh` with tar).
- The keepalive timer runs on your computer. While it sleeps, reserved sandboxes pause about 90
  minutes after the last successful run.

## Reporting provider bugs

Problems with instabox itself (the API, sandboxes, the CLI, the docs) go to the instabox team.
The instabox CLI sends them with `instabox feedback`, and redacts emails, keys, tokens, home
paths and public IPv4 addresses before sending:

```sh
instabox feedback --type bug --component api --title "autoSuspendAfterSeconds is accepted but ignored" \
  --detail "PATCH /v1/machines/{id} with autoSuspendAfterSeconds 7200 returns 200; GET still shows 1800." \
  --expected "the value from the spec range 120-86400 is kept"
```

Seen on 2026-10-15 and described in
[references/field-notes.md](skills/ibx/references/field-notes.md): the ignored
`autoSuspendAfterSeconds`, an SSH-token DELETE lost to a dropped TLS connection that left the
token live, and spec drift (the exec description says the user is `dev`, the desktop
description says Xvfb). Never include API keys, tokens or personal data in a report.

Problems with ibx go to this repository's issues.

## Security

Report vulnerabilities in ibx privately, as [SECURITY.md](SECURITY.md) describes, not in a
public issue.

## License

MIT. See [LICENSE](LICENSE).
