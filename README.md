# ibx

Borrow a disposable [instabox.sh](https://instabox.sh) sandbox from a pool, use it, and give it
back clean.

ibx is an agent skill plus one bash script. Claude Code, Codex, OpenCode, Cursor, Gemini CLI and
other agents that read `SKILL.md` skills use it to run risky or heavy work in a cloud Linux VM
instead of on your computer. That means packages nobody has vetted, Playwright suites, Docker,
long builds and large public datasets. You choose which instabox sandboxes go in the pool. An
agent claims one, works in it, and releases it.

ibx is an independent project. InsForge, the company behind instabox, did not make it and is not
affiliated with it.

```console
$ ibx claim "run the test suite of expressjs/express"
box-2
$ ibx exec box-2 -t 480 -- 'git clone -q --depth 1 https://github.com/expressjs/express && cd express && npm ci -s && npm test >test.log 2>&1 && echo tests passed'
tests passed
$ ibx release box-2
released box-2 (was: run the test suite of expressjs/express (agent-1904731562, since 2026-10-17T14:02:11Z))
```

You rarely type these yourself. The skill tells the agent to reach for a sandbox on its own
whenever work is risky or heavy and nothing secret is involved, and to say which one it used. You
can also just ask: "run this repo's tests in a sandbox".

## "Why not just use the instabox CLI?"

Use it for your account. The instabox CLI creates, snapshots and deletes sandboxes and manages
the Vault and API keys, and InsForge's official skills teach agents to do all of that. The SDK is
the library for building products on instabox.

I wrote ibx for a narrower job. I run several coding agents at once against a handful of
sandboxes, and letting each of them drive the API directly went wrong in the same few ways. Two
agents picked the same box. A box paused halfway through a build. A dropped connection left an
agent unsure whether its migration had run, and retrying would have run it twice. As of its docs
on 2026-10-16, the CLI has no reservations between agents. ibx adds reservations, activity leases
and an exec that never retries once it may have started, and little else.
[How it compares](#how-it-compares) has the side-by-side.

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
| `--keepalive`, `--keepalive=all` | Install the keepalive timer (step 5 of [Setup](#setup)). |
| `--uninstall` | Remove what install.sh installed. |
| `--dry-run` | Print every change, including the timer files, and change nothing. |

### Next to the official instabox skills

`npx instabox@latest` installs InsForge's skills (`instabox`, `instabox-basic-setup`,
`instabox-move-repo`, `instabox-snapshots`) into `~/.claude/skills` and `~/.agents/skills`. ibx
keeps to its own skill directory (`ibx`), metadata keys (`ibx.*`), lease ID (`ibx-keepalive`)
and port names (`ibx:...`), and it does not need the instabox CLI. Install both if you like.

## Setup

1. **Create an API key.** On the API Keys page of the instabox dashboard, create a restricted key
   with only `machines:write`, which includes `machines:read`. Leave out `machines:delete` and
   `images:*`, and set an expiry of 30 to 90 days. Scopes cover the whole account, not single
   sandboxes, so if you keep personal sandboxes with real data, put the pool in a separate
   instabox account.

2. **Store the key.** ibx and the keepalive timer read
   `${XDG_CONFIG_HOME:-~/.config}/instabox/api-key`. This keeps it readable only by you and out
   of your shell history:

   ```sh
   (umask 077 && mkdir -p ~/.config/instabox && cat >~/.config/instabox/api-key)
   # paste the key, press Enter, then Ctrl-D
   ```

   `INSTABOX_API_KEY` also works, but every program your shell starts inherits it.
   `IBX_KEY_FILE` points ibx at another file.

3. **Fill the pool.** Agents claim only sandboxes you add. Create them with the Vault off, so
   your instabox secrets never reach code that agents run there:

   ```sh
   instabox create --name box-1 --no-vault
   instabox create --name box-2 --no-vault
   ibx pool add box-1 box-2     # names or IDs; ibx ls --all lists every sandbox
   ```

   `ibx pool add` refuses a sandbox that the Vault writes secrets into, unless you pass
   `--allow-vault`. It warns when the Vault is on but still empty, because items you add later
   will reach that sandbox. For an existing sandbox that is stopped or paused,
   `instabox start box-1 --no-vault` or `instabox resume box-1 --no-vault` turns the Vault off for
   good.

4. **Check.** `ibx doctor` prints one line per check and exits 0 when everything is ready. It
   also prints the agent name in use, where that name came from, and the claim cap.

5. **Turn on keepalive.** Optional, and I recommend it. Without it a sandbox pauses after 30 idle
   minutes once the 1-hour lease from `ibx claim` runs out. Processes survive the pause and the
   next `exec`, `ssh` or `claim` wakes the sandbox, but public URLs answer 503 until then.

   ```sh
   ./install.sh --keepalive        # keep reserved pool sandboxes awake
   ./install.sh --keepalive=all    # keep every pool sandbox awake, around the clock
   ```

   On Linux this is a systemd user timer, `ibx-keepalive.timer`, every 15 minutes and catching up
   after sleep. On macOS it is a launchd agent, `local.ibx-keepalive`, every 900 s. Manual setup,
   cron, checks and costs are in [keepalive.md](skills/ibx/references/keepalive.md).

## What it does for you

**It keeps agents off each other's sandbox.** `ibx claim` writes a reservation with a random
token into the sandbox's metadata and skips sandboxes that someone else holds. How far that
reaches depends on who else is claiming:

| Who else is claiming | What keeps them apart |
|---|---|
| Other ibx processes of the same user on the same computer | A local lock around the moment `claim` writes the reservation: an atomic `mkdir` lock in `IBX_STATE_DIR`, the same on Linux and macOS. ibx takes it over when its owner died or has hung for 2 minutes, and a claim that waits 5 minutes for it gives up with exit 75 instead of writing. While the lock works, this is real mutual exclusion, and the cap holds exactly. |
| ibx on another computer, or another user | Nothing shared. `claim` waits about 25 s for concurrent writers to settle and checks its token twice before it prints the name. Here reservations are advisory. |
| The instabox CLI, the dashboard, the SDK, your own scripts | Nothing. They ignore reservations and can exec into a held sandbox. |

Every claim that writes a reservation then waits about 25 s for concurrent writers to settle,
even with the lock, so a successful claim takes at least 25 s. If the state directory is
unusable (a symlink, not yours, or writable by others), ibx warns and relies on that wait alone. `claim` also checks that a sandbox is still free in the
same API read it builds its write from.

When nothing is free, `claim` exits 75 and lists who holds what, since when and why, and the
agent asks you. A reservation older than `IBX_STALE_SECS` (86400 s) counts as abandoned, and
`ibx renew` refreshes one for longer jobs.

**It caps how many sandboxes one agent holds.** `IBX_MAX_CLAIMS` sets the cap. The default is 3,
and 0 means no cap. A claim past the cap exits 75, the same code as "no free sandbox", and names
what the agent already holds. That catches an agent that forgot to release:

```console
$ ibx claim "benchmark build B"
ibx: agent-2290417765 already holds 3 sandboxes (box-1, box-3, box-4), the most IBX_MAX_CLAIMS allows. Release one you no longer use, or ask the user.
$ echo $?
75
```

The cap counts per agent name. In Claude Code and Codex the default name is per session, derived
from `CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID`, so the cap counts one session. When ibx finds
no session ID it knows,
the name falls back to one per user and host (`agent-<number>`). Every such agent on one computer
then shares that name and one cap of 3. Give each its own name when you start it, and keep the
name the same for the whole job:

```sh
IBX_AGENT_NAME=opencode-docs opencode
```

Only you set the cap. The skill tells agents never to raise it, and never to change
`IBX_AGENT_NAME` or `IBX_STATE_DIR` to get around it.

**It keeps reserved sandboxes awake.** A sandbox pauses after 30 idle minutes, and light CPU
load does not count as activity. The API accepts the setting that should change this and then
ignores it, as the note under [How it compares](#how-it-compares) shows. `ibx claim` sets a
1-hour activity lease instead, and `ibx keepalive` renews it from a timer while the reservation
lasts. Keepalive wakes a sandbox that paused for idleness and leaves alone one you paused or
stopped by hand. `claim`, `exec`, `put`, `get` and `ssh` wake, resume or start a sandbox that is
not running. When ibx did the waking, it warns if the sandbox came back from a fresh boot with
its processes gone. When the server wakes an idle-paused sandbox for an exec on its own, ibx
cannot tell, so after a long gap check that your processes are still there. The skill has agents
do this.

**It never runs an exec twice by accident.** Once a command may have started, ibx does not retry
it. It retries only errors that mean the command did not run, and otherwise says "may or may not
have run; check before retrying". On network errors it retries calls that are safe to repeat,
with an `Idempotency-Key` where the API takes one.

**It keeps your secrets out of the VM.**

- `ibx put` refuses files that look like credentials, also through symlinks. That covers `.env`
  files, private keys, `credentials*`, `*secret*`, `*token*` and anything under `.ssh/`, `.aws/`
  or `.claude/`. `--force` is for a false positive like `src/token-bucket.js`, never for a file
  that really is a credential.
- `claim` skips sandboxes that your Vault writes secrets into, and `pool add` refuses them.
- Agent commands (`exec`, `put`, `get`, `ssh`, `port`, `unport`, `renew`, `release`) work only on
  pool sandboxes, so your other sandboxes stay out of reach.
- SSH tokens last 1 hour, stay out of argv and error output, and ibx revokes them on exit and
  confirms it. `ibx ssh` also checks host keys against the certificate authority the API returns.

**It keeps the API key to itself.** The key never appears in argv, in the environment of
programs ibx starts, or on disk. It reaches curl through a pipe, and every curl runs with `-q`,
so `~/.curlrc` cannot make it print the key. ibx warns when the key file is readable by others
and sends the key only to `https://api.instabox.sh` unless `IBX_ALLOW_CUSTOM_API=1`.

**It closes public URLs on hand-back.** `ibx port` publishes a port at a public URL with no
authentication, says so, and names the port `ibx:...`. `ibx release` unpublishes ibx's ports and
refuses to finish while one is still public. `claim` warns about ports an earlier holder left
open.

## Using it

### Through your agent

You do not have to ask. The skill tells agents to use a sandbox on their own, without asking you
first, for packages and tools nobody has vetted, builds, test suites, benchmarks and Docker for
public code, headless browsers and video rendering, large public datasets, and jobs that take more
than a few minutes. It keeps them local for quick commands and for anything secret. You can still
ask for the outcome directly:

- "Try this npm package in an instabox sandbox before we add it."
- "Run the Playwright suite of this public repo in a sandbox and bring back the report."
- "Benchmark these two builds on the same sandbox."

The agent runs `ibx doctor` once, claims a sandbox with a generic purpose, and writes the name
down. It uses that name literally in later calls, because shell variables do not survive between
tool calls. It works with `exec`, `put`, `get` and `ssh`, cleans up, and releases the sandbox,
even after errors. It asks you before touching a sandbox someone else holds, publishes ports only
when you ask, and brings results back instead of leaving the only copy in the VM.

Tool timeouts are the usual trap. ibx waits up to `-t` + 90 s for an exec reply, so the agent's
tool call needs more than that:

| Call | Tool timeout |
|---|---|
| `ibx exec -t N` | At least N + 120 s. The default `-t 300` needs 420000 ms. |
| `ibx claim`, `ibx ssh` | 600000 ms, since they may wait for a sandbox to start. |

Claude Code's Bash tool stops at 600000 ms, so `-t` stays at 480 or less there. Jobs longer than
about 8 minutes run detached, and the agent polls them with quick, separate `ibx exec` calls,
never with a long foreground `sleep` loop
([recipe](skills/ibx/references/recipes.md#5-long-jobs-detached)).

Each job that runs at the same time needs its own sandbox. Keep one more sandbox than the number
of agents you run at once. A reservation an agent forgot holds its sandbox until someone runs
`ibx release` or 24 hours pass, and the spare covers it. The account has its own limit. At most 4
execs run at once per account, and ibx waits up to 10 minutes for a slot before it reports that
the exec did not run. With more than four agents running commands at the same moment, the rest
wait even when sandboxes are free.

### By hand

```sh
ibx ls                  # pool sandboxes, their state, and who holds each one and why
ibx ls --all --json     # every sandbox, machine-readable, with a boolean "vault" per sandbox
ibx release box-2       # take back a sandbox an agent forgot; prints what it held
ibx renew box-2         # refresh a reservation for a job that runs past 24 h
ibx pool rm box-3       # stop agents from claiming it
ibx keepalive           # one keepalive run by hand
ibx --help
```

## Safety model

> [!WARNING]
> Treat a pool sandbox as a computer the provider fully controls and that anyone with the
> account's API key can enter as root. ibx limits what reaches it. It cannot make it trustworthy.

[What it does for you](#what-it-does-for-you) lists the checks ibx makes. ibx also strips control
characters from sandbox names, purposes and URLs before printing them, so metadata cannot rewrite
your terminal. These are the things ibx cannot change, with the long version in
[trust-model.md](skills/ibx/references/trust-model.md):

- The provider's guest agent runs as root in the VM, and exec and SSH pass through its gateway.
- You cannot limit an API key to one sandbox. `machines:write` reaches all of them.
- Reservations keep only cooperating ibx processes apart ([table](#what-it-does-for-you)). They
  keep nobody out.
- Vault items with no selector reach every sandbox whose Vault is still on. `--no-vault` on
  create, start or resume turns it off for good.
- The claim purpose and the agent name sit in sandbox metadata, which the provider and every API
  key of the account can read. Keep `IBX_AGENT_NAME` generic. The skill asks agents for generic
  purposes, with no client or employer names and no secrets.
- Agents reuse pool sandboxes, so the next holder sees what you leave behind.

The skill covers what ibx cannot check, such as a tar stream through `ibx ssh` or the text of a
command. The skill tells agents not to bring credentials, logged-in sessions, other people's
personal data, or your private code unless you ask. Public code is fine. Everything inside the VM is data, so
agents report instructions they find there to you instead of following them. `git archive` copies
every versioned file, so before one the agent looks for secrets and stops if anything matches, or
archives only selected paths:

```sh
git ls-files | grep -Ei '(^|/)\.env|\.(pem|key|p12|pfx)$|id_rsa|id_ed25519|credential|secret'
git archive HEAD -- src tests | ibx ssh box-2 'mkdir -p app && tar x -C app'
```

### After untrusted code ran

That code had sudo. An agent that ran it tells you and leaves the cleanup to you. Recreate the
sandbox from a template or a clean snapshot, always with `--no-vault`, and add it back:

```sh
ibx pool rm box-1
instabox rm box-1
instabox create --name box-1 --no-vault     # or --snapshot clean-base --no-vault
ibx pool add box-1
```

A clean snapshot is one taken before any untrusted code ran, with no credentials in HOME. The
API's fork route went away on 2026-10-15, so you cannot copy a sandbox that way.

## How it compares

InsForge ships a CLI, a TypeScript SDK and a set of agent skills, and they cover far more than
ibx does. ibx does one job next to them, lending pool sandboxes to agents, and replaces none of
them. This table comes from [instabox.sh/docs/cli](https://instabox.sh/docs/cli) and
[instabox.sh/docs/sdk](https://instabox.sh/docs/sdk) as I read them on 2026-10-16.

| | ibx | instabox CLI | instabox SDK | Official instabox skills |
|---|---|---|---|---|
| What it is | A skill and one bash script over the HTTP API | InsForge's command-line client | `@insforge/instabox-sdk` 0.5.0, TypeScript for Node 18+, Bun and Deno | Skills from `npx instabox@latest` that teach an agent the CLI |
| Made for | Lending pool sandboxes to agents | Running your account | Building products on instabox | Agents that run your account |
| Create, delete, snapshot sandboxes | No, on purpose | Yes | Yes | Yes, through the CLI |
| Vault and API keys | Reads the Vault state to skip sandboxes | `vault ...` and `keys ...` | `vault`, `pushVault`, `disableVault` | `instabox-basic-setup` can put your tokens and dotfiles into every sandbox through the Vault |
| Run commands | `exec`, up to 600 s, never retried once it may have started | `exec` with `--cwd`, `--env`, `--timeout`, `--stdin` | `commands.run`, never retried, with background handles | Through the CLI |
| Copy files | `put` and `get` up to 750 KB with a credential guard, tar over `ibx ssh` for more | `files` lists a directory or prints a text file, with no upload | `files` read, write, list and remove, up to 10 MiB per call | `instabox-move-repo` moves a local repo, with its agent conversations, onto a box |
| Reservations between agents | Yes, with a per-agent cap | No | No | No |
| Idle pause | Activity lease from `claim`, renewed by `ibx keepalive` | `auto-suspend` (see the note) | `setAutoSuspend()` (see the note), with no activity leases or wake call | The CLI's setting |
| Sandboxes fed by the Vault | Skipped by `claim`, refused by `pool add` | `--no-vault` per sandbox | `disableVault` | `--no-vault` per sandbox |
| Public ports | `release` unpublishes ibx's ports, `claim` reports leftovers | `port publish`, `port ls`, `port unpublish` | Not in the SDK reference | Through the CLI |
| Desktop, usage, metrics | No | `usage` | `sbx.desktop` for screenshots, clicks and a stream link, `getMetrics` and `getUsage` for billing your own customers | Through the CLI |
| Needs | bash, curl, jq, an API key, and ssh for `ibx ssh` | The CLI and a login or an API key | Node 18+, Bun or Deno, and an API key | The CLI |

> [!NOTE]
> As of 2026-10-16, `PATCH /v1/machines/{id}` with `autoSuspendAfterSeconds` 0 returns 200 and
> the value stays 1800, so the sandbox still pauses after 30 idle minutes. The SDK's
> `setAutoSuspend()` in 0.5.0 sends exactly that request. The CLI's `auto-suspend` command sets
> the same API field, though I have not tested the command itself. Activity leases do work, and
> they are what ibx uses.

## Reference

### Commands

| Command | What it does |
|---|---|
| `ibx claim [--json] "<purpose>"` | Reserve a free pool sandbox, set a 1-hour lease and print its name. |
| `ibx exec <box> [-t SECS] [-i] -- <cmd>` | Run `bash -lc` as the sandbox user in HOME (`/data/home`). `-t` defaults to 300, max 600. `-i` sends stdin, up to 1 MiB. |
| `ibx put [--force] <box> <local> <remote>` | Copy a file in, up to 750 KB. Relative remote paths are under HOME. |
| `ibx get <box> <remote> [local]` | Copy a file out, up to 750 KB, text or binary. |
| `ibx ssh <box> [cmd...]` | SSH with a 1-hour token revoked on exit. Streams stdio, for `tar` and long scripts. |
| `ibx port <box> <port> [name]`, `ibx unport <box> <port>` | Publish an HTTP port at a public URL with no authentication, or unpublish it. |
| `ibx renew [--json] <box>` | Refresh your reservation. |
| `ibx release [--json] <box>` | Unpublish ibx ports, drop the lease and clear the reservation. |
| `ibx ls [--all] [--json]` | Pool sandboxes, or all of them, with their state and holders. |
| `ibx pool add [--allow-vault] <box>...`, `ibx pool rm <box>...` | Choose which sandboxes agents may claim. |
| `ibx keepalive [--all]` | Renew leases on reserved pool sandboxes, or on every pool sandbox. |
| `ibx doctor` | Check dependencies, key, API access, pool, Vault, timer, agent name and cap. |

### Exit codes

| Code | Meaning |
|---|---|
| The remote command's own | `exec` and `ssh` pass it through. |
| 124 | `exec` timed out. |
| 75 | No free sandbox, the agent already holds `IBX_MAX_CLAIMS` sandboxes, or another claim on this computer held the lock for 5 minutes. |
| 125 | ibx failed because of the API, the network, usage, or a sandbox outside the pool. |
| 255 | `ssh` could not connect. |
| 143 | The remote command got SIGTERM, or ibx itself did. ibx says which. In the second case the remote command may still be running. |
| 130 | ibx got SIGINT. The remote command may still be running. |
| 1 | `ibx keepalive` could not renew a lease. |

### Environment

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
| `IBX_ALLOW_ANY=1` | Let agent commands use sandboxes outside the pool. |
| `IBX_ALLOW_VAULT=1` | Let `claim` hand out sandboxes that the Vault writes secrets into. |

The `IBX_ALLOW_*` variables switch off safety checks. They are yours to set, and the skill tells
agents never to set them.

### JSON output

`claim`, `renew`, `release` and `ls` take `--json` anywhere after the command. Each of the first
three prints one object on stdout with a `warnings` array. `claim` returns `name`, `id`, `by`,
`since`, `purpose`, `leaseUntil` and `publicPorts` (`publicPorts` is null, with a warning, when the
ports could not be listed, and `leaseUntil` is null when the lease could not be set). `renew` returns `name`, `id`, `by`, `since` and
`abandonedAfter`. `release` returns `name`, `id`, `unpublished`, `leftAlone` and `was`, the
reservation it cleared.

An error is a single object on stdout with the usual exit code:

```json
{"error": {"code": "claim_limit", "message": "...", "held": [...]}, "warnings": [...]}
```

| `error.code` | Exit | Extra |
|---|---|---|
| `no_free_sandbox` | 75 | `held`, every live reservation in the pool |
| `claim_limit` | 75 | `held`, this agent's reservations |
| `lock_busy` | 75 | None. Another claim on this computer held the lock for 5 minutes; try again |
| `interrupted` | 130 or 143 | `held`, the sandbox `claim` had already reserved, so you can release it |
| `failed` | 125, or the status of an unexpected failure | `held` when `claim` had already reserved a sandbox, which you then release |

```sh
if out=$(ibx claim --json "nightly benchmark"); then
  box=$(jq -r .name <<<"$out")
else
  jq -r .error.code <<<"$out"
fi
```

## Version, platforms and limits

This is version 0.2.0, from 2026-10-17. instabox is in beta, and its API changes. The fork route
went away on 2026-10-15, for example. When this README and the live API disagree, trust
[the API's OpenAPI spec](https://api.instabox.sh/v1/openapi.json) and open an issue here.

I test against the live API on Linux. On macOS only CI runs ibx, with the offline suite and
Homebrew bash. Windows is not supported and WSL is untested.

The keepalive timer runs on your computer. While your computer sleeps, reserved sandboxes pause
about 90 minutes after the last successful run.

## Documentation

The skill and its references are the full docs. Agents read them, and so can you. There is no
docs site.

- [SKILL.md](skills/ibx/SKILL.md) is what the agent reads. It covers when to use a sandbox, what
  never goes there, the workflow, tool timeouts, long jobs and killing processes safely.
- [trust-model.md](skills/ibx/references/trust-model.md) covers who can see what, the Vault, key
  scopes and recreating a sandbox.
- [field-notes.md](skills/ibx/references/field-notes.md) records dated instabox behaviour I
  observed that the official docs did not cover yet, such as the idle pause, leases, exec quirks,
  TLS drops, SSH tokens and spec drift.
- [api-notes.md](skills/ibx/references/api-notes.md) lists routes, `Idempotency-Key` rules, error
  codes, limits and curl patterns.
- [keepalive.md](skills/ibx/references/keepalive.md) sets up the timer with systemd, launchd or
  cron, and explains how to check it and what it costs.
- [recipes.md](skills/ibx/references/recipes.md) has screenshots, auditing an untrusted package,
  big transfers, long jobs, Docker, datasets, ports and cleanup.
- [CHANGELOG.md](CHANGELOG.md) lists changes by version, and [SECURITY.md](SECURITY.md) says how
  to report a vulnerability.

## Testing

```sh
tests/offline.sh                   # against a local mock of the API, no account, no network
MOCK_EXEC=real tests/offline.sh    # the mock also runs commands, so put and get are covered (Linux)
ONLY=claim tests/offline.sh        # only the groups whose name matches
IBX_LIVE=1 tests/live.sh           # opt-in, against a real account
```

The offline suite needs python3, curl and jq. The live suite needs your API key and at least two
free pool sandboxes that the Vault writes no secrets into. It claims both, runs commands, copies
files, opens SSH sessions, publishes a port for a few seconds, runs `ibx keepalive`, and
releases both at the end, even after a failure. CI runs `bash -n` and shellcheck from a pinned,
checksum-verified release, and separately the offline suite on Linux with `MOCK_EXEC=real` and on
macOS with Homebrew bash. On macOS it also checks that the system bash 3.2 re-runs ibx with
Homebrew's bash, or refuses with a clear message when it cannot.

## Reporting provider bugs

Problems with instabox itself go to the instabox team. That covers the API, sandboxes, the CLI
and the docs. `instabox feedback` sends a report and redacts emails, keys, tokens, home paths and
public IPv4 addresses first:

```sh
instabox feedback --type bug --component api --title "autoSuspendAfterSeconds is accepted but ignored" \
  --detail "PATCH /v1/machines/{id} with autoSuspendAfterSeconds 0 returns 200; GET still shows 1800." \
  --expected "the new value is kept, or the request is rejected"
```

[field-notes.md](skills/ibx/references/field-notes.md) lists what I have seen so far. Never put
API keys, tokens or personal data in a report.

## Reporting ibx bugs and vulnerabilities

Problems with ibx go to [this repository's issues](https://github.com/hevlyo/ibx/issues). Report
vulnerabilities in ibx privately, as [SECURITY.md](SECURITY.md) describes, not in a public issue.

## License

MIT. See [LICENSE](LICENSE).
