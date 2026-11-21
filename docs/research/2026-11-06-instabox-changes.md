# Instabox changes checked on 2026-11-06

This note updates [the 2026-10-27 note](2026-10-27-instabox-changes.md), which is the baseline.
It covers what changed at instabox since then, the new GitHub Actions feature, and whether the
privacy and security terms now justify trusting agents with more than public code. When the
research was done, no ibx code, timer or other file had been changed, and no authenticated API
route, claim or exec was used; the Impact on ibx section records what changed afterwards. Five sweeps (product and changelog, CI, legal, security, announcements)
each went through an independent verification pass. Claims the verifier found wrong were
dropped, overstated ones are softened below, and claims nobody could check are marked
UNVERIFIED. No credentials or personal identifiers are copied.

The task date is 2026-11-06, but the servers' Date headers read 2026-11-07 around 02:00 UTC, so
timestamps below are UTC as the servers gave them.

## Scope and sources

Primary sources were the [OpenAPI spec](https://api.instabox.sh/v1/openapi.json) (fetched
2026-11-07T01:55Z, public, no auth), [llms-full.txt](https://instabox.sh/llms-full.txt),
[llms.txt](https://instabox.sh/llms.txt), the docs (moved to Mintlify on 2026-11-06, now under
`/docs/reference/*`, `/docs/machines/*`, `/docs/use-cases/*`, `/docs/account/*` and
`/docs/security/*`), [changelog.md](https://instabox.sh/changelog.md),
[blog.md](https://instabox.sh/blog.md) and its posts, and the legal pages
[/privacy](https://instabox.sh/privacy), [/terms](https://instabox.sh/terms) and
[/subprocessors](https://instabox.sh/subprocessors). The legal pages are rendered client-side:
a curl returns the SPA shell, and the text was read from the site bundle
[app.js](https://instabox.sh/assets/5bb05a6db4e67efe/js/app.js). Package metadata came from
`npm view instabox`, `npm view @insforge/instabox-sdk` and
[PyPI](https://pypi.org/pypi/instabox-sdk/json); the GitHub App from the unauthenticated [App
API](https://api.github.com/apps/instabox-cloud); permission semantics from [GitHub's
docs](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps); the
kernel CVE from [cve.org](https://cveawg.mitre.org/api/cve/CVE-2026-98432).

Past versions came from archive.org. The only archived OpenAPI is from
[2026-10-14](https://web.archive.org/web/20261014234551id_/https://api.instabox.sh/v1/openapi.json).
There is no archived llms-full.txt after 2026-10-14, but the SPA fallback archived at
[2026-10-27T16:32Z](https://web.archive.org/web/20261027163202id_/https://instabox.sh/changelog)
embeds that day's llms.txt, and site bundles archived on 2026-10-27
([2beee27ca549ee87](https://web.archive.org/web/20261027162428id_/https://instabox.sh/assets/2beee27ca549ee87/js/app.js),
[abda9e6c27271716](https://web.archive.org/web/20261027171201id_/https://instabox.sh/assets/abda9e6c27271716/js/app.js))
embed the docs and legal text as they were on the baseline day. Archived bundles are
gzip-compressed and must be decompressed before searching. No archive exists for /subprocessors
or docs/ci.md. Some items marked new below may therefore have appeared between 2026-10-14 and
2026-10-27; the text says so where it matters.

The official X account was sampled through the syndication endpoint (four posts confirmed; the
timeline endpoint returned 429). The Discord invite resolves to an "InstaBox" server of about
874 members with an "announcement" channel ([invite
API](https://discord.com/api/v9/invites/instabox?with_counts=true)); its content needs a login
and was not read. Downloaded files were kept as untrusted data in fresh directories under /tmp
and never executed.

## Main changes since 2026-10-27 (ranked)

Ranked by their effect on the ibx pool, then on trust.

1. The free plan now forbids the keepalive pattern. The terms, last updated 2026-11-06, add to
   §2(e) Plan Limits: "On the free plan, Customer may not: ... (ii) generate artificial
   activity, such as scheduled pings, activity leases renewed from outside the Sandbox, or busy
   loops, to keep a Sandbox from pausing after inactivity, or pause and resume a Sandbox to
   reset its maximum runtime." The clause is absent from both bundles archived on 2026-10-27,
   which still carry the 2026-10-22 terms ([/terms](https://instabox.sh/terms), [current
   bundle](https://instabox.sh/assets/5bb05a6db4e67efe/js/app.js)). The `ibx-keepalive` timer
   renews leases from the notebook every 15 minutes so held boxes do not idle-pause, which
   matches the banned pattern literally. Enforcement follows §3(g): stopping or pausing
   sandboxes, blocking network, lowering limits, suspending or terminating the account, and
   InsForge "will tell Customer why". The docs have not caught up: llms-full.txt line 2139
   still says a silently waiting task "keeps its machine awake with a lease ... renewed before
   it expires", and the OpenAPI lease route carries no free-plan caveat. The terms carve out no
   exception for real work. No changelog entry, blog post or sampled X post announces the
   change, and the terms promise only "reasonable notice" (§11(b)).

2. The five-box allowance ends on 2026-12-01 00:00 UTC.
   [Pricing](https://instabox.sh/docs/account/pricing.md) (Questions) says: "Accounts
   registered before 2026-10-20 and activated before 2026-10-25 07:45 UTC got five free
   sandboxes until 2026-12-01 00:00 UTC. After that only one free sandbox runs at a time. The
   others are paused, not deleted, and the one that stays running is the most recently active."
   Affected accounts get an email on 2026-11-26. The end date itself is not new: the
   [2026-10-20 changelog entry](https://instabox.sh/changelog/plans-and-billing.md) already
   said "Accounts activated before October 20 keep five free machines until December 1." The
   baseline and ibx's docs recorded the five-box exception without its expiry. What is new is
   the error [402
   early_allowance_ended](https://instabox.sh/docs/reference/errors.md#early_allowance_ended)
   (not retryable) for starting a second box, the fields `OrgLimits.earlyAllowanceEnded` and
   `Machine.earlyAllowanceEnded`, an `Operation.trigger` value `early_allowance_ended` meaning
   the service itself pauses the extra boxes, the email date, and a changed eligibility wording
   (from "activated before October 20" to the two-date rule above). The same trigger enum also
   adds `payment_method` and `members`, which pause free boxes in a workspace without a card on
   file or with too many members.

3. Max-run on the free plan has new rules.
   [auto-pause.md](https://instabox.sh/docs/machines/auto-pause.md) now documents escalating
   cooldowns: "On the free plan, back-to-back max-run pauses rest longer", 5 to 20 minutes the
   first time, 60 to 75 the second, 120 to 135 from the third on. The count resets when "a run
   ends with no cooldown owed (an idle pause, or you pause or stop the machine)" or when a run
   starts 2 hours or more after the last cooldown ended. The base cooldown is now documented as
   5 minutes plus 0 to 15 random; the baseline's documented value was ten minutes, but it had
   already observed 5-17 minutes live, so only the documentation changed there. The same page
   describes a dynamic runtime: "With dynamic runtime enabled, new free runs start at 120
   minutes... Lease renewals and wake requests do not count as work... Continuous runtime never
   exceeds 480 minutes." Five minutes before the deadline, 5 or more busy minutes in the last
   30 add 2 hours, 1 to 4 add 30 minutes, none adds nothing; if activity collection fails the
   run gets 480 from its start. The page also says "Free machines default to 480 minutes...
   Dynamic runtime, when enabled", and the [CLI
   reference](https://instabox.sh/docs/reference/cli.md#max-run) says "On the free plan the
   value is fixed at 480". Whether dynamic runtime is on for this account is UNVERIFIED;
   reading `Machine.maxRunMinutes` needs an authenticated call. The llms.txt archived on
   2026-10-27 does not mention max-run at all.

4. Exec commands and their output are kept on the server. The OpenAPI `GET
   /v1/machines/{id}/history` says: "Every POST /v1/machines/{id}/exec that reached the sandbox
   (by any account or tool; noHistory requests excepted) is recorded with its exit code and the
   first 64 KiB of each output stream... it is deleted with the sandbox. The server keeps the
   newest 200 commands per sandbox." Entries hold the command text (up to 4096 bytes), cwd,
   status and the userId that ran it. Any key with `machines:write` (or legacy `machines:exec`)
   can read them, also through `instabox history` and `instabox output`.
   `ExecRequest.noHistory` leaves a command out and `historyCommand` replaces the displayed
   text, but any caller can set them, so the history is not tamper-evident; the spec documents
   `noHistory` for "a client's own housekeeping commands". The schema has no env field, so env
   values are probably not stored, but no text guarantees it, and anything a command prints is
   stored. Separately, `/v1/machines/{id}/processes` captures `ps -e -ww ... args` before every
   stop or pause, automatic ones included, keeps that list, and says it "is not in the
   history", so `noHistory` does not cover it: full command lines, including any token passed
   as an argument, stay on the server. The history routes are absent from the 2026-10-14 spec,
   and the cheat sheet in the 2026-10-27 llms.txt has no history or output command. Since pool
   boxes are never deleted, their history is replaced only 200 commands at a time.

5. Automatic abuse checks can lock a box for 24 hours.
   [errors.md](https://instabox.sh/docs/reference/errors.md#machine_cooldown) says
   `machine_cooldown` can mean "an automatic abuse check paused it and locked it for 24 hours",
   with reasons `abuse_egress_blocklist`, `abuse_network_flows` (scanning or attack traffic),
   `abuse_cpu` (mining) and `abuse_proxy`. `Machine.cooldownUntil` says "All wake paths are
   refused until this deadline, including admin actions"; `MachineAbuseLock` gives the reason,
   a description (with exact addresses, such as a blocked destination or repeated connections
   to one port), and an appeal path (`instabox feedback` or support). Whether an appeal lifts a
   lock early is not stated. `abuse_cpu` and `abuse_pool` already existed in the 2026-10-27
   spec; the egress blocklist, network-flow, scan and proxy checks and the 24-hour lock are
   new. Two inconsistencies remain: the `Machine.cooldownReason` and `Error.reason` enums list
   three reasons without `abuse_proxy`, which errors.md and `Operation.trigger` include; and
   auto-pause.md says the lock "can last up to 24 hours". The OpenAPI describes the CPU and
   flow/scan detectors as acting on "a restricted account's sandbox". A lock counts as a
   cooldown for the escalating count. A new `memory_pressure` trigger pauses a box when its
   host runs short of memory; processes are kept and the next use wakes it.

6. The legal text now declares monitoring. On 2026-11-06 the privacy policy gained, in §1
   Machine telemetry, "To detect and prevent abuse and violations of our Terms of Service, we
   use automated and, at times, manual checks of the activity of running machines," and the
   terms gained in §3(g) "To prevent violations of this Section and abuse of the Services,
   InsForge may monitor the use of Sandboxes, including through automated checks." Details are
   in the privacy section below.

7. GitHub Actions jobs can run on instabox boxes (blog
   [2026-10-31](https://instabox.sh/blog/github-actions.md)). See the CI section.

8. Boxes built after 2026-11-01 come with the instabox CLI, skills and MCP preinstalled
   ([changelog](https://instabox.sh/changelog/agent-mcp-skills.md),
   [blog](https://instabox.sh/blog/agent-mcp-skills.md)). Every box on the shared layer
   (agent-browser, universal, t3, herdr, orca, android) gets `/usr/local/bin/instabox`, skills
   in `~/.claude/skills` and `~/.agents/skills`, and the instabox MCP connected. The changelog
   names Claude Code and Codex; the blog adds OpenCode. Documentation tools work without auth;
   action tools need a key, which the blog suggests delivering as a Secret: "Give it an API key
   as a Secret named `INSTABOX_API_KEY`, allowed for `api.instabox.sh`, and the agent can also
   create, run commands on and snapshot your other boxes." The new `instabox agent prompt` runs
   `claude -p` or `codex exec` with "permissions and sandboxing skipped (the machine is the
   boundary)" ([CLI reference](https://instabox.sh/docs/reference/cli.md)). Whether the
   existing pool boxes, created before 2026-11-01, have the kit is UNVERIFIED; it ships with
   template builds, and the OOM docs say older templates need a rebuild for new guest features.

9. Wake-on-use is now documented in detail, though it is not new. The
   [post](https://instabox.sh/blog/wake-on-use.md) is dated 2026-10-26, a day before the
   baseline, which already recorded that the prose docs say exec and public visits wake an
   idle-paused box. New in [auto-pause.md](https://instabox.sh/docs/machines/auto-pause.md) is
   the explicit list ("an HTTP request to the box's public URL, an exec, a file read, an SSH
   connection or opening the box in the dashboard"), a hold of up to 45 seconds, and a
   retryable `409 operation_conflict` if the resume is still running. A box paused or stopped
   by hand does not wake, and its public URLs answer 503. The spec still contradicts itself:
   `POST /exec` says "The sandbox must be running (409 machine_not_running)", while its own
   lifecycle section and `/processes` ("one that paused itself, which wakes as for exec") say
   exec wakes the box. Nothing was tested live.

10. Smaller changes, oldest first. Signed [webhooks](https://instabox.sh/blog/webhooks.md)
    (Standard Webhooks, sandbox.* and snapshot.* events, retries for about 28 hours, 30-day
    log, every plan), [metrics](https://instabox.sh/blog/sandbox-metrics.md) (30-second host
    samples, up to 24 hours, reading them does not wake the box) and paid-plan
    [resize](https://instabox.sh/blog/resize.md) are all dated 2026-10-27, the baseline day, so
    they may predate the baseline snapshot. Usage alerts for paid workspaces (2026-10-31).
    [Android boxes](https://instabox.sh/blog/android.md), free plan included (2026-11-03). The
    Builder plan at US$100 a month (2026-11-03). Higher paid limits
    ([2026-11-04](https://instabox.sh/blog/plan-limits.md)). Alipay (changelog 2026-11-04, blog
    2026-11-05). The Python SDK `instabox-sdk` (first upload 2026-11-04T22:50Z, 0.4.0 on
    2026-11-06T07:28Z, Python 3.9-3.13). [Mintlify
    docs](https://instabox.sh/blog/mintlify-docs.md) (2026-11-06); old paths redirect, for
    example `/docs/cli` and `/docs/sdk` resolve to `/docs/reference/*` and `/docs/ci.md` to
    `/docs/use-cases/ci.md` (307 and 308 were both observed). CI, Android, resize and the
    plan-limit increase have no changelog entry; their dates rest on the blog.

Other API changes. Against the 2026-10-14 spec, paths went from 90 to 129. New are six org
webhook routes plus the `/v1/github/webhook` and `/v1/stripe/webhook` receivers, five GitHub CI
routes, `/history`, `/restore`, `/oom/claim`, `/disk`, `/processes`, `/access`,
`/files/upload-url`, `/logs`, exports, agent auth (`/v1/auth/agent*`), support tickets,
feedback, and org billing, member, invite and key routes. `/v1/admin/*` left the path list but
`info.description` still calls it admin-only. `ExecRequest` gained `argv`, `noHistory`,
`historyCommand` and `secretEnvs`; `ExecResult` gained `oomKill`, `oomKilled`, `invalidUtf8`
and `diskWarning`. `Machine` gained `abuseLock`, `cooldownReason`, `maxRunMinutes`,
`earlyAllowanceEnded`, `oomKills`, `lastOom`, `guestUser`, `envNames`, `readyAt`, `deleteAt`,
`free` and `orgId`, and lost `timeoutAt`, `onTimeout` (the lifetime timeout was retired on
2026-10-20) and `forkedFrom`. Some of these (`runStartedAt`, `cooldownUntil`, files/content,
Secrets, `invalidUtf8`, `diskWarning`) the baseline already used, so the 10-14 comparison
overstates what is new since 10-27. API key scopes did not change. OOM reporting
(`ExecResult.oomKilled`, `Machine.oomKills`) applies from the first control release after
2026-10-29.2; "A machine whose host or template predates it reports none (oomKills: 0,
oomKilled: false): its template needs a rebuild"
([llms-full.txt](https://instabox.sh/llms-full.txt) lines 2395-2405), so zero is not proof of
no kill. `X-Confirm-Delete` existed on 10-27 as an optional header; it is now required only for
machine deletes made with API keys created after the rollout, otherwise `409
delete_confirmation_required`. The create field `deleteAfterSeconds` (60-86400) is in CLI
0.8.0, published 2026-10-27T20:13Z, after the baseline snapshot. The legacy Vault is announced
for retirement, still supported, and `vault_retired` is reserved but not sent.

Current free limits ([limits.md](https://instabox.sh/docs/account/limits.md)): 1 machine in any
state (paused and stopped count) beyond the early allowance, 4 vCPU and 8 GiB only, 20 GiB
disk, 5 snapshots, 200 GiB stored, 100 GiB egress a month, 3 starts a minute ("| Starts /
minute | 3 | 30 | 50 | 100 | 100 |"; create, start, resume and wake all count, above it `429
rate_limited` retryable), 3 members, idle pause fixed at 1800 seconds, and 32 concurrent exec
requests per user. The free plan now creates only from `agent-browser`, `android` or `ci` (403
`template_not_allowed` otherwise); on 2026-10-27 it was agent-browser only. Upload from the VM
is capped around 50 Mbit/s. Whether 3 starts a minute already applied on 10-27 is UNVERIFIED.
`OrgLimits.freeSandboxHours` is still "0: no cap" unless set, `credit_exhausted` now reads "The
account's free machine used its hours for the month", and no public page gives the number of
hours.

Versions. The npm CLI `instabox` went from 0.7.1 (2026-10-25) at the baseline to 0.8.0
(2026-10-27T20:13Z) and 0.8.201 (2026-11-07T02:09:26Z), 202 releases since 2026-10-27, with
`latest` and `staging` on the same version, published from GitHub Actions through npm OIDC. The
TypeScript SDK `@insforge/instabox-sdk` (same name as at the baseline) went from 0.5.3 to 0.6.0
(2026-11-01), 0.7.0 and 0.7.1 (2026-11-06T17:31Z). Both npm packages and the PyPI package point
to `github.com/InsForge/instabox`, which answers 404: none of the client code has public
source.

Several things look new but are not. The December end date was announced on 2026-10-20. The
wake-on-use post is from 2026-10-26. The legal pages first appeared on 2026-10-21 (privacy) and
2026-10-22 (terms) and were live on the baseline day. Env-delivered Secrets readable inside the
VM, and the ability of any `machines:write` key to put them there, already existed on
2026-10-27. The SSH token being sealed and returned to its maker in a sign-in session appeared
between 2026-10-14 and 2026-10-27. `abuse_cpu` and `abuse_pool` were in the 2026-10-27 spec.

## CI

The blog announced instabox CI on [2026-10-31](https://instabox.sh/blog/github-actions.md); an
X post followed on 2026-10-30 UTC. The GitHub App `instabox-cloud` was created
2026-10-27T17:37Z and updated 2026-10-28T17:10Z ([App
API](https://api.github.com/apps/instabox-cloud)). CLI 0.8.0 has no CI strings, so the
`instabox ci` command came in a later 0.8.x. The changelog has no CI entry.

There are two modes ([ci.md](https://instabox.sh/docs/use-cases/ci.md)). With the GitHub App
and `runs-on: instabox-<size>`, each job runs on its own fresh box and uses no GitHub Actions
minutes. Without the App, any CI can run `instabox run --push . --timeout 10m` with an instabox
API key stored as a CI secret; that runner still spends CI minutes and the command runs at most
10 minutes. In App mode, GitHub sends `workflow_job` webhooks to `POST /v1/github/webhook`. The
spec says "`queued` records the job once per job ID and, in the background, creates a CI box
for it (template `ci`, the label's size, deleted after 6 hours at most) with a just-in-time
runner that takes that job only; `completed` deletes the box. A start over the plan's limits
waits and is retried." If GitHub drops the runner but still reports the job, the box is deleted
after 5 minutes (`runner_gone_timeout`). A job can be handed a box created for another waiting
job, but each box runs one job. The `ci` template is Ubuntu 24.04 built from runner-images
`ubuntu24/20261026.354`, with a 50 GiB root, on Linux 6.18.60 amd64 in a Firecracker microVM.
Haskell, Swift, Julia, CodeQL, Edge and Homebrew are left out. There is no macOS and no arm64.

The free plan gets `instabox-medium` (4 vCPU, 8 GiB) only. The launch post listed small, medium
and large; the docs now add xlarge (Builder, Team) and 2xlarge (Team). "A job's box counts and
bills like any other box on your plan", so on the free plan a CI job takes the single sandbox
slot. With five pool boxes present, jobs would presumably sit in `waiting`; that is inference,
UNVERIFIED. So is whether personal-account installs are enabled at all: the spec lists
"personal accounts off on the site" as a refusal reason. Snapshot labels
(`instabox-<size>-snapshot-<name>`) are refused in public repositories and in repositories that
run fork-PR workflows, and the docs warn: "Keep secrets out of the snapshot: no tokens, SSH
keys, or `.env` files. Any workflow on a branch of a linked repository can name it. Jobs get
secrets from GitHub Actions as usual." Plain size labels carry no such restriction in the docs.

The CI routes (`/v1/orgs/{id}/github/installations`, `/jobs`, `/jobs/{job}`, `/stats`) refuse
API keys with 403 and need a signed-in session ([llms.txt](https://instabox.sh/llms.txt)), so
ibx cannot read CI state with its key. `instabox ci [--org O] [--json]` lists recent jobs. The
CLI binary also carries an admin-only `--ci-runners job|pool` flag, so a per-repository
runner-pool mode exists but users cannot select it.

What the App can do differs from what the docs say it does. The docs list Metadata read,
Actions read, Administration read and write ("Registering and deleting each job's runner") and
Members read, and say "The App asks for nothing on your code". The public App metadata also
shows `organization_self_hosted_runners: write`, which the docs table omits, and subscribes
only to `workflow_job`. Its GitHub description ("Wakes your paused InstaBox GitHub Actions
runner") may describe the pool mode rather than a retired design. Per [GitHub's permission
table](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps),
repository Administration write lets an installation token delete the repository, change its
visibility and settings, add collaborators and deploy keys, and change branch protection,
rulesets and Actions settings; deploy keys or collaborators would give code access. Actions
read alone lets it download job logs and artifacts. So "nothing on your code" and "The log
stays on GitHub" are policy statements, not technical limits. More directly, the job runs on an
InsForge-operated VM, so the checkout, every secret the workflow references and the job's
`GITHUB_TOKEN` are present on instabox infrastructure for the job's lifetime. GitHub is now
listed as a sub-processor for "GitHub Actions runner registration and repository integration".
Job metadata (repo, workflow, labels, actor, branch, commit, failed step, timings) has no
CI-specific retention period; the privacy policy's general "Agent, API, and CLI activity logs:
Retained for up to 12 months" probably covers it.

On isolation, GitHub's own [hardening
guide](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners)
says self-hosted runners "should almost never be used for public repositories", but the risk it
names is a persistent runner that can be compromised, and it recommends just-in-time runners
that do one job. A fresh VM per job with a one-job JIT runner removes that main concern. What
remains for a public repo is fork-PR code using the org's sandbox slot, egress and possibly
triggering an abuse lock (UNVERIFIED), and the claim that the host is clean between jobs, which
only instabox can vouch for.

For ibx, CI is not a substitute for claim/exec/release. It is triggered only by GitHub events,
lives for one job, has no agents or desktop, cannot be targeted by ibx exec, and exposes state
only to signed-in sessions. It does not help ibx's own CI either: the workflow runs on
`ubuntu-latest` and `macos-latest`, the macOS leg uses canned exec results so put/get are
skipped there, instabox offers no macOS, and the ibx repository is public and already gets free
Ubuntu runners. The CLI mode would need an org-wide instabox key stored as a GitHub secret; a
key reaches every box in its workspace, so a `machines:write` key could touch the pool, and the
user's rules keep the instabox key out of anything but a 600 file.

## Privacy policy and terms

InstaBox is operated by InsForge AI, Inc., a Delaware corporation
([terms](https://instabox.sh/terms), lead paragraph). The X account's "YC P26" description
could not be read and is UNVERIFIED.

History. Seven site bundles archived between 2026-10-13 and 2026-10-18 (for example
[4c7de785f6bcff7e](https://web.archive.org/web/20261013052156id_/https://instabox.sh/assets/4c7de785f6bcff7e/js/app.js)
and
[eedc2d4168ef2b84](https://web.archive.org/web/20261018073611id_/https://instabox.sh/assets/eedc2d4168ef2b84/js/app.js))
have no `/privacy` or `/terms` route. The first versions appear in the [2026-10-23
bundle](https://web.archive.org/web/20261023073025id_/https://instabox.sh/assets/4770deb9c3b6b169/js/app.js):
privacy "Last updated October 21, 2026", terms "October 22, 2026". Those were live on the
baseline day
([privacy](https://web.archive.org/web/20261027163542/https://instabox.sh/privacy),
[terms](https://web.archive.org/web/20261027163432/https://instabox.sh/terms) as archived on
2026-10-27). Today /privacy, /terms and the new /subprocessors all read "Last updated: November
6, 2026"; the bundle's route table has exactly those three pages. /dpa, /security, /trust,
/cookies, /acceptable-use, /aup and /legal answer 307 to the homepage, and
`/.well-known/security.txt` and `/privacy.md` return 404. The cookie policy lives in privacy §4
and the acceptable-use policy in terms §3.

What changed on 2026-11-06. A full text diff of the 2026-10-21/22 versions against today's
finds four substantive changes, and none is protective:

- Privacy §1 Machine telemetry adds "we use automated and, at times, manual checks of the
  activity of running machines" (quoted in full above). The old text already listed abuse
  detection as a purpose of telemetry; what is new is explicit monitoring and the word
  "manual". Nothing says what a manual check can see.
- Privacy §2 changes the provider list: WorkOS is added, GitHub's role grows from single
  sign-on to "GitHub Actions runner registration and repository integration, and single
  sign-on", and it links the new page.
- Terms §2(e) adds the free-plan paragraph: the keepalive ban quoted above, and in (i) a ban on
  running "a proxy or VPN server, or any other relay, that carries web browsing or other
  general internet traffic through a Sandbox", while "A tunnel that only lets Customer reach
  its own Sandbox or the apps running in it is not a relay", so `ibx forward` is fine. The old
  terms banned only open proxies, public VPN exits and relays of third parties' traffic, so
  this is a new restriction on the free plan, not a new permission on paid plans.
- Terms §3(g) adds "InsForge may monitor the use of Sandboxes, including through automated
  checks." The rest of §3(g), including immediate action without notice for mining, scanning,
  phishing, fraud and CSAM, was already there.

The new [/subprocessors](https://instabox.sh/subprocessors) page lists Amazon Web Services
("Compute, storage, and database hosting (us-west-2)"), GitHub, Vercel, Stripe, WorkOS, PostHog
and Loops, and says "When we engage a new sub-processor or stop using one, we update this page
and the “Last updated” date at its top." There is no advance notice and no right to object;
under terms §7(c) the customer simply authorizes sub-processors, and §7(c) still says the list
is kept "through its Trust Center" rather than on this page. The list was incomplete on its
first day: Google is still named in privacy §2 for single sign-on but missing from the page,
and Mintlify, which has served instabox.sh/docs since 2026-11-06 (response header
`x-mintlify-client-version`), is not listed.

Notice. Privacy §10 says "We will notify you of material changes ... at least 30 days before
they take effect." The pages carry no effective date, only "Last updated". If InsForge counts
the manual-checks sentence as material, it would arguably not apply before about 2026-12-06;
that is a reading of the text, not something InsForge has said. Whether any email went out is
UNVERIFIED. The terms change, including the keepalive ban, carries only "reasonable notice".

What did not change since the baseline. These were all in the 2026-10-21/22 text, so they are
not improvements since 2026-10-27, though they are what makes the terms more than empty:

- Role: InsForge is controller for account data and "primarily" processor for Customer Data.
  "We process Customer Data primarily as a processor, on behalf of and under the instructions
  of the relevant customer, in accordance with our Terms of Service. This Privacy Policy does
  not apply to our processing of Customer Data in that capacity." Customer Data covers the
  files, disks, snapshots and Secrets of sandboxes (terms §1(d)).
- No training and no sale: "We do not sell your personal information, and we do not share it
  with third parties for their own direct marketing purposes. We do not use Customer Data to
  train machine learning models." Terms §1(b), (d) and (f) exclude "Aggregated Data", derived
  from Customer Data in aggregate, anonymized form, from Customer Data and make it InsForge's,
  so the promise does not cover it. Traffic the boxes send to AI providers is governed by the
  customer's agreements with those providers.
- Confidentiality (terms §7(a)): "InsForge will treat Customer Data as Customer’s confidential
  information and will not access, use, or disclose it except as necessary to provide the
  Services, as permitted by this Agreement, or as required by law." With §3(g) now permitting
  monitoring, "as permitted by this Agreement" covers more than before.
- Collection: account and SSO data, key, CLI session and SSH credential metadata, payments via
  Stripe, support and feedback, device and usage data, and "metadata about the requests your
  agents and clients make — the operations invoked, the machines affected, timing, quotas
  consumed, and errors returned". CLI telemetry records flag names, not values, and is disabled
  by `INSTABOX_NO_TELEMETRY=1` or `DO_NOT_TRACK=1`. Machine telemetry covers CPU, memory, disk
  and network usage. The policy does not list exec text, exec output, file contents or proxied
  request contents as collected, yet the exec history above stores the first two.
- Retention (§5): "Machines, snapshots, and agent-generated data: Retained until you delete
  them, or for the duration of your account. Upon account deletion they are deleted from our
  active systems within 30 days. Backup copies may persist for up to 90 days before being
  overwritten." Activity logs up to 12 months, usage and analytics up to 24 months, payment
  records about 7 years, support and feedback 24 months after resolution, contact info 60 days
  after closure, all subject to legal hold. Deletion requests (§6) are acknowledged within 5
  business days and completed within 30 days of verification, up to 90 for complex cases.
  Feedback sent with `instabox feedback` "is not Customer’s confidential information" (terms
  §6(d)).
- Hosting (§12): "the machines you create, their disks and snapshots, your secrets, and the
  systems that hold your account and workspace information and meter usage are in the Amazon
  Web Services US West (Oregon) region." Terms §7(d) says only "stored and processed in the
  United States". The [pricing post](https://instabox.sh/blog/instabox-pricing.md) of
  2026-10-19 says "We run on our own bare metal", so the physical hosting model is described
  inconsistently. Backup location is not stated.
- Transfers and rights: GDPR, UK and Swiss rights and SCCs for EEA, UK and Swiss transfers;
  CCPA and Nevada. LGPD, Brazil and Brasil have zero hits in the whole bundle. Privacy §12's
  "data processing agreements" bullet refers to agreements with InsForge's own sub-processors.
  No customer DPA exists for InstaBox; [insforge.dev/dpa](https://insforge.dev/dpa) (last
  modified 2026-06-20) names InsForge, Inc. and the "InsForge Platform and Services" and never
  mentions InstaBox.
- Breach notice (terms §7(f)): "InsForge will notify Customer without undue delay after
  becoming aware of a confirmed breach of security leading to the unauthorized disclosure of,
  or access to, Customer Data." Privacy §7 cites GDPR's 72 hours for authorities.
- Law and liability: Delaware law, mandatory individual AAA arbitration with a 30-day opt-out
  by email, class-action and jury waivers (§10), service "AS IS" with no promise "THAT A
  SANDBOX OR ITS DATA WILL NOT BE LOST", and liability capped at "THE TOTAL AMOUNTS PAID OR
  PAYABLE BY CUSTOMER TO INSFORGE IN THE TWELVE (12) MONTHS PRECEDING THE EVENT" (§8), which is
  nothing on the free plan. Terms §2(d) treats activity done with a valid credential as the
  customer's and makes the customer responsible for limiting the credentials and Secrets each
  agent can use.

Verdict: the privacy and security terms did not improve on 2026-11-06. The useful promises
predate the baseline, and the day's changes added monitoring, a manual-inspection allowance and
free-plan restrictions.

## Security and isolation

Isolation. Each box is a Firecracker microVM with its own kernel, Debian 13 (Ubuntu 24.04 for
`ci`), with no `/dev/kvm`, kprobes, ftrace or BTF in the guest and unprivileged BPF off
([llms-full.txt](https://instabox.sh/llms-full.txt) lines 1439 and 2316; the Android post says
boxes are "separated from every other box by the CPU's virtualization"). Privacy §7 says "Each
machine is a virtual machine of its own, with its own kernel, isolated from other customers".
None of this is new, and nothing public describes the jailer, host hardening, SMT or
side-channel mitigation. Privacy §7 also self-declares RBAC and MFA for internal systems,
"Audit logging and monitoring of access to personal information", encryption in transit and at
rest, and "Regular security assessments and vulnerability scanning"; these are unverifiable and
none of them is visible to the customer. At-rest encryption has no detail about KMS, per-tenant
or customer-held keys, and the server holds what it needs to decrypt Secrets.

Kernel. The guest kernel went from 6.18.54 (2026-10-27 bundle) to 6.18.60. The docs give
[CVE-2026-98432](https://cveawg.mitre.org/api/cve/CVE-2026-98432) as the example fix; cve.org
lists it, published 2026-10-15 by the Linux CNA, "ipv4: free inet_opt and ireq_opt after an RCU
grace period", fixed for 6.18 in 6.18.56. It is a guest network-stack use-after-free, not a VM
escape, so it does not weaken isolation between customers. A machine picks up a patched kernel
only "from its next **cold boot** ... **Pause and resume** is not a cold boot: resume brings
back the machine's memory, the old kernel included" (llms-full.txt lines 389-399). Pool boxes
that only pause and resume keep the old kernel until a restart. Android boxes have a pinned
kernel and must be recreated.

Monitoring by the provider. Beyond the declared "manual checks", the documented abuse detectors
watch network flow metadata (destinations, port sweeps, multi-port scans, login brute force)
and CPU, and identify "the mining program and its pool" when they confirm mining. No document
describes content inspection, and none rules it out. The exec history keeps command text and up
to 64 KiB of each output stream; the `/processes` capture keeps full command lines at every
pause. `Operation.trigger` includes `admin`, `admin_delete` and `drain`, so operators can stop,
pause and delete boxes. The instabox SSH gateway terminates SSH, so the provider sees sessions
in cleartext (not new). Paused memory is written to disk and object storage (baseline). The
OpenAPI says HOME lives in `/data/home` and "credentials kept there (gh, Claude, Codex, git,
SSH) are included in new snapshots". Exports (`/v1/orgs/{id}/exports`,
`/v1/exports/{id}/download`) build a .tar.gz of a box's `/data`, but only while the workspace
is disabled; they are new since 2026-10-27.

Customer-visible trail. There is still no audit-log route in the public spec, and audit logs
are an Enterprise feature (already so on 2026-10-27). The exec history is a partial trail: each
entry records the account that ran it, for execs "by any account or tool". It misses execs sent
with `noHistory`, SSH sessions, file API reads, the guest agent and anything done from the
host.

Secrets. The egress proxy still does TLS interception for enrolled boxes: "The proxy intercepts
all supported HTTPS hosts, even without a placeholder. Clients must trust the sandbox CA and
cannot pin certificates" ([secrets.md](https://instabox.sh/docs/security/secrets.md)). New
since 10-27: WebSockets pass (previously unsupported), HTTP/3 is noted as bypassing the proxy
and Alt-Svc is stripped, `--ai` scopes provider keys to the provider's host, per-box proxied
and denied counts exist on servers that enable them, file delivery puts direct Secrets in
`/run/instabox/secrets/files` (tmpfs, 0600, symlinked from HOME) and out of snapshots until a
tool rewrites its login file to disk, `secretEnvs` injects env Secrets for a single exec, and
each direct reference is audited by name. The blog's [Secrets
post](https://instabox.sh/blog/secrets.md) says a compromised sandbox gets only a placeholder
("Even if it's fully compromised, that's all an attacker gets"), while the docs say "With `*`,
any process in an enrolled sandbox can send the Secret to any public HTTPS destination,
including a host it controls", and that a direct Secret "puts the real value in the box: any
code there, including an agent or a package it installs, can read and copy it." The
`secretEnvs` promise "Resolved at exec time, never stored or written into the sandbox" is about
persistence: the value is still in the process environment inside the VM while the command
runs. Whether a box created with `--secrets none` stays outside interception is not stated;
omitting `secrets` does not enroll a box, `--secrets none` blocks a box from all Secrets, and
dashboard boxes get all proxy Secrets by default once Secrets is on. The legacy Vault is slated
for retirement.

Ports, desktop, agents. Private ports are new: they answer only requests carrying an `ibp_`
token (cookie or Bearer), the server keeps only its hash, and requests without it get 401 and
do not wake the box. The default is still public, the URL is not a secret, guest code can still
publish ports through the local port-agent credential with `instabox-port publish` (public by
default), and raw TCP ports (admin preview) are always public. Desktop links can now be created
and revoked only by the machine's creator (workspace keys get 403); server-side view-only and
"Expiry stops new connections" were already documented. Agent sign-up lets an agent request a
key that the owner approves with a code; its default scopes are `machines:read`,
`machines:write`, `machines:delete` and `images:read`. With the CLI now preinstalled in boxes,
code in a box can run `instabox login --agent` and ask the owner to approve a delete-capable
key.

Supply chain. The CLI preinstalled in boxes and installed with `npx instabox@latest` had 202
releases in about ten days, with no public source. That cadence is a reason to pin versions
where ibx or the user installs it.

Attestations and contacts. Privacy, terms and /subprocessors link a [Vanta Trust
Center](https://app.vanta.com/insforge.dev/trust/9dxtxcntvvv5ow2tx7e4dm), already linked on
10-27. It is client-rendered; one sweep rendered it with headless Chromium in a disposable
profile and found only HIPAA under Compliance ("InsForge maintains controls aligned to the
HIPAA Security Rule as a Business Associate, monitored continuously. Business Associate
Agreements available on request."), describing the InsForge backend product rather than
InstaBox, with no third-party attestation. That render was not repeated independently, so treat
it as likely. The only SOC 2 statement found is in the insforge.dev DPA §12, "InsForge
maintains a SOC 2 compliance program.", which claims a program, not a report, from a
differently named entity. No source mentions ISO 27001, a pentest or a bug bounty. Terms §3(b)
says "Testing the Services themselves requires InsForge’s prior written permission;
vulnerabilities in the Services can be reported to support@instabox.sh", so there is no safe
harbor, while insforge.dev's security.txt names a different address and instabox.sh has no
security.txt. There is no status page: `status.instabox.sh` does not resolve and no incident
post exists in the changelog, blog or sampled X posts. A third-party forum thread from
2026-11-07 about blocked accounts was not opened and is not evidence.

## What this means for running agents there

The user's current rule is that credentials, logged-in sessions and personal data never go to
the ibx boxes, that company (AM) code goes there only when the user asks in the conversation
(via `git archive`), and that public, secret-free work goes there by default. The evidence does
not justify relaxing any of it. The 2026-11-06 changes point the other way.

Public code. Still a good fit: a Firecracker VM per box, a disposable environment, and a
provider whose stated monitoring targets abuse. Caveats are new. Commands and the first 64 KiB
of their output stay on the server until the box is deleted, which matters only if output
contains something sensitive. Heavy network fan-out, scanning-like test suites or crypto-like
CPU loads can trigger a 24-hour lock. Pool boxes that only pause and resume run an older guest
kernel until a restart. And the keepalive timer is now against the free-plan terms.

Private company code. Keep the current rule. Nothing technical changed in the provider's reach:
it is root-equivalent through the guest agent, file API and SSH gateway, keeps exec text and
output and process command lines, writes paused memory to storage, and now declares "at times,
manual checks of the activity of running machines". Protection is contractual only (terms
§7(a)), with no customer-held keys, no access log for non-exec access on the free plan, no
independent attestation, US hosting, and liability capped at fees paid. `server-ts`, `t3` and
the thinkcentre remain the right places.

Credentials and logged-in sessions. No. Proxy Secrets are a better design than env delivery,
and `--ai` scoping helps, but the proxy decrypts TLS, code in the box can use an injected
credential against allowed hosts (and exfiltrate it with `*`), direct Secrets put real values
in the box, and the server holds decryption keys. HOME, with any gh, Claude, Codex, git or SSH
credentials in it, goes into snapshots. Exec history would keep any token printed or passed on
a command line, and the `/processes` capture keeps command lines regardless of `noHistory`. The
pool should stay at `--no-vault --secrets none` with an org that has no Secrets, and no agent
in a box should get `INSTABOX_API_KEY`.

Personal data (LGPD). No. Data sits in AWS us-west-2 in the US; there is no customer DPA, no
LGPD mention, no SCC-equivalent for Brazil-to-US transfers, a declared manual inspection
allowance, exec output retention, backups up to 90 days, and only a self-attested HIPAA
alignment. Nothing here supports an international transfer under LGPD art. 33 or processor
guarantees for leads' and students' data.

## Impact on ibx

The list below was written as proposals on 2026-11-06. What the branch
`fix/instabox-november-terms` implemented, and the decisions taken:

- The user's `ibx-keepalive` timer was disabled on 2026-11-06. ibx no longer sets or renews a
  lease on a free box (`Machine.free`): `ibx keepalive` skips it, citing Terms §2(e), and
  `ibx claim` sets no lease there. Doctor fails when a timer is installed and a pool box is
  free; `install.sh --keepalive` still installs, with a paid-plans-only warning. No exception
  was sought from instabox, and nothing renews leases from inside the box.
- `402 early_allowance_ended` maps to a new error code, `free_limit`. It refuses only free
  boxes, so after one refusal claim skips the other free boxes that are not running (and any
  marked `Machine.earlyAllowanceEnded`), still tries paid ones, and exits 75 when none is left;
  doctor shows `earlyAllowanceEnded` and `freeSandboxes`.
- `429 rate_limited` on start, resume and wake is waited out within the existing budget; exec
  is never retried.
- `cooldownReason` values starting with `abuse_` fail at once as `abuse_lock`, with the lock's
  explanation and appeal; claim, ls, keepalive and doctor show the lock.
- Every exec ibx composes for itself sends `noHistory`; `ibx run` and `ibx exec --tail` send
  `historyCommand` with the user's command; a plain `ibx exec` sends neither. Exec warns on `oomKilled` and never treats its absence as proof.
- Nothing pauses and resumes a box to reset max-run.
- The README, the skill and its references carry the free-plan rules, the cooldown table, the
  2026-12-01 limit, exec history and monitoring, the preinstalled toolkit rules, and the
  `/docs/reference/*` links. CHANGELOG.md has an Unreleased entry; no version was bumped.
- CI stays on GitHub-hosted runners. The instabox runner is Linux-only (no macOS leg), the
  GitHub App asks for Administration write, and on the free plan a CI job competes with the
  pool for the only running slot.
- Left open: the pool-model decision for 2026-12-01 (one runnable free box, a paid plan, or
  retiring the pool) is the user's. Showing `uname -r` in doctor was not in this branch's
  scope. A wake's `409 operation_conflict` was already handled when ibx made the start,
  resume or wake itself. An exec or file transfer refused with `operation_conflict` (the
  45-second hold ran out, or another operation is active) now waits for the operation the
  error names, then until the box runs, and sends the request again (nothing had started); `ibx run` and `ibx job` say
  nothing started.

The original proposals follow.

- Keepalive and the new terms. The `ibx-keepalive` timer and `ibx keepalive` match "activity
  leases renewed from outside the Sandbox ... to keep a Sandbox from pausing after inactivity".
  This is the user's decision. The options are to stop the timer on the free plan and accept
  idle pauses (wake-on-use brings a self-paused box back on the next exec or file read), to ask
  instabox how the clause applies to leases held for real detached work, or to move the pool to
  a paid plan. Engineering around the clause, for example by renewing leases from inside the
  box, is not advisable. docs/keepalive.md and the INSTABOX.md rule that describes the timer
  would need updating whichever way the user decides, and the docs-versus-terms conflict should
  be written down.
- 2026-12-01. After the cutoff only one free box runs; the service pauses the others itself,
  and starting another returns `402 early_allowance_ended`. ibx maps every 402 to
  `account_blocked` and stops claim. It should recognize this code separately and say that
  another box must be paused first, doctor should show `earlyAllowanceEnded`, and api-notes.md
  and field-notes.md should give the expiry date of the "grandfathered" five-box limit. The
  pool model (five boxes, up to three per agent) stops working on the free plan; the user needs
  to decide between one runnable box, a paid plan, or retiring the pool idea before 2026-11-26,
  when the email arrives.
- Max-run and cooldowns. keepalive.md still says 480 minutes and a ten-minute default. It
  should carry the escalating cooldown table, the reset rules and the dynamic-runtime caveat,
  and doctor or status could show `maxRunMinutes` and `cooldownReason`. Claim already avoids
  boxes in cooldown; the 60 to 135 minute second and third cooldowns make that more important.
  A manual pause before the deadline avoids the cooldown, but the terms forbid pausing and
  resuming to reset max runtime, so this should not become an automatic trick.
- Abuse locks. Treat `cooldownReason` values starting with `abuse_` as a 24-hour skip and
  surface `abuseLock` text in doctor, without retrying.
- Rate limit. The free plan allows 3 starts a minute, and wakes count. The baseline left out
  `rate_limited` handling as speculative; it is now documented and retryable, so claim walking
  several paused boxes should handle it.
- Exec history. Decide whether ibx sends `noHistory` for its own housekeeping commands, the use
  the spec names. Document in the trust model that user commands and their output are kept
  server-side (200 per box, until deletion) and that process command lines are captured at
  every pause whatever ibx sends.
- Wake-on-use. Handle a retryable `409 operation_conflict` during the 45-second wake hold. The
  mock's `409 machine_not_running` remains valid because the spec still says it.
- OOM. Report `oomKilled` when present, but never treat `0` or `false` as proof, since boxes
  from older templates report nothing until rebuilt.
- Kernel. Pool boxes that never cold-boot keep the old guest kernel; a restart picks up
  6.18.60. Doctor could show `uname -r`.
- Preinstalled toolkit. Boxes created or rebuilt after 2026-11-01 carry provider skills in
  `~/.claude/skills` and `~/.agents/skills` and an MCP config. The ibx skill should tell agents
  to treat these as data, never to give a box an instabox key, and never to ask the user to
  approve an `instabox login --agent` code that originated in a box.
- Recreating boxes. The free plan can create only from `agent-browser`, `android` or `ci`.
  `X-Confirm-Delete` matters only if ibx ever deletes, which it does not. `deleteAfterSeconds`
  would suit one-off boxes on a paid plan; on the free plan every extra box competes for the
  single slot.
- Docs links. Links to `/docs/cli` and `/docs/sdk` still resolve through redirects to
  `/docs/reference/*`; update them when the docs are next touched.
- CI. Do not move ibx's CI to instabox: it cannot replace the macOS leg, the Linux leg is
  already free, the App's Administration write is broad, and on the free plan a CI job would
  compete with the pool for the only slot. A reasonable later experiment would be a private
  repository on a separate workspace, with no instabox key stored in GitHub.

## Open questions

- Whether `ibx keepalive` counts as banned "artificial activity" when a reserved box holds real
  detached work; the terms make no exception and the docs still recommend leases. Only instabox
  can answer.
- Whether dynamic runtime is enabled for this account; reading `Machine.maxRunMinutes` needs an
  authenticated call.
- Whether exec actually wakes an idle-paused box or returns `409 machine_not_running`; not
  tested live.
- Whether boxes created with `--secrets none` are outside the TLS-intercepting proxy, and
  whether they carry the sandbox CA.
- Whether `noHistory` prevents any server-side record or only hides the command from
  `/history`.
- Whether the existing pool boxes received the agent toolkit and OOM support, or need a
  rebuild.
- Whether a free CI job waits indefinitely while the pool holds the slots, whether
  personal-account installs are enabled, and whether plain-label jobs from fork PRs in public
  repositories are accepted.
- Whether customers were notified of the 2026-11-06 legal changes, and when they take effect.
- What the Trust Center's restricted documents contain, and whether any SOC 2 or ISO 27001
  report covers InstaBox.
- The number of free hours a month (`freeSandboxHours`), the processing regions of PostHog and
  Loops, and where backups are stored.
- Why the GitHub App holds `organization_self_hosted_runners: write` when the docs table omits
  it.
- Whether the abuse-lock appeal can lift a lock early, and why `abuse_proxy` is missing from
  two of the spec's enums.
- Whether instabox runs on AWS or on its own bare metal, given the conflicting statements.
